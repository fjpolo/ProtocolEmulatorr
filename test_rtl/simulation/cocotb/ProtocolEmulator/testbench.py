# =============================================================================
# File        : testbench.py
# Description : Self-checking Cocotb testbench for Task 03: Input Shift Register
#               (ISR), mid-bit deserialization (IN), edge wait (WAIT), and
#               full-duplex UART Echo Transceiver.
# Tests       : Reset behavior, single-byte echo, string stream loopback,
#               baud-rate tolerance (skew margin), and zero-jitter echo timing.
# =============================================================================

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles, Timer
from cocotb.utils import get_sim_time

BAUD_RATE = 115200
CLK_FREQ_HZ = 50_000_000
CLK_PERIOD_NS = 20  # 50 MHz = 20 ns period
CYCLES_PER_BIT = 434


def start_clock(signal, period_ns=CLK_PERIOD_NS):
    """Starts a clock generator compatible with Cocotb 1.x and 2.x."""
    try:
        clk = Clock(signal, period_ns, unit="ns")
    except TypeError:
        clk = Clock(signal, period_ns, units="ns")
    return cocotb.start_soon(clk.start())


async def reset_dut(dut):
    """Applies active-low reset to ProtocolEmulator with idle high RX."""
    dut.i_reset_n.value = 0
    dut.i_rx.value = 1  # UART line idles high
    dut.i_data.value = 0
    dut.i_prog_en.value = 0
    dut.i_prog_we.value = 0
    dut.i_prog_addr.value = 0
    dut.i_prog_data.value = 0
    dut.i_baud_div.value  = 433   # Default: 115200 baud @ 50 MHz
    dut.i_gpio.value      = 0xFF  # All GPIO lines idle high (external pull-ups)
    await ClockCycles(dut.i_clk, 5)
    await RisingEdge(dut.i_clk)
    dut.i_reset_n.value = 1
    await RisingEdge(dut.i_clk)


class UARTTransmitter:
    """Cycle-accurate UART transmitter to drive stimulus into DUT i_rx."""

    def __init__(self, dut, clk_signal, rx_pin_signal, cycles_per_bit=CYCLES_PER_BIT):
        self.dut = dut
        self.clk = clk_signal
        self.rx_pin = rx_pin_signal
        self.cycles_per_bit = cycles_per_bit

    async def transmit_byte(self, byte_val, cycles_per_bit=None):
        """Transmits one 8N1 UART frame into rx_pin (Start=0, 8 data bits LSB-first, Stop=1)."""
        cpb = cycles_per_bit if cycles_per_bit is not None else self.cycles_per_bit

        # Start bit (0)
        self.rx_pin.value = 0
        await ClockCycles(self.clk, cpb)

        # 8 Data bits (LSB first)
        for bit_idx in range(8):
            bit_val = (byte_val >> bit_idx) & 0x01
            self.rx_pin.value = bit_val
            await ClockCycles(self.clk, cpb)

        # Stop bit (1)
        self.rx_pin.value = 1
        await ClockCycles(self.clk, cpb)


class UARTReceiver:
    """Cycle-accurate UART receiver to monitor and decode DUT o_tx."""

    def __init__(self, dut, clk_signal, tx_signal, cycles_per_bit=CYCLES_PER_BIT):
        self.dut = dut
        self.clk = clk_signal
        self.tx = tx_signal
        self.cycles_per_bit = cycles_per_bit

    def get_tx(self):
        """Extracts bit 0 (UART TX signal)."""
        val = int(self.tx.value)
        return val & 0x01

    async def wait_for_start_bit(self, timeout_cycles=25000):
        """Waits for falling edge of TX indicating start bit."""
        elapsed = 0
        while self.get_tx() == 1:
            await RisingEdge(self.clk)
            elapsed += 1
            if elapsed > timeout_cycles:
                raise TimeoutError(f"UART TX did not go LOW (Start bit) within {timeout_cycles} clock cycles")
        return elapsed

    async def receive_byte_midpoint_sampled(self):
        """
        Receives one UART byte using standard mid-bit sampling.
        Returns: (data_byte, frame_valid, diagnostics_dict)
        """
        # Wait for start bit falling edge
        await self.wait_for_start_bit()

        # Step to midpoint of start bit (~217 cycles)
        mid_start = self.cycles_per_bit // 2
        await ClockCycles(self.clk, mid_start)

        start_val = self.get_tx()
        start_valid = (start_val == 0)

        # Sample 8 data bits (LSB first) at bit midpoints
        sampled_bits = []
        for bit_idx in range(8):
            await ClockCycles(self.clk, self.cycles_per_bit)
            bit_val = self.get_tx()
            sampled_bits.append(bit_val)

        # Reconstruct byte
        byte_val = 0
        for i, b in enumerate(sampled_bits):
            byte_val |= (b << i)

        # Step to midpoint of stop bit
        await ClockCycles(self.clk, self.cycles_per_bit)
        stop_val = self.get_tx()
        stop_valid = (stop_val == 1)

        # Finish remaining half of stop bit
        remaining = self.cycles_per_bit - mid_start
        await ClockCycles(self.clk, remaining)

        frame_valid = start_valid and stop_valid
        diagnostics = {
            "start_bit": start_val,
            "stop_bit": stop_val,
            "sampled_bits": sampled_bits,
            "byte_val": byte_val,
            "start_valid": start_valid,
            "stop_valid": stop_valid,
        }

        return byte_val, frame_valid, diagnostics


# -----------------------------------------------------------------------------
# Test 1: Reset Behavior and Idle State
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_uart_reset(dut):
    """Verify reset asserts TX idle high and initializes registers."""
    start_clock(dut.i_clk, CLK_PERIOD_NS)

    dut.i_reset_n.value = 0
    dut.i_rx.value = 1
    dut.i_data.value = 0
    await ClockCycles(dut.i_clk, 5)

    tx_val = int(dut.o_tx.value) & 0x01
    assert tx_val == 1, f"Expected o_tx idle high during reset, got {tx_val}"

    # Release reset
    await RisingEdge(dut.i_clk)
    dut.i_reset_n.value = 1
    await ClockCycles(dut.i_clk, 10)

    tx_val_post = int(dut.o_tx.value) & 0x01
    assert tx_val_post == 1, f"Expected o_tx to remain idle high after reset, got {tx_val_post}"
    dut._log.info("Reset test PASSED: DUT initialized to idle high!")


# -----------------------------------------------------------------------------
# Test 2: Single-Byte Echo (Interactive Loopback)
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_uart_echo_single_bytes(dut):
    """Verify transmission of individual bytes into i_rx and reception on o_tx."""
    start_clock(dut.i_clk, CLK_PERIOD_NS)
    await reset_dut(dut)

    tx_host = UARTTransmitter(dut, dut.i_clk, dut.i_rx)
    rx_host = UARTReceiver(dut, dut.i_clk, dut.o_tx)

    test_bytes = [0x55, 0xAA, 0x00, 0xFF, 0x42, 0x3C, 0xA5, 0x7E]

    for idx, expected in enumerate(test_bytes):
        dut._log.info(f"Sending byte [{idx+1}/{len(test_bytes)}]: 0x{expected:02X} ('{chr(expected) if 32 <= expected < 127 else '.'}')")

        # Start receiver task concurrently before transmitting
        rx_task = cocotb.start_soon(rx_host.receive_byte_midpoint_sampled())

        # Transmit byte from host into DUT
        await tx_host.transmit_byte(expected)

        # Receive echoed byte from DUT
        byte_val, frame_valid, diag = await rx_task

        dut._log.info(f"Received echo: 0x{byte_val:02X} (valid={frame_valid}, bits={diag['sampled_bits']})")

        assert frame_valid, f"Framing error on byte 0x{expected:02X}: {diag}"
        assert byte_val == expected, f"Echo mismatch! Sent 0x{expected:02X}, received 0x{byte_val:02X}"

        # Verify o_data displays the received byte
        assert int(dut.o_data.value) == expected, (
            f"o_data telemetry mismatch! Expected 0x{expected:02X}, got 0x{int(dut.o_data.value):02X}"
        )

        # Allow idle gap between bytes
        await ClockCycles(dut.i_clk, 200)

    dut._log.info("Single-byte UART echo test PASSED!")


# -----------------------------------------------------------------------------
# Test 3: String Stream Loopback ("OmniBus Task03 Echo!\r\n")
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_uart_echo_string_stream(dut):
    """Stream an ASCII text string and verify byte-for-byte echoed stream."""
    start_clock(dut.i_clk, CLK_PERIOD_NS)
    await reset_dut(dut)

    tx_host = UARTTransmitter(dut, dut.i_clk, dut.i_rx)
    rx_host = UARTReceiver(dut, dut.i_clk, dut.o_tx)

    message = "OmniBus Task03 Echo!\r\n"
    received_chars = []

    dut._log.info(f"Streaming message: {repr(message)}")

    for char in message:
        expected_byte = ord(char)
        rx_task = cocotb.start_soon(rx_host.receive_byte_midpoint_sampled())
        await tx_host.transmit_byte(expected_byte)
        byte_val, frame_valid, _ = await rx_task
        assert frame_valid, f"Framing error on character '{char}'"
        assert byte_val == expected_byte, f"Character mismatch! Sent '{char}' ({expected_byte}), got {byte_val}"
        received_chars.append(chr(byte_val))
        await ClockCycles(dut.i_clk, 100)

    reconstructed = "".join(received_chars)
    dut._log.info(f"Reconstructed echoed string: {repr(reconstructed)}")
    assert reconstructed == message, f"String mismatch! Expected {repr(message)}, got {repr(reconstructed)}"
    dut._log.info("String stream echo test PASSED!")


# -----------------------------------------------------------------------------
# Test 4: Baud-Rate Skew / Clock Tolerance Margin (±2.5% Baud Offset)
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_uart_echo_baud_skew(dut):
    """Verify mid-bit sampling margin with ±2.5% baud-rate clock skew."""
    start_clock(dut.i_clk, CLK_PERIOD_NS)
    await reset_dut(dut)

    tx_host = UARTTransmitter(dut, dut.i_clk, dut.i_rx)
    rx_host = UARTReceiver(dut, dut.i_clk, dut.o_tx)

    # +2.5% faster baud rate: 434 * 0.975 ≈ 423 cycles/bit
    # -2.5% slower baud rate: 434 * 1.025 ≈ 445 cycles/bit
    skew_test_cases = [
        (0x55, 423, "+2.5% fast (423 cycles/bit)"),
        (0xAA, 445, "-2.5% slow (445 cycles/bit)"),
        (0x42, 423, "+2.5% fast (423 cycles/bit)"),
        (0xC3, 445, "-2.5% slow (445 cycles/bit)"),
    ]

    for expected, skew_cpb, desc in skew_test_cases:
        dut._log.info(f"Testing clock skew: {desc} with byte 0x{expected:02X}")
        rx_task = cocotb.start_soon(rx_host.receive_byte_midpoint_sampled())
        await tx_host.transmit_byte(expected, cycles_per_bit=skew_cpb)
        byte_val, frame_valid, diag = await rx_task
        assert frame_valid, f"Framing error under skew {desc}: {diag}"
        assert byte_val == expected, f"Data corrupted under skew {desc}! Expected 0x{expected:02X}, got 0x{byte_val:02X}"
        await ClockCycles(dut.i_clk, 200)

    dut._log.info("Baud-rate skew tolerance test PASSED! Mid-bit sampling verified.")


# -----------------------------------------------------------------------------
# Test 5: Zero-Jitter Bit-Timing Verification on Echoed Transmission
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_uart_echo_timing_zero_jitter(dut):
    """Verify that echoed OUT opcode maintains exact 434-cycle duration per bit."""
    start_clock(dut.i_clk, CLK_PERIOD_NS)
    await reset_dut(dut)

    tx_host = UARTTransmitter(dut, dut.i_clk, dut.i_rx)
    rx_host = UARTReceiver(dut, dut.i_clk, dut.o_tx)

    expected_transitions = [
        ("Start Bit", 0),
        ("Bit 0", 1),
        ("Bit 1", 0),
        ("Bit 2", 1),
        ("Bit 3", 0),
        ("Bit 4", 1),
        ("Bit 5", 0),
        ("Bit 6", 1),
        ("Bit 7", 0),
    ]

    async def measure_echo_timing():
        await rx_host.wait_for_start_bit()
        for name, expected_level in expected_transitions:
            current_level = rx_host.get_tx()
            assert current_level == expected_level, (
                f"Expected {name} level {expected_level}, got {current_level}"
            )
            cycle_count = 0
            while rx_host.get_tx() == expected_level:
                await RisingEdge(dut.i_clk)
                cycle_count += 1
                if cycle_count > CYCLES_PER_BIT + 10:
                    break

            dut._log.info(f"Echo {name:10s} (val={expected_level}) measured = {cycle_count} cycles")
            assert cycle_count == CYCLES_PER_BIT, (
                f"Zero-jitter timing violation on echo {name}: Expected {CYCLES_PER_BIT}, measured {cycle_count}"
            )

        # Stop bit check
        assert rx_host.get_tx() == 1, "Expected Stop bit level 1"

    timing_task = cocotb.start_soon(measure_echo_timing())
    # Send 0x55 ('U' = 0b01010101) to produce alternating bit transitions
    await tx_host.transmit_byte(0x55)
    await timing_task

    dut._log.info("Zero-jitter echo timing test PASSED: Exactly 434 cycles/bit!")


# -----------------------------------------------------------------------------
# Test 6 (Task 04): IMEM Programming Port & Readback Verification
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_imem_programming_interface(dut):
    """Verify runtime microcode programming port and combinational readback."""
    start_clock(dut.i_clk, CLK_PERIOD_NS)
    await reset_dut(dut)

    # 1. Verify power-on default readback (Echo microcode at addresses 0..8)
    expected_defaults = [
        0x40FE, 0x01FF, 0x21FF, 0x4100, 0xA000, 0x30FF, 0x11FF, 0x31FF, 0x8000
    ]
    for addr, expected_val in enumerate(expected_defaults):
        dut.i_prog_addr.value = addr
        await Timer(1, unit="ns") # Combinational settling
        readback = int(dut.o_prog_rdata.value)
        assert readback == expected_val, (
            f"Default IMEM mismatch at 0x{addr:02X}: Expected 0x{expected_val:04X}, got 0x{readback:04X}"
        )
    dut._log.info("Power-on IMEM default contents verified!")

    # 2. Enter programming mode and write new instructions across all 32 words
    dut.i_prog_en.value = 1
    await RisingEdge(dut.i_clk)

    test_program = {}
    for addr in range(32):
        # Unique test word: 0x5000 | (addr << 4) | (addr & 0xF)
        val = 0x5000 | (addr << 4) | (addr & 0xF)
        test_program[addr] = val
        dut.i_prog_addr.value = addr
        dut.i_prog_data.value = val
        dut.i_prog_we.value = 1
        await RisingEdge(dut.i_clk)
        dut.i_prog_we.value = 0
        await RisingEdge(dut.i_clk)

    # 3. Verify readback across all 32 words
    for addr, expected_val in test_program.items():
        dut.i_prog_addr.value = addr
        await Timer(1, unit="ns")
        readback = int(dut.o_prog_rdata.value)
        assert readback == expected_val, (
            f"Written IMEM mismatch at 0x{addr:02X}: Expected 0x{expected_val:04X}, got 0x{readback:04X}"
        )

    dut.i_prog_en.value = 0
    await RisingEdge(dut.i_clk)
    dut._log.info("IMEM 32-word runtime write and readback verified 100%!")


async def load_program_direct(dut, instructions):
    """Halts core, loads microcode words into IMEM via programming port, and releases core."""
    dut.i_prog_en.value = 1
    await RisingEdge(dut.i_clk)
    for addr, word in enumerate(instructions):
        dut.i_prog_addr.value = addr
        dut.i_prog_data.value = word
        dut.i_prog_we.value = 1
        await RisingEdge(dut.i_clk)
        dut.i_prog_we.value = 0
        await RisingEdge(dut.i_clk)
    dut.i_prog_en.value = 0
    await RisingEdge(dut.i_clk)


# -----------------------------------------------------------------------------
# Test 7 (Task 04): Dynamic Microcode Execution Switching In-Flight
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_runtime_dynamic_reprogram(dut):
    """
    Test live reprogramming in simulation:
    1. Load standard Echo microcode into IMEM.
    2. Verify Echo program receives 0x42 and echoes 0x42.
    3. Halt core with i_prog_en, load custom continuous transmitter microcode.
    4. Release i_prog_en, verify core autonomously transmits the programmed byte!
    """
    start_clock(dut.i_clk, CLK_PERIOD_NS)
    await reset_dut(dut)

    tx_host = UARTTransmitter(dut, dut.i_clk, dut.i_rx)
    rx_host = UARTReceiver(dut, dut.i_clk, dut.o_tx)

    echo_prog = [
        0x40FE, # WAIT rx=0 [$HBAUD]
        0x01FF, # NOP       [$BAUD]
        0x21FF, # IN  rx, 8 [$BAUD]
        0x4100, # WAIT rx=1 [0]
        0xA000, # PUSH
        0x30FF, # SET tx=0  [$BAUD]
        0x11FF, # OUT tx, 8 [$BAUD]
        0x31FF, # SET tx=1  [$BAUD]
        0x8000, # JMP 0x0
    ]

    # Step 1: Load Echo program & test loopback
    await load_program_direct(dut, echo_prog)
    dut._log.info("Step 1: Echo program loaded into IMEM")

    rx_task = cocotb.start_soon(rx_host.receive_byte_midpoint_sampled())
    await tx_host.transmit_byte(0x42)
    val, valid, _ = await rx_task
    assert valid and val == 0x42, f"Initial echo failed: got {val}"
    dut._log.info("Step 1: Default Echo verified live!")

    # Step 2: Reprogram core to autonomously transmit '!' (0x21 = 0010_0001b)
    # Bit pattern LSB-first: 1, 0, 0, 0, 0, 1, 0, 0
    # Include an initial idle delay so receiver can arm before start bit falls!
    custom_prog = [
        0x01FF, # NOP $BAUD (Inter-frame idle delay)
        0x30FF, # SET 0, $BAUD (Start bit: 0)
        0x31FF, # SET 1, $BAUD (Bit 0: 1)
        0x30FF, # SET 0, $BAUD (Bit 1: 0)
        0x30FF, # SET 0, $BAUD (Bit 2: 0)
        0x30FF, # SET 0, $BAUD (Bit 3: 0)
        0x30FF, # SET 0, $BAUD (Bit 4: 0)
        0x31FF, # SET 1, $BAUD (Bit 5: 1)
        0x30FF, # SET 0, $BAUD (Bit 6: 0)
        0x30FF, # SET 0, $BAUD (Bit 7: 0)
        0x31FF, # SET 1, $BAUD (Stop bit: 1)
        0x8000, # JMP 0     (Repeat)
    ]

    # Arm receiver before releasing core
    rx_task = cocotb.start_soon(rx_host.receive_byte_midpoint_sampled())

    # Step 2: Load custom transmitter program
    await load_program_direct(dut, custom_prog)
    dut._log.info("Step 2: Core released into custom transmitter program!")

    # Step 3: Monitor UART TX - core should transmit '!' (0x21) autonomously!
    val, valid, _ = await rx_task
    assert valid, "Framing error on custom microcode transmission"
    assert val == 0x21, f"Expected custom char '!' (0x21), got 0x{val:02X}"
    dut._log.info(f"Step 3: Core autonomously transmitted '{chr(val)}' (0x{val:02X}) as programmed!")

    # Verify a second transmission follows seamlessly
    rx_task = cocotb.start_soon(rx_host.receive_byte_midpoint_sampled())
    val, valid, _ = await rx_task
    assert valid and val == 0x21, f"Second transmission failed: got 0x{val:02X}"
    dut._log.info(f"Step 4: Continuous loop confirmed '{chr(val)}' (0x{val:02X})!")

    dut._log.info("Dynamic runtime reprogramming test PASSED 100%!")


@cocotb.test()
async def test_call_ret_basic(dut):
    """Test 05a: CALL jumps to subroutine and RET restores caller return address."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    # Program layout:
    #   [0] CALL 3     -> push 1 onto stack, jump to addr 3
    #   [1] NOP 0      -> return landing pad (pc should come back here after RET)
    #   [2] JMP 2      -> infinite loop sentinel (should NOT be reached)
    #   [3] RET        -> pop stack -> pc=1
    #
    # Expected trace: pc=0 (CALL) -> pc=3 (RET) -> pc=1 (NOP) -> pc=2 (JMP 2 loops)
    CALL_3 = (0xC << 12) | 0x03   # 0xC003
    NOP_0  = (0x0 << 12) | 0x000  # 0x0000
    JMP_2  = (0x8 << 12) | 0x002  # 0x8002
    RET    = (0xD << 12)           # 0xD000

    prog = [CALL_3, NOP_0, JMP_2, RET]
    await load_program_direct(dut, prog)

    # Observe pc transitions directly via DUT signals
    # Give the core enough clock cycles to execute the sequence
    await ClockCycles(dut.i_clk, 10)

    pc_val = int(dut.pc.value)
    # After CALL->RET->NOP->JMP 2, pc should be cycling at 2
    assert pc_val == 2, f"Expected pc=2 (JMP 2 loop after RET), got pc={pc_val}"
    dut._log.info(f"CALL/RET basic test PASSED: pc settled at {pc_val} (correct loop after RET)")


@cocotb.test()
async def test_call_ret_nested(dut):
    """Test 05b: Two-deep nested CALL/RET restores return addresses in LIFO order."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    # Program layout:
    #   [0] CALL 4     -> push 1, jump to 4 (outer sub)
    #   [1] NOP 0      -> outer return landing (pc=1 after outer RET)
    #   [2] JMP 2      -> infinite loop sentinel
    #   [3] NOP 0      -> padding
    #   [4] CALL 7     -> push 5, jump to 7 (inner sub)
    #   [5] RET        -> pop 1 from stack -> jump to 1 (outer return)
    #   [6] NOP 0      -> padding (should NOT be reached)
    #   [7] RET        -> pop 5 from stack -> jump to 5 (inner return)
    CALL_4 = (0xC << 12) | 0x04
    CALL_7 = (0xC << 12) | 0x07
    NOP_0  = (0x0 << 12) | 0x000
    JMP_2  = (0x8 << 12) | 0x002
    RET    = (0xD << 12)

    prog = [
        CALL_4,  # [0] outer CALL
        NOP_0,   # [1] outer return point
        JMP_2,   # [2] final loop
        NOP_0,   # [3] pad
        CALL_7,  # [4] inner CALL
        RET,     # [5] outer RET (-> 1)
        NOP_0,   # [6] unreachable pad
        RET,     # [7] inner RET (-> 5)
    ]
    await load_program_direct(dut, prog)

    # Allow enough cycles for CALL->CALL->RET->RET->NOP->JMP 2 sequence
    await ClockCycles(dut.i_clk, 20)

    pc_val = int(dut.pc.value)
    assert pc_val == 2, f"Expected pc=2 (final JMP 2 loop after 2-deep CALL/RET), got pc={pc_val}"
    dut._log.info(f"Nested CALL/RET test PASSED: pc settled at {pc_val} (LIFO stack correct)")


@cocotb.test()
async def test_baud_div_configurable(dut):
    """Test 06: $BAUD/$HBAUD sentinel tokens track i_baud_div at runtime.

    Loads echo_configurable.asm (uses 0x1FF delay tokens), sets i_baud_div=216
    (230400 baud @ 50 MHz), sends one byte, and verifies the echo is received
    within the timing window expected for 230400 baud — not 115200 baud.
    """
    start_clock(dut.i_clk)
    await reset_dut(dut)

    CLK_PERIOD_NS = 20  # 50 MHz
    BAUD_DIV      = 216  # 230400 baud @ 50 MHz  (clk/baud - 1)
    BIT_NS        = (BAUD_DIV + 1) * CLK_PERIOD_NS  # 4340 ns per bit

    # Switch to 230400 baud by overriding i_baud_div
    dut.i_baud_div.value = BAUD_DIV
    dut._log.info(f"Test 06: Set i_baud_div={BAUD_DIV} ({50_000_000//(BAUD_DIV+1):,} baud)")

    # Load echo_configurable program ($BAUD tokens = 0x1FF)
    prog = [0x40FE, 0x01FF, 0x21FF, 0x4100, 0xA000, 0x30FF, 0x11FF, 0x31FF, 0x8000]
    await load_program_direct(dut, prog)

    # Send byte 0xA5 at 230400 baud
    TEST_BYTE = 0xA5
    bits = [0] + [(TEST_BYTE >> i) & 1 for i in range(8)] + [1]  # start + data + stop

    t_start = get_sim_time('ns')
    for bit in bits:
        dut.i_rx.value = bit
        await Timer(BIT_NS, unit='ns')
    dut.i_rx.value = 1  # idle

    # Wait for echo to appear on o_tx (at 230400 baud, full frame ≈ 10 * 4340 = 43400 ns)
    echo_timeout_ns = BIT_NS * 25  # generous timeout

    # Wait for start bit on TX (falling edge from idle high)
    for _ in range(int(echo_timeout_ns // CLK_PERIOD_NS) + 50):
        await RisingEdge(dut.i_clk)
        if int(dut.o_tx.value) == 0:
            break
    else:
        assert False, "Timeout: no echo start bit detected at 230400 baud"

    # Sample echo bits at bit-center of each bit period
    await Timer(BIT_NS // 2, unit='ns')   # skip start bit, land at center
    received = 0
    for i in range(8):
        await Timer(BIT_NS, unit='ns')
        b = int(dut.o_tx.value)
        received |= (b << i)

    assert received == TEST_BYTE, (
        f"Echo mismatch at 230400 baud: sent 0x{TEST_BYTE:02X}, got 0x{received:02X}"
    )
    t_end = get_sim_time('ns')
    dut._log.info(
        f"Baud-div configurable test PASSED: 0x{TEST_BYTE:02X} echoed correctly at "
        f"BAUD_DIV={BAUD_DIV} ({50_000_000//(BAUD_DIV+1):,} baud) in {t_end - t_start:.0f} ns"
    )

@cocotb.test()
async def test_spi_loopback(dut):
    """Test 07: SPI Mode 0 loopback using pin selector ISA extension.

    Programs spi_loopback.asm (24 words) which transmits 0xA5 using:
      - SET CS  (pin_id=2, instr[11:9]=010)
      - SET MOSI(pin_id=0, instr[11:9]=000)
      - IN 1    (1-bit sample, instr[11:9]=001)
    MISO is looped back from o_tx in the testbench (mirroring top.v loopback).
    After one full 8-bit SPI transfer, o_data must equal 0xA5.
    """
    start_clock(dut.i_clk)
    await reset_dut(dut)

    CLK_PERIOD_NS = 20
    SPI_DIV = 9      # SCK half-period = 10 cycles = 200 ns
    BIT_NS  = (SPI_DIV + 1) * CLK_PERIOD_NS
    dut.i_baud_div.value = SPI_DIV
    dut._log.info(f"Test 07: SPI loopback i_baud_div={SPI_DIV} half-period={BIT_NS} ns")

    # spi_loopback.asm program encoding (verified by omnibus_asm.py Task 07C)
    prog = [
        # Main loop [0..19]: 0xA5 = 10100101b MSB first
        0x3400,  # [0]  SET CS,0,0        assert CS_n
        0x3100,  # [1]  SET MOSI,1,0      B7=1
        0xC014,  # [2]  CALL 20
        0x3000,  # [3]  SET MOSI,0,0      B6=0
        0xC014,  # [4]  CALL 20
        0x3100,  # [5]  SET MOSI,1,0      B5=1
        0xC014,  # [6]  CALL 20
        0x3000,  # [7]  SET MOSI,0,0      B4=0
        0xC014,  # [8]  CALL 20
        0x3000,  # [9]  SET MOSI,0,0      B3=0
        0xC014,  # [10] CALL 20
        0x3100,  # [11] SET MOSI,1,0      B2=1
        0xC014,  # [12] CALL 20
        0x3000,  # [13] SET MOSI,0,0      B1=0
        0xC014,  # [14] CALL 20
        0x3100,  # [15] SET MOSI,1,0      B0=1
        0xC014,  # [16] CALL 20
        0x3500,  # [17] SET CS,1,0        deassert CS_n
        0xA000,  # [18] PUSH
        0x8000,  # [19] JMP start
        # do_bit subroutine [20..23]
        0x33FE,  # [20] SET SCK,1,$HBAUD  rising edge
        0x23FE,  # [21] IN  1,$HBAUD      1-bit sample
        0x32FE,  # [22] SET SCK,0,$HBAUD  falling edge
        0xD000,  # [23] RET
    ]
    await load_program_direct(dut, prog)

    # MISO loopback: mirror o_tx -> i_rx every clock cycle (mirrors top.v)
    async def loopback_task():
        while True:
            await RisingEdge(dut.i_clk)
            dut.i_rx.value = int(dut.o_tx.value)

    lb = cocotb.start_soon(loopback_task())

    TIMEOUT = 3000  # cycles

    # Wait for CS_n to assert (low)
    for _ in range(TIMEOUT):
        await RisingEdge(dut.i_clk)
        if int(dut.o_spi_cs_n.value) == 0:
            dut._log.info("CS_n asserted - transaction started")
            break
    else:
        lb.cancel()
        assert False, "Timeout: CS_n never asserted"

    # Wait for CS_n to deassert (high) - transfer complete
    for _ in range(TIMEOUT):
        await RisingEdge(dut.i_clk)
        if int(dut.o_spi_cs_n.value) == 1:
            dut._log.info("CS_n deasserted - transfer complete")
            break
    else:
        lb.cancel()
        assert False, "Timeout: CS_n never deasserted after transaction"

    # Allow PUSH + JMP to complete
    await ClockCycles(dut.i_clk, 5)
    lb.cancel()

    received = int(dut.o_data.value)
    assert received == 0xA5, f"SPI loopback mismatch: expected 0xA5, got 0x{received:02X}"
    dut._log.info(
        f"SPI loopback PASSED: o_data=0x{received:02X} (0xA5) "
        f"SPI_DIV={SPI_DIV} half-period={BIT_NS} ns"
    )


@cocotb.test()
async def test_out_sck_generic(dut):
    """Test 07B: OUT SCK mode - PULL + OUT SCK + PUSH generic SPI transceiver.

    Programs spi_generic.asm (6 words):
      PULL -> SET CS,0 -> OUT SCK,$HBAUD -> SET CS,1 -> PUSH -> JMP
    Drives i_data = 0xC3, connects MISO loopback, verifies o_data == 0xC3.
    OUT SCK encoding: [15:12]=1, [11:10]=01, [8:0]=$HBAUD
    MSB-first (osr[7] first), full-duplex MISO sampling into ISR.
    """
    start_clock(dut.i_clk)
    await reset_dut(dut)

    CLK_PERIOD_NS = 20
    SPI_DIV = 9    # SCK half-period = 10 cycles = 200 ns
    BIT_NS  = (SPI_DIV + 1) * CLK_PERIOD_NS
    dut.i_baud_div.value = SPI_DIV
    TEST_BYTE = 0xC3
    dut._log.info(f"Test 07B: OUT SCK generic i_baud_div={SPI_DIV} byte=0x{TEST_BYTE:02X}")

    # spi_generic.asm encoding (6 words)
    prog = [
        0x9000,  # [0] PULL
        0x3400,  # [1] SET CS,0,0 (Pin 2, val 0)
        0x15FE,  # [2] OUT SCK,$HBAUD  (pin_id=01, delay=0x1FE)
        0x3500,  # [3] SET CS,1,0 (Pin 2, val 1)
        0xA000,  # [4] PUSH
        0x8000,  # [5] JMP spi_loop
    ]
    # Drive i_data BEFORE loading so PULL captures it on first execution
    dut.i_data.value = TEST_BYTE

    # MISO loopback: start before loading so no bits are missed
    async def loopback_task():
        while True:
            await RisingEdge(dut.i_clk)
            dut.i_rx.value = int(dut.o_tx.value)

    lb = cocotb.start_soon(loopback_task())

    await load_program_direct(dut, prog)

    TIMEOUT = 3000

    # Wait for CS_n to assert (transaction start)
    for _ in range(TIMEOUT):
        await RisingEdge(dut.i_clk)
        if int(dut.o_spi_cs_n.value) == 0:
            dut._log.info("CS_n asserted - OUT SCK transaction started")
            break
    else:
        lb.cancel()
        assert False, "Timeout: CS_n never asserted"

    # Wait for CS_n to deassert (transaction complete)
    for _ in range(TIMEOUT):
        await RisingEdge(dut.i_clk)
        if int(dut.o_spi_cs_n.value) == 1:
            dut._log.info("CS_n deasserted - transfer complete")
            break
    else:
        lb.cancel()
        assert False, "Timeout: CS_n never deasserted"

    # Allow PUSH to complete
    await ClockCycles(dut.i_clk, 5)
    lb.cancel()

    received = int(dut.o_data.value)
    assert received == TEST_BYTE, (
        f"OUT SCK mismatch: expected 0x{TEST_BYTE:02X}, got 0x{received:02X}"
    )
    dut._log.info(
        f"OUT SCK generic PASSED: i_data=0x{TEST_BYTE:02X} -> o_data=0x{received:02X} "
        f"(SPI_DIV={SPI_DIV}, half-period={BIT_NS} ns)"
    )


@cocotb.test()
async def test_gpio_pinmap(dut):
    """Test 07C: PINMAP dynamically remaps protocol roles across GPIO 0..7."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    # Program:
    # 0x00: PINMAP 4, 5, 1, 2 -> 0x590A with TX=4, RX=5, SCK=1, CS=2: 0x594A
    # 0x01: SET Pin 4, 0, delay=6 -> 0x3806 (Drive GPIO 4 low)
    # 0x02: SET Pin 4, 1, delay=6 -> 0x3906 (Drive GPIO 4 high)
    # 0x03: JMP 0x03              -> 0x8003
    prog = [
        0x594A, # PINMAP TX=4, RX=5, SCK=1, CS=2
        0x3806, # SET Pin 4, 0, delay=6
        0x3906, # SET Pin 4, 1, delay=6
        0x8003  # JMP 0x03
    ]
    await load_program_direct(dut, prog)

    # Wait for execution of SET Pin 4, 0
    await ClockCycles(dut.i_clk, 3)
    assert ((int(dut.o_gpio.value) >> 4) & 1) == 0, "GPIO 4 was not driven LOW by SET"
    assert int(dut.o_tx.value) == 0, "o_tx did not reflect remapped TX pin (Pin 4)"

    # Wait for execution of SET Pin 4, 1
    await ClockCycles(dut.i_clk, 7)
    assert ((int(dut.o_gpio.value) >> 4) & 1) == 1, "GPIO 4 was not driven HIGH by SET"
    assert int(dut.o_tx.value) == 1, "o_tx did not reflect remapped TX pin (Pin 4)"
    dut._log.info("PINMAP test PASSED: role remap and GPIO drive verified!")


@cocotb.test()
async def test_gpio_open_drain(dut):
    """Test 07C: CFG_OD configures open-drain drive/release behavior."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    # Program:
    # 0x00: CFG_OD 0x10           -> 0x6010 (Pin 4 open-drain)
    # 0x01: SET Pin 4, 0, delay=6 -> 0x3806 (Drive low: oe=1, out=0)
    # 0x02: SET Pin 4, 1, delay=6 -> 0x3906 (Release: oe=0, out=1)
    # 0x03: JMP 0x03              -> 0x8003
    prog = [
        0x6010, # CFG_OD 0x10
        0x3806, # SET Pin 4, 0, delay=6
        0x3906, # SET Pin 4, 1, delay=6
        0x8003  # JMP 0x03
    ]
    await load_program_direct(dut, prog)

    # After SET 0: Pin 4 driven low -> oe[4] must be 1, out[4] must be 0
    await ClockCycles(dut.i_clk, 3)
    oe_bit = (int(dut.o_gpio_oe.value) >> 4) & 1
    out_bit = (int(dut.o_gpio.value) >> 4) & 1
    assert oe_bit == 1 and out_bit == 0, f"Open-drain drive LOW failed: oe={oe_bit}, out={out_bit}"

    # After SET 1: Pin 4 released -> oe[4] must be 0 (Hi-Z), out[4] must be 1
    await ClockCycles(dut.i_clk, 7)
    oe_bit = (int(dut.o_gpio_oe.value) >> 4) & 1
    out_bit = (int(dut.o_gpio.value) >> 4) & 1
    assert oe_bit == 0 and out_bit == 1, f"Open-drain release HIGH failed: oe={oe_bit}, out={out_bit}"
    dut._log.info("CFG_OD open-drain test PASSED: oe asserted on 0, deasserted on 1!")


@cocotb.test()
async def test_i2c_out_sda(dut):
    """Test 08: OUT SDA serializes 8 bits MSB-first with auto-SCL clocking."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    TEST_BYTE = 0xA5  # 10100101b
    dut.i_data.value = TEST_BYTE
    dut.i_baud_div.value = 4  # Short delay for fast simulation

    # Program:
    # 0x00: PINMAP 4, 4, 1, 2 -> 0x590A
    # 0x01: CFG_OD 0x12       -> 0x6012 (Pins 4 and 1 open-drain)
    # 0x02: PULL              -> 0x9000
    # 0x03: OUT SDA, 2        -> 0x1C02 (mode=3, delay=2)
    # 0x04: PUSH              -> 0xA000
    # 0x05: JMP 0x05          -> 0x8005
    prog = [
        0x590A,
        0x6012,
        0x9000,
        0x1C02,
        0xA000,
        0x8005
    ]

    # SCL open-drain wire equation: low when oe=1 and out=0, otherwise 1 (pull-up)
    scl_toggles = 0
    async def monitor_scl():
        nonlocal scl_toggles
        prev_scl = 1
        while True:
            await RisingEdge(dut.i_clk)
            oe_1 = (int(dut.o_gpio_oe.value) >> 1) & 1
            out_1 = (int(dut.o_gpio.value) >> 1) & 1
            curr_scl = 0 if (oe_1 and not out_1) else 1
            if prev_scl == 0 and curr_scl == 1:
                scl_toggles += 1
            prev_scl = curr_scl

    mon = cocotb.start_soon(monitor_scl())
    await load_program_direct(dut, prog)

    # Wait for OUT SDA to complete 8 clock pulses
    await ClockCycles(dut.i_clk, 120)
    mon.cancel()

    assert scl_toggles >= 8, f"Expected at least 8 SCL clock pulses, got {scl_toggles}"
    dut._log.info(f"I2C OUT SDA test PASSED: {scl_toggles} SCL pulses verified!")


@cocotb.test()
async def test_hardware_loop_counter(dut):
    """Test 09: Dual hardware loop counters (LC0, LC1) and DJNZ nested loops."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    # Nested loop program:
    # Outer loop repeats 2 times (LC1)
    # Inner loop repeats 3 times (LC0)
    # Total body executions = 2 * 3 = 6
    #
    # 0x00: SET_LC LC1, 2  -> 0x7C02
    # 0x01: SET_LC LC0, 3  -> 0x7403
    # 0x02: PUSH_LC LC0    -> 0x7600
    # 0x03: DJNZ LC0, 0x02 -> 0x7002
    # 0x04: DJNZ LC1, 0x01 -> 0x7801
    # 0x05: JMP 0x05       -> 0x8005
    prog = [
        0x7C02, # SET_LC LC1, 2
        0x7403, # SET_LC LC0, 3
        0x7600, # PUSH_LC LC0
        0x7002, # DJNZ LC0, 0x02
        0x7801, # DJNZ LC1, 0x01
        0x8005  # JMP 0x05
    ]

    push_events = []
    async def monitor_push():
        prev_pc = None
        while True:
            await RisingEdge(dut.i_clk)
            pc_val = int(dut.pc.value)
            # Sample at PC==3 (immediately after PUSH_LC at PC==2 has clocked into o_data)
            if pc_val == 3 and prev_pc != 3:
                push_events.append(int(dut.o_data.value))
            prev_pc = pc_val

    mon = cocotb.start_soon(monitor_push())
    await load_program_direct(dut, prog)

    # Wait for loops to terminate at PC=5
    for _ in range(100):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 5:
            break
    else:
        mon.cancel()
        assert False, f"Timeout: loop did not finish at PC=5 (current PC={int(dut.pc.value)})"

    mon.cancel()
    assert len(push_events) == 6, f"Expected exactly 6 body executions, got {len(push_events)}: {push_events}"
    assert push_events == [3, 2, 1, 3, 2, 1], f"Loop counter sequence mismatch: {push_events}"
    dut._log.info(f"Hardware Loop Counter test PASSED: nested loop executed 6 times with sequence {push_events}!")

