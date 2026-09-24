# =============================================================================
# File        : testbench.py
# Description : Cocotb Verification Suite for OmniBus_Wishbone SoC Wrapper
#               Tests:
#                 1. Register access (Status, Control, Baud Divisor, GPIO)
#                 2. Direct CPU Microcode RAM programming via 0x80..0xFC window
#                 3. TX FIFO streaming from Wishbone into ProtocolEmulator PULL
#                 4. RX FIFO streaming from ProtocolEmulator PUSH into Wishbone
#                 5. Interrupt generation & watermark triggers
# =============================================================================

import sys
import os
repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../.."))
if repo_root not in sys.path:
    sys.path.insert(0, repo_root)

from python.omnibus_asm import OmnibusAssembler

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer

CLK_PERIOD_NS = 20  # 50 MHz clock

ADDR_DATA      = 0x00
ADDR_STATUS    = 0x04
ADDR_CTRL      = 0x08
ADDR_BAUD      = 0x0C
ADDR_GPIO      = 0x10
ADDR_IMEM_BANK = 0x14
ADDR_IMEM      = 0x80


class WishboneMaster:
    """Helper class to drive standard Wishbone B4 single-cycle read and write cycles."""

    def __init__(self, dut):
        self.dut = dut
        self.clk = dut.i_wb_clk

    async def write(self, addr, data, sel=0xF):
        """Perform a Wishbone write cycle."""
        await RisingEdge(self.clk)
        self.dut.i_wb_addr.value = addr
        self.dut.i_wb_data.value = data
        self.dut.i_wb_sel.value  = sel
        self.dut.i_wb_we.value   = 1
        self.dut.i_wb_cyc.value  = 1
        self.dut.i_wb_stb.value  = 1

        while True:
            await RisingEdge(self.clk)
            if int(self.dut.o_wb_ack.value) == 1:
                break

        self.dut.i_wb_cyc.value = 0
        self.dut.i_wb_stb.value = 0
        self.dut.i_wb_we.value  = 0

    async def read(self, addr, sel=0xF):
        """Perform a Wishbone read cycle and return 32-bit data."""
        await RisingEdge(self.clk)
        self.dut.i_wb_addr.value = addr
        self.dut.i_wb_sel.value  = sel
        self.dut.i_wb_we.value   = 0
        self.dut.i_wb_cyc.value  = 1
        self.dut.i_wb_stb.value  = 1

        while True:
            await RisingEdge(self.clk)
            if int(self.dut.o_wb_ack.value) == 1:
                break

        rdata = int(self.dut.o_wb_data.value)
        self.dut.i_wb_cyc.value = 0
        self.dut.i_wb_stb.value = 0
        return rdata


async def reset_dut(dut):
    """Assert active-low reset for 5 cycles."""
    dut.i_wb_rst_n.value = 0
    dut.i_wb_cyc.value   = 0
    dut.i_wb_stb.value   = 0
    dut.i_wb_we.value    = 0
    dut.i_wb_addr.value  = 0
    dut.i_wb_data.value  = 0
    dut.i_wb_sel.value   = 0
    dut.i_gpio.value     = 0xFF
    dut.i_rx.value       = 1
    await ClockCycles(dut.i_wb_clk, 5)
    dut.i_wb_rst_n.value = 1
    await ClockCycles(dut.i_wb_clk, 2)


# -----------------------------------------------------------------------------
# Test 1: Register Read / Write Access & Defaults
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_wb_reg_access(dut):
    """Test 14A: Verify Wishbone register access, defaults, and baud configuration."""
    cocotb.start_soon(Clock(dut.i_wb_clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    wb = WishboneMaster(dut)

    # 1. Read default Status register
    status = await wb.read(ADDR_STATUS)
    dut._log.info(f"Initial Status: 0x{status:08X}")
    tx_empty = (status >> 1) & 1
    rx_empty = (status >> 5) & 1
    assert tx_empty == 1, "Expected TX FIFO empty on reset"
    assert rx_empty == 1, "Expected RX FIFO empty on reset"

    # 2. Read default Baud rate divisor (expected default 433)
    baud = await wb.read(ADDR_BAUD)
    dut._log.info(f"Initial Baud Divisor: {baud}")
    assert baud == 433, f"Expected default baud div 433, got {baud}"

    # 3. Write new Baud rate divisor (e.g. 50 cycles/bit for 1 Mbps)
    await wb.write(ADDR_BAUD, 50)
    new_baud = await wb.read(ADDR_BAUD)
    dut._log.info(f"Updated Baud Divisor: {new_baud}")
    assert new_baud == 50, f"Expected updated baud div 50, got {new_baud}"

    # 4. Soft Reset via Control Register
    await wb.write(ADDR_CTRL, 0x01) # Soft reset bit 0
    await ClockCycles(dut.i_wb_clk, 2)
    await wb.write(ADDR_CTRL, 0x00) # Release soft reset

    dut._log.info("Wishbone Register Access test PASSED!")


# -----------------------------------------------------------------------------
# Test 2: Direct Microcode RAM Programming via 0x80..0xFC Window
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_wb_imem_programming(dut):
    """Test 14B: Write microcode directly into IMEM via Wishbone without serial bootloader."""
    cocotb.start_soon(Clock(dut.i_wb_clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    wb = WishboneMaster(dut)

    # Custom microcode program (sets GPIO pin 0 to 0, then to 1, then loops):
    # 0x00: SET 0, 0, 10 -> 0x300A
    # 0x01: SET 0, 1, 10 -> 0x310A
    # 0x02: JMP 0x00     -> 0x8000
    prog = [0x300A, 0x310A, 0x8000]

    # Halt core before programming
    await wb.write(ADDR_CTRL, 0x02) # prog_en = 1 (bit 1)

    # Write instructions to 0x80 + (addr * 4)
    for idx, word in enumerate(prog):
        addr = ADDR_IMEM + (idx * 4)
        await wb.write(addr, word)

    # Read back and verify instructions
    for idx, expected_word in enumerate(prog):
        addr = ADDR_IMEM + (idx * 4)
        read_word = (await wb.read(addr)) & 0xFFFF
        dut._log.info(f"IMEM[0x{idx:02X}]: wrote 0x{expected_word:04X}, readback 0x{read_word:04X}")
        assert read_word == expected_word, f"IMEM mismatch at word {idx}: expected 0x{expected_word:04X}, got 0x{read_word:04X}"

    # Release core to run
    await wb.write(ADDR_CTRL, 0x00) # prog_en = 0

    # Wait 30 cycles and verify GPIO pin 0 toggles
    toggled = False
    for _ in range(50):
        await RisingEdge(dut.i_wb_clk)
        gpio_val = int(dut.o_gpio.value) & 1
        if gpio_val == 0:
            toggled = True
            break
    assert toggled, "Microcode execution failed: GPIO pin 0 did not toggle"
    dut._log.info("Direct IMEM Programming via Wishbone test PASSED!")


# -----------------------------------------------------------------------------
# Test 3: TX FIFO Streaming from Wishbone into ProtocolEmulator PULL
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_wb_tx_streaming(dut):
    """Test 14C: Host CPU streaming bytes into TX FIFO, consumed by ProtocolEmulator via PULL."""
    cocotb.start_soon(Clock(dut.i_wb_clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    wb = WishboneMaster(dut)

    # Fast baud for quick test execution
    await wb.write(ADDR_BAUD, 4)

    # Program:
    # 0x00: PULL BLOCK -> 0x9001 (waits for TX FIFO, pops into OSR)
    # 0x01: OUT 0, 4   -> 0x1004 (UART serialize LSB-first)
    # 0x02: JMP 0x00   -> 0x8000
    prog = [0x9001, 0x1004, 0x8000]

    await wb.write(ADDR_CTRL, 0x02) # prog_en = 1
    for idx, word in enumerate(prog):
        await wb.write(ADDR_IMEM + (idx * 4), word)

    # Push 3 bytes into TX FIFO via Wishbone writes to ADDR_DATA: 0xA5, 0x5A, 0x3C
    tx_bytes = [0xA5, 0x5A, 0x3C]
    for b in tx_bytes:
        await wb.write(ADDR_DATA, b)

    # Check status: TX FIFO level should be 3
    status = await wb.read(ADDR_STATUS)
    tx_level = (status >> 8) & 0xFF
    dut._log.info(f"TX FIFO Level after write: {tx_level}")
    assert tx_level == 3, f"Expected TX FIFO level 3, got {tx_level}"

    # Release core to start popping and serializing
    await wb.write(ADDR_CTRL, 0x00)

    # Wait for core to consume all bytes
    for _ in range(400):
        await RisingEdge(dut.i_wb_clk)
        status = await wb.read(ADDR_STATUS)
        tx_level = (status >> 8) & 0xFF
        if tx_level == 0:
            break
    else:
        assert False, f"Timeout: TX FIFO did not drain (level={tx_level})"

    assert (status >> 1) & 1 == 1, "Expected TX FIFO empty flag asserted"
    dut._log.info("TX FIFO Streaming test PASSED: all 3 bytes popped and transmitted!")


# -----------------------------------------------------------------------------
# Test 4: RX FIFO Streaming from ProtocolEmulator PUSH into Wishbone
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_wb_rx_streaming(dut):
    """Test 14D: ProtocolEmulator pushing data into RX FIFO, read back by Host CPU via Wishbone."""
    cocotb.start_soon(Clock(dut.i_wb_clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    wb = WishboneMaster(dut)

    BAUD_CYCLES = 10
    await wb.write(ADDR_BAUD, BAUD_CYCLES)

    # Standard UART receiver microcode:
    # 0x00: WAIT rx=0, $HBAUD -> 0x40FE
    # 0x01: NOP       $BAUD   -> 0x01FF
    # 0x02: IN   rx, 8 $BAUD  -> 0x21FF
    # 0x03: WAIT rx=1, 0      -> 0x4100
    # 0x04: PUSH BLOCK        -> 0xA001 (pushes ISR into RX FIFO via o_rx_push!)
    # 0x05: JMP  0x00         -> 0x8000
    prog = [
        0x40FE,
        0x01FF,
        0x21FF,
        0x4100,
        0xA001,
        0x8000
    ]

    await wb.write(ADDR_CTRL, 0x02) # prog_en = 1
    for idx, word in enumerate(prog):
        await wb.write(ADDR_IMEM + (idx * 4), word)

    # Release core to run and allow receiver to arm in idle state
    dut.i_rx.value = 1
    await wb.write(ADDR_CTRL, 0x00)
    await ClockCycles(dut.i_wb_clk, 40)

    async def transmit_uart(byte_val):
        # Start bit (0)
        dut.i_rx.value = 0
        await ClockCycles(dut.i_wb_clk, BAUD_CYCLES + 1)
        # 8 data bits (LSB-first)
        for i in range(8):
            dut.i_rx.value = (byte_val >> i) & 1
            await ClockCycles(dut.i_wb_clk, BAUD_CYCLES + 1)
        # Stop bit (1)
        dut.i_rx.value = 1
        await ClockCycles(dut.i_wb_clk, (BAUD_CYCLES + 1) * 2)

    # Transmit 3 bytes into UART RX: 0xA5, 0x5A, 0x7E
    test_stream = [0xA5, 0x5A, 0x7E]
    for b in test_stream:
        await transmit_uart(b)

    # Wait for RX FIFO to accumulate 3 bytes
    for _ in range(100):
        await RisingEdge(dut.i_wb_clk)
        status = await wb.read(ADDR_STATUS)
        rx_level = (status >> 16) & 0xFF
        if rx_level == 3:
            break
    else:
        assert False, f"Timeout: RX FIFO did not reach level 3 (level={rx_level})"

    # Host CPU reads 3 bytes from ADDR_DATA via Wishbone
    b0 = (await wb.read(ADDR_DATA)) & 0xFF
    b1 = (await wb.read(ADDR_DATA)) & 0xFF
    b2 = (await wb.read(ADDR_DATA)) & 0xFF

    dut._log.info(f"Read back from RX FIFO: 0x{b0:02X}, 0x{b1:02X}, 0x{b2:02X}")
    assert [b0, b1, b2] == test_stream, f"Data mismatch: expected {test_stream}, got {[b0, b1, b2]}"

    # Verify RX FIFO is now empty
    status = await wb.read(ADDR_STATUS)
    rx_empty = (status >> 5) & 1
    assert rx_empty == 1, "Expected RX FIFO empty after reading all bytes"
    dut._log.info("RX FIFO Streaming test PASSED!")


# -----------------------------------------------------------------------------
# Test 5: Interrupt Generation & Watermarks
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_wb_irq_watermarks(dut):
    """Test 14E: Verify o_irq asserts on RX ready and TX empty with enable masks."""
    cocotb.start_soon(Clock(dut.i_wb_clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    wb = WishboneMaster(dut)

    # Initially all IRQ enables are 0 -> o_irq should be 0
    await ClockCycles(dut.i_wb_clk, 2)
    assert int(dut.o_irq.value) == 0, "o_irq should be 0 when IRQ enables are disabled"

    # 1. Enable TX Empty IRQ (bit 4 of ADDR_CTRL)
    await wb.write(ADDR_CTRL, 0x10) # irq_tx_empty_en = 1
    await ClockCycles(dut.i_wb_clk, 2)
    assert int(dut.o_irq.value) == 1, "Expected o_irq == 1 when TX FIFO is empty and irq_tx_empty_en is set"

    # Write a byte to TX FIFO -> TX FIFO not empty -> o_irq should drop
    await wb.write(ADDR_DATA, 0x77)
    await ClockCycles(dut.i_wb_clk, 2)
    assert int(dut.o_irq.value) == 0, "Expected o_irq == 0 when TX FIFO has data"

    # Disable TX Empty IRQ, enable RX Ready IRQ (bit 5)
    await wb.write(ADDR_CTRL, 0x20) # irq_rx_ready_en = 1
    await ClockCycles(dut.i_wb_clk, 2)
    assert int(dut.o_irq.value) == 0, "Expected o_irq == 0 since RX FIFO is empty"

    dut._log.info("Wishbone IRQ Watermarks test PASSED!")


# -----------------------------------------------------------------------------
# Test 6: IMEM Bank Switching & Isolation across all 4 banks (128 words)
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_wb_imem_banking(dut):
    """Test 16: Wishbone IMEM Bank Switching across all 4 banks (128 words)."""
    cocotb.start_soon(Clock(dut.i_wb_clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    wb = WishboneMaster(dut)

    # Halt core before programming
    await wb.write(ADDR_CTRL, 0x02) # prog_en = 1

    # Write unique pattern to Word 0 of each of the 4 banks:
    # Bank 0 (IMEM[0]): 0x1111
    # Bank 1 (IMEM[32]): 0x2222
    # Bank 2 (IMEM[64]): 0x3333
    # Bank 3 (IMEM[96]): 0x4444
    bank_patterns = {0: 0x1111, 1: 0x2222, 2: 0x3333, 3: 0x4444}
    for bank, val in bank_patterns.items():
        await wb.write(ADDR_IMEM_BANK, bank)
        bank_read = await wb.read(ADDR_IMEM_BANK)
        assert (bank_read & 0x3) == bank, f"Expected bank {bank}, got {bank_read & 0x3}"
        # Write Word 0 in this bank (mapped via 0x80)
        await wb.write(ADDR_IMEM, val)

    # Now read back all 4 banks and verify data isolation
    for bank, expected_val in bank_patterns.items():
        await wb.write(ADDR_IMEM_BANK, bank)
        read_val = (await wb.read(ADDR_IMEM)) & 0xFFFF
        assert read_val == expected_val, f"Bank {bank} mismatch: expected 0x{expected_val:04X}, got 0x{read_val:04X}"
        dut._log.info(f"Bank {bank} (IMEM[{bank*32}]): verified 0x{read_val:04X}")

    await wb.write(ADDR_CTRL, 0x00) # prog_en = 0
    dut._log.info("Wishbone IMEM Bank Switching test PASSED across all 4 banks!")



# -----------------------------------------------------------------------------
# Test 7: Hardware Glitch & Wire-Speed MitM Telemetry Register (0x24)
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_wb_glitch_telemetry(dut):
    """Test 25D: Verify Wishbone ADDR_GLITCH (0x24) register readback and telemetry."""
    cocotb.start_soon(Clock(dut.i_wb_clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    wb = WishboneMaster(dut)

    ADDR_GLITCH = 0x24

    # 1. Read default ADDR_GLITCH -> should be 0x00000000
    val = await wb.read(ADDR_GLITCH)
    dut._log.info(f"Default ADDR_GLITCH: 0x{val:08X}")
    assert val == 0x00000000, f"Expected 0x00000000 on default ADDR_GLITCH, got 0x{val:08X}"

    # 2. Program core via Wishbone window (0x80) with Glitch & MitM config
    # Bank 0:
    # 0: GLITCH_CFG 4, 1 (pin 4, pol 1)
    # 1: MOV acc, 0xBE
    # 2: MITM_REPLACE
    # 3: GLITCH_ARM 0
    # 4: JMP 4
    asm_source = """
    GLITCH_CFG 4, 1
    MOV acc, 0xBE
    MITM_REPLACE
    GLITCH_ARM 0
halt:
    JMP halt
"""
    asm = OmnibusAssembler()
    instructions, _ = asm.assemble(asm_source)
    prog = [w[1] for w in instructions]

    # Halt core and program
    await wb.write(ADDR_CTRL, 0x02) # prog_en = 1
    await wb.write(ADDR_IMEM_BANK, 0)
    for idx, word in enumerate(prog):
        await wb.write(ADDR_IMEM + (idx * 4), word)

    # Release prog_en to run
    await wb.write(ADDR_CTRL, 0x00)
    await ClockCycles(dut.i_wb_clk, 15)

    # Read ADDR_GLITCH:
    # [31:24] mitm_match_count: 0
    # [23:16] glitch_timer[7:0]: 0
    # [15:8]  mitm_replace_byte: 0xBE
    # [7]     glitch_fired: 0
    # [6]     mitm_match_found: 0
    # [5]     glitch_armed: 1
    # [4]     glitch_active: 0
    # [3]     glitch_pol: 1
    # [2:0]   glitch_pin: 4 -> [7:0] = 0010_1100b = 0x2C
    # Expected word: {0x00, 0x00, 0xBE, 0x2C} = 0x0000BE2C
    val = await wb.read(ADDR_GLITCH)
    dut._log.info(f"Configured ADDR_GLITCH: 0x{val:08X}")
    assert val == 0x0000BE2C, f"Expected 0x0000BE2C, got 0x{val:08X}"
    dut._log.info("Wishbone Glitch & MitM Telemetry Register (0x24) test PASSED!")
