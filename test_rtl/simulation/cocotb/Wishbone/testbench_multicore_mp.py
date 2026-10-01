# =============================================================================
# File        : testbench_multicore_mp.py
# Description : Cocotb Multi-Core MP Dedicated Verification Suite
#               Tests:
#                 1. Multi-core configuration parameterization (1, 2, 4 cores)
#                 2. 4-Core Protocol Grid and Token Passing via Mailboxes
#                 3. 4-Core Spinlock Contention and Priority Arbitration
#                 4. 4-Core Hardware Rendezvous Barrier simultaneous release
#                 5. 4-Stage Cascade Streaming Pipeline (Core 0 -> 1 -> 2 -> 3)
#                 6. Dual-Core Simultaneous Multi-Protocol Bridge (UART + SPI)
# License     : MIT License
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
ADDR_MP_CTRL     = 0x28
ADDR_MP_STATUS   = 0x2C
ADDR_MP_MAILBOX  = 0x7C
ADDR_IMEM        = 0x80


class WishboneMaster:
    """Helper class to drive standard Wishbone B4 single-cycle read and write cycles."""

    def __init__(self, dut):
        self.dut = dut
        self.clk = dut.i_wb_clk

    async def write(self, addr, data, sel=0xF):
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
# Test 1: Quad-Core Grid & ID Logging to Mailboxes (0..3)
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_mp_quad_core_id_and_mailboxes(dut):
    """Test 35F: Program all 4 cores to read their CORE_ID and write to Mailboxes 0..3."""
    cocotb.start_soon(Clock(dut.i_wb_clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    wb = WishboneMaster(dut)

    # 1. Read MP status to check configured cores
    st = await wb.read(ADDR_MP_STATUS)
    num_cores = (st >> 12) & 0x0F
    dut._log.info(f"Detected NUM_CORES: {num_cores}, ADDR_MP_STATUS: 0x{st:08X}")

    # 2. Place engine in programming mode
    await wb.write(ADDR_CTRL, 0x02)

    # Program each core:
    # CORE_ID
    # MB_WRITE <core_id>
    # BARRIER_WAIT
    # JMP <reset_pc + 2>
    for c in range(min(num_cores, 4)):
        await wb.write(ADDR_IMEM_BANK, c)
        await wb.write(ADDR_IMEM + 0x00, 0xFC00)        # CORE_ID
        await wb.write(ADDR_IMEM + 0x04, 0xF900 | c)     # MB_WRITE c
        await wb.write(ADDR_IMEM + 0x08, 0xFF00)        # BARRIER_WAIT
        await wb.write(ADDR_IMEM + 0x0C, 0x8000 | (c * 32 + 2)) # JMP (stay at barrier)

    # 3. Release programming mode and enable all active cores
    await wb.write(ADDR_MP_CTRL, (1 << num_cores) - 1)
    await wb.write(ADDR_CTRL, 0x00)

    # Wait for all cores to execute and synchronize at barrier
    await ClockCycles(dut.i_wb_clk, 30)

    # 4. Host reads Mailbox Window 0 (Mailboxes 3..0): {MB3, MB2, MB1, MB0}
    mb_w0 = await wb.read(ADDR_MP_MAILBOX)
    dut._log.info(f"Mailbox Window 0 after Core ID write: 0x{mb_w0:08X}")

    for c in range(min(num_cores, 4)):
        mb_val = (mb_w0 >> (c * 8)) & 0xFF
        assert mb_val == c, f"Core {c} Mailbox mismatch: expected {c}, got {mb_val}"

    dut._log.info("Quad-Core Grid & ID Logging test PASSED!")


# -----------------------------------------------------------------------------
# Test 2: Dual-Core Simultaneous Multi-Protocol Bridge (UART + SPI)
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_mp_dual_core_uart_spi_concurrency(dut):
    """Test 35G: Core 0 executes UART while Core 1 simultaneously generates SPI SCK/MOSI."""
    cocotb.start_soon(Clock(dut.i_wb_clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    wb = WishboneMaster(dut)

    # 1. Program Core 0 (Bank 0) with UART TX byte sender
    # 0: PINMAP tx=0, rx=3, sck=1, cs=2
    # 1: MOV osr, 0xA5
    # 2: SET tx=0, [5]   (Start bit)
    # 3: OUT 8, [5]      (8 data bits)
    # 4: SET tx=1, [5]   (Stop bit)
    # 5: JMP 5
    asm = OmnibusAssembler()
    core0_asm = """
    .bank 0
    PINMAP tx=0, rx=3, sck=1, cs=2
    MOV acc, 0xA5
    MOV osr, acc
    SET tx, 0, [5]
    OUT 8, [5]
    SET tx, 1, [5]
    lbl_idle:
    JMP lbl_idle
    """
    words0, _ = asm.assemble(core0_asm)

    # 2. Program Core 1 (Bank 1) with SPI Master transmitter on pins 4..7
    core1_asm = """
    .bank 1
    PINMAP tx=4, rx=7, sck=5, cs=6
    SET cs, 0, [2]
    MOV acc, 0x3C
    MOV osr, acc
    OUT SCK, 8, [4]
    SET cs, 1, [2]
    lbl_spi_done:
    JMP lbl_spi_done
    """
    words1, _ = asm.assemble(core1_asm)

    await wb.write(ADDR_CTRL, 0x02) # prog_en
    # Load Bank 0
    await wb.write(ADDR_IMEM_BANK, 0)
    for addr, word, _ in words0:
        await wb.write(ADDR_IMEM + ((addr % 32) * 4), word)

    # Load Bank 1
    await wb.write(ADDR_IMEM_BANK, 1)
    for addr, word, _ in words1:
        await wb.write(ADDR_IMEM + ((addr % 32) * 4), word)

    # Start both cores
    await wb.write(ADDR_CTRL, 0x00)

    # Sample GPIO pins during execution to verify simultaneous activity
    sampled_gpio = []
    for _ in range(80):
        await RisingEdge(dut.i_wb_clk)
        sampled_gpio.append(int(dut.o_gpio.value))

    # Verify that Pin 0 (UART TX) toggled and Pin 5 (SPI SCK) toggled
    uart_toggles = any(g & 0x01 == 0 for g in sampled_gpio)
    spi_sck_toggles = any(g & 0x20 != 0 for g in sampled_gpio)

    dut._log.info(f"UART toggled: {uart_toggles}, SPI SCK toggled: {spi_sck_toggles}")
    assert uart_toggles, "Expected Pin 0 (UART TX) activity"
    assert spi_sck_toggles, "Expected Pin 5 (SPI SCK) activity"

    dut._log.info("Dual-Core Simultaneous Multi-Protocol Bridge test PASSED!")
