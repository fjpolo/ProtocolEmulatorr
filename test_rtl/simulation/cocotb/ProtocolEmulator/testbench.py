# =============================================================================
# File        : testbench.py
# Description : Self-checking Cocotb testbench for Task 02: Dynamic Register
#               Serialization with Output Shift Register (OSR) and OUT opcode.
# Tests       : Dynamic byte patterns, string streaming, zero-jitter timing,
#               tx_busy telemetry, and PC progression.
# =============================================================================

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles, Timer

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


async def reset_dut(dut, initial_data=0):
    """Applies active-low reset to ProtocolEmulator with given initial data."""
    dut.i_reset_n.value = 0
    dut.i_data.value = initial_data
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

    async def wait_for_start_bit(self, timeout_cycles=20000):
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
    """Verify reset asserts TX idle high, initializes PC=0, and sets tx_busy=0."""
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
# Test 2: Dynamic Byte Pattern Transmission (OSR Serialization)
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_uart_dynamic_bytes(dut):
    """Verify transmission of arbitrary dynamic bytes supplied via i_data."""
    start_clock(dut.i_clk, CLK_PERIOD_NS)

    test_patterns = [0x55, 0xAA, 0x00, 0xFF, 0x3C, 0xA5, 0x42]
    await reset_dut(dut, initial_data=test_patterns[0])

    uart_rx = UARTReceiver(dut, dut.i_clk, dut.o_data)

    for idx, expected_byte in enumerate(test_patterns):
        byte_val, frame_valid, diag = await uart_rx.receive_byte_midpoint_sampled()

        # Update i_data during inter-character gap for next frame
        if idx + 1 < len(test_patterns):
            dut.i_data.value = test_patterns[idx + 1]

        dut._log.info(
            f"Pattern test [{idx+1}/{len(test_patterns)}]: sent 0x{expected_byte:02X}, "
            f"received 0x{byte_val:02X} (bits={diag['sampled_bits']}, valid={frame_valid})"
        )

        assert frame_valid, f"Framing error on byte 0x{expected_byte:02X}: {diag}"
        assert byte_val == expected_byte, (
            f"Data mismatch! Expected 0x{expected_byte:02X}, got 0x{byte_val:02X}"
        )

    dut._log.info("Dynamic byte pattern transmission test PASSED!")


# -----------------------------------------------------------------------------
# Test 3: String Streaming ("Hello, OmniBus!\n")
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_uart_string_stream(dut):
    """Stream an ASCII text message and verify byte-for-byte reception."""
    start_clock(dut.i_clk, CLK_PERIOD_NS)

    message = "Hello, OmniBus!\n"
    await reset_dut(dut, initial_data=ord(message[0]))

    uart_rx = UARTReceiver(dut, dut.i_clk, dut.o_data)
    received_chars = []

    dut._log.info(f"Streaming message: {repr(message)}")

    for idx in range(len(message)):
        char = message[idx]
        byte_val, frame_valid, _ = await uart_rx.receive_byte_midpoint_sampled()
        assert frame_valid, f"Framing error on char '{char}'"
        received_chars.append(chr(byte_val))

        # Update next character during the inter-character pause
        if idx + 1 < len(message):
            dut.i_data.value = ord(message[idx + 1])

    reconstructed_str = "".join(received_chars)
    dut._log.info(f"Received string: {repr(reconstructed_str)}")
    assert reconstructed_str == message, (
        f"String mismatch! Expected {repr(message)}, got {repr(reconstructed_str)}"
    )
    dut._log.info("ASCII string streaming test PASSED!")


# -----------------------------------------------------------------------------
# Test 4: Zero-Jitter Bit-Timing Verification on OUT instruction
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_uart_bit_timing_zero_jitter(dut):
    """
    Verify that OUT opcode generates exactly 434 clock cycles per bit
    with zero cycle jitter on alternating payload 0x55 ('U').
    """
    start_clock(dut.i_clk, CLK_PERIOD_NS)

    # Set payload to 0x55 before releasing reset so first frame has alternating bits
    await reset_dut(dut, initial_data=0x55)

    uart_rx = UARTReceiver(dut, dut.i_clk, dut.o_data)
    await uart_rx.wait_for_start_bit()

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

    for name, expected_level in expected_transitions:
        current_level = uart_rx.get_tx()
        assert current_level == expected_level, (
            f"Expected {name} to be level {expected_level}, got {current_level}"
        )

        cycle_count = 0
        while uart_rx.get_tx() == expected_level:
            await RisingEdge(dut.i_clk)
            cycle_count += 1
            if cycle_count > CYCLES_PER_BIT + 10:
                break

        dut._log.info(f"{name:10s} (val={expected_level}) duration = {cycle_count} cycles ({cycle_count * CLK_PERIOD_NS} ns)")

        assert cycle_count == CYCLES_PER_BIT, (
            f"Timing violation on {name}: Expected exactly {CYCLES_PER_BIT} cycles, "
            f"measured {cycle_count} cycles (error = {cycle_count - CYCLES_PER_BIT} cycles)"
        )

    # Stop bit level check
    stop_level = uart_rx.get_tx()
    assert stop_level == 1, f"Expected Stop Bit level 1, got {stop_level}"

    dut._log.info("Zero-jitter OUT timing test PASSED: Exactly 434 cycles/bit!")


# -----------------------------------------------------------------------------
# Test 5: Telemetry and PC Progression
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_pc_and_busy_telemetry(dut):
    """Verify that o_data[4:1] reflects PC progression (0..5) and o_data[7] reflects tx_busy."""
    start_clock(dut.i_clk, CLK_PERIOD_NS)
    await reset_dut(dut, initial_data=0x42)

    pcs_observed = set()
    busy_observed = set()

    for _ in range(5500):
        val = int(dut.o_data.value)
        pc = (val >> 1) & 0x0F
        busy = (val >> 7) & 0x01
        pcs_observed.add(pc)
        busy_observed.add(busy)
        await RisingEdge(dut.i_clk)

    # Microcode now uses addresses 0 to 5
    expected_pcs = set(range(6))
    assert expected_pcs.issubset(pcs_observed), (
        f"Missing expected PC states! Expected {expected_pcs}, observed {pcs_observed}"
    )

    assert 1 in busy_observed, "tx_busy flag was never asserted during transmission"

    dut._log.info(f"Telemetry test PASSED: PC states {sorted(list(pcs_observed))} observed, tx_busy verified!")