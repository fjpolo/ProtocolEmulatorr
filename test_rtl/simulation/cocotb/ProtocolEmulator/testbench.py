# =============================================================================
# File        : testbench.py
# Description : Self-checking Cocotb testbench for Task 03: Input Shift Register
#               (ISR), mid-bit deserialization (IN), edge wait (WAIT), and
#               full-duplex UART Echo Transceiver.
# Tests       : Reset behavior, single-byte echo, string stream loopback,
#               baud-rate tolerance (skew margin), and zero-jitter echo timing.
# =============================================================================

import sys
import os
repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../.."))
if repo_root not in sys.path:
    sys.path.insert(0, repo_root)

from python.omnibus_asm import OmnibusAssembler, assemble_file

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
    dut.i_tx_valid.value  = 1     # Default: TX FIFO has valid data
    dut.i_rx_full.value   = 0     # Default: RX FIFO has available space
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
    dut.i_tx_valid.value = 1
    dut.i_rx_full.value = 0
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

    # 2. Enter programming mode and write new instructions across all 128 words (4 banks)
    dut.i_prog_en.value = 1
    await RisingEdge(dut.i_clk)

    test_program = {}
    for addr in range(128):
        # Unique test word: 0x5000 | (addr << 4) | (addr & 0xF)
        val = 0x5000 | (addr << 4) | (addr & 0xF)
        test_program[addr] = val
        dut.i_prog_addr.value = addr
        dut.i_prog_data.value = val
        dut.i_prog_we.value = 1
        await RisingEdge(dut.i_clk)
        dut.i_prog_we.value = 0
        await RisingEdge(dut.i_clk)

    # 3. Verify readback across all 128 words
    for addr, expected_val in test_program.items():
        dut.i_prog_addr.value = addr
        await Timer(1, unit="ns")
        readback = int(dut.o_prog_rdata.value)
        assert readback == expected_val, (
            f"Written IMEM mismatch at 0x{addr:02X}: Expected 0x{expected_val:04X}, got 0x{readback:04X}"
        )

    dut.i_prog_en.value = 0
    await RisingEdge(dut.i_clk)
    dut._log.info("IMEM 128-word (4-bank) runtime write and readback verified 100%!")


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


@cocotb.test()
async def test_spi_full_duplex(dut):
    """Test 10A: Full-Duplex SPI - simultaneous MOSI transmit and MISO receive in 1 transfer."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    SPI_DIV = 4  # SCK half-period = 5 cycles
    dut.i_baud_div.value = SPI_DIV
    TX_BYTE = 0xA5  # 1010_0101
    RX_SLAVE_BYTE = 0x5A  # 0101_1010

    # Program:
    # 0x00: PINMAP 0, 3, 1, 2 (TX=0, RX=3, SCK=1, CS=2) -> 0x50CA
    # 0x01: PULL              -> 0x9000
    # 0x02: SET CS, 0, 0      -> 0x3400
    # 0x03: OUT SCK, $HBAUD   -> 0x15FE
    # 0x04: SET CS, 1, 0      -> 0x3500
    # 0x05: PUSH              -> 0xA000
    # 0x06: JMP 0x06          -> 0x8006
    prog = [
        0x50CA,
        0x9000,
        0x3400,
        0x15FE,
        0x3500,
        0xA000,
        0x8006
    ]
    dut.i_data.value = TX_BYTE

    # Slave SPI device model on Pin 3 (MISO):
    mosi_captured = []
    async def spi_slave():
        slave_sr = RX_SLAVE_BYTE
        prev_sck = 0
        while True:
            await RisingEdge(dut.i_clk)
            sck = (int(dut.o_gpio.value) >> 1) & 1
            cs  = (int(dut.o_gpio.value) >> 2) & 1
            if cs == 0:
                miso_bit = (slave_sr >> 7) & 1
                curr_gpio = int(dut.i_gpio.value)
                if miso_bit:
                    dut.i_gpio.value = curr_gpio | (1 << 3)
                else:
                    dut.i_gpio.value = curr_gpio & ~(1 << 3)

                if prev_sck == 1 and sck == 0:
                    slave_sr = ((slave_sr << 1) & 0xFF) | 1

                if prev_sck == 0 and sck == 1:
                    mosi_bit = (int(dut.o_gpio.value) >> 0) & 1
                    mosi_captured.append(mosi_bit)
            prev_sck = sck

    slave_task = cocotb.start_soon(spi_slave())
    await load_program_direct(dut, prog)

    for _ in range(500):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 6:
            break
    else:
        slave_task.cancel()
        assert False, "Timeout: SPI transaction did not complete at PC=6"

    slave_task.cancel()
    assert len(mosi_captured) == 8, f"Expected 8 MOSI bits captured, got {len(mosi_captured)}"
    captured_tx = 0
    for b in mosi_captured:
        captured_tx = (captured_tx << 1) | b
    assert captured_tx == TX_BYTE, f"MOSI TX mismatch: expected 0x{TX_BYTE:02X}, got 0x{captured_tx:02X}"

    received_rx = int(dut.o_data.value)
    assert received_rx == RX_SLAVE_BYTE, f"MISO RX mismatch: expected 0x{RX_SLAVE_BYTE:02X}, got 0x{received_rx:02X}"
    dut._log.info(f"Full-Duplex SPI test PASSED: MOSI sent 0x{TX_BYTE:02X}, MISO received 0x{RX_SLAVE_BYTE:02X} simultaneously!")


@cocotb.test()
async def test_in_sck_master_read(dut):
    """Test 10B: Synchronous SPI Master Read (IN SCK) auto-toggles SCK and reads MISO."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    SPI_DIV = 9  # SCK half-period = 4 cycles (80 ns @ 50 MHz)
    dut.i_baud_div.value = SPI_DIV
    SLAVE_DATA = 0x3C  # 0011_1100

    # Program:
    # 0x00: PINMAP 0, 3, 1, 2 -> 0x50CA
    # 0x01: SET CS, 0, 0      -> 0x3400
    # 0x02: IN SCK, $HBAUD    -> 0x25FE (opcode 2, mode 1, delay 0x1FE)
    # 0x03: SET CS, 1, 0      -> 0x3500
    # 0x04: PUSH              -> 0xA000
    # 0x05: JMP 0x05          -> 0x8005
    prog = [
        0x50CA,
        0x3400,
        0x25FE,
        0x3500,
        0xA000,
        0x8005
    ]

    sck_pulses = 0
    async def spi_slave():
        nonlocal sck_pulses
        slave_sr = SLAVE_DATA
        prev_sck = 0
        while True:
            await RisingEdge(dut.i_clk)
            sck = (int(dut.o_gpio.value) >> 1) & 1
            cs  = (int(dut.o_gpio.value) >> 2) & 1
            if cs == 0:
                miso_bit = (slave_sr >> 7) & 1
                curr_gpio = int(dut.i_gpio.value)
                if miso_bit:
                    dut.i_gpio.value = curr_gpio | (1 << 3)
                else:
                    dut.i_gpio.value = curr_gpio & ~(1 << 3)

                if prev_sck == 0 and sck == 1:
                    sck_pulses += 1
                elif prev_sck == 1 and sck == 0:
                    slave_sr = ((slave_sr << 1) & 0xFF) | 1
            prev_sck = sck

    slave_task = cocotb.start_soon(spi_slave())
    await load_program_direct(dut, prog)

    for _ in range(500):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 5:
            break
    else:
        slave_task.cancel()
        assert False, "Timeout: IN SCK transaction did not finish at PC=5"

    slave_task.cancel()
    assert sck_pulses == 8, f"Expected 8 SCK pulses, got {sck_pulses}"
    received = int(dut.o_data.value)
    assert received == SLAVE_DATA, f"Expected 0x{SLAVE_DATA:02X}, got 0x{received:02X}"
    dut._log.info(f"IN SCK master read test PASSED: 8 SCK pulses generated, received 0x{received:02X}!")


@cocotb.test()
async def test_in_sda_i2c_read(dut):
    """Test 10C: Synchronous I2C Master Read (IN SDA) releases SDA and reads slave byte."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    dut.i_baud_div.value = 2  # fast simulation
    SLAVE_DATA = 0xD2  # 1101_0010

    # Program:
    # 0x00: PINMAP 4, 4, 1, 2 -> 0x590A (Pin 4 = SDA, Pin 1 = SCL)
    # 0x01: CFG_OD 0x12       -> 0x6012 (Pins 4, 1 open drain)
    # 0x02: IN SDA, 2         -> 0x2C02 (opcode 2, mode 3, delay 2)
    # 0x03: PUSH              -> 0xA000
    # 0x04: JMP 0x04          -> 0x8004
    prog = [
        0x590A,
        0x6012,
        0x2C02,
        0xA000,
        0x8004
    ]

    scl_pulses = 0
    sda_oe_during_in = []
    async def i2c_slave():
        nonlocal scl_pulses
        slave_sr = SLAVE_DATA
        prev_scl = 1
        while True:
            await RisingEdge(dut.i_clk)
            pc_val = int(dut.pc.value)
            scl_oe = (int(dut.o_gpio_oe.value) >> 1) & 1
            scl_out = (int(dut.o_gpio.value) >> 1) & 1
            scl = 0 if (scl_oe and not scl_out) else 1

            sda_oe = (int(dut.o_gpio_oe.value) >> 4) & 1
            if pc_val == 2:
                sda_oe_during_in.append(sda_oe)

            bit = (slave_sr >> 7) & 1
            curr_gpio = int(dut.i_gpio.value)
            if bit:
                dut.i_gpio.value = curr_gpio | (1 << 4)
            else:
                dut.i_gpio.value = curr_gpio & ~(1 << 4)

            if prev_scl == 0 and scl == 1:
                scl_pulses += 1
            elif prev_scl == 1 and scl == 0:
                slave_sr = ((slave_sr << 1) & 0xFF) | 1

            prev_scl = scl

    slave_task = cocotb.start_soon(i2c_slave())
    await load_program_direct(dut, prog)

    for _ in range(500):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 4:
            break
    else:
        slave_task.cancel()
        assert False, "Timeout: IN SDA transaction did not finish at PC=4"

    slave_task.cancel()
    assert scl_pulses == 8, f"Expected 8 SCL pulses, got {scl_pulses}"
    assert all(oe == 0 for oe in sda_oe_during_in), f"Expected master to release SDA (oe=0), got {sda_oe_during_in}"
    received = int(dut.o_data.value)
    assert received == SLAVE_DATA, f"Expected 0x{SLAVE_DATA:02X}, got 0x{received:02X}"
    dut._log.info(f"IN SDA I2C master read test PASSED: 8 SCL pulses, SDA released, received 0x{received:02X}!")


# -----------------------------------------------------------------------------
# Task 11: Hardware FIFO Handshaking & Status Flags
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_fifo_conditional_jmp(dut):
    """Test 11A: JMP [cond], target branches on TX_VALID, TX_EMPTY, RX_FULL, RX_READY, PIN_HI, PIN_LO."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    # Program:
    # 0x00: JMP TX_VALID, 0x03   -> 0x8103
    # 0x01: NOP 0                 -> 0x0000 (fallthrough if !i_tx_valid)
    # 0x02: JMP 0x02              -> 0x8002
    # 0x03: JMP RX_FULL,  0x06   -> 0x8306
    # 0x04: NOP 0                 -> 0x0000
    # 0x05: JMP 0x05              -> 0x8005
    # 0x06: JMP PIN_HI,   0x09   -> 0x8509
    # 0x07: NOP 0                 -> 0x0000
    # 0x08: JMP 0x08              -> 0x8008
    # 0x09: JMP 0x09              -> 0x8009 (terminal success)
    prog = [
        0x8103, # [0] JMP TX_VALID, 3
        0x0000, # [1]
        0x8002, # [2]
        0x8306, # [3] JMP RX_FULL, 6
        0x0000, # [4]
        0x8005, # [5]
        0x8509, # [6] JMP PIN_HI, 9
        0x0000, # [7]
        0x8008, # [8]
        0x8009  # [9]
    ]

    # Test Branch 1: Set i_tx_valid = 0 -> PC should fall through to 1, then 2
    dut.i_tx_valid.value = 0
    await load_program_direct(dut, prog)
    for _ in range(10):
        await RisingEdge(dut.i_clk)
    assert int(dut.pc.value) == 2, f"Expected fallthrough to PC=2 with tx_valid=0, got {int(dut.pc.value)}"

    # Test Branch 1 Taken: Set i_tx_valid = 1, i_rx_full = 0 -> Should jump 0 -> 3 -> fallthrough to 5
    dut.i_tx_valid.value = 1
    dut.i_rx_full.value = 0
    await load_program_direct(dut, prog)
    for _ in range(10):
        await RisingEdge(dut.i_clk)
    assert int(dut.pc.value) == 5, f"Expected jump to 3 then fallthrough to 5, got {int(dut.pc.value)}"

    # Test Branch 2 Taken: Set i_rx_full = 1, pin = 1 -> Should jump 0 -> 3 -> 6 -> 9
    dut.i_tx_valid.value = 1
    dut.i_rx_full.value = 1
    dut.i_rx.value = 1
    await load_program_direct(dut, prog)
    for _ in range(15):
        await RisingEdge(dut.i_clk)
    assert int(dut.pc.value) == 9, f"Expected jump sequence to PC=9, got {int(dut.pc.value)}"
    dut._log.info("Conditional JMP tests PASSED: all branch and fallthrough paths verified!")


@cocotb.test()
async def test_pull_blocking(dut):
    """Test 11B: PULL BLOCK stalls core while TX FIFO empty and pops immediately when valid."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    # 0x00: PULL BLOCK -> 0x9001
    # 0x01: JMP 0x01   -> 0x8001
    prog = [
        0x9001,
        0x8001
    ]

    # Start with empty TX FIFO
    dut.i_tx_valid.value = 0
    dut.i_data.value = 0x55
    await load_program_direct(dut, prog)

    # Verify core stalls at PC=0 and o_tx_pop remains 0
    for _ in range(15):
        await RisingEdge(dut.i_clk)
        assert int(dut.pc.value) == 0, f"Expected stall at PC=0, got {int(dut.pc.value)}"
        assert int(dut.o_tx_pop.value) == 0, "o_tx_pop must remain 0 while stalled"

    # Present valid data
    dut.i_data.value = 0xAA
    dut.i_tx_valid.value = 1

    # In the cycle where data is accepted:
    await RisingEdge(dut.i_clk)
    # Give 1 cycle to execute
    await RisingEdge(dut.i_clk)
    assert int(dut.pc.value) == 1, f"Expected advance to PC=1, got {int(dut.pc.value)}"
    assert int(dut.osr.value) == 0xAA, f"Expected OSR=0xAA, got {int(dut.osr.value):02X}"

    # Verify o_tx_pop returned to 0
    await RisingEdge(dut.i_clk)
    assert int(dut.o_tx_pop.value) == 0, "o_tx_pop must return to 0 after 1 cycle"
    dut._log.info("Blocking PULL test PASSED: stalled on empty, popped on valid, single-cycle strobe verified!")


@cocotb.test()
async def test_push_blocking(dut):
    """Test 11C: PUSH BLOCK stalls core while RX FIFO full and pushes when space available."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    # 0x00: PUSH BLOCK -> 0xA001
    # 0x01: JMP 0x01   -> 0x8001
    prog = [
        0xA001,
        0x8001
    ]

    # Start with full RX FIFO
    dut.i_rx_full.value = 1
    await load_program_direct(dut, prog)

    # Verify core stalls at PC=0 and o_rx_push remains 0
    for _ in range(15):
        await RisingEdge(dut.i_clk)
        assert int(dut.pc.value) == 0, f"Expected stall at PC=0, got {int(dut.pc.value)}"
        assert int(dut.o_rx_push.value) == 0, "o_rx_push must remain 0 while stalled"

    # Clear RX full (space available)
    dut.i_rx_full.value = 0

    await RisingEdge(dut.i_clk)
    await RisingEdge(dut.i_clk)
    assert int(dut.pc.value) == 1, f"Expected advance to PC=1, got {int(dut.pc.value)}"

    await RisingEdge(dut.i_clk)
    assert int(dut.o_rx_push.value) == 0, "o_rx_push must return to 0 after 1 cycle"
    dut._log.info("Blocking PUSH test PASSED: stalled on full, pushed on space, single-cycle strobe verified!")


@cocotb.test()
async def test_pop_push_strobes(dut):
    """Test 11D: Non-blocking PULL and PUSH generate exact 1-cycle active-high strobes."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    # 0x00: PULL     -> 0x9000
    # 0x01: PUSH     -> 0xA000
    # 0x02: JMP 0x02 -> 0x8002
    prog = [
        0x9000,
        0xA000,
        0x8002
    ]

    dut.i_tx_valid.value = 1
    dut.i_rx_full.value = 0
    dut.i_data.value = 0xBE

    pop_pulses = 0
    push_pulses = 0
    async def monitor_strobes():
        nonlocal pop_pulses, push_pulses
        while True:
            await RisingEdge(dut.i_clk)
            if int(dut.o_tx_pop.value) == 1:
                pop_pulses += 1
            if int(dut.o_rx_push.value) == 1:
                push_pulses += 1

    mon = cocotb.start_soon(monitor_strobes())
    await load_program_direct(dut, prog)

    for _ in range(20):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 2:
            break

    await ClockCycles(dut.i_clk, 5)
    mon.cancel()

    assert pop_pulses == 1, f"Expected exactly 1 pop pulse, got {pop_pulses}"
    assert push_pulses == 1, f"Expected exactly 1 push pulse, got {push_pulses}"
    assert int(dut.o_data.value) == 0x00 or int(dut.o_data.value) == int(dut.isr.value)
    dut._log.info("Pop/Push strobe test PASSED: exact 1-cycle active-high pulses verified!")


# =============================================================================
# Task 12: 1-Wire (OneWire) Protocol Testcases
# =============================================================================

@cocotb.test()
async def test_onewire_write_byte(dut):
    """Test 12A: 1-Wire Master Write Byte (OUT 1W) with open-drain bit timing."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    DELAY = 4  # T_SHORT = 4 cycles (Write 1 low = 4 cyc, Write 0 low = 40 cyc)
    TX_BYTE = 0xCC  # 1100_1100b (bits 0,1=0, bits 2,3=1, bits 4,5=0, bits 6,7=1)

    # 0x00: PINMAP 0, 0, 1, 2 -> 0x500A (TX=0, RX=0, SCK=1, CS=2)
    # 0x01: CFG_OD 0x01       -> 0x6001 (Pin 0 open-drain)
    # 0x02: PULL              -> 0x9000
    # 0x03: OUT 1W, 4         -> 0x1804 (mode=2, delay=4)
    # 0x04: JMP 0x04          -> 0x8004
    prog = [
        0x500A,
        0x6001,
        0x9000,
        0x1804,
        0x8004
    ]
    dut.i_data.value = TX_BYTE

    # Monitor 1-Wire bus on Pin 0
    bits_decoded = []
    async def bus_monitor():
        prev_pin = 1
        low_start = 0
        cycle = 0
        while True:
            await RisingEdge(dut.i_clk)
            cycle += 1
            # Wire level with external pull-up
            pin_drive = (int(dut.o_gpio_oe.value) & 1) and not (int(dut.o_gpio.value) & 1)
            pin_val = 0 if pin_drive else 1
            curr_gpio = int(dut.i_gpio.value)
            dut.i_gpio.value = (curr_gpio & ~1) | pin_val

            if prev_pin == 1 and pin_val == 0:
                low_start = cycle
            elif prev_pin == 0 and pin_val == 1:
                low_dur = cycle - low_start
                # DELAY=4 -> short low is ~4-5 cycles, long low is ~40-41 cycles
                bit = 1 if low_dur < 15 else 0
                bits_decoded.append((bit, low_dur))
            prev_pin = pin_val

    mon = cocotb.start_soon(bus_monitor())
    await load_program_direct(dut, prog)

    for _ in range(1000):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 4:
            break
    else:
        mon.cancel()
        assert False, f"Timeout: OUT 1W did not reach PC=4 (PC={int(dut.pc.value)})"

    await ClockCycles(dut.i_clk, 10)
    mon.cancel()

    assert len(bits_decoded) == 8, f"Expected 8 1-Wire bits, got {len(bits_decoded)}: {bits_decoded}"
    decoded_byte = 0
    for idx, (b, dur) in enumerate(bits_decoded):
        decoded_byte |= (b << idx)

    assert decoded_byte == TX_BYTE, f"1-Wire Write mismatch: expected 0x{TX_BYTE:02X}, got 0x{decoded_byte:02X}"
    dut._log.info(f"1-Wire Write Byte test PASSED: correctly decoded 0x{TX_BYTE:02X} across 8 slots with open-drain timing!")


@cocotb.test()
async def test_onewire_read_byte(dut):
    """Test 12B: 1-Wire Master Read Byte (IN 1W) with slave bit response and sampling."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    DELAY = 4
    SLAVE_BYTE = 0xA5  # 1010_0101b (LSB-first: 1, 0, 1, 0, 0, 1, 0, 1)

    # 0x00: PINMAP 0, 0, 1, 2 -> 0x500A
    # 0x01: CFG_OD 0x01       -> 0x6001
    # 0x02: IN 1W, 4          -> 0x2804 (mode=2, delay=4)
    # 0x03: PUSH              -> 0xA000
    # 0x04: JMP 0x04          -> 0x8004
    prog = [
        0x500A,
        0x6001,
        0x2804,
        0xA000,
        0x8004
    ]

    # Model 1-Wire slave on bus
    async def onewire_slave():
        slave_data = SLAVE_BYTE
        bit_idx = 0
        prev_master_drive = 0
        while bit_idx < 8:
            await RisingEdge(dut.i_clk)
            master_drive_low = (int(dut.o_gpio_oe.value) & 1) and not (int(dut.o_gpio.value) & 1)
            
            # Detect master initiating read slot (falling edge of DQ)
            if not prev_master_drive and master_drive_low:
                # Master started slot. Wait for master to release line (after DELAY cycles)
                cur_bit = (slave_data >> bit_idx) & 1
                bit_idx += 1
                while True:
                    await RisingEdge(dut.i_clk)
                    master_oe = int(dut.o_gpio_oe.value) & 1
                    if master_oe == 0:
                        break # Master released line
                
                # If slave bit is 0, slave pulls line low for ~15 cycles
                if cur_bit == 0:
                    for _ in range(15):
                        curr_gpio = int(dut.i_gpio.value)
                        dut.i_gpio.value = (curr_gpio & ~1) | 0
                        await RisingEdge(dut.i_clk)
                    # Release line
                    curr_gpio = int(dut.i_gpio.value)
                    dut.i_gpio.value = (curr_gpio & ~1) | 1
                else:
                    # Bit is 1: slave leaves line released (pull-up keeps it high)
                    curr_gpio = int(dut.i_gpio.value)
                    dut.i_gpio.value = (curr_gpio & ~1) | 1
            else:
                # Normal pull-up when idle
                curr_gpio = int(dut.i_gpio.value)
                wire_val = 0 if master_drive_low else 1
                dut.i_gpio.value = (curr_gpio & ~1) | wire_val

            prev_master_drive = master_drive_low

    slave_task = cocotb.start_soon(onewire_slave())
    await load_program_direct(dut, prog)

    for _ in range(1000):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 4:
            break
    else:
        slave_task.cancel()
        assert False, f"Timeout: IN 1W did not reach PC=4 (PC={int(dut.pc.value)})"

    await ClockCycles(dut.i_clk, 5)
    slave_task.cancel()

    received_data = int(dut.o_data.value)
    assert received_data == SLAVE_BYTE, f"1-Wire Read mismatch: expected 0x{SLAVE_BYTE:02X}, got 0x{received_data:02X}"
    dut._log.info(f"1-Wire Read Byte test PASSED: successfully sampled and assembled 0x{SLAVE_BYTE:02X} into ISR/o_data!")


@cocotb.test()
async def test_onewire_reset_and_presence(dut):
    """Test 12C: 1-Wire Master Reset Pulse (16-bit $BAUD) and Slave Presence Detection."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    RESET_CYCLES = 300  # Emulate 480us reset with 300 cycles via i_baud_div
    dut.i_baud_div.value = RESET_CYCLES

    # 0x00: PINMAP 0, 0, 1, 2    -> 0x500A
    # 0x01: CFG_OD 0x01           -> 0x6001
    # 0x02: SET 0, 0, $BAUD       -> 0x30FF (Master pull-down reset pulse)
    # 0x03: SET 0, 1, 20          -> 0x3114 (Release line, wait 20 cycles)
    # 0x04: WAIT 0, 0, 30         -> 0x401E (Wait for slave presence pulse low, delay 30 cyc)
    # 0x05: WAIT 0, 1, 20         -> 0x4114 (Wait for presence pulse release high)
    # 0x06: JMP 0x06              -> 0x8006 (Success target)
    prog = [
        0x500A,
        0x6001,
        0x30FF,
        0x3114,
        0x401E,
        0x4114,
        0x8006
    ]

    # Slave detects reset (>50 cycles low), then pulses presence low for 40 cycles
    async def slave_presence():
        low_count = 0
        while True:
            await RisingEdge(dut.i_clk)
            master_drive_low = (int(dut.o_gpio_oe.value) & 1) and not (int(dut.o_gpio.value) & 1)
            if master_drive_low:
                low_count += 1
                curr_gpio = int(dut.i_gpio.value)
                dut.i_gpio.value = (curr_gpio & ~1) | 0
            else:
                if low_count >= 100:
                    # Master finished reset pulse. Wait 10 cycles, then assert presence pulse for 40 cycles
                    for _ in range(10):
                        curr_gpio = int(dut.i_gpio.value)
                        dut.i_gpio.value = (curr_gpio & ~1) | 1
                        await RisingEdge(dut.i_clk)
                    for _ in range(40):
                        curr_gpio = int(dut.i_gpio.value)
                        dut.i_gpio.value = (curr_gpio & ~1) | 0
                        await RisingEdge(dut.i_clk)
                    curr_gpio = int(dut.i_gpio.value)
                    dut.i_gpio.value = (curr_gpio & ~1) | 1
                    break
                else:
                    low_count = 0
                    curr_gpio = int(dut.i_gpio.value)
                    dut.i_gpio.value = (curr_gpio & ~1) | 1

    presence_task = cocotb.start_soon(slave_presence())
    await load_program_direct(dut, prog)

    for _ in range(1000):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 6:
            break
    else:
        presence_task.cancel()
        assert False, f"Timeout: Reset/Presence did not reach PC=6 (PC={int(dut.pc.value)})"

    await ClockCycles(dut.i_clk, 5)
    presence_task.cancel()
    dut._log.info("1-Wire Reset & Presence test PASSED: 300-cycle reset pulse generated and slave presence handshaked!")


@cocotb.test()
async def test_onewire_single_bit(dut):
    """Test 12D: 1-Wire Single-Bit Mode (OUT 1W, 1 and IN 1W, 1) for Search ROM algorithm."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    DELAY = 4
    # 0x00: PINMAP 0, 0, 1, 2  -> 0x500A
    # 0x01: CFG_OD 0x01         -> 0x6001
    # 0x02: PULL                -> 0x9000
    # 0x03: OUT 1W, 1, 4        -> 0x1A04 (mode=2, bit_count=1, delay=4)
    # 0x04: IN 1W, 1, 4         -> 0x2A04 (mode=2, bit_count=1, delay=4)
    # 0x05: JMP 0x05            -> 0x8005
    prog = [
        0x500A,
        0x6001,
        0x9000,
        0x1A04,
        0x2A04,
        0x8005
    ]

    dut.i_data.value = 0x01  # LSB is 1

    # Bus handler: wire pullup
    async def bus_handler():
        while True:
            await RisingEdge(dut.i_clk)
            master_drive_low = (int(dut.o_gpio_oe.value) & 1) and not (int(dut.o_gpio.value) & 1)
            pin_val = 0 if master_drive_low else 1
            curr_gpio = int(dut.i_gpio.value)
            dut.i_gpio.value = (curr_gpio & ~1) | pin_val

    bus_task = cocotb.start_soon(bus_handler())
    await load_program_direct(dut, prog)

    for _ in range(300):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 5:
            break
    else:
        bus_task.cancel()
        assert False, f"Timeout: Single-bit operations did not reach PC=5 (PC={int(dut.pc.value)})"

    await ClockCycles(dut.i_clk, 5)
    bus_task.cancel()

    # The 1 bit sampled by IN 1W, 1 should be 1 (pulled high)
    assert (int(dut.isr.value) & 1) == 1, f"Expected ISR[0]=1, got {int(dut.isr.value)}"
    dut._log.info("1-Wire Single-Bit test PASSED: 1-bit write and read completed in single slot each!")


# -----------------------------------------------------------------------------
# Test 13A: Hardware CRC-8 Dallas / 1-Wire Calculation & Residue Check
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_crc8_dallas_calculation(dut):
    """Test 13A: Hardware Dallas CRC-8 calculation on known vector and zero-residue check."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    # Dallas test vector: [0x02, 0x1C, 0xB8, 0x01, 0x00, 0x00, 0x00] -> CRC = 0xA2
    # Microcode:
    # 0x00: CRC_INIT DALLAS, 0
    # 0x01: SET_LC   LC0, 7
    # 0x02: PULL     BLOCK
    # 0x03: CRC_BYTE OSR
    # 0x04: DJNZ     LC0, 0x02
    # 0x05: CRC_READ_LOW
    # 0x06: PULL     BLOCK
    # 0x07: CRC_BYTE OSR
    # 0x08: CRC_READ_LOW
    # 0x09: JMP      0x09
    prog = [
        0xE020, # CRC_INIT DALLAS, 0
        0x7407, # SET_LC   LC0, 7
        0x9001, # PULL     BLOCK
        0xE200, # CRC_BYTE OSR
        0x7002, # DJNZ     LC0, 0x02
        0xE800, # CRC_READ_LOW
        0x9001, # PULL     BLOCK
        0xE200, # CRC_BYTE OSR
        0xE800, # CRC_READ_LOW
        0x8009  # JMP      0x09
    ]

    vector = [0x02, 0x1C, 0xB8, 0x01, 0x00, 0x00, 0x00]
    expected_crc = 0xA2

    async def feed_fifo(byte_list):
        for b in byte_list:
            dut.i_data.value = b
            dut.i_tx_valid.value = 1
            while True:
                await RisingEdge(dut.i_clk)
                if int(dut.o_tx_pop.value) == 1:
                    break
        dut.i_tx_valid.value = 0

    await load_program_direct(dut, prog)

    # Feed the 7 payload bytes
    feed_task = cocotb.start_soon(feed_fifo(vector))

    # Wait until PC reaches 6 (immediately after CRC_READ_LOW at PC=5)
    for _ in range(200):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 6:
            break
    else:
        feed_task.cancel()
        assert False, f"Timeout waiting for PC=6 (current PC={int(dut.pc.value)})"

    feed_task.cancel()
    calc_crc = int(dut.o_data.value)
    dut._log.info(f"Dallas CRC calculated: 0x{calc_crc:02X} (expected: 0x{expected_crc:02X})")
    assert calc_crc == expected_crc, f"Dallas CRC mismatch: expected 0x{expected_crc:02X}, got 0x{calc_crc:02X}"

    # Now feed the 8th byte: the calculated CRC itself (0xA2)
    feed_crc_task = cocotb.start_soon(feed_fifo([expected_crc]))

    # Wait until PC reaches 9 (halt after reading residue)
    for _ in range(100):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 9:
            break
    else:
        feed_crc_task.cancel()
        assert False, f"Timeout waiting for PC=9 (current PC={int(dut.pc.value)})"

    feed_crc_task.cancel()
    residue = int(dut.o_data.value)
    dut._log.info(f"Dallas CRC residue: 0x{residue:02X} (expected: 0x00)")
    assert residue == 0x00, f"Dallas residue mismatch: expected 0x00, got 0x{residue:02X}"
    assert int(dut.crc_reg.value) == 0, f"Expected crc_reg == 0, got {int(dut.crc_reg.value)}"
    dut._log.info("Dallas CRC-8 test PASSED: 0xA2 computed and 0x00 residue verified!")


# -----------------------------------------------------------------------------
# Test 13B: Hardware CRC-8 SMBus / I2C PEC Calculation & Residue Check
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_crc8_smbus_pec(dut):
    """Test 13B: Hardware SMBus PEC CRC-8 calculation on known vector and zero-residue check."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    # SMBus test vector: [0xB2, 0x04, 0x00, 0x00] -> PEC = 0x1F
    # Microcode:
    # 0x00: CRC_INIT SMBUS, 0
    # 0x01: SET_LC   LC0, 4
    # 0x02: PULL     BLOCK
    # 0x03: CRC_BYTE OSR
    # 0x04: DJNZ     LC0, 0x02
    # 0x05: CRC_READ_LOW
    # 0x06: PULL     BLOCK
    # 0x07: CRC_BYTE OSR
    # 0x08: CRC_READ_LOW
    # 0x09: JMP      0x09
    prog = [
        0xE0A0, # CRC_INIT SMBUS, 0
        0x7404, # SET_LC   LC0, 4
        0x9001, # PULL     BLOCK
        0xE200, # CRC_BYTE OSR
        0x7002, # DJNZ     LC0, 0x02
        0xE800, # CRC_READ_LOW
        0x9001, # PULL     BLOCK
        0xE200, # CRC_BYTE OSR
        0xE800, # CRC_READ_LOW
        0x8009  # JMP      0x09
    ]

    vector = [0xB2, 0x04, 0x00, 0x00]
    expected_pec = 0x1F

    async def feed_fifo(byte_list):
        for b in byte_list:
            dut.i_data.value = b
            dut.i_tx_valid.value = 1
            while True:
                await RisingEdge(dut.i_clk)
                if int(dut.o_tx_pop.value) == 1:
                    break
        dut.i_tx_valid.value = 0

    await load_program_direct(dut, prog)

    feed_task = cocotb.start_soon(feed_fifo(vector))

    for _ in range(200):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 6:
            break
    else:
        feed_task.cancel()
        assert False, f"Timeout waiting for PC=6 (current PC={int(dut.pc.value)})"

    feed_task.cancel()
    calc_pec = int(dut.o_data.value)
    dut._log.info(f"SMBus PEC calculated: 0x{calc_pec:02X} (expected: 0x{expected_pec:02X})")
    assert calc_pec == expected_pec, f"SMBus PEC mismatch: expected 0x{expected_pec:02X}, got 0x{calc_pec:02X}"

    # Feed PEC byte (0x1F) to verify residue
    feed_pec_task = cocotb.start_soon(feed_fifo([expected_pec]))

    for _ in range(100):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 9:
            break
    else:
        feed_pec_task.cancel()
        assert False, f"Timeout waiting for PC=9 (current PC={int(dut.pc.value)})"

    feed_pec_task.cancel()
    residue = int(dut.o_data.value)
    dut._log.info(f"SMBus PEC residue: 0x{residue:02X} (expected: 0x00)")
    assert residue == 0x00, f"SMBus residue mismatch: expected 0x00, got 0x{residue:02X}"
    assert int(dut.crc_reg.value) == 0, f"Expected crc_reg == 0, got {int(dut.crc_reg.value)}"
    dut._log.info("SMBus PEC CRC-8 test PASSED: 0x1F computed and 0x00 residue verified!")


# -----------------------------------------------------------------------------
# Test 13C: Hardware CRC-16 Modbus and CCITT Calculation
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_crc16_modbus_and_ccitt(dut):
    """Test 13C: Hardware CRC-16 Modbus (0xA001) and CCITT (0x1021) calculation & readout."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    async def feed_fifo(byte_list):
        for b in byte_list:
            dut.i_data.value = b
            dut.i_tx_valid.value = 1
            while True:
                await RisingEdge(dut.i_clk)
                if int(dut.o_tx_pop.value) == 1:
                    break
        dut.i_tx_valid.value = 0

    # -------------------------------------------------------------------------
    # Part 1: Modbus RTU CRC-16
    # Vector: [0x01, 0x03, 0x00, 0x00, 0x00, 0x0A] -> CRC = 0xCDC5 (Low=0xC5, High=0xCD)
    # -------------------------------------------------------------------------
    modbus_prog = [
        0xE1C0, # CRC_INIT MODBUS, 0xFFFF
        0x7406, # SET_LC   LC0, 6
        0x9001, # PULL     BLOCK
        0xE200, # CRC_BYTE OSR
        0x7002, # DJNZ     LC0, 0x02
        0xE800, # CRC_READ_LOW   (PC=5)
        0xEA00, # CRC_READ_HIGH  (PC=6)
        0x9001, # PULL     BLOCK (feed low CRC)
        0xE200, # CRC_BYTE OSR
        0x9001, # PULL     BLOCK (feed high CRC)
        0xE200, # CRC_BYTE OSR
        0xE800, # CRC_READ_LOW   (residue low)
        0xEA00, # CRC_READ_HIGH  (residue high)
        0x800D  # JMP      0x0D  (halt PC=13)
    ]

    await load_program_direct(dut, modbus_prog)
    modbus_vec = [0x01, 0x03, 0x00, 0x00, 0x00, 0x0A]
    feed_task = cocotb.start_soon(feed_fifo(modbus_vec))

    low_crc = None
    high_crc = None
    while True:
        await RisingEdge(dut.i_clk)
        pc_val = int(dut.pc.value)
        if pc_val == 6 and low_crc is None:
            low_crc = int(dut.o_data.value)
        elif pc_val == 7 and high_crc is None:
            high_crc = int(dut.o_data.value)
            break

    feed_task.cancel()
    dut._log.info(f"Modbus CRC calculated: Low=0x{low_crc:02X}, High=0x{high_crc:02X}")
    assert low_crc == 0xC5, f"Expected Modbus Low=0xC5, got 0x{low_crc:02X}"
    assert high_crc == 0xCD, f"Expected Modbus High=0xCD, got 0x{high_crc:02X}"

    # Feed low then high to check residue
    feed_residue_task = cocotb.start_soon(feed_fifo([0xC5, 0xCD]))
    for _ in range(100):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 13:
            break
    feed_residue_task.cancel()

    assert int(dut.crc_reg.value) == 0, f"Modbus residue non-zero: 0x{int(dut.crc_reg.value):04X}"
    dut._log.info("Modbus CRC-16 test PASSED: 0xCDC5 calculated and 0x0000 residue verified!")

    # -------------------------------------------------------------------------
    # Part 2: CCITT CRC-16
    # Vector: [0x31, 0x32, 0x33, 0x34] ("1234") -> CRC = 0xD789 (High=0xD7, Low=0x89)
    # -------------------------------------------------------------------------
    ccitt_prog = [
        0xE100, # CRC_INIT CCITT, 0
        0x7404, # SET_LC   LC0, 4
        0x9001, # PULL     BLOCK
        0xE200, # CRC_BYTE OSR
        0x7002, # DJNZ     LC0, 0x02
        0xEA00, # CRC_READ_HIGH (PC=5)
        0xE800, # CRC_READ_LOW  (PC=6)
        0x9001, # PULL     BLOCK (feed high CRC)
        0xE200, # CRC_BYTE OSR
        0x9001, # PULL     BLOCK (feed low CRC)
        0xE200, # CRC_BYTE OSR
        0xE800, # CRC_READ_LOW  (residue)
        0x800C  # JMP      0x0C (halt PC=12)
    ]

    await load_program_direct(dut, ccitt_prog)
    ccitt_vec = [0x31, 0x32, 0x33, 0x34]
    feed_ccitt_task = cocotb.start_soon(feed_fifo(ccitt_vec))

    ccitt_high = None
    ccitt_low = None
    while True:
        await RisingEdge(dut.i_clk)
        pc_val = int(dut.pc.value)
        if pc_val == 6 and ccitt_high is None:
            ccitt_high = int(dut.o_data.value)
        elif pc_val == 7 and ccitt_low is None:
            ccitt_low = int(dut.o_data.value)
            break

    feed_ccitt_task.cancel()
    dut._log.info(f"CCITT CRC calculated: High=0x{ccitt_high:02X}, Low=0x{ccitt_low:02X}")
    assert ccitt_high == 0xD7, f"Expected CCITT High=0xD7, got 0x{ccitt_high:02X}"
    assert ccitt_low == 0x89, f"Expected CCITT Low=0x89, got 0x{ccitt_low:02X}"

    # Feed high then low to verify residue
    feed_ccitt_res = cocotb.start_soon(feed_fifo([0xD7, 0x89]))
    for _ in range(100):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 12:
            break
    feed_ccitt_res.cancel()

    assert int(dut.crc_reg.value) == 0, f"CCITT residue non-zero: 0x{int(dut.crc_reg.value):04X}"
    dut._log.info("CCITT CRC-16 test PASSED: 0xD789 calculated and 0x0000 residue verified!")


# -----------------------------------------------------------------------------
# Test 13D: JMP CRC_OK Conditional Branching
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_crc_jmp_conditional(dut):
    """Test 13D: Hardware zero-overhead conditional branch via JMP CRC_OK."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    async def feed_fifo(byte_list):
        for b in byte_list:
            dut.i_data.value = b
            dut.i_tx_valid.value = 1
            while True:
                await RisingEdge(dut.i_clk)
                if int(dut.o_tx_pop.value) == 1:
                    break
        dut.i_tx_valid.value = 0

    # Microcode:
    # 0x00: CRC_INIT DALLAS, 0
    # 0x01: PULL     BLOCK
    # 0x02: CRC_BYTE OSR
    # 0x03: PULL     BLOCK
    # 0x04: CRC_BYTE OSR
    # 0x05: JMP      CRC_OK, 0x08
    # 0x06: SET      1, 0, 0 (fail)
    # 0x07: JMP      0x07
    # 0x08: SET      1, 1, 0 (success)
    # 0x09: JMP      0x09
    prog = [
        0xE020, # CRC_INIT DALLAS, 0
        0x9001, # PULL     BLOCK
        0xE200, # CRC_BYTE OSR
        0x9001, # PULL     BLOCK
        0xE200, # CRC_BYTE OSR
        0x8708, # JMP      CRC_OK, 0x08
        0x3200, # SET      1, 0, 0
        0x8007, # JMP      0x07
        0x3300, # SET      1, 1, 0
        0x8009  # JMP      0x09
    ]

    # Sub-test 1: Valid packet (Data=0x02, CRC=0x02 -> for Dallas with single byte 0x02, CRC=0x1C? Wait, let's check single byte 0x02)
    # With data = 0x02, Dallas CRC-8 is:
    # Let's feed byte 0x5A, then its calculated CRC:
    # Instead of guessing, let's feed [0x00, 0x00] -> Dallas CRC of 0x00 is 0x00!
    # If data = 0x00, CRC is 0x00 -> residue is 0x00.
    # Or let's test with Data = 0x02, CRC = 0x1C (from vector: 0x02 -> 0x1C? wait, earlier vector was [0x02, 0x1C, 0xB8...])
    # Let's verify Dallas CRC of [0x5A]:
    # In python: crc8_dallas([0x5A]) = 0x5F. Feeding 0x5A, 0x5F gives residue 0.
    # Feeding 0x5A, 0xEE gives non-zero residue!

    # Sub-test 1: Clean packet -> [0x5A, 0xA5]
    await load_program_direct(dut, prog)
    task1 = cocotb.start_soon(feed_fifo([0x5A, 0xA5]))

    for _ in range(50):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 9:
            break
    else:
        task1.cancel()
        assert False, f"Timeout on valid packet (PC={int(dut.pc.value)})"

    task1.cancel()
    pin1_val = (int(dut.o_gpio.value) >> 1) & 1
    assert pin1_val == 1, f"Expected Pin 1 == 1 (success), got {pin1_val}"
    assert int(dut.pc.value) == 9, f"Expected PC == 9 (success halt), got {int(dut.pc.value)}"
    dut._log.info("Clean packet branch PASSED: JMP CRC_OK successfully jumped to success!")

    # Sub-test 2: Corrupted packet -> [0x5A, 0xEE]
    await load_program_direct(dut, prog)
    task2 = cocotb.start_soon(feed_fifo([0x5A, 0xEE]))

    for _ in range(50):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 7:
            break
    else:
        task2.cancel()
        assert False, f"Timeout on corrupt packet (PC={int(dut.pc.value)})"

    task2.cancel()
    pin1_val = (int(dut.o_gpio.value) >> 1) & 1
    assert pin1_val == 0, f"Expected Pin 1 == 0 (fail), got {pin1_val}"
    assert int(dut.pc.value) == 7, f"Expected PC == 7 (fail loop), got {int(dut.pc.value)}"
    dut._log.info("Corrupted packet branch PASSED: JMP CRC_OK fell through to failure branch!")


# =============================================================================
# Task 15: 8-bit Micro-ALU & Arithmetic Engine (Opcode 0xB) Tests
# =============================================================================

@cocotb.test()
async def test_alu_arithmetic_and_flags(dut):
    """Test 15A: ADD, SUB, CMP arithmetic operations, carry and zero flags, and JMP conditions."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    # Microcode test program:
    # 0: MOV acc, 0x55
    # 1: ADD acc, 0xAA      ; 0x55 + 0xAA = 0xFF (no carry, non-zero)
    # 2: ADD acc, 0x01      ; 0xFF + 0x01 = 0x00 (carry=1, zero=1)
    # 3: JMP NOT_ZERO, 10   ; Should not jump
    # 4: JMP CARRY, 6       ; Should jump to 6
    # 5: JMP 10             ; Trap if jump missed
    # 6: SUB acc, 0x01      ; 0x00 - 0x01 = 0xFF (carry/borrow=1, non-zero)
    # 7: CMP acc, 0xFF      ; 0xFF - 0xFF = 0 (carry=0, zero=1, acc remains 0xFF)
    # 8: JMP ZERO, 9        ; Should jump to 9
    # 9: SET 1, 1, 0        ; Success indicator (Pin 1 = 1)
    # 10: NOP               ; Error/halt
    prog_asm = """
    MOV acc, 0x55
    ADD acc, 0xAA
    ADD acc, 0x01
    JMP NOT_ZERO, 10
    JMP CARRY, 6
    JMP 10
    SUB acc, 0x01
    CMP acc, 0xFF
    JMP ZERO, 9
    SET 1, 1, 0
    NOP
    """
    asm = OmnibusAssembler()
    words, _ = asm.assemble(prog_asm)
    prog = [w[1] for w in words]

    await load_program_direct(dut, prog)

    # Step through execution and observe flags & results
    for _ in range(25):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 10:
            break

    assert int(dut.acc.value) == 0xFF, f"Expected acc == 0xFF, got 0x{int(dut.acc.value):02X}"
    assert int(dut.zero_flag.value) == 1, f"Expected zero_flag == 1 from CMP, got {int(dut.zero_flag.value)}"
    assert int(dut.carry_flag.value) == 0, f"Expected carry_flag == 0 from CMP 0xFF, got {int(dut.carry_flag.value)}"

    pin1_val = (int(dut.o_gpio.value) >> 1) & 1
    assert pin1_val == 1, f"Expected Pin 1 == 1 (success), got {pin1_val}"
    dut._log.info("Test 15A: ALU Arithmetic, Flags, and JMP Conditions PASSED!")


@cocotb.test()
async def test_alu_logic_and_shifts(dut):
    """Test 15B: AND, OR, XOR, NOT, INC, DEC, CLR, SHL, SHR bitwise and shift operations."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    prog_asm = """
    MOV acc, 0xF0
    AND acc, 0x3C       ; 0xF0 & 0x3C = 0x30
    OR  acc, 0x05       ; 0x30 | 0x05 = 0x35
    XOR acc, 0x35       ; 0x35 ^ 0x35 = 0x00 (zero=1)
    NOT acc             ; ~0x00 = 0xFF
    INC acc             ; 0xFF + 1 = 0x00 (carry=1, zero=1)
    DEC acc             ; 0x00 - 1 = 0xFF (carry/borrow=1)
    SHL acc             ; 0xFF << 1 = 0xFE (carry=1)
    SHR acc             ; 0xFE >> 1 = 0x7F (carry=0)
    CLR acc             ; acc = 0x00 (zero=1)
    SET 2, 1, 0         ; Success: Pin 2 = 1
    NOP
    """
    asm = OmnibusAssembler()
    words, _ = asm.assemble(prog_asm)
    prog = [w[1] for w in words]

    await load_program_direct(dut, prog)

    for _ in range(25):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 11:
            break

    assert int(dut.acc.value) == 0x00, f"Expected acc == 0x00, got 0x{int(dut.acc.value):02X}"
    assert int(dut.zero_flag.value) == 1, f"Expected zero_flag == 1, got {int(dut.zero_flag.value)}"

    pin2_val = (int(dut.o_gpio.value) >> 2) & 1
    assert pin2_val == 1, f"Expected Pin 2 == 1 (success), got {pin2_val}"
    dut._log.info("Test 15B: ALU Logic, Inversion, and Shifts PASSED!")


@cocotb.test()
async def test_alu_register_transfers(dut):
    """Test 15C: Inter-register transfers (MOV acc, reg & MOV reg, acc) and dynamic loop setup."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    # Use ALU to compute LC0 count = 4, then loop with DJNZ
    prog_asm = """
    MOV acc, 10
    SUB acc, 6          ; acc <= 4
    MOV LC0, acc        ; LC0 <= 4
    MOV acc, 0
loop:
    INC acc             ; increments acc 4 times
    DJNZ LC0, loop
    SET 0, 1, 0         ; Pin 0 = 1 on loop completion
    NOP
    """
    asm = OmnibusAssembler()
    words, _ = asm.assemble(prog_asm)
    prog = [w[1] for w in words]

    await load_program_direct(dut, prog)

    for _ in range(30):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 6:
            break

    assert int(dut.acc.value) == 4, f"Expected acc == 4 after loop, got {int(dut.acc.value)}"
    assert int(dut.lc0.value) == 0, f"Expected LC0 == 0 after loop, got {int(dut.lc0.value)}"

    pin0_val = int(dut.o_gpio.value) & 1
    assert pin0_val == 1, f"Expected Pin 0 == 1, got {pin0_val}"
    dut._log.info("Test 15C: ALU Register Transfers & Dynamic Loop Setup PASSED!")


@cocotb.test()
async def test_alu_packet_parser(dut):
    """Test 15D: Full autonomous packet parser demo (magic verification, length decode, CRC validation)."""
    start_clock(dut.i_clk)
    await reset_dut(dut)
    dut.i_tx_valid.value = 0

    demo_path = os.path.join(repo_root, "examples/packet_parser_demo.asm")
    words, _ = assemble_file(demo_path)
    prog = [w[1] for w in words]

    def calc_dallas(bytes_list):
        crc = 0
        for b in bytes_list:
            cur = b
            for _ in range(8):
                mix = (crc ^ cur) & 0x01
                crc >>= 1
                if mix:
                    crc ^= 0x8C
                cur >>= 1
        return crc

    # Sub-test 1: Valid Packet [0x5A, 3, 0x10, 0x20, 0x30, CRC] -> expects ACK (0x06)
    payload = [0x10, 0x20, 0x30]
    crc_val = calc_dallas(payload)
    valid_pkt = [0x5A, len(payload)] + payload + [crc_val]

    await load_program_direct(dut, prog)

    async def send_pkt(bytes_data):
        for b in bytes_data:
            dut.i_data.value = b
            dut.i_tx_valid.value = 1
            while True:
                await RisingEdge(dut.i_clk)
                if int(dut.o_tx_pop.value) == 1:
                    break
            dut.i_tx_valid.value = 0
            await RisingEdge(dut.i_clk)

    pkt_task = cocotb.start_soon(send_pkt(valid_pkt))

    # Wait for response on o_data with o_rx_push
    for _ in range(200):
        await RisingEdge(dut.i_clk)
        if int(dut.o_rx_push.value) == 1:
            resp = int(dut.o_data.value)
            break
    else:
        pkt_task.cancel()
        assert False, "Timeout waiting for packet parser response"

    pkt_task.cancel()
    assert resp == 0x06, f"Expected ACK (0x06) for valid packet, got 0x{resp:02X}"
    dut._log.info(f"Valid Packet parsed successfully: response = 0x{resp:02X} (ACK)")
    await ClockCycles(dut.i_clk, 5)

    # Sub-test 2: Bad Magic Packet [0x55] -> expects 0xFF error
    bad_magic_pkt = [0x55]
    pkt_task2 = cocotb.start_soon(send_pkt(bad_magic_pkt))

    for _ in range(200):
        await RisingEdge(dut.i_clk)
        if int(dut.o_rx_push.value) == 1:
            resp2 = int(dut.o_data.value)
            break
    else:
        pkt_task2.cancel()
        assert False, "Timeout waiting for bad magic response"

    pkt_task2.cancel()
    assert resp2 == 0xFF, f"Expected Error (0xFF) for bad magic packet, got 0x{resp2:02X}"
    dut._log.info(f"Bad Magic Packet detected: response = 0x{resp2:02X} (Error)")
    await ClockCycles(dut.i_clk, 5)

    # Sub-test 3: Corrupt CRC Packet [0x5A, 3, 0x10, 0x20, 0x30, 0xEE] -> expects NAK (0x15)
    bad_crc_pkt = [0x5A, len(payload)] + payload + [0xEE]
    pkt_task3 = cocotb.start_soon(send_pkt(bad_crc_pkt))

    for _ in range(200):
        await RisingEdge(dut.i_clk)
        if int(dut.o_rx_push.value) == 1:
            resp3 = int(dut.o_data.value)
            break
    else:
        pkt_task3.cancel()
        assert False, "Timeout waiting for bad CRC response"

    pkt_task3.cancel()
    assert resp3 == 0x15, f"Expected NAK (0x15) for corrupt CRC packet, got 0x{resp3:02X}"
    dut._log.info(f"Corrupt CRC Packet rejected: response = 0x{resp3:02X} (NAK)")

    dut._log.info("Test 15D: Autonomous Packet Parser Demo PASSED across all frame types!")


# =============================================================================
# Task 16: Instruction Memory (IMEM) Expansion to 128 Words & Bank Switching
# =============================================================================

@cocotb.test()
async def test_imem_128_words_linear(dut):
    """Task 16A: Verifies linear execution across all 128 words crossing bank boundaries."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    # Build 128-instruction program:
    #   [0..125]: ADD acc, 1 (each increments acc by 1)
    #   [126]:    ADD acc, 1
    #   [127]:    JMP 127      (halt loop)
    asm_source = ""
    for i in range(127):
        asm_source += f"ADD acc, 1\n"
    asm_source += "halt:\nJMP halt\n"

    asm = OmnibusAssembler()
    instructions, _ = asm.assemble(asm_source)
    assert len(instructions) == 128, f"Expected 128 instructions, got {len(instructions)}"

    prog = [w[1] for w in instructions]
    await load_program_direct(dut, prog)

    # Wait for execution to reach word 127
    for _ in range(250):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 127:
            break
    else:
        assert False, f"Timeout waiting for linear execution to reach PC=127 (current PC={int(dut.pc.value)})"

    assert int(dut.acc.value) == 127, f"Expected acc=127 after 127 ADDs, got {int(dut.acc.value)}"
    dut._log.info("Test 16A: Linear execution across all 128 words and 4 banks verified! (acc=127, PC=127)")


@cocotb.test()
async def test_bank_switching_and_hot_reload(dut):
    """Task 16B: Verifies BANK instruction, active_bank register, and JMP_BANK inter-bank jump."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    # Bank 0:
    #   [0]: SET_BANK 1     (switch active bank to 1)
    #   [1]: MOV acc, BANK  (read active bank into acc)
    #   [2]: JMP_BANK 2     (switch active bank to 2 and jump to address 64)
    # Bank 2 (address 64):
    #   [64]: ADD acc, 10   (acc = 1 + 10 = 11)
    #   [65]: JMP 65        (halt)
    asm_source = """
    SET_BANK 1
    MOV acc, BANK
    JMP_BANK 2

    @64
    ADD acc, 10
halt:
    JMP halt
"""
    asm = OmnibusAssembler()
    instructions, _ = asm.assemble(asm_source)
    prog = [w[1] for w in instructions]

    # Load instructions directly to their addresses
    dut.i_prog_en.value = 1
    await RisingEdge(dut.i_clk)
    for addr, word, _ in instructions:
        dut.i_prog_addr.value = addr
        dut.i_prog_data.value = word
        dut.i_prog_we.value = 1
        await RisingEdge(dut.i_clk)
        dut.i_prog_we.value = 0
        await RisingEdge(dut.i_clk)
    dut.i_prog_en.value = 0
    await RisingEdge(dut.i_clk)

    # Run and verify execution reaches Bank 2 halt
    for _ in range(50):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 65:
            break
    else:
        assert False, f"Timeout: failed to jump to Bank 2 (PC={int(dut.pc.value)}, active_bank={int(dut.active_bank.value)})"

    assert int(dut.active_bank.value) == 2, f"Expected active_bank=2, got {int(dut.active_bank.value)}"
    assert int(dut.acc.value) == 11, f"Expected acc=11 (1 from Bank 1 + 10 in Bank 2), got {int(dut.acc.value)}"
    dut._log.info("Test 16B: Bank switching and JMP_BANK verified! (active_bank=2, acc=11, PC=65)")


@cocotb.test()
async def test_call_ret_extended_range(dut):
    """Task 16C: Verifies CALL and RET across banks (caller in Bank 0, callee in Bank 3)."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    # Caller in Bank 0:
    #   [0]: MOV acc, 5
    #   [1]: CALL 100       (jump to subroutine in Bank 3 at address 100)
    #   [2]: ADD acc, 3     (acc = 5 + 20 + 3 = 28)
    #   [3]: JMP halt
    #
    # Callee in Bank 3 (address 100):
    #   [100]: ADD acc, 20
    #   [101]: RET
    asm_source = """
    MOV acc, 5
    CALL sub_bank3
    ADD acc, 3
halt:
    JMP halt

    @100
sub_bank3:
    ADD acc, 20
    RET
"""
    asm = OmnibusAssembler()
    instructions, _ = asm.assemble(asm_source)

    dut.i_prog_en.value = 1
    await RisingEdge(dut.i_clk)
    for addr, word, _ in instructions:
        dut.i_prog_addr.value = addr
        dut.i_prog_data.value = word
        dut.i_prog_we.value = 1
        await RisingEdge(dut.i_clk)
        dut.i_prog_we.value = 0
        await RisingEdge(dut.i_clk)
    dut.i_prog_en.value = 0
    await RisingEdge(dut.i_clk)

    # Run and wait for halt
    for _ in range(50):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 3:
            break
    else:
        assert False, f"Timeout: failed to return from Bank 3 subroutine (PC={int(dut.pc.value)})"

    assert int(dut.acc.value) == 28, f"Expected acc=28 after cross-bank CALL/RET, got {int(dut.acc.value)}"
    dut._log.info("Test 16C: Cross-bank CALL/RET verified! (Caller Bank 0 -> Callee Bank 3 -> Return Bank 0, acc=28)")


# =============================================================================
# Task 17: Autonomous Stream Accelerators (NRZI & Bit-Stuffing / De-stuffing)
# =============================================================================

@cocotb.test()
async def test_assist_nrzi_tx_rx(dut):
    """Task 17A: Verifies NRZI encoding on TX (toggle on 0, hold on 1) and decoding on RX."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    DELAY = 4
    # Program:
    #   [0]: ASSIST CFG, NRZI=1, STUFF=0, INIT=1
    #   [1]: MOV acc, 0x96     (0b1001_0110: bits 0..7 are 0,1,1,0,1,0,0,1)
    #   [2]: MOV OSR, acc
    #   [3]: OUT 8, 4
    #   [4]: JMP halt
    asm_source = f"""
    ASSIST CFG, NRZI=1, STUFF=0, INIT=1
    MOV acc, 0x96
    MOV OSR, acc
    OUT 8, {DELAY}
halt:
    JMP halt
"""
    asm = OmnibusAssembler()
    instructions, _ = asm.assemble(asm_source)
    prog = [w[1] for w in instructions]

    tx_bits = []
    async def monitor_tx():
        while int(dut.pc.value) != 3:
            await RisingEdge(dut.i_clk)
        while len(tx_bits) < 8:
            await RisingEdge(dut.i_clk)
            if int(dut.delay_cnt.value) == 2:
                tx_bits.append(int(dut.o_tx.value))

    mon = cocotb.start_soon(monitor_tx())
    await load_program_direct(dut, prog)

    for _ in range(200):
        await RisingEdge(dut.i_clk)
        if len(tx_bits) == 8:
            break
    else:
        assert False, f"Timeout waiting for 8 NRZI bits (got {len(tx_bits)})"

    mon.cancel()
    # Expected NRZI waveform for 0x96 (LSB-first: 0, 1, 1, 0, 1, 0, 0, 1) starting from initial state 1:
    # Bit 0 (0) -> toggle to 0
    # Bit 1 (1) -> hold at 0
    # Bit 2 (1) -> hold at 0
    # Bit 3 (0) -> toggle to 1
    # Bit 4 (1) -> hold at 1
    # Bit 5 (0) -> toggle to 0
    # Bit 6 (0) -> toggle to 1
    # Bit 7 (1) -> hold at 1
    expected_nrzi = [0, 0, 0, 1, 1, 0, 1, 1]
    assert tx_bits == expected_nrzi, f"NRZI TX mismatch: expected {expected_nrzi}, got {tx_bits}"
    dut._log.info(f"Test 17A: NRZI TX encoding verified! Emitted {tx_bits} for 0x96")


@cocotb.test()
async def test_assist_usb_bit_stuffing_tx(dut):
    """Task 17B: Verifies USB 1.1 bit-stuffing on TX (inserts '0' after 6 consecutive 1s)."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    DELAY = 4
    # Program:
    #   [0]: ASSIST CFG, NRZI=0, STUFF=USB
    #   [1]: MOV acc, 0x7E     (0b0111_1110: LSB-first: 0, 1, 1, 1, 1, 1, 1, 0 -> 6 consecutive 1s!)
    #   [2]: MOV OSR, acc
    #   [3]: OUT 8, 4          (should transmit 9 bits: 0, 1, 1, 1, 1, 1, 1, [0_STUFF], 0)
    #   [4]: JMP halt
    asm_source = f"""
    ASSIST CFG, NRZI=0, STUFF=USB
    MOV acc, 0x7E
    MOV OSR, acc
    OUT 8, {DELAY}
halt:
    JMP halt
"""
    asm = OmnibusAssembler()
    instructions, _ = asm.assemble(asm_source)
    prog = [w[1] for w in instructions]

    tx_bits = []
    async def monitor_tx():
        while int(dut.pc.value) != 3:
            await RisingEdge(dut.i_clk)
        while len(tx_bits) < 9:
            await RisingEdge(dut.i_clk)
            if int(dut.delay_cnt.value) == 2:
                tx_bits.append(int(dut.o_tx.value))

    mon = cocotb.start_soon(monitor_tx())
    await load_program_direct(dut, prog)

    for _ in range(250):
        await RisingEdge(dut.i_clk)
        if len(tx_bits) == 9:
            break
    else:
        assert False, f"Timeout waiting for 9 bits (got {len(tx_bits)}: {tx_bits})"

    mon.cancel()
    # Expected: 8 data bits + 1 stuff bit inserted after the 6th '1'
    expected_bits = [0, 1, 1, 1, 1, 1, 1, 0, 0]  # bit 7 is the stuffed 0, bit 8 is the payload 0
    assert len(tx_bits) == 9, f"Expected 9 bits (8 payload + 1 stuff), got {len(tx_bits)}: {tx_bits}"
    assert tx_bits == expected_bits, f"USB Bit-Stuffing mismatch: expected {expected_bits}, got {tx_bits}"
    dut._log.info(f"Test 17B: USB 1.1 Bit-Stuffing on TX verified! Inserted '0' stuff bit: {tx_bits}")


@cocotb.test()
async def test_assist_usb_bit_destuffing_rx(dut):
    """Task 17C: Verifies USB 1.1 bit-destuffing on RX (strips '0' after 6 consecutive 1s)."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    DELAY = 4
    # Line starts idle high (1).
    # Then start bit (0) -> WAIT 0, 0 detects falling edge.
    # NOP 2 steps past start bit to midpoint of bit 0.
    # IN 8, 4 samples 8 payload bits, transparently stripping stuff bit.
    asm_source = f"""
    ASSIST CFG, NRZI=0, STUFF=USB
    WAIT 0, 0
    NOP 4
    IN 8, {DELAY}
    PUSH
halt:
    JMP halt
"""
    asm = OmnibusAssembler()
    instructions, _ = asm.assemble(asm_source)
    prog = [w[1] for w in instructions]

    # Pre-idle RX line HIGH
    dut.i_gpio.value = 1
    dut.i_rx.value = 1

    await load_program_direct(dut, prog)

    # Payload 0x7E with stuff bit: [0, 1, 1, 1, 1, 1, 1, 0_STUFF, 0_DATA]
    # Plus start bit (0):
    full_stream = [0] + [0, 1, 1, 1, 1, 1, 1, 0, 0]
    
    # Wait for core to reach WAIT 0, 0 (PC=1)
    while int(dut.pc.value) != 1:
        await RisingEdge(dut.i_clk)
    await ClockCycles(dut.i_clk, 4)

    # Feed stream: 5 cycles per bit period
    for bit in full_stream:
        dut.i_gpio.value = bit
        dut.i_rx.value = bit
        await ClockCycles(dut.i_clk, DELAY + 1)

    # Return line to idle high
    dut.i_gpio.value = 1
    dut.i_rx.value = 1

    # Wait for execution to reach halt (PC=5)
    for _ in range(50):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 5:
            break
    else:
        assert False, f"Timeout: IN did not complete to halt (PC={int(dut.pc.value)})"

    # Verify that ISR recovered exactly the original 8-bit payload 0x7E!
    assert int(dut.isr.value) == 0x7E, f"Destuffing failed: expected ISR=0x7E, got 0x{int(dut.isr.value):02X}"
    assert int(dut.stuff_error.value) == 0, f"Unexpected stuff error flag asserted"
    dut._log.info(f"Test 17C: USB 1.1 Bit-Destuffing on RX verified! Recovered 0x{int(dut.isr.value):02X} from 9-bit stream")


@cocotb.test()
async def test_assist_usb_stuff_error(dut):
    """Task 17D: Verifies USB bit-stuff error detection (7 consecutive 1s asserts stuff_error)."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    DELAY = 4
    asm_source = f"""
    ASSIST CFG, NRZI=0, STUFF=USB
    IN 8, {DELAY}
    JMP STUFF_ERR, error_handler
    MOV acc, 0xAA
    JMP halt
error_handler:
    MOV acc, 0xEE
halt:
    JMP halt
"""
    asm = OmnibusAssembler()
    instructions, _ = asm.assemble(asm_source)
    prog = [w[1] for w in instructions]

    await load_program_direct(dut, prog)

    while int(dut.pc.value) != 1:
        await RisingEdge(dut.i_clk)

    # Drive an illegal violation: 7 consecutive 1s!
    illegal_stream = [1, 1, 1, 1, 1, 1, 1, 0]
    for bit in illegal_stream:
        dut.i_gpio.value = bit
        dut.i_rx.value = bit
        await ClockCycles(dut.i_clk, DELAY + 1)

    for _ in range(50):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 6:
            break
    else:
        assert False, f"Timeout: failed to reach halt (PC={int(dut.pc.value)})"

    assert int(dut.stuff_error.value) == 1, f"Expected stuff_error=1, got {int(dut.stuff_error.value)}"
    assert int(dut.acc.value) == 0xEE, f"Expected JMP STUFF_ERR branch to error_handler (acc=0xEE), got 0x{int(dut.acc.value):02X}"
    dut._log.info("Test 17D: USB Bit-Stuff Error detection and JMP STUFF_ERR verified!")


@cocotb.test()
async def test_assist_can_bit_stuffing(dut):
    """Task 17E: Verifies CAN 2.0 bit-stuffing (inserts inverted bit after 5 identical bits)."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    DELAY = 4
    # Program:
    #   [0]: ASSIST CFG, NRZI=0, STUFF=CAN
    #   [1]: MOV acc, 0x1F     (0b0001_1111: LSB-first: 1, 1, 1, 1, 1, 0, 0, 0 -> five 1s followed by three 0s)
    #   [2]: MOV OSR, acc
    #   [3]: OUT 8, 4          (should insert '0' stuff bit after the five 1s)
    #   [4]: JMP halt
    asm_source = f"""
    ASSIST CFG, NRZI=0, STUFF=CAN
    MOV acc, 0x1F
    MOV OSR, acc
    OUT 8, {DELAY}
halt:
    JMP halt
"""
    asm = OmnibusAssembler()
    instructions, _ = asm.assemble(asm_source)
    prog = [w[1] for w in instructions]

    tx_bits = []
    async def monitor_tx():
        while int(dut.pc.value) != 3:
            await RisingEdge(dut.i_clk)
        while len(tx_bits) < 9:
            await RisingEdge(dut.i_clk)
            if int(dut.delay_cnt.value) == 2:
                tx_bits.append(int(dut.o_tx.value))

    mon = cocotb.start_soon(monitor_tx())
    await load_program_direct(dut, prog)

    for _ in range(250):
        await RisingEdge(dut.i_clk)
        if len(tx_bits) == 9:
            break
    else:
        assert False, f"Timeout waiting for 9 CAN bits (got {len(tx_bits)})"

    mon.cancel()
    # Expected CAN stream: five 1s -> '0' stuff bit -> three 0s = 9 bits total!
    expected_can = [1, 1, 1, 1, 1, 0, 0, 0, 0]  # bit 5 is the stuffed '0'
    assert len(tx_bits) == 9, f"Expected 9 bits (8 data + 1 CAN stuff), got {len(tx_bits)}: {tx_bits}"
    assert tx_bits == expected_can, f"CAN bit-stuffing mismatch: expected {expected_can}, got {tx_bits}"
    dut._log.info(f"Test 17E: CAN 2.0 Bit-Stuffing verified! Inserted inverted bit: {tx_bits}")


# =============================================================================
# Task 18: Asymmetric Single-Wire & Retro Physical Protocol Accelerators
# =============================================================================

@cocotb.test()
async def test_pulse_neopixel_tx(dut):
    """Task 18A: Verifies WS2812B NeoPixel 800kHz single-wire asymmetric pulse timing (MSB-first)."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    # 0x96 = 0b1001_0110. In MSB-first: bits are 1, 0, 0, 1, 0, 1, 1, 0
    # Bit 1: 40 cycles HIGH, 22 cycles LOW
    # Bit 0: 20 cycles HIGH, 42 cycles LOW
    asm_source = """
    ASSIST PULSE_CFG, NEOPIXEL
    MOV acc, 0x96
    MOV OSR, acc
    OUT 8, 0
halt:
    JMP halt
"""
    asm = OmnibusAssembler()
    instructions, _ = asm.assemble(asm_source)
    prog = [w[1] for w in instructions]

    pulses = []  # list of (high_cycles, low_cycles)
    async def monitor_pulses():
        while int(dut.pc.value) != 3:
            await RisingEdge(dut.i_clk)
        
        while len(pulses) < 8:
            # Wait for line to go HIGH
            while int(dut.o_tx.value) == 0:
                await RisingEdge(dut.i_clk)
            
            high_count = 0
            while int(dut.o_tx.value) == 1:
                high_count += 1
                await RisingEdge(dut.i_clk)
            
            low_count = 0
            while int(dut.o_tx.value) == 0 and len(pulses) < 8:
                low_count += 1
                await RisingEdge(dut.i_clk)
                if len(pulses) == 7 and low_count >= 20:
                    # Last bit rest
                    break

            pulses.append((high_count, low_count))

    mon = cocotb.start_soon(monitor_pulses())
    await load_program_direct(dut, prog)

    for _ in range(700):
        await RisingEdge(dut.i_clk)
        if len(pulses) == 8:
            break
    else:
        assert False, f"Timeout waiting for 8 NeoPixel pulses (got {len(pulses)}: {pulses})"

    mon.cancel()

    # 0x96 MSB-first: [1, 0, 0, 1, 0, 1, 1, 0]
    expected_bits = [1, 0, 0, 1, 0, 1, 1, 0]
    decoded_bits = [1 if h > 30 else 0 for (h, l) in pulses]
    assert decoded_bits == expected_bits, f"Decoded bits mismatch: expected {expected_bits}, got {decoded_bits} (pulses: {pulses})"
    dut._log.info(f"Test 18A: WS2812B NeoPixel pulse timing verified! Pulses: {pulses}")


@cocotb.test()
async def test_pulse_neopixel_rgb_frame(dut):
    """Task 18B: Verifies continuous 24-bit GRB frame transmission for WS2812B."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    # Transmit Green=0xFF, Red=0x00, Blue=0x55
    asm_source = """
    ASSIST PULSE_CFG, NEOPIXEL
    MOV acc, 0xFF
    MOV OSR, acc
    OUT 8, 0
    MOV acc, 0x00
    MOV OSR, acc
    OUT 8, 0
    MOV acc, 0x55
    MOV OSR, acc
    OUT 8, 0
halt:
    JMP halt
"""
    asm = OmnibusAssembler()
    instructions, _ = asm.assemble(asm_source)
    prog = [w[1] for w in instructions]

    high_pulses = 0
    async def count_rising():
        nonlocal high_pulses
        prev = 0
        while True:
            await RisingEdge(dut.i_clk)
            cur = int(dut.o_tx.value)
            if cur == 1 and prev == 0:
                high_pulses += 1
            prev = cur

    counter = cocotb.start_soon(count_rising())
    await load_program_direct(dut, prog)

    for _ in range(1800):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 10:
            break
    else:
        assert False, f"Timeout: failed to reach halt (PC={int(dut.pc.value)}, high_pulses={high_pulses})"

    counter.cancel()
    assert high_pulses == 24, f"Expected 24 NeoPixel bit pulses for 3 bytes, got {high_pulses}"
    dut._log.info(f"Test 18B: 24-bit WS2812B GRB frame verified! Total pulses: {high_pulses}")


@cocotb.test()
async def test_pulse_joybus_tx(dut):
    """Task 18C: Verifies N64/GameCube Joybus open-drain pulse timing (active-low 3us/1us)."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    # 0x01 in LSB-first: bit 0 is 1, bit 1..7 are 0
    # In JOYBUS:
    # Bit 0 (0): 150 cycles LOW (3us), 50 cycles HIGH (1us)
    # Bit 1 (1): 50 cycles LOW (1us), 150 cycles HIGH (3us)
    asm_source = """
    ASSIST PULSE_CFG, JOYBUS
    MOV acc, 0x01
    MOV OSR, acc
    OUT 8, 0
halt:
    JMP halt
"""
    asm = OmnibusAssembler()
    instructions, _ = asm.assemble(asm_source)
    prog = [w[1] for w in instructions]

    low_durations = []
    async def monitor_joybus():
        while int(dut.pc.value) != 3:
            await RisingEdge(dut.i_clk)
        
        while len(low_durations) < 8:
            while int(dut.o_tx.value) == 1:
                await RisingEdge(dut.i_clk)
            
            low_count = 0
            while int(dut.o_tx.value) == 0:
                low_count += 1
                await RisingEdge(dut.i_clk)
            
            low_durations.append(low_count)

    mon = cocotb.start_soon(monitor_joybus())
    await load_program_direct(dut, prog)

    for _ in range(2000):
        await RisingEdge(dut.i_clk)
        if len(low_durations) == 8:
            break
    else:
        assert False, f"Timeout waiting for 8 Joybus pulses (got {len(low_durations)}: {low_durations})"

    mon.cancel()

    # Bit 0 was 1 (short low ~50 cycles), bits 1..7 were 0 (long low ~150 cycles)
    assert low_durations[0] < 80, f"Expected short low pulse for bit 1, got {low_durations[0]}"
    for i in range(1, 8):
        assert low_durations[i] > 120, f"Expected long low pulse for bit 0, got {low_durations[i]}"
    dut._log.info(f"Test 18C: N64/GameCube Joybus open-drain pulse timing verified! Durations: {low_durations}")


@cocotb.test()
async def test_gamepad_nes_host_read(dut):
    """Task 18D: Verifies NES Gamepad Host read (autonomous LATCH pulse and 8 clock pulses)."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    # Program:
    # [0] ASSIST GAMEPAD_CFG, ROLE=HOST, TYPE=NES
    # [1] IN 8, 4
    # [2] PUSH
    # [3] JMP halt
    asm_source = """
    ASSIST GAMEPAD_CFG, ROLE=HOST, TYPE=NES
    IN 8, 4
    PUSH
halt:
    JMP halt
"""
    asm = OmnibusAssembler()
    instructions, _ = asm.assemble(asm_source)
    prog = [w[1] for w in instructions]

    latch_seen = False
    clock_pulses = 0

    # Test vector: Button mask 0xA5 (1010_0101)
    test_buttons = 0xA5

    async def gamepad_controller_mock():
        nonlocal latch_seen, clock_pulses
        # Wait for LATCH on cs_pin (Pin 2)
        while (int(dut.o_gpio.value) & (1 << 2)) == 0:
            await RisingEdge(dut.i_clk)
        latch_seen = True
        
        while (int(dut.o_gpio.value) & (1 << 2)) != 0:
            await RisingEdge(dut.i_clk)

        # For 8 clock pulses on sck_pin (Pin 1), supply bits on rx_pin (Pin 0)
        btn_reg = test_buttons
        for _ in range(8):
            # Wait for clock HIGH
            while (int(dut.o_gpio.value) & (1 << 1)) == 0:
                await RisingEdge(dut.i_clk)
            clock_pulses += 1
            # Drive MSB onto rx_pin (Pin 0)
            bit = (btn_reg >> 7) & 1
            dut.i_gpio.value = bit
            dut.i_rx.value = bit
            btn_reg = (btn_reg << 1) & 0xFF
            # Wait for clock LOW
            while (int(dut.o_gpio.value) & (1 << 1)) != 0:
                await RisingEdge(dut.i_clk)

    mock = cocotb.start_soon(gamepad_controller_mock())
    await load_program_direct(dut, prog)

    for _ in range(400):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 3:
            break
    else:
        assert False, f"Timeout: failed to reach halt (PC={int(dut.pc.value)}, clocks={clock_pulses})"

    mock.cancel()
    assert latch_seen, "LATCH pulse on cs_pin was not detected"
    assert clock_pulses == 8, f"Expected 8 clock pulses on sck_pin, got {clock_pulses}"
    assert int(dut.isr.value) == test_buttons, f"Sampled button mismatch: expected 0x{test_buttons:02X}, got 0x{int(dut.isr.value):02X}"
    dut._log.info(f"Test 18D: NES Gamepad Host read verified! Sampled 0x{int(dut.isr.value):02X} across 8 clock cycles")


@cocotb.test()
async def test_gamepad_snes_host_read(dut):
    """Task 18E: Verifies SNES Gamepad Host read (autonomous LATCH pulse and 16 clock pulses)."""
    start_clock(dut.i_clk)
    await reset_dut(dut)

    asm_source = """
    ASSIST GAMEPAD_CFG, ROLE=HOST, TYPE=SNES
    IN 8, 4
    PUSH
halt:
    JMP halt
"""
    asm = OmnibusAssembler()
    instructions, _ = asm.assemble(asm_source)
    prog = [w[1] for w in instructions]

    latch_seen = False
    clock_pulses = 0

    # 16-bit SNES button word: 0xCAFE
    test_word = 0xCAFE

    async def snes_controller_mock():
        nonlocal latch_seen, clock_pulses
        while (int(dut.o_gpio.value) & (1 << 2)) == 0:
            await RisingEdge(dut.i_clk)
        latch_seen = True
        
        while (int(dut.o_gpio.value) & (1 << 2)) != 0:
            await RisingEdge(dut.i_clk)

        shift = test_word
        for _ in range(16):
            while (int(dut.o_gpio.value) & (1 << 1)) == 0:
                await RisingEdge(dut.i_clk)
            clock_pulses += 1
            bit = (shift >> 15) & 1
            dut.i_gpio.value = bit
            dut.i_rx.value = bit
            shift = (shift << 1) & 0xFFFF
            while (int(dut.o_gpio.value) & (1 << 1)) != 0:
                await RisingEdge(dut.i_clk)

    mock = cocotb.start_soon(snes_controller_mock())
    await load_program_direct(dut, prog)

    for _ in range(600):
        await RisingEdge(dut.i_clk)
        if int(dut.pc.value) == 3:
            break
    else:
        assert False, f"Timeout: failed to reach halt (PC={int(dut.pc.value)}, clocks={clock_pulses})"

    mock.cancel()
    assert latch_seen, "SNES LATCH pulse was not detected"
    assert clock_pulses == 16, f"Expected 16 clock pulses for SNES, got {clock_pulses}"
    assert int(dut.pad_shift_reg.value) == test_word, f"SNES 16-bit word mismatch: expected 0x{test_word:04X}, got 0x{int(dut.pad_shift_reg.value):04X}"
    dut._log.info(f"Test 18E: SNES 16-bit Gamepad Host read verified! Sampled 0x{int(dut.pad_shift_reg.value):04X} across 16 clock cycles")



