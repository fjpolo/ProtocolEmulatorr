# =============================================================================
# File        : testbench.py
# Description : Self-checking Cocotb testbench for ProtocolEmulator UART core
# Tests       : Framing, cycle-accurate zero-jitter timing, character decoding,
#               consecutive frame streaming, and PC telemetry.
# =============================================================================

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles, Timer

BAUD_RATE = 115200
CLK_FREQ_HZ = 50_000_000
CLK_PERIOD_NS = 20  # 50 MHz = 20 ns period
CYCLES_PER_BIT = 434
EXPECTED_CHAR = 0x55  # ASCII 'U' = 8'b01010101


def start_clock(signal, period_ns=CLK_PERIOD_NS):
    """Starts a clock generator compatible with Cocotb 1.x and 2.x."""
    try:
        clk = Clock(signal, period_ns, unit="ns")
    except TypeError:
        clk = Clock(signal, period_ns, units="ns")
    return cocotb.start_soon(clk.start())


async def reset_dut(dut):
    """Applies active-low reset to ProtocolEmulator."""
    dut.i_reset_n.value = 0
    dut.i_data.value = 0
    await ClockCycles(dut.i_clk, 5)
    await RisingEdge(dut.i_clk)
    dut.i_reset_n.value = 1
    await RisingEdge(dut.i_clk)


class UARTReceiver:
    """Cycle-accurate UART receiver and protocol checker."""

    def __init__(self, dut, clk_signal, tx_signal, cycles_per_bit=CYCLES_PER_BIT):
        self.dut = dut
        self.clk = clk_signal
        self.tx = tx_signal
        self.cycles_per_bit = cycles_per_bit

    def get_tx(self):
        """Extracts bit 0 (UART TX signal)."""
        val = int(self.tx.value)
        return val & 0x01

    async def wait_for_start_bit(self, timeout_cycles=10000):
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
# Test 1: Reset behavior and idle line state
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_uart_reset(dut):
    """Verify reset asserts TX idle high and initializes PC to 0."""
    start_clock(dut.i_clk, CLK_PERIOD_NS)

    dut.i_reset_n.value = 0
    dut.i_data.value = 0
    await ClockCycles(dut.i_clk, 5)

    tx_val = int(dut.o_data.value) & 0x01
    pc_val = (int(dut.o_data.value) >> 1) & 0x0F

    assert tx_val == 1, f"Expected TX line high (idle) during reset, got {tx_val}"
    assert pc_val == 0, f"Expected PC=0 during reset, got {pc_val}"

    # Release reset
    await RisingEdge(dut.i_clk)
    dut.i_reset_n.value = 1
    await RisingEdge(dut.i_clk)
    dut._log.info("Reset test PASSED: DUT initialized to idle high and PC=0")


# -----------------------------------------------------------------------------
# Test 2: Single UART Frame Validation ('U' = 0x55)
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_uart_single_frame(dut):
    """Verify reception of a valid 8N1 UART frame containing 'U' (0x55)."""
    start_clock(dut.i_clk, CLK_PERIOD_NS)
    await reset_dut(dut)

    uart_rx = UARTReceiver(dut, dut.i_clk, dut.o_data)
    byte_val, frame_valid, diag = await uart_rx.receive_byte_midpoint_sampled()

    dut._log.info(
        f"Received frame: char='{chr(byte_val)}' (0x{byte_val:02X}), "
        f"bits={diag['sampled_bits']}, start_bit={diag['start_bit']}, stop_bit={diag['stop_bit']}"
    )

    assert diag["start_valid"], "Framing error: Start bit was not 0"
    assert diag["stop_valid"], "Framing error: Stop bit was not 1"
    assert frame_valid, "Frame error: Invalid start or stop bit"
    assert byte_val == EXPECTED_CHAR, (
        f"Data mismatch! Expected 0x{EXPECTED_CHAR:02X} ('{chr(EXPECTED_CHAR)}'), "
        f"got 0x{byte_val:02X} ('{chr(byte_val)}')"
    )
    dut._log.info("Single frame reception test PASSED with correct 8N1 payload 'U' (0x55)")


# -----------------------------------------------------------------------------
# Test 3: Zero-Jitter Bit-Timing Verification
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_uart_bit_timing_zero_jitter(dut):
    """
    Verify that every single bit of 'U' (which alternates 0/1 on every bit)
    measures exactly 434 clock cycles (8.68 us) with zero cycle jitter.
    """
    start_clock(dut.i_clk, CLK_PERIOD_NS)
    await reset_dut(dut)

    uart_rx = UARTReceiver(dut, dut.i_clk, dut.o_data)
    await uart_rx.wait_for_start_bit()

    # Character 'U' (0x55 = 8'b01010101):
    # Bit 0: 1, Bit 1: 0, Bit 2: 1, Bit 3: 0, Bit 4: 1, Bit 5: 0, Bit 6: 1, Bit 7: 0, Stop: 1
    # Because every bit alternates, there is an edge between EVERY bit!
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

    measured_cycles = []

    for name, expected_level in expected_transitions:
        current_level = uart_rx.get_tx()
        assert current_level == expected_level, (
            f"Expected {name} to be level {expected_level}, got {current_level}"
        )

        # Count clock cycles until transition
        cycle_count = 0
        while uart_rx.get_tx() == expected_level:
            await RisingEdge(dut.i_clk)
            cycle_count += 1
            if cycle_count > CYCLES_PER_BIT + 10:
                break

        measured_cycles.append((name, cycle_count))
        dut._log.info(f"{name:10s} (val={expected_level}) duration = {cycle_count} cycles ({cycle_count * CLK_PERIOD_NS} ns)")

        assert cycle_count == CYCLES_PER_BIT, (
            f"Timing violation on {name}: Expected exactly {CYCLES_PER_BIT} cycles, "
            f"measured {cycle_count} cycles (error = {cycle_count - CYCLES_PER_BIT} cycles)"
        )

    # Stop bit level check
    stop_level = uart_rx.get_tx()
    assert stop_level == 1, f"Expected Stop Bit level 1, got {stop_level}"

    # Stop bit + NOP gap + JMP hold check (Stop bit is 434, NOP gap is 433+1=434, JMP is 1 cycle = 869 cycles)
    stop_and_gap_cycles = 0
    while uart_rx.get_tx() == 1 and stop_and_gap_cycles < 2000:
        await RisingEdge(dut.i_clk)
        stop_and_gap_cycles += 1
        if stop_and_gap_cycles > 869:
            break

    dut._log.info(f"Stop bit + Inter-character pause = {stop_and_gap_cycles} cycles")
    # Expected: 434 (Stop bit) + 434 (NOP) + 1 (JMP) = 869 cycles total idle time
    assert stop_and_gap_cycles == 869, (
        f"Inter-character gap mismatch: Expected 869 cycles (434 stop + 434 NOP + 1 JMP), got {stop_and_gap_cycles}"
    )

    dut._log.info("Zero-jitter timing test PASSED: Exactly 434 cycles/bit with 0 cycle jitter!")


# -----------------------------------------------------------------------------
# Test 4: Consecutive Multi-Frame Reception & Stream Continuity
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_uart_consecutive_frames(dut):
    """Verify that multiple consecutive frames are transmitted continuously and correctly."""
    start_clock(dut.i_clk, CLK_PERIOD_NS)
    await reset_dut(dut)

    uart_rx = UARTReceiver(dut, dut.i_clk, dut.o_data)
    NUM_FRAMES = 5
    received_bytes = []

    dut._log.info(f"Receiving {NUM_FRAMES} consecutive UART frames...")
    for frame_idx in range(NUM_FRAMES):
        byte_val, frame_valid, diag = await uart_rx.receive_byte_midpoint_sampled()
        received_bytes.append(byte_val)

        assert frame_valid, f"Frame {frame_idx} has framing errors: {diag}"
        assert byte_val == EXPECTED_CHAR, (
            f"Frame {frame_idx} data error: expected 0x{EXPECTED_CHAR:02X}, got 0x{byte_val:02X}"
        )
        dut._log.info(f"Frame {frame_idx + 1}/{NUM_FRAMES}: received '{chr(byte_val)}' (0x{byte_val:02X}) [PASS]")

    received_str = "".join(chr(b) for b in received_bytes)
    assert received_str == "U" * NUM_FRAMES, f"Expected '{'U' * NUM_FRAMES}', got '{received_str}'"
    dut._log.info(f"Consecutive frame streaming test PASSED: received \"{received_str}\"")


# -----------------------------------------------------------------------------
# Test 5: Program Counter (PC) Telemetry & State Progression
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_pc_telemetry(dut):
    """Verify that o_data[4:1] correctly reflects the PC progression 0 -> 11 -> 0."""
    start_clock(dut.i_clk, CLK_PERIOD_NS)
    await reset_dut(dut)

    # Sample PC progression over 1 full loop (4775 clock cycles)
    pcs_observed = set()
    for _ in range(5000):
        pc = (int(dut.o_data.value) >> 1) & 0x0F
        pcs_observed.add(pc)
        await RisingEdge(dut.i_clk)

    # The microcode uses addresses 0 to 11
    expected_pcs = set(range(12))
    assert expected_pcs.issubset(pcs_observed), (
        f"Missing expected PC states! Expected {expected_pcs}, observed {pcs_observed}"
    )

    dut._log.info(f"PC Telemetry test PASSED: All instruction states {sorted(list(pcs_observed))} observed on o_data[4:1]")