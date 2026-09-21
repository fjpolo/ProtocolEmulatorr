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