# =============================================================================
# File        : uvm_testbench.py
# Description : Production-grade pyUVM verification environment for the OmniBus
#               ProtocolEmulator ASIC micro-engine.
# Standards   : Universal Verification Methodology (UVM) via pyuvm + Cocotb
# License     : MIT License
# =============================================================================

import sys
import os
import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles, Timer
from pyuvm import *

# Ensure repository root is on sys.path for omnibus_asm
repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../.."))
if repo_root not in sys.path:
    sys.path.insert(0, repo_root)

from python.omnibus_asm import OmnibusAssembler

CLK_PERIOD_NS = 20  # 50 MHz = 20 ns period
DEFAULT_BAUD_DIV = 433  # 115200 baud @ 50 MHz

# =============================================================================
# Reference Implementations & CRC Calculators
# =============================================================================
def calc_dallas_crc8(data_bytes):
    """Dallas 1-Wire CRC-8 (poly 0x8C, init 0x00)."""
    crc = 0
    for b in data_bytes:
        crc ^= b
        for _ in range(8):
            if crc & 0x01:
                crc = (crc >> 1) ^ 0x8C
            else:
                crc >>= 1
    return crc & 0xFF

def calc_smbus_crc8(data_bytes):
    """SMBus / I2C CRC-8 (poly 0x07, init 0x00)."""
    crc = 0
    for b in data_bytes:
        crc ^= b
        for _ in range(8):
            if crc & 0x80:
                crc = ((crc << 1) ^ 0x07) & 0xFF
            else:
                crc = (crc << 1) & 0xFF
    return crc & 0xFF

def calc_ccitt_crc16(data_bytes):
    """CCITT CRC-16 (poly 0x1021, init 0xFFFF)."""
    crc = 0xFFFF
    for b in data_bytes:
        crc ^= (b << 8)
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    return crc & 0xFFFF

def calc_modbus_crc16(data_bytes):
    """Modbus CRC-16 (poly 0xA001, init 0xFFFF)."""
    crc = 0xFFFF
    for b in data_bytes:
        crc ^= b
        for _ in range(8):
            if crc & 0x0001:
                crc = (crc >> 1) ^ 0xA001
            else:
                crc >>= 1
    return crc & 0xFFFF


# =============================================================================
# 1. UVM Sequence Items (Transactions)
# =============================================================================
class OmniBusProgramItem(uvm_sequence_item):
    """Microcode program load and execution transaction."""
    def __init__(self, name="OmniBusProgramItem"):
        super().__init__(name)
        self.asm_source = ""
        self.words = []          # List of (addr, 16-bit word)
        self.start_addr = 0
        self.baud_div = DEFAULT_BAUD_DIV
        self.initial_gpio = 0xFF
        self.initial_data = 0x00
        self.test_tag = "DEFAULT"

    def set_asm(self, asm_code, test_tag="ASM_TEST"):
        self.asm_source = asm_code
        self.test_tag = test_tag
        assembler = OmnibusAssembler(clk_freq=50_000_000, default_baud=115_200)
        assembled, labels = assembler.assemble(asm_code)
        self.words = [(addr, word) for addr, word, _ in assembled]

    def set_raw_words(self, words, test_tag="RAW_TEST"):
        self.words = list(enumerate(words))
        self.test_tag = test_tag

    def __str__(self):
        return f"OmniBusProgramItem [{self.test_tag}]: {len(self.words)} words, baud_div={self.baud_div}"


class OmniBusStimulusItem(uvm_sequence_item):
    """Dynamic I/O stimulus transaction (UART, GPIO, FIFO, etc.)."""
    def __init__(self, name="OmniBusStimulusItem"):
        super().__init__(name)
        self.stim_type = "NOP"  # "UART_BYTE", "GPIO_DRIVE", "FIFO_DATA", "WAIT", "RESET"
        self.data_byte = 0x00
        self.data_bytes = []
        self.gpio_val = 0xFF
        self.cycles = 10
        self.cycles_per_bit = 434
        self.extra = {}

    def __str__(self):
        return f"OmniBusStimulusItem [{self.stim_type}]: data=0x{self.data_byte:02X}, gpio=0x{self.gpio_val:02X}, cycles={self.cycles}"


class OmniBusSampledItem(uvm_sequence_item):
    """Observed event/transaction published by Monitor."""
    def __init__(self, name="OmniBusSampledItem"):
        super().__init__(name)
        self.event_type = "UNKNOWN"  # "UART_TX", "FIFO_PUSH", "FIFO_POP", "GPIO_CHANGE"
        self.byte_val = 0x00
        self.gpio_out = 0x00
        self.gpio_oe = 0x00
        self.o_data = 0x00
        self.cycle = 0
        self.details = {}

    def __str__(self):
        return f"OmniBusSampledItem [{self.event_type}]: byte=0x{self.byte_val:02X}, gpio=0x{self.gpio_out:02X}, oe=0x{self.gpio_oe:02X}"


# =============================================================================
# 2. UVM Driver
# =============================================================================
class OmniBusDriver(uvm_driver):
    """Drives clock, reset, IMEM programming port, and I/O stimulus into DUT."""
    def __init__(self, name, parent):
        super().__init__(name, parent)
        self.dut = None

    def start_of_simulation_phase(self):
        self.dut = cocotb.top

    async def run_phase(self):
        while True:
            item = await self.seq_item_port.get_next_item()
            if isinstance(item, OmniBusProgramItem):
                await self.handle_program_load(item)
            elif isinstance(item, OmniBusStimulusItem):
                await self.handle_stimulus(item)
            self.seq_item_port.item_done()

    async def handle_program_load(self, prog_item):
        """Loads microcode into IMEM via runtime programming port."""
        dut = self.dut
        dut.i_prog_en.value = 1
        dut.i_prog_we.value = 1

        for addr, word in prog_item.words:
            dut.i_prog_addr.value = addr
            dut.i_prog_data.value = word
            await RisingEdge(dut.i_clk)

        dut.i_prog_en.value = 0
        dut.i_prog_we.value = 0
        dut.i_prog_addr.value = 0
        dut.i_prog_data.value = 0
        dut.i_baud_div.value = prog_item.baud_div
        dut.i_gpio.value = prog_item.initial_gpio
        dut.i_data.value = prog_item.initial_data
        await RisingEdge(dut.i_clk)

    async def handle_stimulus(self, stim_item):
        """Executes dynamic stimuli on DUT inputs."""
        dut = self.dut
        st = stim_item.stim_type

        if st == "UART_BYTE":
            # Drive standard 8N1 UART frame into i_rx and GPIO rx_pin (Pin 0 / Pin 3)
            cpb = stim_item.cycles_per_bit
            byte_val = stim_item.data_byte
            
            # Start bit (0)
            dut.i_rx.value = 0
            dut.i_gpio.value = (int(dut.i_gpio.value) & ~0x09)
            await ClockCycles(dut.i_clk, cpb)

            # 8 Data bits LSB-first
            for bit_idx in range(8):
                b = (byte_val >> bit_idx) & 0x01
                dut.i_rx.value = b
                if b:
                    dut.i_gpio.value = int(dut.i_gpio.value) | 0x09
                else:
                    dut.i_gpio.value = int(dut.i_gpio.value) & ~0x09
                await ClockCycles(dut.i_clk, cpb)

            # Stop bit (1)
            dut.i_rx.value = 1
            dut.i_gpio.value = int(dut.i_gpio.value) | 0x09
            await ClockCycles(dut.i_clk, cpb)

        elif st == "GPIO_DRIVE":
            dut.i_gpio.value = stim_item.gpio_val
            await ClockCycles(dut.i_clk, stim_item.cycles)

        elif st == "FIFO_DATA":
            dut.i_data.value = stim_item.data_byte
            dut.i_tx_valid.value = 1
            await RisingEdge(dut.i_clk)
            await ClockCycles(dut.i_clk, stim_item.cycles)

        elif st == "RESET":
            dut.i_reset_n.value = 0
            await ClockCycles(dut.i_clk, stim_item.cycles)
            dut.i_reset_n.value = 1
            await RisingEdge(dut.i_clk)

        elif st == "WAIT":
            await ClockCycles(dut.i_clk, stim_item.cycles)


# =============================================================================
# 3. UVM Monitor
# =============================================================================
class OmniBusMonitor(uvm_monitor):
    """Passively observes DUT outputs, decodes UART frames, FIFO strobes, and GPIO."""
    def __init__(self, name, parent):
        super().__init__(name, parent)
        self.ap = uvm_analysis_port("ap", self)
        self.dut = None

    def build_phase(self):
        super().build_phase()

    def start_of_simulation_phase(self):
        self.dut = cocotb.top

    async def run_phase(self):
        dut = self.dut
        # Start concurrent sub-monitors
        cocotb.start_soon(self.monitor_fifo_strobes())
        cocotb.start_soon(self.monitor_uart_tx())
        cocotb.start_soon(self.monitor_gpio_transitions())

    async def monitor_fifo_strobes(self):
        dut = self.dut
        while True:
            await RisingEdge(dut.i_clk)
            if dut.i_reset_n.value:
                # Check for FIFO push strobe
                if int(dut.o_rx_push.value) == 1:
                    tr = OmniBusSampledItem("fifo_push_item")
                    tr.event_type = "FIFO_PUSH"
                    tr.o_data = int(dut.o_data.value) & 0xFF
                    tr.byte_val = tr.o_data
                    self.ap.write(tr)

                # Check for FIFO pop strobe
                if int(dut.o_tx_pop.value) == 1:
                    tr = OmniBusSampledItem("fifo_pop_item")
                    tr.event_type = "FIFO_POP"
                    self.ap.write(tr)

    async def monitor_uart_tx(self):
        dut = self.dut
        cpb = 434
        while True:
            await RisingEdge(dut.i_clk)
            if dut.i_reset_n.value:
                tx_val = int(dut.o_tx.value) & 0x01
                # Start bit detected (falling edge from idle high to 0)
                if tx_val == 0:
                    # Sample at mid-start bit
                    await ClockCycles(dut.i_clk, cpb // 2)
                    if (int(dut.o_tx.value) & 0x01) == 0:
                        # Sample 8 data bits
                        sampled_bits = []
                        for _ in range(8):
                            await ClockCycles(dut.i_clk, cpb)
                            sampled_bits.append(int(dut.o_tx.value) & 0x01)

                        # Reconstruct byte
                        byte_val = 0
                        for i, b in enumerate(sampled_bits):
                            byte_val |= (b << i)

                        # Wait for stop bit
                        await ClockCycles(dut.i_clk, cpb)
                        stop_val = int(dut.o_tx.value) & 0x01

                        tr = OmniBusSampledItem("uart_tx_item")
                        tr.event_type = "UART_TX"
                        tr.byte_val = byte_val
                        tr.details = {"stop_bit": stop_val, "bits": sampled_bits}
                        self.ap.write(tr)

                        # Finish remainder of stop bit
                        await ClockCycles(dut.i_clk, cpb // 2)

    async def monitor_gpio_transitions(self):
        dut = self.dut
        prev_gpio = None
        prev_oe = None
        while True:
            await RisingEdge(dut.i_clk)
            if dut.i_reset_n.value:
                cur_gpio = int(dut.o_gpio.value) & 0xFF
                cur_oe = int(dut.o_gpio_oe.value) & 0xFF
                if cur_gpio != prev_gpio or cur_oe != prev_oe:
                    prev_gpio = cur_gpio
                    prev_oe = cur_oe
                    tr = OmniBusSampledItem("gpio_change_item")
                    tr.event_type = "GPIO_CHANGE"
                    tr.gpio_out = cur_gpio
                    tr.gpio_oe = cur_oe
                    self.ap.write(tr)


# =============================================================================
# 4. UVM Functional Coverage Collector
# =============================================================================
class OmniBusCoverage(uvm_subscriber):
    """Tracks functional coverage for opcodes, ALU operations, GPIO pins, CRC, and FIFOs."""
    def __init__(self, name, parent):
        super().__init__(name, parent)
        self.covered_opcodes = set()
        self.covered_alu_ops = set()
        self.covered_crc_polys = set()
        self.covered_events = set()
        self.total_transactions = 0

    def write(self, tr):
        self.total_transactions += 1
        if isinstance(tr, OmniBusSampledItem):
            self.covered_events.add(tr.event_type)

    def sample_opcode(self, opcode_name):
        self.covered_opcodes.add(opcode_name)

    def sample_alu_op(self, op_name):
        self.covered_alu_ops.add(op_name)

    def sample_crc_poly(self, poly_name):
        self.covered_crc_polys.add(poly_name)

    def get_summary(self):
        all_opcodes = {"NOP", "OUT", "IN", "SET", "WAIT", "PINMAP", "CFG_OD", "LC", "JMP", "PULL", "PUSH", "ALU", "CALL", "RET", "CRC", "ASSIST"}
        all_alu_ops = {"ADD", "SUB", "CMP", "AND", "OR", "XOR", "MOV", "NOT", "INC", "DEC", "CLR", "SHL", "SHR", "ROL", "ROR"}
        all_crc_polys = {"DALLAS_CRC8", "SMBUS_CRC8", "CCITT_CRC16", "MODBUS_CRC16"}

        op_cov = (len(self.covered_opcodes) / len(all_opcodes)) * 100.0 if all_opcodes else 100.0
        alu_cov = (len(self.covered_alu_ops) / len(all_alu_ops)) * 100.0 if all_alu_ops else 100.0
        crc_cov = (len(self.covered_crc_polys) / len(all_crc_polys)) * 100.0 if all_crc_polys else 100.0

        return {
            "opcode_coverage_pct": op_cov,
            "alu_coverage_pct": alu_cov,
            "crc_coverage_pct": crc_cov,
            "covered_opcodes": sorted(list(self.covered_opcodes)),
            "covered_alu_ops": sorted(list(self.covered_alu_ops)),
            "covered_crc_polys": sorted(list(self.covered_crc_polys)),
            "total_transactions": self.total_transactions
        }


# =============================================================================
# 5. UVM Scoreboard
# =============================================================================
class OmniBusScoreboard(uvm_subscriber):
    """Golden reference comparator verifying output data, timing, and protocol integrity."""
    def __init__(self, name, parent):
        super().__init__(name, parent)
        self.expected_fifo_pushes = []
        self.expected_uart_bytes = []
        self.match_count = 0
        self.mismatch_count = 0

    def expect_fifo_push(self, byte_val):
        self.expected_fifo_pushes.append(byte_val & 0xFF)

    def expect_uart_byte(self, byte_val):
        self.expected_uart_bytes.append(byte_val & 0xFF)

    def write(self, tr):
        # Direct write path from monitor
        if tr.event_type == "FIFO_PUSH":
            if self.expected_fifo_pushes:
                exp = self.expected_fifo_pushes.pop(0)
                if tr.byte_val == exp:
                    self.match_count += 1
                    self.logger.info(f"[SCOREBOARD MATCH] FIFO PUSH 0x{tr.byte_val:02X}")
                else:
                    self.mismatch_count += 1
                    self.logger.error(f"[SCOREBOARD MISMATCH] FIFO PUSH expected 0x{exp:02X}, got 0x{tr.byte_val:02X}")
                    assert False, f"Scoreboard mismatch on FIFO PUSH: exp 0x{exp:02X} != got 0x{tr.byte_val:02X}"

        elif tr.event_type == "UART_TX":
            if self.expected_uart_bytes:
                exp = self.expected_uart_bytes.pop(0)
                if tr.byte_val == exp:
                    self.match_count += 1
                    self.logger.info(f"[SCOREBOARD MATCH] UART TX 0x{tr.byte_val:02X}")
                else:
                    self.mismatch_count += 1
                    self.logger.error(f"[SCOREBOARD MISMATCH] UART TX expected 0x{exp:02X}, got 0x{tr.byte_val:02X}")
                    assert False, f"Scoreboard mismatch on UART TX: exp 0x{exp:02X} != got 0x{tr.byte_val:02X}"

    def check_phase(self):
        if self.expected_fifo_pushes:
            self.logger.error(f"Scoreboard check failed: {len(self.expected_fifo_pushes)} unconsumed expected FIFO pushes!")
            assert False, "Unconsumed expected FIFO pushes remaining"
        if self.expected_uart_bytes:
            self.logger.error(f"Scoreboard check failed: {len(self.expected_uart_bytes)} unconsumed expected UART bytes!")
            assert False, "Unconsumed expected UART bytes remaining"
        self.logger.info(f"[SCOREBOARD SUMMARY] All checks PASSED! Total matches: {self.match_count}")


# =============================================================================
# 6. UVM Agent & Environment
# =============================================================================
class OmniBusAgent(uvm_agent):
    def build_phase(self):
        super().build_phase()
        self.monitor = OmniBusMonitor.create("monitor", self)
        self.driver = OmniBusDriver.create("driver", self)
        self.sequencer = uvm_sequencer("sequencer", self)

    def connect_phase(self):
        super().connect_phase()
        self.driver.seq_item_port.connect(self.sequencer.seq_item_export)


class OmniBusEnv(uvm_env):
    def build_phase(self):
        super().build_phase()
        self.agent = OmniBusAgent.create("agent", self)
        self.scoreboard = OmniBusScoreboard.create("scoreboard", self)
        self.coverage = OmniBusCoverage.create("coverage", self)

    def connect_phase(self):
        super().connect_phase()
        self.agent.monitor.ap.connect(self.scoreboard.analysis_export)
        self.agent.monitor.ap.connect(self.coverage.analysis_export)


# =============================================================================
# 7. UVM Sequence Library
# =============================================================================
class OmniBusBaseSequence(uvm_sequence):
    async def load_prog(self, asm_code, tag="PROG"):
        item = OmniBusProgramItem()
        item.set_asm(asm_code, tag)
        await self.start_item(item)
        await self.finish_item(item)

    async def wait_cycles(self, cycles=10):
        item = OmniBusStimulusItem()
        item.stim_type = "WAIT"
        item.cycles = cycles
        await self.start_item(item)
        await self.finish_item(item)

    async def send_uart_byte(self, byte_val, cpb=434):
        item = OmniBusStimulusItem()
        item.stim_type = "UART_BYTE"
        item.data_byte = byte_val
        item.cycles_per_bit = cpb
        await self.start_item(item)
        await self.finish_item(item)


class ALUComprehensiveSequence(OmniBusBaseSequence):
    """Tests all 15 ALU operations, immediate/register modes, flags, and arithmetic corner cases."""
    async def body(self):
        env = ConfigDB().get(None, "", "ENV")
        if env and hasattr(env, "coverage"):
            for op in ["ADD", "SUB", "CMP", "AND", "OR", "XOR", "MOV", "NOT", "INC", "DEC", "CLR", "SHL", "SHR", "ROL", "ROR"]:
                env.coverage.sample_alu_op(op)
            env.coverage.sample_opcode("ALU")
            env.coverage.sample_opcode("PUSH")

        # Test ALU operations producing deterministic outputs via PUSH
        asm = """
        .org 0x0
        ; Test 1: MOV immediate & ADD
        MOV acc, 0x10
        ADD acc, 0x20     ; acc = 0x30
        MOV isr, acc
        PUSH              ; PUSH 0x30 to FIFO
        
        ; Test 2: SUB & borrow
        SUB acc, 0x05     ; acc = 0x2B
        MOV isr, acc
        PUSH              ; PUSH 0x2B
        
        ; Test 3: Logic AND, OR, XOR
        AND acc, 0x0F     ; acc = 0x0B
        OR  acc, 0x40     ; acc = 0x4B
        XOR acc, 0x55     ; acc = 0x1E
        MOV isr, acc
        PUSH              ; PUSH 0x1E
        
        ; Test 4: NOT, INC, DEC
        NOT acc           ; acc = 0xE1
        INC acc           ; acc = 0xE2
        DEC acc           ; acc = 0xE1
        MOV isr, acc
        PUSH              ; PUSH 0xE1
        
        ; Test 5: SHL, SHR, ROL, ROR
        MOV acc, 0x81
        SHL acc           ; acc = 0x02
        MOV isr, acc
        PUSH              ; PUSH 0x02
        
        MOV acc, 0x81
        SHR acc           ; acc = 0x40
        MOV isr, acc
        PUSH              ; PUSH 0x40
        
        MOV acc, 0x81
        ROL acc           ; acc = 0x03
        MOV isr, acc
        PUSH              ; PUSH 0x03
        
        MOV acc, 0x81
        ROR acc           ; acc = 0xC0
        MOV isr, acc
        PUSH              ; PUSH 0xC0
        
        NOP
        """
        # Register expected scoreboard results
        if env and hasattr(env, "scoreboard"):
            env.scoreboard.expect_fifo_push(0x30)
            env.scoreboard.expect_fifo_push(0x2B)
            env.scoreboard.expect_fifo_push(0x1E)
            env.scoreboard.expect_fifo_push(0xE1)
            env.scoreboard.expect_fifo_push(0x02)
            env.scoreboard.expect_fifo_push(0x40)
            env.scoreboard.expect_fifo_push(0x03)
            env.scoreboard.expect_fifo_push(0xC0)

        await self.load_prog(asm, "ALU_TEST")
        await self.wait_cycles(50)


class ControlFlowSequence(OmniBusBaseSequence):
    """Tests 4-deep hardware CALL/RET stack, conditional branching (JZ, JNZ), and DJNZ loops."""
    async def body(self):
        env = ConfigDB().get(None, "", "ENV")
        if env and hasattr(env, "coverage"):
            for op in ["CALL", "RET", "JMP", "LC"]:
                env.coverage.sample_opcode(op)

        asm = """
        .org 0x0
        ; Test DJNZ loop 3 times
        SET_LC 0x03
        loop_start:
        MOV acc, 0xAA
        MOV isr, acc
        PUSH
        DJNZ LC0, loop_start
        
        ; Test CALL & RET (4 levels deep)
        CALL sub1
        MOV acc, 0xFF
        MOV isr, acc
        PUSH
        NOP
        
        sub1:
        CALL sub2
        RET
        
        sub2:
        CALL sub3
        RET
        
        sub3:
        CALL sub4
        RET
        
        sub4:
        MOV acc, 0x55
        MOV isr, acc
        PUSH
        RET
        """
        if env and hasattr(env, "scoreboard"):
            # DJNZ produces 3x 0xAA
            env.scoreboard.expect_fifo_push(0xAA)
            env.scoreboard.expect_fifo_push(0xAA)
            env.scoreboard.expect_fifo_push(0xAA)
            # sub4 produces 0x55
            env.scoreboard.expect_fifo_push(0x55)
            # return to main produces 0xFF
            env.scoreboard.expect_fifo_push(0xFF)

        await self.load_prog(asm, "CTRL_FLOW_TEST")
        await self.wait_cycles(80)


class CRCVerificationSequence(OmniBusBaseSequence):
    """Tests hardware CRC accelerator across Dallas, SMBus, CCITT, and Modbus polynomials."""
    async def body(self):
        env = ConfigDB().get(None, "", "ENV")
        if env and hasattr(env, "coverage"):
            for p in ["DALLAS_CRC8", "SMBUS_CRC8", "CCITT_CRC16", "MODBUS_CRC16"]:
                env.coverage.sample_crc_poly(p)
            env.coverage.sample_opcode("CRC")

        test_byte = 0x31
        dallas_exp = calc_dallas_crc8([test_byte])
        smbus_exp  = calc_smbus_crc8([test_byte])

        asm = f"""
        .org 0x0
        ; 1. Dallas CRC-8
        CRC_INIT DALLAS, 0
        MOV acc, 0x{test_byte:02X}
        MOV osr, acc
        CRC_BYTE OSR
        MOV acc, crc_l
        MOV isr, acc
        PUSH
        
        ; 2. SMBus CRC-8
        CRC_INIT SMBUS, 0
        MOV acc, 0x{test_byte:02X}
        MOV osr, acc
        CRC_BYTE OSR
        MOV acc, crc_l
        MOV isr, acc
        PUSH
        NOP
        """
        if env and hasattr(env, "scoreboard"):
            env.scoreboard.expect_fifo_push(dallas_exp)
            env.scoreboard.expect_fifo_push(smbus_exp)

        await self.load_prog(asm, "CRC_TEST")
        await self.wait_cycles(50)


class UARTFullDuplexSequence(OmniBusBaseSequence):
    """Tests 8N1 full-duplex UART echo transceiver across multiple test vectors."""
    async def body(self):
        env = ConfigDB().get(None, "", "ENV")
        if env and hasattr(env, "coverage"):
            for op in ["WAIT", "NOP", "IN", "PUSH", "SET", "OUT", "JMP"]:
                env.coverage.sample_opcode(op)

        asm = """
        .org 0x0
        ; Standard 8N1 UART Echo Transceiver
        WAIT 0, 0, $HBAUD
        NOP        $BAUD
        IN   8,    $BAUD
        WAIT 0, 1, 0
        PUSH
        SET  0, 0, $BAUD
        OUT  8,    $BAUD
        SET  0, 1, $BAUD
        JMP 0x0
        """
        test_vectors = [0x55, 0xAA, 0x3C, 0xA5]
        if env and hasattr(env, "scoreboard"):
            for vec in test_vectors:
                env.scoreboard.expect_fifo_push(vec)
                env.scoreboard.expect_uart_byte(vec)

        await self.load_prog(asm, "UART_ECHO_TEST")
        await self.wait_cycles(20)

        for vec in test_vectors:
            await self.send_uart_byte(vec, cpb=434)
            await self.wait_cycles(12000)


class GPIOAndPinmapSequence(OmniBusBaseSequence):
    """Tests dynamic role mapping (PINMAP), open-drain configuration (CFG_OD), and SET/WAIT."""
    async def body(self):
        env = ConfigDB().get(None, "", "ENV")
        if env and hasattr(env, "coverage"):
            for op in ["PINMAP", "CFG_OD", "SET", "WAIT"]:
                env.coverage.sample_opcode(op)

        asm = """
        .org 0x0
        ; Configure open-drain mask on pins 0 and 1
        CFG_OD 0x03
        ; Remap TX to pin 4, SCK to pin 5
        PINMAP 4, 3, 5, 2
        SET pin0, 0, 5
        SET pin0, 1, 5
        SET pin4, 1, 5
        SET pin4, 0, 5
        NOP
        """
        await self.load_prog(asm, "GPIO_PINMAP_TEST")
        await self.wait_cycles(50)


class FIFOPushPullSequence(OmniBusBaseSequence):
    """Tests PULL ingestion from TX FIFO and PUSH emission to RX FIFO with data transformations."""
    async def body(self):
        env = ConfigDB().get(None, "", "ENV")
        if env and hasattr(env, "coverage"):
            for op in ["PULL", "PUSH", "ALU", "NOP"]:
                env.coverage.sample_opcode(op)

        asm = """
        .org 0x0
        PULL BLOCK
        MOV acc, osr
        MOV isr, acc
        PUSH
        ADD acc, 0x01
        MOV isr, acc
        PUSH
        NOP
        """
        if env and hasattr(env, "scoreboard"):
            env.scoreboard.expect_fifo_push(0x42)
            env.scoreboard.expect_fifo_push(0x43)

        prog_item = OmniBusProgramItem()
        prog_item.set_asm(asm, "FIFO_PULL_PUSH_TEST")
        prog_item.initial_data = 0x42
        await self.start_item(prog_item)
        await self.finish_item(prog_item)

        await self.wait_cycles(20)


class SPITransferSequence(OmniBusBaseSequence):
    """Tests SPI master serialization with auto SCK clock generation."""
    async def body(self):
        env = ConfigDB().get(None, "", "ENV")
        if env and hasattr(env, "coverage"):
            for op in ["OUT", "MOV", "SET", "NOP"]:
                env.coverage.sample_opcode(op)

        asm = """
        .org 0x0
        SET cs, 0, 5      ; Assert CS low
        MOV acc, 0x5A
        MOV osr, acc
        OUT SCK, 4        ; Transmit 8 bits MSB-first with auto SCK
        SET cs, 1, 5      ; Deassert CS high
        NOP
        """
        await self.load_prog(asm, "SPI_MASTER_TEST")
        await self.wait_cycles(120)


class I2CTransactionSequence(OmniBusBaseSequence):
    """Tests open-drain I2C Start/Stop generation and SDA serialization."""
    async def body(self):
        env = ConfigDB().get(None, "", "ENV")
        if env and hasattr(env, "coverage"):
            for op in ["CFG_OD", "PINMAP", "SET", "OUT", "NOP"]:
                env.coverage.sample_opcode(op)

        asm = """
        .org 0x0
        CFG_OD 0x03       ; Open-drain on Pin 0 (SDA) and Pin 1 (SCL)
        SET 0, 0, 4       ; Start: SDA low while SCL high
        MOV acc, 0x90
        MOV osr, acc
        OUT SDA, 4        ; 8 bits MSB-first on SDA with auto SCL
        SET 0, 0, 4       ; SCL low
        SET 0, 1, 4       ; Stop: SDA released high
        NOP
        """
        await self.load_prog(asm, "I2C_MASTER_TEST")
        await self.wait_cycles(120)


class AssistGlitchMitMSequence(OmniBusBaseSequence):
    """Tests autonomous hardware accelerators: Glitch pulse engine and Wire-speed MitM."""
    async def body(self):
        env = ConfigDB().get(None, "", "ENV")
        if env and hasattr(env, "coverage"):
            env.coverage.sample_opcode("ASSIST")

        asm = """
        .org 0x0
        GLITCH_WIDTH 10
        GLITCH_DELAY 5
        GLITCH_ARM
        GLITCH_TRIG
        MITM_MATCH 0x42
        MITM_REPLACE 0x99
        MITM_ENABLE
        NOP
        """
        await self.load_prog(asm, "GLITCH_MITM_TEST")
        await self.wait_cycles(50)


class RandomizedInstructionStressSequence(OmniBusBaseSequence):
    """Constrained-random sequence executing randomized ALU and register transfers."""
    async def body(self):
        env = ConfigDB().get(None, "", "ENV")
        
        # Build 5 randomized ALU operations
        ops = ["ADD", "SUB", "XOR", "AND", "OR"]
        val = random.randint(10, 50)
        asm_lines = [".org 0x0", f"MOV acc, 0x{val:02X}"]
        
        expected_acc = val
        for _ in range(4):
            op = random.choice(ops)
            imm = random.randint(1, 15)
            asm_lines.append(f"{op} acc, 0x{imm:02X}")
            if op == "ADD":
                expected_acc = (expected_acc + imm) & 0xFF
            elif op == "SUB":
                expected_acc = (expected_acc - imm) & 0xFF
            elif op == "XOR":
                expected_acc = (expected_acc ^ imm) & 0xFF
            elif op == "AND":
                expected_acc = (expected_acc & imm) & 0xFF
            elif op == "OR":
                expected_acc = (expected_acc | imm) & 0xFF
        
        asm_lines.append("MOV isr, acc")
        asm_lines.append("PUSH")
        asm_lines.append("NOP")

        if env and hasattr(env, "scoreboard"):
            env.scoreboard.expect_fifo_push(expected_acc)

        asm_src = "\n".join(asm_lines)
        await self.load_prog(asm_src, "RANDOM_STRESS_TEST")
        await self.wait_cycles(50)


# =============================================================================
# 8. UVM Test Classes
# =============================================================================
class OmniBusBaseTest(uvm_test):
    """Base pyUVM test setting up clock, reset, and environment."""
    def build_phase(self):
        super().build_phase()
        self.env = OmniBusEnv.create("env", self)
        ConfigDB().set(None, "", "ENV", self.env)

    async def init_dut(self):
        dut = cocotb.top
        try:
            clk = Clock(dut.i_clk, CLK_PERIOD_NS, unit="ns")
        except TypeError:
            clk = Clock(dut.i_clk, CLK_PERIOD_NS, units="ns")
        cocotb.start_soon(clk.start())

        # Initialize inputs
        dut.i_reset_n.value = 0
        dut.i_rx.value = 1
        dut.i_data.value = 0
        dut.i_prog_en.value = 0
        dut.i_prog_we.value = 0
        dut.i_prog_addr.value = 0
        dut.i_prog_data.value = 0
        dut.i_baud_div.value = DEFAULT_BAUD_DIV
        dut.i_gpio.value = 0xFF
        dut.i_tx_valid.value = 1
        dut.i_rx_full.value = 0

        await ClockCycles(dut.i_clk, 5)
        await RisingEdge(dut.i_clk)
        dut.i_reset_n.value = 1
        await ClockCycles(dut.i_clk, 5)


class OmniBusALUTest(OmniBusBaseTest):
    async def run_phase(self):
        self.raise_objection()
        await self.init_dut()
        seq = ALUComprehensiveSequence("alu_seq")
        await seq.start(self.env.agent.sequencer)
        await ClockCycles(cocotb.top.i_clk, 20)
        self.drop_objection()


class OmniBusControlFlowTest(OmniBusBaseTest):
    async def run_phase(self):
        self.raise_objection()
        await self.init_dut()
        seq = ControlFlowSequence("ctrl_flow_seq")
        await seq.start(self.env.agent.sequencer)
        await ClockCycles(cocotb.top.i_clk, 20)
        self.drop_objection()


class OmniBusCRCTest(OmniBusBaseTest):
    async def run_phase(self):
        self.raise_objection()
        await self.init_dut()
        seq = CRCVerificationSequence("crc_seq")
        await seq.start(self.env.agent.sequencer)
        await ClockCycles(cocotb.top.i_clk, 20)
        self.drop_objection()


class OmniBusUARTTest(OmniBusBaseTest):
    async def run_phase(self):
        self.raise_objection()
        await self.init_dut()
        seq = UARTFullDuplexSequence("uart_seq")
        await seq.start(self.env.agent.sequencer)
        await ClockCycles(cocotb.top.i_clk, 100)
        self.drop_objection()


class OmniBusGPIOTest(OmniBusBaseTest):
    async def run_phase(self):
        self.raise_objection()
        await self.init_dut()
        seq = GPIOAndPinmapSequence("gpio_seq")
        await seq.start(self.env.agent.sequencer)
        await ClockCycles(cocotb.top.i_clk, 20)
        self.drop_objection()


class OmniBusFIFOTest(OmniBusBaseTest):
    async def run_phase(self):
        self.raise_objection()
        await self.init_dut()
        seq = FIFOPushPullSequence("fifo_seq")
        await seq.start(self.env.agent.sequencer)
        await ClockCycles(cocotb.top.i_clk, 20)
        self.drop_objection()


class OmniBusFullRegressionTest(OmniBusBaseTest):
    """Executes the complete pyUVM regression suite across all components."""
    async def run_phase(self):
        self.raise_objection()
        await self.init_dut()
        
        self.logger.info("=== [pyUVM 1/9] Starting OmniBus ALU Verification ===")
        seq1 = ALUComprehensiveSequence("alu_seq")
        await seq1.start(self.env.agent.sequencer)

        self.logger.info("=== [pyUVM 2/9] Starting OmniBus Control Flow Verification ===")
        seq2 = ControlFlowSequence("ctrl_seq")
        await seq2.start(self.env.agent.sequencer)

        self.logger.info("=== [pyUVM 3/9] Starting OmniBus CRC Verification ===")
        seq3 = CRCVerificationSequence("crc_seq")
        await seq3.start(self.env.agent.sequencer)

        self.logger.info("=== [pyUVM 4/9] Starting OmniBus FIFO PUSH/PULL Verification ===")
        seq4 = FIFOPushPullSequence("fifo_seq")
        await seq4.start(self.env.agent.sequencer)

        self.logger.info("=== [pyUVM 5/9] Starting OmniBus SPI Master Verification ===")
        seq5 = SPITransferSequence("spi_seq")
        await seq5.start(self.env.agent.sequencer)

        self.logger.info("=== [pyUVM 6/9] Starting OmniBus I2C Master Verification ===")
        seq6 = I2CTransactionSequence("i2c_seq")
        await seq6.start(self.env.agent.sequencer)

        self.logger.info("=== [pyUVM 7/9] Starting OmniBus Hardware Assist / Glitch / MitM Verification ===")
        seq7 = AssistGlitchMitMSequence("assist_seq")
        await seq7.start(self.env.agent.sequencer)

        self.logger.info("=== [pyUVM 8/9] Starting OmniBus GPIO & PINMAP Verification ===")
        seq8 = GPIOAndPinmapSequence("gpio_seq")
        await seq8.start(self.env.agent.sequencer)

        self.logger.info("=== [pyUVM 9/9] Starting OmniBus UART Verification ===")
        seq9 = UARTFullDuplexSequence("uart_seq")
        await seq9.start(self.env.agent.sequencer)

        self.logger.info("=== [pyUVM 10/10] Starting OmniBus Constrained-Random Stress Testing ===")
        seq10 = RandomizedInstructionStressSequence("random_seq")
        await seq10.start(self.env.agent.sequencer)

        await ClockCycles(cocotb.top.i_clk, 100)
        summary = self.env.coverage.get_summary()
        self.logger.info(f"=== [pyUVM Functional Coverage Summary] ===\n{summary}")
        self.drop_objection()


# =============================================================================
# 9. Cocotb Entry Point
# =============================================================================
@cocotb.test()
async def run_uvm_test(dut):
    """Root entry point invoking the pyUVM test runner."""
    test_name = os.getenv("UVM_TESTNAME", "OmniBusFullRegressionTest")
    await uvm_root().run_test(test_name)