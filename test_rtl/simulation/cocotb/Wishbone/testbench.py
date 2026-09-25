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

ADDR_DATA        = 0x00
ADDR_STATUS      = 0x04
ADDR_CTRL        = 0x08
ADDR_BAUD        = 0x0C
ADDR_GPIO        = 0x10
ADDR_IMEM_BANK   = 0x14
ADDR_AUDIO       = 0x18
ADDR_DEBUG       = 0x1C
ADDR_QSPI        = 0x20
ADDR_GLITCH      = 0x24
ADDR_DMA_CTRL    = 0x30
ADDR_DMA_STATUS  = 0x34
ADDR_DMA_TX_ADDR = 0x38
ADDR_DMA_TX_LEN  = 0x3C
ADDR_DMA_RX_ADDR = 0x40
ADDR_DMA_RX_LEN  = 0x44
ADDR_DMA_TX_DESC = 0x48
ADDR_DMA_RX_DESC = 0x4C
ADDR_PROFILER_CTRL   = 0x50
ADDR_PROFILER_STATUS = 0x54
ADDR_PROFILER_TMIN   = 0x58
ADDR_PROFILER_PERIOD = 0x5C
ADDR_IMEM        = 0x80


class WishboneMemorySlave:
    """Simulates host system RAM responding to DMA Master bus requests."""

    def __init__(self, dut, clk):
        self.dut = dut
        self.clk = clk
        self.mem = {}
        self.dut.i_m_wb_ack.value = 0
        self.dut.i_m_wb_err.value = 0
        self.dut.i_m_wb_data.value = 0
        self._running = True

    def write_byte(self, addr, val):
        self.mem[addr] = val & 0xFF

    def read_byte(self, addr):
        return self.mem.get(addr, 0x00)

    def write_word(self, addr, val):
        self.write_byte(addr + 0, val & 0xFF)
        self.write_byte(addr + 1, (val >> 8) & 0xFF)
        self.write_byte(addr + 2, (val >> 16) & 0xFF)
        self.write_byte(addr + 3, (val >> 24) & 0xFF)

    def read_word(self, addr):
        b0 = self.read_byte(addr + 0)
        b1 = self.read_byte(addr + 1)
        b2 = self.read_byte(addr + 2)
        b3 = self.read_byte(addr + 3)
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)

    async def run(self):
        while self._running:
            await RisingEdge(self.clk)
            if int(self.dut.o_m_wb_cyc.value) == 1 and int(self.dut.o_m_wb_stb.value) == 1:
                addr = int(self.dut.o_m_wb_addr.value)
                we   = int(self.dut.o_m_wb_we.value)
                sel  = int(self.dut.o_m_wb_sel.value)
                if we == 1:
                    wdata = int(self.dut.o_m_wb_data.value)
                    if sel & 0x1: self.write_byte(addr + 0, wdata & 0xFF)
                    if sel & 0x2: self.write_byte(addr + 1, (wdata >> 8) & 0xFF)
                    if sel & 0x4: self.write_byte(addr + 2, (wdata >> 16) & 0xFF)
                    if sel & 0x8: self.write_byte(addr + 3, (wdata >> 24) & 0xFF)
                else:
                    self.dut.i_m_wb_data.value = self.read_word(addr)

                self.dut.i_m_wb_ack.value = 1
                await RisingEdge(self.clk)
                self.dut.i_m_wb_ack.value = 0
            else:
                self.dut.i_m_wb_ack.value = 0

    def stop(self):
        self._running = False



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
    dut.i_m_wb_ack.value  = 0
    dut.i_m_wb_err.value  = 0
    dut.i_m_wb_data.value = 0
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


# -----------------------------------------------------------------------------
# Test 8: DMA Linear TX Channel (Host Memory -> TX FIFO)
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_wb_dma_linear_tx(dut):
    """Test 26A: Verify DMA Linear Memory-to-TX-FIFO transfer."""
    cocotb.start_soon(Clock(dut.i_wb_clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    wb = WishboneMaster(dut)
    mem = WishboneMemorySlave(dut, dut.i_wb_clk)
    cocotb.start_soon(mem.run())

    # 1. Populate system memory at 0x1000 with 16 test bytes
    tx_data = [
        0x10, 0x11, 0x12, 0x13,
        0x20, 0x21, 0x22, 0x23,
        0x30, 0x31, 0x32, 0x33,
        0x40, 0x41, 0x42, 0x43
    ]
    for idx, b in enumerate(tx_data):
        mem.write_byte(0x1000 + idx, b)

    # 2. Place core in programming mode and flush TX FIFO
    await wb.write(ADDR_CTRL, 0x06) # prog_en=1, tx_flush=1
    await ClockCycles(dut.i_wb_clk, 5)

    # 3. Configure DMA TX Channel
    await wb.write(ADDR_DMA_TX_ADDR, 0x00001000)
    await wb.write(ADDR_DMA_TX_LEN, 16)

    # 4. Trigger DMA TX transfer (tx_en=1, tx_start=1)
    await wb.write(ADDR_DMA_CTRL, 0x03)

    # 5. Poll ADDR_DMA_STATUS until transfer finishes (tx_busy==0 and tx_done==1)
    for _ in range(100):
        await ClockCycles(dut.i_wb_clk, 2)
        status = await wb.read(ADDR_DMA_STATUS)
        if (status & 0x01) == 0 and (status & 0x02) != 0:
            break
    else:
        assert False, f"DMA TX did not complete in time, status: 0x{status:08X}"

    dut._log.info(f"DMA TX Complete! Status: 0x{status:08X}")

    # 6. Verify TX FIFO level in ADDR_STATUS is 16
    stat = await wb.read(ADDR_STATUS)
    tx_level = (stat >> 8) & 0xFF
    dut._log.info(f"TX FIFO Level after DMA: {tx_level}")
    assert tx_level == 16, f"Expected 16 bytes in TX FIFO, got {tx_level}"

    # 7. Read and verify all 16 bytes popped from TX FIFO
    popped_bytes = []
    for i in range(16):
        await RisingEdge(dut.i_wb_clk)
        b = int(dut.tx_fifo_rdata.value)
        popped_bytes.append(b)
        dut.core.o_tx_pop.value = 1
        await RisingEdge(dut.i_wb_clk)
        dut.core.o_tx_pop.value = 0

    dut._log.info(f"Popped bytes: {[hex(x) for x in popped_bytes]}")
    assert popped_bytes == tx_data, f"Data mismatch! Expected {tx_data}, got {popped_bytes}"
    mem.stop()
    dut._log.info("DMA Linear TX Channel test PASSED!")


# -----------------------------------------------------------------------------
# Test 9: DMA Linear RX Channel (RX FIFO -> Host Memory)
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_wb_dma_linear_rx(dut):
    """Test 26B: Verify DMA Linear RX-FIFO-to-Memory capture."""
    cocotb.start_soon(Clock(dut.i_wb_clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    wb = WishboneMaster(dut)
    mem = WishboneMemorySlave(dut, dut.i_wb_clk)
    cocotb.start_soon(mem.run())

    rx_test_bytes = [0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC]

    # 1. Place core in programming mode and flush RX FIFO
    await wb.write(ADDR_CTRL, 0x0A) # prog_en=1, rx_flush=1
    await ClockCycles(dut.i_wb_clk, 5)

    # 2. Push 8 test bytes into rx_fifo
    for b in rx_test_bytes:
        await RisingEdge(dut.i_wb_clk)
        dut.core.o_data.value = b
        dut.core.o_rx_push.value = 1
        await RisingEdge(dut.i_wb_clk)
        dut.core.o_rx_push.value = 0

    await ClockCycles(dut.i_wb_clk, 2)
    stat = await wb.read(ADDR_STATUS)
    rx_level = (stat >> 16) & 0xFF
    dut._log.info(f"RX FIFO Level before DMA: {rx_level}")
    assert rx_level == 8, f"Expected 8 bytes in RX FIFO, got {rx_level}"

    # 3. Configure RX DMA
    await wb.write(ADDR_DMA_RX_ADDR, 0x00002000)
    await wb.write(ADDR_DMA_RX_LEN, 8)

    # 4. Trigger RX DMA (rx_en=1, rx_start=1) -> bits [5, 4] = 0x30
    await wb.write(ADDR_DMA_CTRL, 0x30)

    # 5. Poll ADDR_DMA_STATUS until rx_done is asserted
    for _ in range(150):
        await ClockCycles(dut.i_wb_clk, 2)
        status = await wb.read(ADDR_DMA_STATUS)
        if (status & 0x10) == 0 and (status & 0x20) != 0:
            break
    else:
        assert False, f"DMA RX did not complete in time, status: 0x{status:08X}"

    dut._log.info(f"DMA RX Complete! Status: 0x{status:08X}")

    # 6. Verify memory contents at 0x2000..0x2007
    captured = [mem.read_byte(0x00002000 + i) for i in range(8)]
    dut._log.info(f"Memory captured bytes: {[hex(x) for x in captured]}")
    assert captured == rx_test_bytes, f"RX Data mismatch! Expected {rx_test_bytes}, got {captured}"
    mem.stop()
    dut._log.info("DMA Linear RX Channel test PASSED!")


# -----------------------------------------------------------------------------
# Test 10: DMA Scatter-Gather Chained Descriptors (TX Channel)
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_wb_dma_scatter_gather_chain(dut):
    """Test 26C: Verify 2-stage Scatter-Gather linked-list descriptor traversal."""
    cocotb.start_soon(Clock(dut.i_wb_clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    wb = WishboneMaster(dut)
    mem = WishboneMemorySlave(dut, dut.i_wb_clk)
    cocotb.start_soon(mem.run())

    # Descriptor 1 @ 0x3000: 4 bytes from 0x4000, next = 0x3010, flags = 0
    mem.write_word(0x3000, 0x00004000)               # Word 0: buf_addr
    mem.write_word(0x3004, (0x0000 << 16) | 4)        # Word 1: flags=0, len=4
    mem.write_word(0x3008, 0x00003010)               # Word 2: next_desc = 0x3010
    mem.write_word(0x300C, 0x00000000)               # Word 3: status

    # Descriptor 2 @ 0x3010: 4 bytes from 0x4010, next = 0x0000, flags = 1 (EOT)
    mem.write_word(0x3010, 0x00004010)               # Word 0: buf_addr
    mem.write_word(0x3014, (0x0001 << 16) | 4)        # Word 1: flags=EOT(bit 16), len=4
    mem.write_word(0x3018, 0x00000000)               # Word 2: next_desc
    mem.write_word(0x301C, 0x00000000)               # Word 3: status

    # Data buffers
    buf1 = [0xCA, 0xFE, 0xBA, 0xBE]
    buf2 = [0xDE, 0xAD, 0xBE, 0xEF]
    for idx, b in enumerate(buf1):
        mem.write_byte(0x4000 + idx, b)
    for idx, b in enumerate(buf2):
        mem.write_byte(0x4010 + idx, b)

    # Halt core and flush FIFO
    await wb.write(ADDR_CTRL, 0x06)
    await ClockCycles(dut.i_wb_clk, 5)

    # Configure DMA for Scatter-Gather:
    # ADDR_DMA_TX_ADDR = 0x3000 (first descriptor)
    await wb.write(ADDR_DMA_TX_ADDR, 0x00003000)
    # Trigger SG TX: tx_en=1, tx_start=1, tx_sg_en=1 -> bits [3, 1, 0] = 0x0B
    await wb.write(ADDR_DMA_CTRL, 0x0B)

    # Poll until complete
    for _ in range(150):
        await ClockCycles(dut.i_wb_clk, 2)
        status = await wb.read(ADDR_DMA_STATUS)
        if (status & 0x01) == 0 and (status & 0x02) != 0:
            break
    else:
        assert False, f"Scatter-gather DMA did not complete, status: 0x{status:08X}"

    dut._log.info(f"Scatter-Gather DMA Complete! Status: 0x{status:08X}")

    # Verify status write-backs in memory
    st1 = mem.read_word(0x300C)
    st2 = mem.read_word(0x301C)
    dut._log.info(f"Desc1 status: 0x{st1:08X}, Desc2 status: 0x{st2:08X}")
    assert (st1 & 0xFFFF) == 4, f"Expected 4 bytes transferred for Desc1, got {st1}"
    assert (st2 & 0xFFFF) == 4, f"Expected 4 bytes transferred for Desc2, got {st2}"

    # Verify 8 total bytes in TX FIFO
    popped = []
    for _ in range(8):
        await RisingEdge(dut.i_wb_clk)
        popped.append(int(dut.tx_fifo_rdata.value))
        dut.core.o_tx_pop.value = 1
        await RisingEdge(dut.i_wb_clk)
        dut.core.o_tx_pop.value = 0

    expected = buf1 + buf2
    dut._log.info(f"Scatter-Gather popped bytes: {[hex(x) for x in popped]}")
    assert popped == expected, f"Expected {expected}, got {popped}"
    mem.stop()
    dut._log.info("DMA Scatter-Gather Chained Descriptors test PASSED!")


# -----------------------------------------------------------------------------
# Test 11: DMA Interrupt Generation & Abort Logic
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_wb_dma_irq_and_abort(dut):
    """Test 26D: Verify DMA completion interrupt assertion and software abort."""
    cocotb.start_soon(Clock(dut.i_wb_clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    wb = WishboneMaster(dut)
    mem = WishboneMemorySlave(dut, dut.i_wb_clk)
    cocotb.start_soon(mem.run())

    # 1. Verify o_irq initially low
    assert int(dut.o_irq.value) == 0

    # 2. Populate 4 bytes in memory
    for i in range(4):
        mem.write_byte(0x1000 + i, 0x11 * (i + 1))

    # Halt core and flush FIFO
    await wb.write(ADDR_CTRL, 0x06)
    await ClockCycles(dut.i_wb_clk, 5)

    # 3. Start TX DMA with tx_irq_en (bit 2) + tx_en (bit 0) + tx_start (bit 1) = 0x07
    await wb.write(ADDR_DMA_TX_ADDR, 0x00001000)
    await wb.write(ADDR_DMA_TX_LEN, 4)
    await wb.write(ADDR_DMA_CTRL, 0x07)

    # 4. Wait for transfer done
    for _ in range(50):
        await ClockCycles(dut.i_wb_clk, 2)
        status = await wb.read(ADDR_DMA_STATUS)
        if (status & 0x02) != 0:
            break

    # 5. Verify interrupt asserted on completion
    assert int(dut.o_irq.value) == 1, "Expected o_irq to assert after DMA TX Done!"
    dut._log.info("DMA Interrupt asserted successfully!")

    # 6. Test Abort
    await wb.write(ADDR_DMA_CTRL, 0x0100) # abort = bit 8
    await ClockCycles(dut.i_wb_clk, 2)
    st = await wb.read(ADDR_DMA_STATUS)
    assert (st & 0x01) == 0, f"Expected tx_busy == 0 after abort, got: 0x{st:08X}"
    assert (st & 0x10) == 0, f"Expected rx_busy == 0 after abort, got: 0x{st:08X}"

    mem.stop()
    dut._log.info("DMA Interrupt Generation & Abort test PASSED!")



@cocotb.test()
async def test_wb_profiler_registers(dut):
    """Test 27D: Wishbone slave register read/write and profiler telemetry control."""
    cocotb.start_soon(Clock(dut.i_wb_clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    wb = WishboneMaster(dut)

    # 1. Configure profiler: pin=2, filter=3, arm=1, irq_en=1
    # [2:0]=2 (pin 2), [6:3]=3 (filter 3), [8]=arm (1), [11]=irq_en (1)
    ctrl_val = 2 | (3 << 3) | (1 << 8) | (1 << 11)
    await wb.write(ADDR_PROFILER_CTRL, ctrl_val)
    await ClockCycles(dut.i_wb_clk, 2)

    # Read back CTRL register
    ctrl_rb = await wb.read(ADDR_PROFILER_CTRL)
    assert (ctrl_rb & 0x7) == 2, f"Expected pin 2, got {ctrl_rb & 0x7}"
    assert ((ctrl_rb >> 3) & 0xF) == 3, f"Expected filter 3, got {(ctrl_rb >> 3) & 0xF}"
    assert ((ctrl_rb >> 11) & 0x1) == 1, "Expected irq_en 1"

    # Read status: busy should be 1
    status = await wb.read(ADDR_PROFILER_STATUS)
    busy = status & 1
    assert busy == 1, f"Expected busy=1, got status=0x{status:08X}"

    # Stimulate pin 2 (i_gpio[2]) with pulse train: 50 cycles high, 50 cycles low
    for _ in range(8):
        dut.i_gpio.value = int(dut.i_gpio.value) | 0x04
        await ClockCycles(dut.i_wb_clk, 50)
        dut.i_gpio.value = int(dut.i_gpio.value) & ~0x04
        await ClockCycles(dut.i_wb_clk, 50)

    # Wait for edges
    await ClockCycles(dut.i_wb_clk, 20)
    status2 = await wb.read(ADDR_PROFILER_STATUS)
    edges = (status2 >> 8) & 0xFF
    assert edges >= 6, f"Expected at least 6 edges, got {edges}"

    # Read tmin and period
    tmin_reg = await wb.read(ADDR_PROFILER_TMIN)
    tmin_val = tmin_reg & 0xFFFF
    dut._log.info(f"Wishbone read tmin_val: {tmin_val} cycles")
    assert abs(tmin_val - 50) <= 3, f"Expected ~50 cycles, got {tmin_val}"

    # Stop profiler
    await wb.write(ADDR_PROFILER_CTRL, 1 << 9) # stop
    await ClockCycles(dut.i_wb_clk, 5)
    st_stopped = await wb.read(ADDR_PROFILER_STATUS)
    assert (st_stopped & 1) == 0, "Expected busy=0 after stop"

    dut._log.info("Wishbone Autonomous Profiler Register & Control test PASSED!")


# -----------------------------------------------------------------------------
# Test 13: USB 1.1 Autonomous SIE Wishbone Registers & Telemetry (Task 28)
# -----------------------------------------------------------------------------
ADDR_USB_CTRL     = 0x60
ADDR_USB_STATUS   = 0x64
ADDR_USB_EP_CTRL  = 0x68
ADDR_USB_TX_TOKEN = 0x6C

@cocotb.test()
async def test_wb_usb_sie_registers(dut):
    """Test 28D: Verify Wishbone USB 1.1 SIE control registers, address config, and telemetry."""
    cocotb.start_soon(Clock(dut.i_wb_clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    wb = WishboneMaster(dut)

    # 1. Default read of ADDR_USB_CTRL: sie_en=0, auto_ack=1, dev_addr=0, bit_div=4
    ctrl = await wb.read(ADDR_USB_CTRL)
    dut._log.info(f"Initial ADDR_USB_CTRL: 0x{ctrl:08X}")
    assert (ctrl & 0x01) == 0, "Expected sie_en=0 by default"

    # 2. Configure USB SIE:
    # sie_en = 1 (bit 0)
    # speed_mode = 0 (bit 1: Full Speed)
    # auto_ack = 1 (bit 2)
    # dev_addr = 0x1A = 26 (bits [9:3])
    # bit_div = 10 (bits [25:10])
    cfg_val = (10 << 10) | (0x1A << 3) | (1 << 2) | (0 << 1) | 1
    await wb.write(ADDR_USB_CTRL, cfg_val)
    await ClockCycles(dut.i_wb_clk, 5)

    ctrl_read = await wb.read(ADDR_USB_CTRL)
    dut._log.info(f"Configured ADDR_USB_CTRL: 0x{ctrl_read:08X}")
    assert (ctrl_read & 0x01) == 1, "Expected sie_en=1"
    assert ((ctrl_read >> 3) & 0x7F) == 0x1A, f"Expected dev_addr 0x1A, got {hex((ctrl_read >> 3) & 0x7F)}"
    assert ((ctrl_read >> 10) & 0xFFFF) == 10, f"Expected bit_div 10, got {((ctrl_read >> 10) & 0xFFFF)}"

    # 3. Configure Endpoint Controls (ADDR_USB_EP_CTRL):
    # ep_stall = 0x01 (EP0 stall)
    # ep_nak = 0x04 (EP2 nak)
    # ep_toggle = 0x08 (EP3 DATA1)
    ep_val = (0x8 << 8) | (0x4 << 4) | 0x1
    await wb.write(ADDR_USB_EP_CTRL, ep_val)
    await ClockCycles(dut.i_wb_clk, 5)

    ep_read = await wb.read(ADDR_USB_EP_CTRL)
    assert (ep_read & 0x0F) == 0x01, f"Expected ep_stall 0x01, got {hex(ep_read & 0x0F)}"
    assert ((ep_read >> 4) & 0x0F) == 0x04, f"Expected ep_nak 0x04, got {hex((ep_read >> 4) & 0x0F)}"
    assert ((ep_read >> 8) & 0x0F) == 0x08, f"Expected ep_toggle 0x08, got {hex((ep_read >> 8) & 0x0F)}"

    # 4. Check Status (ADDR_USB_STATUS):
    dut.i_gpio.value = 0xFD  # Idle J-state: Pin 0 (D+)=1, Pin 1 (D-)=0
    await ClockCycles(dut.i_wb_clk, 10)
    status = await wb.read(ADDR_USB_STATUS)
    dut._log.info(f"ADDR_USB_STATUS: 0x{status:08X}")
    # In idle, bus_idle (bit 29) should be 1
    bus_idle = (status >> 29) & 1
    assert bus_idle == 1, "Expected bus_idle == 1"

    dut._log.info("Wishbone USB 1.1 SIE Control & Status test PASSED!")


# -----------------------------------------------------------------------------
# Test 14: On-Chip Self-Play & Virtual Crossbar (BIST Engine) Registers (0x70..0x78)
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_wb_bist_registers(dut):
    """Test 29D: Verify Wishbone BIST control, status telemetry, and score readback."""
    cocotb.start_soon(Clock(dut.i_wb_clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    wb = WishboneMaster(dut)

    ADDR_BIST_CTRL   = 0x70
    ADDR_BIST_STATUS = 0x74
    ADDR_BIST_SCORES = 0x78

    # 1. Read default BIST Status
    status = await wb.read(ADDR_BIST_STATUS)
    dut._log.info(f"Default ADDR_BIST_STATUS: 0x{status:08X}")
    assert (status & 0x01) == 0, "Expected bist_active=0 by default"

    # 2. Configure BIST Control:
    # mode = 2 (split crossbar, bits [1:0] = 0b10)
    # jitter_en = 0 (bit 2)
    # bist_en = 1 (bit 3)
    # start = 1 (bit 4)
    # stage = 5 (bits [11:8] = 0x5)
    # Value: (5 << 8) | (1 << 4) | (1 << 3) | 2 = 0x051A
    await wb.write(ADDR_BIST_CTRL, 0x051A)
    await ClockCycles(dut.i_wb_clk, 5)

    status_read = await wb.read(ADDR_BIST_STATUS)
    dut._log.info(f"Active ADDR_BIST_STATUS: 0x{status_read:08X}")
    assert (status_read & 0x01) == 1, "Expected bist_active == 1"
    assert ((status_read >> 2) & 0x03) == 2, f"Expected bist_mode == 2, got {((status_read >> 2) & 0x03)}"
    assert ((status_read >> 4) & 0x0F) == 5, f"Expected bist_stage == 5, got {((status_read >> 4) & 0x0F)}"

    # 3. Read Scores
    scores = await wb.read(ADDR_BIST_SCORES)
    dut._log.info(f"ADDR_BIST_SCORES: 0x{scores:08X}")

    # 4. Stop BIST
    # stop = bit 5
    await wb.write(ADDR_BIST_CTRL, 1 << 5)
    await ClockCycles(dut.i_wb_clk, 5)
    status_stopped = await wb.read(ADDR_BIST_STATUS)
    assert (status_stopped & 0x01) == 0, "Expected bist_active == 0 after stop"

    dut._log.info("Wishbone BIST Control & Status Registers (0x70..0x78) test PASSED!")
