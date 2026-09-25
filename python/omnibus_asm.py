#!/usr/bin/env python3
# =============================================================================
# File        : omnibus_asm.py
# Description : OmniBus Microcode Assembler
#               Assembles human-readable microcode into 16-bit binary/hex words
#               for runtime execution on the OmniBus Protocol Emulator.
#               Task 06: $BAUD/9'h1FF, $HBAUD/9'h1FE runtime baud sentinels.
#               Task 07: SET/WAIT 3-arg form with pin selector [11:10];
#                        IN variable bit count [11:9] (0->8bits compat, 1-7->N);
#                        pin aliases: MOSI=TX=0, SCK=1, CS=CS_N=2, MISO=RX=0.
# License     : MIT License
# =============================================================================

import sys
import os
import re
import argparse

OPCODES = {
    "NOP":    0x0,
    "OUT":    0x1,
    "IN":     0x2,
    "SET":    0x3,
    "WAIT":   0x4,
    "PINMAP":  0x5,  # Dynamic role mapping: tx, rx, sck, cs (3 bits each)
    "CFG_OD":  0x6,  # Open-drain mask: mask[7:0]
    "DJNZ":    0x7,  # Decrement loop counter and jump if not zero
    "LOOP":    0x7,  # Alias for DJNZ LC0, target
    "SET_LC":  0x7,  # Load immediate into loop counter
    "PULL_LC": 0x7,  # Load loop counter from i_data
    "PUSH_LC": 0x7,  # Transfer loop counter to o_data & osr
    "MOV_LC":  0x7,  # Load loop counter from osr
    "JMP":     0x8,
    "PULL":   0x9,
    "PUSH":   0xA,
    "ALU":    0xB,  # 8-bit Micro-ALU & Arithmetic Engine
    "ADD":    0xB,
    "SUB":    0xB,
    "CMP":    0xB,
    "AND":    0xB,
    "OR":     0xB,
    "XOR":    0xB,
    "MOV":    0xB,
    "NOT":    0xB,
    "INV":    0xB,
    "INC":    0xB,
    "DEC":    0xB,
    "CLR":    0xB,
    "SHL":    0xB,
    "SHR":    0xB,
    "ROL":    0xB,
    "ROR":    0xB,
    "BANK":     0xB,  # Switch active execution bank (0..3)
    "SET_BANK": 0xB,
    "JMP_BANK": 0xB,  # Switch bank and jump to bank start (offset 0)
    "CALL":   0xC,  # Push pc+1 to call stack, jump to target
    "RET":    0xD,  # Pop return address from call stack
    "CRC":           0xE,  # Hardware CRC Generator & Checksum Accelerator
    "CRC_INIT":      0xE,
    "CRC_BYTE":      0xE,
    "CRC_READ_LOW":  0xE,
    "CRC_READ_L":    0xE,
    "CRC_READ_HIGH": 0xE,
    "CRC_READ_H":    0xE,
    "CRC_READ_B0":   0xE,
    "CRC_READ_B1":   0xE,
    "CRC_READ_B2":   0xE,
    "CRC_READ_B3":   0xE,
    "CRC_RESET":     0xE,
    "ASSIST":        0xF,  # Autonomous Stream Accelerators (NRZI & Bit-Stuffing)
    "ASSIST_CFG":    0xF,
    "ASSIST_RESET":  0xF,
    "ASSIST_READ":   0xF,
    "PULSE_CFG":     0xF,  # Task 18: Asymmetric Single-Wire Pulse Accelerator
    "GAMEPAD_CFG":   0xF,  # Task 18: Retro NES/SNES Gamepad Controller Bus
    "PULSE_TIME0":   0xF,
    "PULSE_TIME1":   0xF,
    "I2C_SLAVE_CFG":     0xF,  # Task 21: Dedicated Hardware I2C Slave Engine
    "I2C_RELEASE_SCL":   0xF,
    "I2C_SLAVE_DISABLE": 0xF,
    "AUDIO_CFG":         0xF,  # Task 22: 1-Bit Delta-Sigma Audio DAC & Chiptune Synthesizer
    "AUDIO_VOL":         0xF,
    "AUDIO_SAMPLE":      0xF,
    "AUDIO_DUTY":        0xF,
    "AUDIO_NOTE_LO":     0xF,
    "AUDIO_NOTE_HI":     0xF,
    "AUDIO_PLAY":        0xF,
    "AUDIO_STOP":        0xF,
    "JTAG_CFG":          0xF,  # Task 23: Dedicated JTAG & SWD Sequencer
    "JTAG_TMS":          0xF,
    "JTAG_NAV":          0xF,
    "JTAG_SHIFT":        0xF,
    "SWD_CFG":           0xF,
    "SWD_REQ":           0xF,
    "SWD_RESET":         0xF,
    "SWD_RD32":          0xF,
    "SWD_WR32":          0xF,
    "SWD_LOAD":          0xF,
    "QSPI_CFG":          0xF,  # Task 24: Dedicated QSPI & Multi-Lane Host Controller
    "QSPI_CS":           0xF,
    "QSPI_CMD":          0xF,
    "QSPI_DUMMY":        0xF,
    "QSPI_ADDR":         0xF,
    "QSPI_LOAD_ADDR":    0xF,
    "QSPI_LOAD":         0xF,
    "GLITCH_CFG":        0xF,  # Task 25: Hardware Glitch & MitM Fuzzing Engine
    "GLITCH_WIDTH":      0xF,
    "GLITCH_DELAY":      0xF,
    "GLITCH_DELAY_LO":   0xF,
    "GLITCH_DELAY_HI":   0xF,
    "GLITCH_ARM":        0xF,
    "GLITCH_TRIG":       0xF,
    "GLITCH_TRIGGER":    0xF,
    "GLITCH_DISARM":     0xF,
    "MITM_CFG":          0xF,
    "MITM_MATCH":        0xF,
    "MITM_REPLACE":      0xF,
    "MITM_MASK":         0xF,
    "MITM_ENABLE":       0xF,
    "MITM_DISABLE":      0xF,
    "MITM_RESET":        0xF,
    "MITM_CLR":          0xF,
    "PROFILER_CFG":      0xF,
    "PROFILER_FILTER":   0xF,
    "PROFILER_ARM":      0xF,
    "PROFILER_STOP":     0xF,
    "PROFILER_RST":      0xF,
    "PROFILER_RESET":    0xF,
    "USB_CFG":           0xF,
    "USB_CONFIG":        0xF,
    "USB_TX_TOKEN":      0xF,
    "USB_TOKEN":         0xF,
    "USB_TX_DATA":       0xF,
    "USB_DATA_PKT":      0xF,
    "USB_SEND_ACK":      0xF,
    "USB_ACK":           0xF,
    "USB_SEND_NAK":      0xF,
    "USB_NAK":           0xF,
    "USB_SEND_STALL":    0xF,
    "USB_STALL":         0xF,
    "USB_SIE_EN":        0xF,
    "USB_SIE_DIS":       0xF,
    "BIST_CFG":          0xF,
    "BIST_CONFIG":       0xF,
    "BIST_DIS":          0xF,
    "BIST_DISABLE":      0xF,
    "BIST_LOOP":         0xF,
    "BIST_LOOPBACK":     0xF,
    "BIST_SPLIT":        0xF,
    "BIST_CROSSBAR":     0xF,
    "BIST_JITTER":       0xF,
    "BIST_STRESS":       0xF,
    "BIST_START":        0xF,
    "BIST_EN":           0xF,
    "BIST_STOP":         0xF,
    "BIST_RST":          0xF,
    "BIST_RESET":        0xF,
    "BIST_PASS":         0xF,
    "BIST_FAIL":         0xF,
    "BIST_STAGE":        0xF,
}

# 8-bit GPIO Pin Aliases for SET/WAIT/PINMAP [11:9]
PIN_NAMES = {
    "MOSI": 0, "TX": 0, "PIN0": 0, "P0": 0,
    "SCK":  1, "SCL": 1, "PIN1": 1, "P1": 1,
    "CS":   2, "CS_N": 2, "CSN": 2, "PIN2": 2, "P2": 2,
    "MISO": 3, "RX": 3, "PIN3": 3, "P3": 3,
    "SDA":  4, "PIN4": 4, "P4": 4,
    "PIN5": 5, "P5": 5,
    "PIN6": 6, "P6": 6,
    "PIN7": 7, "P7": 7,
}

class AssemblerError(Exception):
    pass

class OmnibusAssembler:
    def __init__(self, clk_freq=50_000_000, default_baud=115_200):
        self.clk_freq = clk_freq
        self.baud = default_baud
        self.update_baud_constants()

    def update_baud_constants(self):
        # 1 execution cycle + delay cycles = total cycles per bit
        cycles_per_bit = round(self.clk_freq / self.baud)
        self.bit_delay = max(0, cycles_per_bit - 1)
        self.half_bit_delay = max(0, round(cycles_per_bit / 2) - 1)

    def assemble(self, source_text):
        """Assembles assembly source text into a list of (address, 16-bit word, source_line)."""
        lines = source_text.splitlines()
        labels = {}
        # Baud-rate aware symbols (computed from clock/baud parameters)
        symbols = {
            "BIT_DELAY":  self.bit_delay,
            "HALF_DELAY": self.half_bit_delay,
            # Magic sentinel tokens: substitute i_baud_div at runtime
            "$BAUD":  0x1FF,  # 9'h1FF = use i_baud_div[8:0]   (full bit period)
            "$HBAUD": 0x1FE,  # 9'h1FE = use i_baud_div[8:0]>>1 (half bit period)
        }

        # ---------------------------------------------------------------------
        # Pass 1: Parse directives, collect labels and instructions
        # ---------------------------------------------------------------------
        parsed_instructions = []
        current_addr = 0

        for line_num, raw_line in enumerate(lines, start=1):
            # Strip comments (; or #)
            line = re.sub(r"[;#].*$", "", raw_line).strip()
            if not line:
                continue

            # Check for directives: .clock, .baud, .equ
            if line.startswith("."):
                parts = line.split()
                directive = parts[0].lower()
                if directive == ".clock" and len(parts) >= 2:
                    self.clk_freq = int(parts[1])
                    self.update_baud_constants()
                    symbols["BIT_DELAY"] = self.bit_delay
                    symbols["HALF_DELAY"] = self.half_bit_delay
                elif directive == ".baud" and len(parts) >= 2:
                    self.baud = int(parts[1])
                    self.update_baud_constants()
                    symbols["BIT_DELAY"] = self.bit_delay
                    symbols["HALF_DELAY"] = self.half_bit_delay
                elif directive == ".equ" and len(parts) >= 3:
                    symbols[parts[1]] = int(parts[2], 0)
                elif directive == ".bank" and len(parts) >= 2:
                    bank_num = int(parts[1], 0)
                    if bank_num < 0 or bank_num > 3:
                        raise AssemblerError(f"Line {line_num}: Invalid bank number {bank_num} (must be 0..3)")
                    current_addr = bank_num * 32
                elif directive == ".org" and len(parts) >= 2:
                    current_addr = int(parts[1], 0)
                continue

            # Check for labels: "label:"
            while ":" in line:
                label_part, rest = line.split(":", 1)
                label_name = label_part.strip()
                if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", label_name):
                    raise AssemblerError(f"Line {line_num}: Invalid label name '{label_name}'")
                if label_name in labels:
                    raise AssemblerError(f"Line {line_num}: Duplicate label '{label_name}'")
                labels[label_name] = current_addr
                line = rest.strip()
                if not line:
                    break

            if not line:
                continue

            # Check for origin directive: "@04"
            if line.startswith("@"):
                current_addr = int(line[1:], 0)
                continue

            # Macro expansion for multi-word Task 25 commands
            macro_tokens = re.split(r"[,\s]+", line.strip())
            macro_op = macro_tokens[0].upper()
            if macro_op == "MITM_CFG" and len(macro_tokens) >= 3:
                m_match = macro_tokens[1]
                m_repl = macro_tokens[2]
                m_mask = macro_tokens[3] if len(macro_tokens) >= 4 else "0xFF"
                macro_lines = [
                    f"MOV acc, {m_match}",
                    "MITM_MATCH",
                    f"MOV acc, {m_repl}",
                    "MITM_REPLACE",
                    f"MOV acc, {m_mask}",
                    "MITM_MASK",
                    "MITM_ENABLE"
                ]
                for ml in macro_lines:
                    parsed_instructions.append((line_num, current_addr, ml))
                    current_addr += 1
                continue
            elif macro_op == "GLITCH_CFG" and len(macro_tokens) >= 4:
                g_pin = macro_tokens[1]
                g_pol = macro_tokens[2]
                g_w = macro_tokens[3]
                parsed_instructions.append((line_num, current_addr, f"GLITCH_CFG {g_pin}, {g_pol}"))
                current_addr += 1
                parsed_instructions.append((line_num, current_addr, f"MOV acc, {g_w}"))
                current_addr += 1
                parsed_instructions.append((line_num, current_addr, "GLITCH_WIDTH 0"))
                current_addr += 1
                continue
            elif macro_op == "PROFILER_CFG" and len(macro_tokens) >= 3:
                p_pin = macro_tokens[1]
                p_flt = macro_tokens[2]
                parsed_instructions.append((line_num, current_addr, f"MOV acc, {p_flt}"))
                current_addr += 1
                parsed_instructions.append((line_num, current_addr, f"PROFILER_CFG {p_pin}"))
                current_addr += 1
                continue

            parsed_instructions.append((line_num, current_addr, line))
            current_addr += 1
            if current_addr > 128:
                raise AssemblerError(f"Program exceeds 128 words of IMEM at line {line_num}")

        # ---------------------------------------------------------------------
        # Pass 2: Assemble machine code words
        # ---------------------------------------------------------------------
        assembled = []

        for line_num, addr, line in parsed_instructions:
            tokens = re.split(r"[,\s]+", line.strip())
            op = tokens[0].upper()

            if op not in OPCODES:
                raise AssemblerError(f"Line {line_num}: Unknown opcode '{op}' in: '{line}'")

            opcode_val = OPCODES[op]
            word = 0

            def eval_arg(arg_str):
                arg_clean = arg_str.strip()
                if arg_clean in labels:
                    return labels[arg_clean]
                if arg_clean in symbols:
                    return symbols[arg_clean]
                try:
                    return int(arg_clean, 0)
                except ValueError:
                    raise AssemblerError(f"Line {line_num}: Undefined identifier or invalid number '{arg_str}'")

            if op == "NOP":
                # NOP [delay]
                delay = eval_arg(tokens[1]) if len(tokens) > 1 else 0
                word = (opcode_val << 12) | (delay & 0x1FF)

            elif op in ("OUT", "IN"):
                # OUT/IN [bits,] delay (bits is 8 by default)
                # Task 07: IN bit count encoded in [11:9]
                #   0 -> 8 bits (backward compat, old programs encode 0)
                #   1..7 -> N bits (new variable-bit form)
                if op == "IN":
                    # Forms:
                    #   IN delay            (mode=0, 8-bit default LSB-first UART, backward compat)
                    #   IN N, delay         (mode=0, variable N-bit LSB-first UART, N=8 -> 0)
                    #   IN SCK, delay       (mode=1, 8-bit MSB-first SPI Master Read + auto-SCK toggle)
                    #   IN 1W, delay        (mode=2, 8-bit LSB-first 1-Wire Master Read)
                    #   IN 1W, 1, delay     (mode=2, 1-bit 1-Wire Master Read for Search ROM)
                    #   IN 1W, 8, delay     (mode=2, 8-bit 1-Wire Master Read)
                    #   IN SDA, delay       (mode=3, 8-bit MSB-first I2C Master Read + auto-SCL toggle)
                    def _in_mode(s):
                        s = s.strip().upper()
                        if s in ("SCK", "SCLK", "CLK", "SPI"):
                            return 1
                        elif s in ("1W", "OW", "DQ", "ONEWIRE"):
                            return 2
                        elif s in ("SDA", "SCL", "I2C"):
                            return 3
                        return 0

                    if len(tokens) >= 2 and tokens[1].strip().upper() in ("QSPI", "OCTAL", "QUAD", "DUAL"):
                        word = (opcode_val << 12) | (0x1E << 7)
                    elif len(tokens) >= 2 and tokens[1].strip().upper() in ("AUDIO", "DAC", "PDM"):
                        word = (opcode_val << 12) | (0x1F << 7)
                    elif len(tokens) >= 2 and tokens[1].strip().upper() in ("SLAVE", "I2C_SLAVE"):
                        # IN SLAVE [, NACK] [, delay]
                        # [11:9] = 3'b111 (7)
                        # [8] = NACK (1 if NACK, 0 if ACK)
                        # [7:0] = delay
                        nack = 1 if (len(tokens) >= 3 and tokens[2].strip().upper() in ("NACK", "1")) else 0
                        delay = 0
                        if len(tokens) >= 4:
                            delay = eval_arg(tokens[3]) & 0xFF
                        elif len(tokens) >= 3 and tokens[2].strip().upper() not in ("NACK", "ACK", "0", "1"):
                            delay = eval_arg(tokens[2]) & 0xFF
                        word = (opcode_val << 12) | (7 << 9) | (nack << 8) | (delay & 0xFF)
                    elif len(tokens) >= 4 and _in_mode(tokens[1]) == 2:
                        # IN 1W, bit_count, delay
                        mode = 2
                        bit_flag = 1 if eval_arg(tokens[2]) == 1 else 0
                        delay = eval_arg(tokens[3]) & 0x1FF
                        word = (opcode_val << 12) | (mode << 10) | (bit_flag << 9) | delay
                    elif len(tokens) >= 3 and _in_mode(tokens[1]) != 0:
                        mode = _in_mode(tokens[1])
                        delay = eval_arg(tokens[2]) & 0x1FF
                        word = (opcode_val << 12) | (mode << 10) | delay
                    elif len(tokens) == 2:
                        # IN delay — 8-bit default (bit_count=0, mode=0)
                        bit_count = 0
                        delay = eval_arg(tokens[1]) & 0x1FF
                        word = (opcode_val << 12) | (bit_count << 9) | delay
                    elif len(tokens) >= 3:
                        # IN N, delay
                        n = eval_arg(tokens[1])
                        bit_count = 0 if n == 8 else (n & 0x7)  # 8->0 (compat), 1-7->N
                        delay = eval_arg(tokens[2]) & 0x1FF
                        word = (opcode_val << 12) | (bit_count << 9) | delay
                    else:
                        word = (opcode_val << 12)
                else:  # OUT
                    # Forms:
                    #   OUT delay           (mode=0, 8-bit LSB-first UART, backward compat)
                    #   OUT 8, delay        (same)
                    #   OUT SCK, delay      (mode=1, 8-bit MSB-first SPI + auto-SCK toggle)
                    #   OUT 1W, delay       (mode=2, 8-bit LSB-first 1-Wire Write)
                    #   OUT 1W, 1, delay    (mode=2, 1-bit 1-Wire Write for Search ROM)
                    #   OUT 1W, 8, delay    (mode=2, 8-bit 1-Wire Write)
                    #   OUT SDA, delay      (mode=3, 8-bit MSB-first I2C + auto-SCL toggle)
                    #   OUT AUDIO           (5'b11111 << 7, Hardware Audio DAC sample load)
                    #   OUT SLAVE, delay    (mode=7, Hardware I2C Slave Transmit)
                    def _out_mode(s):
                        s = s.strip().upper()
                        if s in ("SCK", "SCLK", "CLK"):
                            return 1
                        elif s in ("1W", "OW", "DQ", "ONEWIRE"):
                            return 2
                        elif s in ("SDA", "SCL", "I2C"):
                            return 3
                        return 0

                    if len(tokens) >= 2 and tokens[1].strip().upper() in ("QSPI", "OCTAL", "QUAD", "DUAL"):
                        word = (opcode_val << 12) | (0x1E << 7)
                    elif len(tokens) >= 2 and tokens[1].strip().upper() in ("AUDIO", "DAC", "PDM"):
                        word = (opcode_val << 12) | (0x1F << 7)
                    elif len(tokens) >= 2 and tokens[1].strip().upper() in ("SLAVE", "I2C_SLAVE"):
                        delay = eval_arg(tokens[2]) & 0x1FF if len(tokens) >= 3 else 0
                        word = (opcode_val << 12) | (7 << 9) | (delay & 0x1FF)
                    elif len(tokens) >= 4 and _out_mode(tokens[1]) == 2:
                        # OUT 1W, bit_count, delay
                        mode = 2
                        bit_flag = 1 if eval_arg(tokens[2]) == 1 else 0
                        delay = eval_arg(tokens[3]) & 0x1FF
                        word = (opcode_val << 12) | (mode << 10) | (bit_flag << 9) | delay
                    elif len(tokens) >= 3 and _out_mode(tokens[1]) != 0:
                        mode  = _out_mode(tokens[1])
                        delay = eval_arg(tokens[2]) & 0x1FF
                        word  = (opcode_val << 12) | (mode << 10) | (delay & 0x1FF)
                    elif len(tokens) == 2:
                        mode, delay = 0, eval_arg(tokens[1]) & 0x1FF
                        word = (opcode_val << 12) | (mode << 10) | (delay & 0x1FF)
                    elif len(tokens) >= 3:
                        mode, delay = 0, eval_arg(tokens[2]) & 0x1FF
                        word = (opcode_val << 12) | (mode << 10) | (delay & 0x1FF)
                    else:
                        word = (opcode_val << 12)

            elif op in ("SET", "WAIT"):
                # Forms:
                #   SET pin, val, delay    (3-arg explicit pin 0..7)
                #   SET pin, val           (2-arg explicit pin 0..7, delay=0)
                #   SET val, delay         (legacy 2-arg: pin=0, delay)
                def resolve_pin(s):
                    s = s.strip().upper()
                    if s in PIN_NAMES:
                        return PIN_NAMES[s]
                    try:
                        return int(s, 0) & 0x7
                    except ValueError:
                        raise AssemblerError(f"Line {line_num}: Unknown pin identifier '{s}'")

                def eval_delay_8(arg_str):
                    s = arg_str.strip()
                    if s in ("$BAUD", "BIT_DELAY"):
                        return 0xFF
                    if s in ("$HBAUD", "HALF_DELAY"):
                        return 0xFE
                    val = eval_arg(s)
                    if val == 0x1FF:
                        return 0xFF
                    if val == 0x1FE:
                        return 0xFE
                    return val & 0xFF

                if len(tokens) >= 4:
                    # 3-arg form: SET pin, val, delay
                    pin_id  = resolve_pin(tokens[1])
                    pin_val = eval_arg(tokens[2]) & 0x1
                    delay   = eval_delay_8(tokens[3])
                elif len(tokens) == 3:
                    tok1 = tokens[1].strip().upper()
                    if tok1 in PIN_NAMES or tok1.startswith("PIN") or tok1.startswith("P"):
                        # SET pin, val (delay=0)
                        pin_id  = resolve_pin(tok1)
                        pin_val = eval_arg(tokens[2]) & 0x1
                        delay   = 0
                    else:
                        # SET val, delay (legacy pin=0)
                        pin_id  = 0
                        pin_val = eval_arg(tokens[1]) & 0x1
                        delay   = eval_delay_8(tokens[2])
                else:
                    raise AssemblerError(f"Line {line_num}: {op} requires 'pin, val, delay', 'pin, val', or 'val, delay'")
                word = (opcode_val << 12) | ((pin_id & 0x7) << 9) | ((pin_val & 0x1) << 8) | (delay & 0xFF)

            elif op == "PINMAP":
                # PINMAP tx, rx, sck, cs
                # Form: PINMAP 0, 3, 1, 2  or  PINMAP TX=0, RX=3, SCK=1, CS=2
                if len(tokens) < 5:
                    raise AssemblerError(f"Line {line_num}: PINMAP requires 4 arguments: tx, rx, sck, cs")
                def parse_role_pin(arg_str):
                    clean = arg_str.strip()
                    if "=" in clean:
                        clean = clean.split("=")[1].strip()
                    if clean.upper() in PIN_NAMES:
                        return PIN_NAMES[clean.upper()]
                    return int(clean, 0) & 0x7

                tx  = parse_role_pin(tokens[1])
                rx  = parse_role_pin(tokens[2])
                sck = parse_role_pin(tokens[3])
                cs  = parse_role_pin(tokens[4])
                word = (opcode_val << 12) | (tx << 9) | (rx << 6) | (sck << 3) | cs

            elif op == "CFG_OD":
                # CFG_OD mask (8-bit open drain mask)
                if len(tokens) < 2:
                    raise AssemblerError(f"Line {line_num}: CFG_OD requires mask argument (e.g. CFG_OD 0x10)")
                mask = eval_arg(tokens[1]) & 0xFF
                word = (opcode_val << 12) | mask

            elif op in ("DJNZ", "LOOP"):
                # Forms:
                #   DJNZ LC0, target
                #   DJNZ LC1, target
                #   DJNZ target       (defaults to LC0)
                #   LOOP target       (alias for DJNZ LC0, target)
                def parse_lc(tok):
                    tok = tok.strip().upper()
                    if tok in ("LC1", "1", "1'B1"):
                        return 1
                    return 0

                if op == "LOOP":
                    lc_sel = 0
                    if len(tokens) < 2:
                        raise AssemblerError(f"Line {line_num}: LOOP requires target address or label")
                    target = eval_arg(tokens[1]) & 0x7F
                else:
                    if len(tokens) >= 3 and tokens[1].strip().upper() in ("LC0", "LC_0", "LC1", "LC_1"):
                        lc_sel = 0 if tokens[1].strip().upper() in ("LC0", "LC_0") else 1
                        target = eval_arg(tokens[2]) & 0x7F
                    elif len(tokens) == 2:
                        lc_sel = 0
                        target = eval_arg(tokens[1]) & 0x7F
                    else:
                        raise AssemblerError(f"Line {line_num}: DJNZ requires [LCx,] target")
                # Format: [15:12]=0x7, [11]=lc_sel, [10]=0, [6:0]=target
                word = (opcode_val << 12) | (lc_sel << 11) | (0 << 10) | target

            elif op == "SET_LC":
                # Forms:
                #   SET_LC LC0, count
                #   SET_LC LC1, count
                #   SET_LC count      (defaults to LC0)
                def parse_lc(tok):
                    tok = tok.strip().upper()
                    if tok in ("LC1", "1"):
                        return 1
                    return 0

                if len(tokens) >= 3:
                    lc_sel = parse_lc(tokens[1])
                    count = eval_arg(tokens[2]) & 0xFF
                elif len(tokens) == 2:
                    lc_sel = 0
                    count = eval_arg(tokens[1]) & 0xFF
                else:
                    raise AssemblerError(f"Line {line_num}: SET_LC requires [LCx,] count")
                # Format: [15:12]=0x7, [11]=lc_sel, [10]=1, [9:8]=00, [7:0]=count
                word = (opcode_val << 12) | (lc_sel << 11) | (1 << 10) | (0 << 8) | count

            elif op == "PULL_LC":
                # Forms:
                #   PULL_LC LCx
                #   PULL_LC           (defaults to LC0)
                lc_sel = 1 if (len(tokens) >= 2 and tokens[1].strip().upper() in ("LC1", "1")) else 0
                # Format: [15:12]=0x7, [11]=lc_sel, [10]=1, [9:8]=01
                word = (opcode_val << 12) | (lc_sel << 11) | (1 << 10) | (1 << 8)

            elif op == "PUSH_LC":
                # Forms:
                #   PUSH_LC LCx
                #   PUSH_LC           (defaults to LC0)
                lc_sel = 1 if (len(tokens) >= 2 and tokens[1].strip().upper() in ("LC1", "1")) else 0
                # Format: [15:12]=0x7, [11]=lc_sel, [10]=1, [9:8]=10
                word = (opcode_val << 12) | (lc_sel << 11) | (1 << 10) | (2 << 8)

            elif op == "MOV_LC":
                # Forms:
                #   MOV_LC LCx, OSR
                #   MOV_LC LCx
                lc_sel = 1 if (len(tokens) >= 2 and tokens[1].strip().upper() in ("LC1", "1")) else 0
                # Format: [15:12]=0x7, [11]=lc_sel, [10]=1, [9:8]=11
                word = (opcode_val << 12) | (lc_sel << 11) | (1 << 10) | (3 << 8)

            elif op == "JMP":
                # Forms:
                #   JMP target
                #   JMP cond, target
                CONDITIONS = {
                    "ALWAYS": (0, 0),
                    "TX_VALID": (0, 1),
                    "TX_RDY": (0, 1),
                    "TX_READY": (0, 1),
                    "TX_EMPTY": (0, 2),
                    "NO_TX": (0, 2),
                    "RX_FULL": (0, 3),
                    "RX_READY": (0, 4),
                    "RX_RDY": (0, 4),
                    "NOT_FULL": (0, 4),
                    "PIN_HI": (0, 5),
                    "PIN_HIGH": (0, 5),
                    "PIN_1": (0, 5),
                    "PIN_LO": (0, 6),
                    "PIN_LOW": (0, 6),
                    "PIN_0": (0, 6),
                    "CRC_OK": (0, 7),
                    "CRC_VALID": (0, 7),
                    "CRC_ZERO": (0, 7),
                    # ALU Condition Codes (0x8 .. 0xE)
                    "ZERO": (0, 8), "EQ": (0, 8), "Z": (0, 8),
                    "NOT_ZERO": (0, 9), "NE": (0, 9), "NZ": (0, 9),
                    "CARRY": (0, 10), "ULT": (0, 10), "C": (0, 10), "CY": (0, 10),
                    "NOT_CARRY": (0, 11), "UGE": (0, 11), "NC": (0, 11),
                    "NEG": (0, 12), "NEGATIVE": (0, 12), "SIGN": (0, 12), "MINUS": (0, 12),
                    "POS": (0, 13), "POSITIVE": (0, 13), "PLUS": (0, 13),
                    "CRC_ERR": (0, 14), "CRC_BAD": (0, 14), "CRC_ERROR": (0, 14),
                    "STUFF_ERR": (0, 15), "STUFF_ERROR": (0, 15), "STUFF_BAD": (0, 15),
                    "MANCH_ERR": (0, 15), "MANCH_ERROR": (0, 15), "MANCH_VIOLATION": (0, 15), "STREAM_ERR": (0, 15),
                    # Task 21: Extended I2C Slave Condition Codes
                    "I2C_MATCH": (1, 0), "I2C_ADDR_MATCH": (1, 0), "I2C_ADDR": (1, 0),
                    "I2C_START": (1, 1),
                    "I2C_STOP": (1, 2),
                    "I2C_READ": (1, 3),
                    "I2C_WRITE": (1, 4),
                    "I2C_ACK": (1, 5),
                    "I2C_NACK": (1, 6),
                    "I2C_BUS_ACTIVE": (1, 7), "I2C_ACTIVE": (1, 7),
                    # Task 23: Extended JTAG & SWD Condition Codes
                    "SWD_OK": (1, 8), "ACK_OK": (1, 8),
                    "SWD_WAIT": (1, 9), "ACK_WAIT": (1, 9),
                    "SWD_FAULT": (1, 10), "ACK_FAULT": (1, 10),
                    "JTAG_IDLE": (1, 11), "TAP_IDLE": (1, 11),
                    # Task 25: Extended Glitch & MitM Condition Codes
                    "GLITCH_DONE": (1, 12), "GLITCH_FIRED": (1, 12),
                    "MATCH_FOUND": (1, 13), "MITM_MATCH": (1, 13),
                    # Task 27: Extended Waveform Profiler Condition Codes
                    "PROFILER_DONE": (1, 14), "PROFILER_CONVERGED": (1, 14),
                    "PROFILER_CLOCK": (1, 15), "IS_CLOCK": (1, 15),
                }
                if len(tokens) >= 3:
                    cond_name = tokens[1].strip().upper()
                    if cond_name not in CONDITIONS:
                        raise AssemblerError(f"Line {line_num}: Unknown condition '{tokens[1]}' for JMP")
                    is_ext, cond = CONDITIONS[cond_name]
                    target = eval_arg(tokens[2]) & 0x7F
                elif len(tokens) == 2:
                    is_ext, cond = 0, 0  # Unconditional JMP
                    target = eval_arg(tokens[1]) & 0x7F
                else:
                    raise AssemblerError(f"Line {line_num}: JMP requires target address or label")
                word = (opcode_val << 12) | (cond << 8) | ((1 << 7) if is_ext else 0) | target

            elif op == "PULL":
                # Forms:
                #   PULL
                #   PULL BLOCK / PULL WAIT
                block = 1 if (len(tokens) >= 2 and tokens[1].strip().upper() in ("BLOCK", "WAIT", "1")) else 0
                word = (opcode_val << 12) | block

            elif op == "PUSH":
                # Forms:
                #   PUSH
                #   PUSH BLOCK / PUSH WAIT
                block = 1 if (len(tokens) >= 2 and tokens[1].strip().upper() in ("BLOCK", "WAIT", "1")) else 0
                word = (opcode_val << 12) | block

            elif op == "CALL":
                # CALL target_label_or_addr
                if len(tokens) < 2:
                    raise AssemblerError(f"Line {line_num}: CALL requires a target address or label")
                target = eval_arg(tokens[1]) & 0x7F
                word = (opcode_val << 12) | target

            elif op == "RET":
                # RET — no operands
                word = opcode_val << 12

            elif op in ("CRC", "CRC_INIT", "CRC_BYTE", "CRC_READ_LOW", "CRC_READ_L", "CRC_READ_HIGH", "CRC_READ_H",
                        "CRC_READ_B0", "CRC_READ_B1", "CRC_READ_B2", "CRC_READ_B3", "CRC_RESET"):
                # Sub-operations:
                # 3'b000: CRC_INIT poly, [seed]
                # 3'b001: CRC_BYTE OSR
                # 3'b010: CRC_BYTE ISR
                # 3'b011: CRC_BYTE DATA
                # 3'b100: CRC_READ_LOW / CRC_READ_B0
                # 3'b101: CRC_READ_HIGH / CRC_READ_B1
                # 3'b110: CRC_RESET
                # 3'b111: CRC_READ_B2 (bit 0=0) / CRC_READ_B3 (bit 0=1)
                POLY_MAP = {
                    "DALLAS": 0, "1WIRE": 0, "ONEWIRE": 0, "CRC8_DALLAS": 0, "0": 0,
                    "SMBUS": 1, "I2C": 1, "PEC": 1, "CRC8_SMBUS": 1, "1": 1,
                    "CCITT": 2, "XMODEM": 2, "CRC16_CCITT": 2, "2": 2,
                    "MODBUS": 3, "IBM": 3, "USB": 3, "CRC16_MODBUS": 3, "3": 3,
                    "ETHERNET": 4, "ETH": 4, "CRC32": 4, "CRC-32": 4, "CRC32_ETH": 4, "4": 4,
                    "USB5": 5, "CRC5": 5, "CRC-5": 5, "CRC5_USB": 5, "5": 5,
                }
                SEED_MAP = {
                    "DEFAULT": 0, "AUTO": 0,
                    "0": 1, "0X0000": 1, "0X0": 1, "0X00": 1, "ZERO": 1,
                    "0xFFFF": 2, "65535": 2, "ONES": 2, "-1": 2,
                    "0XFFFFFFFF": 2, "4294967295": 2,
                }
                SRC_MAP = {
                    "OSR": 1,
                    "ISR": 2,
                    "DATA": 3, "I_DATA": 3, "DIN": 3,
                }

                if op == "CRC":
                    if len(tokens) < 2:
                        raise AssemblerError(f"Line {line_num}: CRC requires sub-operation (e.g. CRC INIT, CRC BYTE, CRC READ_LOW)")
                    sub_cmd = tokens[1].strip().upper()
                    arg_tokens = tokens[2:]
                else:
                    sub_cmd = op[4:]  # Strip 'CRC_'
                    arg_tokens = tokens[1:]

                if sub_cmd == "INIT":
                    if len(arg_tokens) < 1:
                        raise AssemblerError(f"Line {line_num}: CRC_INIT requires polynomial argument (DALLAS, SMBUS, CCITT, MODBUS, ETHERNET, USB5)")
                    poly_str = arg_tokens[0].strip().upper()
                    if poly_str not in POLY_MAP:
                        raise AssemblerError(f"Line {line_num}: Unknown CRC polynomial '{arg_tokens[0]}'")
                    poly = POLY_MAP[poly_str]
                    seed = 0
                    if len(arg_tokens) >= 2:
                        seed_str = arg_tokens[1].strip().upper()
                        if seed_str in SEED_MAP:
                            seed = SEED_MAP[seed_str]
                        else:
                            seed_val = eval_arg(seed_str)
                            seed = 1 if seed_val == 0 else 2

                    if poly >= 4:
                        # Extended polynomial: bit 3 = 1, bits 2:1 = poly - 4, bits 5:4 = seed
                        word = (0xE << 12) | (0 << 9) | ((seed & 3) << 4) | (1 << 3) | (((poly - 4) & 3) << 1)
                    else:
                        # Legacy polynomial: bit 3 = 0, bits 8:7 = poly, bits 6:5 = seed
                        word = (0xE << 12) | (0 << 9) | (poly << 7) | (seed << 5)

                elif sub_cmd == "BYTE":
                    if len(arg_tokens) < 1:
                        raise AssemblerError(f"Line {line_num}: CRC_BYTE requires source operand (OSR, ISR, or DATA)")
                    src_str = arg_tokens[0].strip().upper()
                    if src_str not in SRC_MAP:
                        raise AssemblerError(f"Line {line_num}: Unknown CRC source register '{arg_tokens[0]}' (expected OSR, ISR, DATA)")
                    src = SRC_MAP[src_str]
                    word = (0xE << 12) | (src << 9)

                elif sub_cmd in ("READ_LOW", "READ_L", "READLOW", "READ_B0", "B0"):
                    word = (0xE << 12) | (4 << 9)

                elif sub_cmd in ("READ_HIGH", "READ_H", "READHIGH", "READ_B1", "B1"):
                    word = (0xE << 12) | (5 << 9)

                elif sub_cmd in ("READ_B2", "B2"):
                    word = (0xE << 12) | (7 << 9) | 0

                elif sub_cmd in ("READ_B3", "B3"):
                    word = (0xE << 12) | (7 << 9) | 1

                elif sub_cmd == "RESET":
                    word = (0xE << 12) | (6 << 9)

                elif sub_cmd == "READ":
                    if len(arg_tokens) < 1:
                        raise AssemblerError(f"Line {line_num}: CRC READ requires byte identifier (LOW, HIGH, B0, B1, B2, B3)")
                    target_part = arg_tokens[0].strip().upper()
                    if target_part in ("LOW", "L", "B0", "BYTE0", "0"):
                        word = (0xE << 12) | (4 << 9)
                    elif target_part in ("HIGH", "H", "B1", "BYTE1", "1"):
                        word = (0xE << 12) | (5 << 9)
                    elif target_part in ("B2", "BYTE2", "2"):
                        word = (0xE << 12) | (7 << 9) | 0
                    elif target_part in ("B3", "BYTE3", "3"):
                        word = (0xE << 12) | (7 << 9) | 1
                    else:
                        raise AssemblerError(f"Line {line_num}: CRC READ requires LOW, HIGH, B0, B1, B2, or B3, got '{arg_tokens[0]}'")

                else:
                    raise AssemblerError(f"Line {line_num}: Unknown CRC command '{sub_cmd}'")

            elif op in ("ALU", "ADD", "SUB", "CMP", "AND", "OR", "XOR", "MOV", "NOT", "INV", "INC", "DEC", "CLR", "SHL", "SHR", "ROL", "ROR", "BANK", "SET_BANK", "JMP_BANK"):
                SRC_REG_MAP = {
                    "OSR": 0,
                    "ISR": 1,
                    "LC0": 2, "LC_0": 2,
                    "LC1": 3, "LC_1": 3,
                    "DATA": 4, "I_DATA": 4, "DIN": 4,
                    "ACC": 5, "A": 5, "BANK": 5, "ACTIVE_BANK": 5,
                    "CRC_L": 6, "CRC_LOW": 6, "CRC_REG_L": 6,
                    "CRC_H": 7, "CRC_HIGH": 7, "CRC_REG_H": 7,
                }
                DST_REG_MAP = {
                    "OSR": 0,
                    "ISR": 1,
                    "LC0": 2, "LC_0": 2,
                    "LC1": 3, "LC_1": 3,
                    "O_DATA": 4, "DATA_OUT": 4, "DOUT": 4, "DATA": 4,
                    "ACC": 5, "A": 5, "BANK": 5, "ACTIVE_BANK": 5,
                    "CRC_SEED_L": 6, "CRC_SEED_LOW": 6,
                    "CRC_SEED_H": 7, "CRC_SEED_HIGH": 7,
                }

                alu_cmd = op
                alu_tokens = tokens[1:]
                if op == "ALU":
                    if len(tokens) < 2:
                        raise AssemblerError(f"Line {line_num}: ALU requires sub-operation (e.g. ALU ADD, acc, 5)")
                    alu_cmd = tokens[1].strip().upper()
                    alu_tokens = tokens[2:]

                # 1. Unary operations on acc & Bank switching: NOT, INV, INC, DEC, CLR, BANK, JMP_BANK
                if alu_cmd in ("NOT", "INV"):
                    word = (0xB << 12) | (0 << 11) | (7 << 8)
                elif alu_cmd in ("BANK", "SET_BANK"):
                    if len(alu_tokens) < 1:
                        raise AssemblerError(f"Line {line_num}: BANK requires bank number (0..3)")
                    bank_imm = eval_arg(alu_tokens[0]) & 3
                    word = (0xB << 12) | (0 << 11) | (7 << 8) | (1 << 6) | bank_imm
                elif alu_cmd in ("JMP_BANK", "JMP.BANK"):
                    if len(alu_tokens) < 1:
                        raise AssemblerError(f"Line {line_num}: JMP_BANK requires bank number (0..3)")
                    bank_imm = eval_arg(alu_tokens[0]) & 3
                    word = (0xB << 12) | (0 << 11) | (7 << 8) | (2 << 6) | bank_imm
                elif alu_cmd == "INC":
                    word = (0xB << 12) | (1 << 11) | (6 << 8) | (0 << 3)
                elif alu_cmd == "DEC":
                    word = (0xB << 12) | (1 << 11) | (6 << 8) | (1 << 3)
                elif alu_cmd == "CLR":
                    word = (0xB << 12) | (1 << 11) | (6 << 8) | (2 << 3)

                # 2. Shift operations on acc: SHL, SHR, ROL, ROR
                elif alu_cmd == "SHL":
                    word = (0xB << 12) | (1 << 11) | (7 << 8) | (0 << 3)
                elif alu_cmd == "SHR":
                    word = (0xB << 12) | (1 << 11) | (7 << 8) | (1 << 3)
                elif alu_cmd == "ROL":
                    word = (0xB << 12) | (1 << 11) | (7 << 8) | (2 << 3)
                elif alu_cmd == "ROR":
                    word = (0xB << 12) | (1 << 11) | (7 << 8) | (3 << 3)

                # 3. MOV operations: MOV acc, imm | MOV acc, reg | MOV reg, acc
                elif alu_cmd == "MOV":
                    if len(alu_tokens) < 2:
                        raise AssemblerError(f"Line {line_num}: MOV requires destination and source operands (e.g. MOV acc, 0x10 or MOV lc0, acc)")
                    dst_name = alu_tokens[0].strip().upper()
                    src_name = alu_tokens[1].strip().upper()

                    if dst_name in ("ACC", "A"):
                        if src_name in SRC_REG_MAP:
                            src_id = SRC_REG_MAP[src_name]
                            word = (0xB << 12) | (1 << 11) | (0 << 8) | src_id
                        else:
                            imm8 = eval_arg(alu_tokens[1]) & 0xFF
                            word = (0xB << 12) | (0 << 11) | (6 << 8) | imm8
                    elif src_name in ("ACC", "A"):
                        if dst_name not in DST_REG_MAP:
                            raise AssemblerError(f"Line {line_num}: Invalid destination register '{alu_tokens[0]}' for MOV from ACC")
                        dst_id = DST_REG_MAP[dst_name]
                        word = (0xB << 12) | (1 << 11) | (1 << 8) | (dst_id << 3)
                    else:
                        raise AssemblerError(f"Line {line_num}: MOV must have ACC as either source or destination (got '{dst_name}', '{src_name}')")

                # 4. Binary operations: ADD, SUB, CMP, AND, OR, XOR
                elif alu_cmd in ("ADD", "SUB", "CMP", "AND", "OR", "XOR"):
                    if len(alu_tokens) >= 2:
                        first_arg = alu_tokens[0].strip().upper()
                        if first_arg in ("ACC", "A"):
                            operand_str = alu_tokens[1].strip()
                        else:
                            raise AssemblerError(f"Line {line_num}: First operand of {alu_cmd} must be ACC (e.g. {alu_cmd} acc, operand)")
                    elif len(alu_tokens) == 1:
                        operand_str = alu_tokens[0].strip()
                    else:
                        raise AssemblerError(f"Line {line_num}: {alu_cmd} requires operand (e.g. {alu_cmd} acc, 5 or {alu_cmd} 5)")

                    op_clean = operand_str.upper()
                    if op_clean in SRC_REG_MAP:
                        reg_id = SRC_REG_MAP[op_clean]
                        if alu_cmd == "ADD":
                            word = (0xB << 12) | (1 << 11) | (2 << 8) | reg_id
                        elif alu_cmd == "SUB":
                            word = (0xB << 12) | (1 << 11) | (3 << 8) | reg_id
                        elif alu_cmd == "CMP":
                            word = (0xB << 12) | (1 << 11) | (4 << 8) | reg_id
                        elif alu_cmd == "AND":
                            word = (0xB << 12) | (1 << 11) | (5 << 8) | (0 << 3) | reg_id
                        elif alu_cmd == "OR":
                            word = (0xB << 12) | (1 << 11) | (5 << 8) | (1 << 3) | reg_id
                        elif alu_cmd == "XOR":
                            word = (0xB << 12) | (1 << 11) | (5 << 8) | (2 << 3) | reg_id
                    else:
                        imm8 = eval_arg(operand_str) & 0xFF
                        if alu_cmd == "ADD":
                            word = (0xB << 12) | (0 << 11) | (0 << 8) | imm8
                        elif alu_cmd == "SUB":
                            word = (0xB << 12) | (0 << 11) | (1 << 8) | imm8
                        elif alu_cmd == "CMP":
                            word = (0xB << 12) | (0 << 11) | (2 << 8) | imm8
                        elif alu_cmd == "AND":
                            word = (0xB << 12) | (0 << 11) | (3 << 8) | imm8
                        elif alu_cmd == "OR":
                            word = (0xB << 12) | (0 << 11) | (4 << 8) | imm8
                        elif alu_cmd == "XOR":
                            word = (0xB << 12) | (0 << 11) | (5 << 8) | imm8
                else:
                    raise AssemblerError(f"Line {line_num}: Unknown ALU operation '{alu_cmd}'")

            elif op in ("ASSIST", "ASSIST_CFG", "ASSIST_RESET", "ASSIST_READ", "PULSE_CFG", "GAMEPAD_CFG", "PULSE_TIME0", "PULSE_TIME1", "I2C_SLAVE_CFG", "I2C_RELEASE_SCL", "I2C_SLAVE_DISABLE", "AUDIO_CFG", "AUDIO_VOL", "AUDIO_SAMPLE", "AUDIO_DUTY", "AUDIO_NOTE_LO", "AUDIO_NOTE_HI", "AUDIO_PLAY", "AUDIO_STOP", "JTAG_CFG", "JTAG_TMS", "JTAG_NAV", "JTAG_SHIFT", "SWD_CFG", "SWD_REQ", "SWD_RESET", "SWD_RD32", "SWD_WR32", "SWD_LOAD", "QSPI_CFG", "QSPI_CS", "QSPI_CMD", "QSPI_DUMMY", "QSPI_ADDR", "QSPI_LOAD_ADDR", "QSPI_LOAD", "GLITCH_CFG", "GLITCH_WIDTH", "GLITCH_DELAY", "GLITCH_DELAY_LO", "GLITCH_DELAY_HI", "GLITCH_ARM", "GLITCH_TRIG", "GLITCH_TRIGGER", "GLITCH_DISARM", "MITM_MATCH", "MITM_REPLACE", "MITM_MASK", "MITM_ENABLE", "MITM_DISABLE", "MITM_RESET", "MITM_CLR", "PROFILER_CFG", "PROFILER_FILTER", "PROFILER_ARM", "PROFILER_STOP", "PROFILER_RST", "PROFILER_RESET", "USB_CFG", "USB_CONFIG", "USB_TX_TOKEN", "USB_TOKEN", "USB_TX_DATA", "USB_DATA_PKT", "USB_SEND_ACK", "USB_ACK", "USB_SEND_NAK", "USB_NAK", "USB_SEND_STALL", "USB_STALL", "USB_SIE_EN", "USB_SIE_DIS", "BIST_CFG", "BIST_CONFIG", "BIST_DIS", "BIST_DISABLE", "BIST_LOOP", "BIST_LOOPBACK", "BIST_SPLIT", "BIST_CROSSBAR", "BIST_JITTER", "BIST_STRESS", "BIST_START", "BIST_EN", "BIST_STOP", "BIST_RST", "BIST_RESET", "BIST_PASS", "BIST_FAIL", "BIST_STAGE"):
                # Sub-operations:
                # 2'b00: ASSIST CFG, nrzi_en, stuff_mode [, init_val]
                # 2'b01: ASSIST RESET
                # 2'b10: ASSIST READ [, PAD_HIGH]
                # 2'b11: ASSIST PULSE / GAMEPAD
                #        [9:8]=00: PULSE_CFG
                #        [9:8]=01: GAMEPAD_CFG
                #        [9:8]=10: PULSE_TIME0
                #        [9:8]=11: PULSE_TIME1
                STUFF_MAP = {
                    "OFF": 0, "NONE": 0, "0": 0, "DISABLE": 0, "BYPASS": 0,
                    "USB": 1, "USB1": 1, "USB11": 1, "1": 1, "6ONES": 1,
                    "CAN": 2, "CAN2": 2, "2": 2, "5BITS": 2,
                }
                NRZI_MAP = {
                    "OFF": 0, "0": 0, "DISABLE": 0, "NRZ": 0, "NONE": 0,
                    "ON": 1, "1": 1, "ENABLE": 1, "NRZI": 1,
                }

                if op == "ASSIST":
                    if len(tokens) < 2:
                        raise AssemblerError(f"Line {line_num}: ASSIST requires sub-operation (CFG, RESET, READ, PULSE_CFG, GAMEPAD_CFG, PULSE_TIME0, PULSE_TIME1)")
                    sub_cmd = tokens[1].strip().upper()
                    arg_tokens = tokens[2:]
                elif op.startswith("ASSIST_"):
                    sub_cmd = op[7:]  # Strip 'ASSIST_'
                    arg_tokens = tokens[1:]
                else:
                    sub_cmd = op  # Direct mnemonic like PULSE_CFG, GAMEPAD_CFG
                    arg_tokens = tokens[1:]

                if sub_cmd == "CFG":
                    # Forms:
                    #   ASSIST CFG, NRZI=1, STUFF=USB
                    #   ASSIST CFG, 1, USB
                    #   ASSIST CFG, NRZI, USB
                    #   ASSIST CFG, NRZI, USB, INIT=1
                    nrzi_val = 0
                    stuff_val = 0
                    init_en = 0
                    init_val = 1
                    manch_cfg_en = 0
                    manch_en = 0
                    manch_mode = 0
                    manch_state = 0

                    for a in arg_tokens:
                        item = a.strip().upper()
                        if "=" in item:
                            k, v = item.split("=", 1)
                            k, v = k.strip(), v.strip()
                            if k == "NRZI":
                                nrzi_val = NRZI_MAP[v] if v in NRZI_MAP else (1 if eval_arg(v) else 0)
                            elif k in ("STUFF", "MODE"):
                                stuff_val = STUFF_MAP[v] if v in STUFF_MAP else (eval_arg(v) & 3)
                            elif k in ("INIT", "LEVEL", "STATE"):
                                init_en = 1
                                init_val = 1 if (v in ("1", "HIGH", "J") or (eval_arg(v) != 0 if v.isdigit() else 0)) else 0
                            elif k in ("MANCH", "MANCHESTER"):
                                manch_cfg_en = 1
                                manch_en = 0 if v in ("0", "OFF", "DISABLE") else 1
                            elif k in ("MANCH_MODE", "MANCH_TYPE"):
                                manch_cfg_en = 1
                                manch_en = 1
                                if v in ("THOMAS", "INVERTED", "1"):
                                    manch_mode = 1
                                elif v in ("BMC", "BIPHASE", "DALI", "2"):
                                    manch_mode = 2
                                else:
                                    manch_mode = 0
                        elif item in ("NRZI", "ENABLE_NRZI"):
                            nrzi_val = 1
                        elif item in ("NRZ", "NO_NRZI", "DISABLE_NRZI"):
                            nrzi_val = 0
                        elif item in STUFF_MAP:
                            stuff_val = STUFF_MAP[item]
                        elif item in ("MANCH", "MANCHESTER", "ENABLE_MANCH"):
                            manch_cfg_en = 1
                            manch_en = 1
                        elif item in ("IEEE", "10BASET", "ETHERNET"):
                            manch_cfg_en = 1
                            manch_en = 1
                            manch_mode = 0
                        elif item in ("THOMAS", "INVERTED_MANCH"):
                            manch_cfg_en = 1
                            manch_en = 1
                            manch_mode = 1
                        elif item in ("BMC", "BIPHASE", "BIPHASE_MARK"):
                            manch_cfg_en = 1
                            manch_en = 1
                            manch_mode = 2
                        else:
                            try:
                                v_int = eval_arg(item)
                                if nrzi_val == 0:
                                    nrzi_val = 1 if v_int else 0
                                else:
                                    stuff_val = v_int & 3
                            except Exception:
                                pass

                    word = (0xF << 12) | (0 << 10) | (nrzi_val << 9) | (stuff_val << 7) | (init_en << 6) | (init_val << 5) | (manch_cfg_en << 4) | (manch_en << 3) | (manch_mode << 1) | manch_state

                elif sub_cmd in ("MANCH_CFG", "MANCH", "MANCHESTER"):
                    # ASSIST MANCH_CFG, <IEEE / THOMAS / BMC> [, EN=1/0]
                    manch_en = 1
                    manch_mode = 0
                    manch_state = 0
                    for a in arg_tokens:
                        item = a.strip().upper()
                        if "=" in item:
                            k, v = item.split("=", 1)
                            k, v = k.strip(), v.strip()
                            if k in ("EN", "ENABLE"):
                                manch_en = 0 if v in ("0", "OFF", "DISABLE") else 1
                            elif k in ("MODE", "TYPE"):
                                if v in ("THOMAS", "INVERTED", "1"):
                                    manch_mode = 1
                                elif v in ("BMC", "BIPHASE", "DALI", "2"):
                                    manch_mode = 2
                                else:
                                    manch_mode = 0
                            elif k in ("STATE", "INIT"):
                                manch_state = 1 if v in ("1", "HIGH") else 0
                        else:
                            if item in ("THOMAS", "INVERTED"):
                                manch_mode = 1
                            elif item in ("BMC", "BIPHASE", "DALI"):
                                manch_mode = 2
                            elif item in ("IEEE", "10BASET", "ETHERNET"):
                                manch_mode = 0
                            elif item in ("OFF", "DISABLE"):
                                manch_en = 0
                    word = (0xF << 12) | (0 << 10) | (1 << 4) | (manch_en << 3) | (manch_mode << 1) | manch_state

                elif sub_cmd in ("RESET", "I2C_RESET"):
                    word = (0xF << 12) | (1 << 10) | (0 << 8)

                elif sub_cmd in ("I2C_SLAVE_DISABLE", "I2C_DISABLE"):
                    word = (0xF << 12) | (1 << 10) | (1 << 8)

                elif sub_cmd in ("I2C_SLAVE_CFG", "I2C_CFG", "SLAVE_CFG"):
                    # I2C_SLAVE_CFG <addr7> [, stretch=0|1]
                    slave_addr = 0
                    stretch = 0
                    for a in arg_tokens:
                        item = a.strip().upper()
                        if "=" in item:
                            k, v = item.split("=", 1)
                            k, v = k.strip(), v.strip()
                            if k in ("ADDR", "ADDRESS", "SLAVE_ADDR"):
                                slave_addr = eval_arg(v) & 0x7F
                            elif k in ("STRETCH", "CLOCK_STRETCH"):
                                stretch = 1 if v in ("1", "TRUE", "ENABLE", "ON") else 0
                        elif item in ("STRETCH", "ENABLE_STRETCH"):
                            stretch = 1
                        elif item in ("NO_STRETCH", "DISABLE_STRETCH"):
                            stretch = 0
                        else:
                            slave_addr = eval_arg(a) & 0x7F
                    word = (0xF << 12) | (1 << 10) | (2 << 8) | ((stretch & 1) << 7) | (slave_addr & 0x7F)

                elif sub_cmd in ("I2C_RELEASE_SCL", "RELEASE_SCL", "RELEASE"):
                    word = (0xF << 12) | (1 << 10) | (3 << 8)

                elif sub_cmd in ("JTAG_CFG", "JTAG"):
                    en = 1
                    if arg_tokens and arg_tokens[0].strip().upper() in ("0", "OFF", "DISABLE"):
                        en = 0
                    word = (0xF << 12) | (1 << 10) | (1 << 8) | (1 << 4) | (en & 1)

                elif sub_cmd in ("JTAG_TMS",):
                    cnt = eval_arg(arg_tokens[0]) & 0xF if arg_tokens else 1
                    word = (0xF << 12) | (1 << 10) | (1 << 8) | (2 << 4) | (cnt & 0xF)

                elif sub_cmd in ("JTAG_NAV",):
                    NAV_MAP = {
                        "RESET": 0, "TLR": 0, "TEST_LOGIC_RESET": 0,
                        "IDLE": 1, "RTI": 1, "RUN_TEST_IDLE": 1,
                        "SHIFT_DR": 2, "DR": 2,
                        "SHIFT_IR": 3, "IR": 3,
                        "EXIT_TO_IDLE": 4, "EXIT": 4, "UPDATE": 4,
                    }
                    target_preset = 1
                    if arg_tokens:
                        tok = arg_tokens[0].strip().upper()
                        if tok in NAV_MAP:
                            target_preset = NAV_MAP[tok]
                        else:
                            target_preset = eval_arg(tok) & 0xF
                    word = (0xF << 12) | (1 << 10) | (1 << 8) | (3 << 4) | (target_preset & 0xF)

                elif sub_cmd in ("JTAG_SHIFT",):
                    cnt = 8
                    exit_on_last = 0
                    for a in arg_tokens:
                        item = a.strip().upper()
                        if "=" in item:
                            k, v = item.split("=", 1)
                            if k.strip() in ("EXIT", "EXIT_ON_LAST"):
                                exit_on_last = 1 if v.strip() in ("1", "TRUE", "ENABLE") else 0
                        elif item in ("EXIT", "EXIT1"):
                            exit_on_last = 1
                        else:
                            cnt = eval_arg(item) & 0x7
                    word = (0xF << 12) | (1 << 10) | (1 << 8) | (7 << 4) | ((exit_on_last & 1) << 3) | (cnt & 0x7)

                elif sub_cmd in ("SWD_CFG", "SWD"):
                    en = 1
                    if arg_tokens and arg_tokens[0].strip().upper() in ("0", "OFF", "DISABLE"):
                        en = 0
                    word = (0xF << 12) | (1 << 10) | (1 << 8) | (4 << 4) | (en & 1)

                elif sub_cmd in ("SWD_REQ",):
                    ap = 0
                    rnw = 1
                    swd_addr = 0
                    if len(arg_tokens) >= 3:
                        ap = 1 if arg_tokens[0].strip().upper() in ("AP", "1") else 0
                        rnw = 1 if arg_tokens[1].strip().upper() in ("READ", "RD", "R", "1") else 0
                        swd_addr = (eval_arg(arg_tokens[2]) >> 2) & 0x3
                    word = (0xF << 12) | (1 << 10) | (1 << 8) | (5 << 4) | ((ap & 1) << 3) | ((rnw & 1) << 2) | (swd_addr & 3)

                elif sub_cmd in ("SWD_RESET",):
                    sw = 1
                    if arg_tokens and arg_tokens[0].strip().upper() in ("0", "OFF", "NO_SWITCH"):
                        sw = 0
                    word = (0xF << 12) | (1 << 10) | (1 << 8) | (6 << 4) | (sw & 1)

                elif sub_cmd in ("SWD_RD32",):
                    word = (0xF << 12) | (1 << 10) | (1 << 8) | (8 << 4)

                elif sub_cmd in ("SWD_WR32",):
                    word = (0xF << 12) | (1 << 10) | (1 << 8) | (9 << 4)

                elif sub_cmd in ("SWD_LOAD", "SWD_LOAD_BYTE"):
                    idx = eval_arg(arg_tokens[0]) & 0x3 if arg_tokens else 0
                    word = (0xF << 12) | (1 << 10) | (1 << 8) | (10 << 4) | (idx & 0x3)

                elif sub_cmd in ("QSPI_CFG", "QSPI"):
                    en = 1
                    width = 2  # default QUAD
                    cpol = 0
                    for a in arg_tokens:
                        item = a.strip().upper()
                        if "=" in item:
                            k, v = item.split("=", 1)
                            k, v = k.strip(), v.strip()
                            if k in ("EN", "ENABLE"):
                                en = 1 if v not in ("0", "OFF", "DISABLE") else 0
                            elif k in ("WIDTH", "MODE", "LANES"):
                                if v in ("OCTAL", "8", "OCT"): width = 3
                                elif v in ("QUAD", "4"): width = 2
                                elif v in ("DUAL", "2"): width = 1
                                elif v in ("SINGLE", "1", "STANDARD"): width = 0
                                else: width = eval_arg(v) & 3
                            elif k in ("CPOL", "POLARITY", "POL"):
                                cpol = 1 if v in ("1", "HIGH", "TRUE") else 0
                        else:
                            if item in ("OFF", "DISABLE", "0"):
                                en = 0
                            elif item in ("OCTAL", "8", "OCT"):
                                width = 3
                            elif item in ("QUAD", "4"):
                                width = 2
                            elif item in ("DUAL", "2"):
                                width = 1
                            elif item in ("SINGLE", "1"):
                                width = 0
                            elif item in ("CPOL1", "CPOL=1", "HIGH"):
                                cpol = 1
                            elif item in ("CPOL0", "CPOL=0", "LOW"):
                                cpol = 0
                            elif item.isdigit():
                                w = eval_arg(item)
                                if w in (1, 2, 4, 8):
                                    width = {1: 0, 2: 1, 4: 2, 8: 3}[w]
                                else:
                                    en = w & 1
                    word = (0xF << 12) | (1 << 10) | (1 << 8) | (0xB << 4) | ((cpol & 1) << 3) | ((width & 3) << 1) | (en & 1)

                elif sub_cmd in ("QSPI_CS",):
                    cs_val = 0
                    if arg_tokens:
                        tok = arg_tokens[0].strip().upper()
                        if tok in ("DEASSERT", "HIGH", "1", "RELEASE", "DISABLE"):
                            cs_val = 1
                        elif tok in ("ASSERT", "LOW", "0", "SELECT", "ENABLE"):
                            cs_val = 0
                        else:
                            cs_val = eval_arg(tok) & 1
                    word = (0xF << 12) | (1 << 10) | (1 << 8) | (0xC << 4) | (cs_val & 1)

                elif sub_cmd in ("QSPI_CMD",):
                    word = (0xF << 12) | (1 << 10) | (1 << 8) | (0xD << 4)

                elif sub_cmd in ("QSPI_DUMMY",):
                    cycles = eval_arg(arg_tokens[0]) & 0xF if arg_tokens else 6
                    word = (0xF << 12) | (1 << 10) | (1 << 8) | (0xE << 4) | (cycles & 0xF)

                elif sub_cmd in ("QSPI_ADDR",):
                    is_32 = 0
                    if arg_tokens:
                        tok = arg_tokens[0].strip().upper()
                        if tok in ("32", "32B", "4", "4BYTE"):
                            is_32 = 1
                        else:
                            is_32 = 1 if eval_arg(tok) == 32 else 0
                    word = (0xF << 12) | (1 << 10) | (1 << 8) | (0xF << 4) | (1 << 3) | (is_32 & 1)

                elif sub_cmd in ("QSPI_LOAD_ADDR", "QSPI_LOAD"):
                    idx = eval_arg(arg_tokens[0]) & 3 if arg_tokens else 0
                    word = (0xF << 12) | (1 << 10) | (1 << 8) | (0xF << 4) | (0 << 3) | (idx & 3)

                elif sub_cmd in ("GLITCH_CFG",):
                    # GLITCH_CFG pin, pol
                    pin = 0
                    pol = 0
                    if arg_tokens:
                        tok0 = arg_tokens[0].strip().upper()
                        if tok0 in PIN_NAMES: pin = PIN_NAMES[tok0]
                        else: pin = eval_arg(tok0) & 7
                    if len(arg_tokens) > 1:
                        tok1 = arg_tokens[1].strip().upper()
                        if tok1 in ("LOW", "ACTIVE_LOW", "CROWBAR", "1"): pol = 1
                        else: pol = eval_arg(tok1) & 1
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (1 << 4) | (pol << 3) | (pin & 7)

                elif sub_cmd in ("GLITCH_WIDTH",):
                    w = eval_arg(arg_tokens[0]) & 0xF if arg_tokens else 1
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (2 << 4) | (w & 0xF)

                elif sub_cmd in ("GLITCH_DELAY_LO",):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (3 << 4)

                elif sub_cmd in ("GLITCH_DELAY_HI",):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (4 << 4)

                elif sub_cmd in ("GLITCH_DELAY",):
                    d = eval_arg(arg_tokens[0]) & 0xF if arg_tokens else 0
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (5 << 4) | (d & 0xF)

                elif sub_cmd in ("GLITCH_ARM",):
                    on_match = 0
                    if arg_tokens:
                        tok = arg_tokens[0].strip().upper()
                        if tok in ("MATCH", "1", "TRUE", "PATTERN", "ON_MATCH"):
                            on_match = 1
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (0 << 4) | (3 if on_match else 2)

                elif sub_cmd in ("GLITCH_TRIG", "GLITCH_TRIGGER"):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (0 << 4) | 1

                elif sub_cmd in ("GLITCH_DISARM",):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (0 << 4) | 4

                elif sub_cmd in ("MITM_MATCH",):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (6 << 4)

                elif sub_cmd in ("MITM_REPLACE",):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (7 << 4)

                elif sub_cmd in ("MITM_MASK",):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (8 << 4)

                elif sub_cmd in ("MITM_ENABLE", "MITM_EN"):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (0 << 4) | 5

                elif sub_cmd in ("MITM_DISABLE", "MITM_DIS"):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (0 << 4) | 6

                elif sub_cmd in ("MITM_RESET", "MITM_CLR"):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (0 << 4) | 7

                elif sub_cmd in ("PROFILER_CFG",):
                    pin = 0
                    if arg_tokens:
                        tok0 = arg_tokens[0].strip().upper()
                        if tok0 in PIN_NAMES: pin = PIN_NAMES[tok0]
                        else: pin = eval_arg(tok0) & 7
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (9 << 4) | (pin & 7)

                elif sub_cmd in ("PROFILER_FILTER",):
                    flt = eval_arg(arg_tokens[0]) & 0xF if arg_tokens else 0
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (10 << 4) | (flt & 0xF)

                elif sub_cmd in ("PROFILER_ARM",):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (0 << 4) | 8

                elif sub_cmd in ("PROFILER_STOP",):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (0 << 4) | 9

                elif sub_cmd in ("PROFILER_RST", "PROFILER_RESET"):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (0 << 4) | 10

                elif sub_cmd in ("USB_CFG", "USB_CONFIG", "USB_ADDR"):
                    addr = eval_arg(arg_tokens[0]) & 0x7F if arg_tokens else 0
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (11 << 4) | (addr & 0xF)

                elif sub_cmd in ("USB_TX_TOKEN", "USB_TOKEN"):
                    PID_MAP = {"OUT": 1, "IN": 9, "SOF": 5, "SETUP": 13, "0": 0}
                    pid_val = 1
                    if arg_tokens:
                        tok = arg_tokens[0].strip().upper()
                        if tok in PID_MAP: pid_val = PID_MAP[tok]
                        else: pid_val = eval_arg(tok) & 0xF
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (12 << 4) | (pid_val & 0xF)

                elif sub_cmd in ("USB_TX_DATA", "USB_DATA_PKT"):
                    PID_DATA_MAP = {"DATA0": 3, "DATA1": 11, "DATA2": 7, "MDATA": 15, "0": 3, "1": 11}
                    pid_val = 3
                    if arg_tokens:
                        tok = arg_tokens[0].strip().upper()
                        if tok in PID_DATA_MAP: pid_val = PID_DATA_MAP[tok]
                        else: pid_val = eval_arg(tok) & 0xF
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (13 << 4) | (pid_val & 0xF)

                elif sub_cmd in ("USB_SIE_EN", "USB_ENABLE"):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (0 << 4) | 11

                elif sub_cmd in ("USB_SIE_DIS", "USB_DISABLE"):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (0 << 4) | 12

                elif sub_cmd in ("USB_SEND_ACK", "USB_ACK"):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (0 << 4) | 13

                elif sub_cmd in ("USB_SEND_NAK", "USB_NAK"):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (0 << 4) | 14

                elif sub_cmd in ("USB_SEND_STALL", "USB_STALL"):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (0 << 4) | 15

                elif sub_cmd in ("BIST_DIS", "BIST_DISABLE"):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (14 << 4) | 0

                elif sub_cmd in ("BIST_LOOP", "BIST_LOOPBACK"):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (14 << 4) | 1

                elif sub_cmd in ("BIST_SPLIT", "BIST_CROSSBAR"):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (14 << 4) | 2

                elif sub_cmd in ("BIST_JITTER", "BIST_STRESS"):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (14 << 4) | 3

                elif sub_cmd in ("BIST_START", "BIST_EN"):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (14 << 4) | 4

                elif sub_cmd in ("BIST_STOP",):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (14 << 4) | 5

                elif sub_cmd in ("BIST_RST", "BIST_RESET"):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (14 << 4) | 6

                elif sub_cmd in ("BIST_PASS",):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (14 << 4) | 7

                elif sub_cmd in ("BIST_FAIL",):
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (14 << 4) | 8

                elif sub_cmd in ("BIST_STAGE",):
                    stage_val = eval_arg(arg_tokens[0]) & 0xF if arg_tokens else 1
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (15 << 4) | (stage_val & 0xF)

                elif sub_cmd in ("BIST_CFG", "BIST_CONFIG"):
                    mode_val = eval_arg(arg_tokens[0]) & 0x3 if arg_tokens else 1
                    word = (0xF << 12) | (1 << 10) | (0 << 8) | (14 << 4) | (mode_val & 0x3)

                elif sub_cmd in ("READ", "STATUS"):
                    if any("PROFILER_TMIN_L" in a.upper() or "TMIN_L" in a.upper() or "TMIN_LO" in a.upper() for a in arg_tokens):
                        word = (0xF << 12) | (2 << 10) | (3 << 8) | (1 << 7) | (0 << 5)
                    elif any("PROFILER_TMIN_H" in a.upper() or "TMIN_H" in a.upper() or "TMIN_HI" in a.upper() for a in arg_tokens):
                        word = (0xF << 12) | (2 << 10) | (3 << 8) | (1 << 7) | (1 << 5)
                    elif any("PROFILER_EDGES" in a.upper() or "EDGES" in a.upper() for a in arg_tokens):
                        word = (0xF << 12) | (2 << 10) | (3 << 8) | (1 << 7) | (3 << 5)
                    elif any("PROFILER" in a.upper() for a in arg_tokens):
                        word = (0xF << 12) | (2 << 10) | (3 << 8) | (1 << 7) | (2 << 5)
                    elif any("USB_STATUS" in a.upper() or "USB_STAT" in a.upper() for a in arg_tokens):
                        word = (0xF << 12) | (2 << 10) | (3 << 8) | (0 << 7) | (1 << 4) | (0 << 5)
                    elif any("USB_TOKEN" in a.upper() for a in arg_tokens):
                        word = (0xF << 12) | (2 << 10) | (3 << 8) | (0 << 7) | (1 << 4) | (1 << 5)
                    elif any("USB_DATA" in a.upper() or "USB_RX" in a.upper() for a in arg_tokens):
                        word = (0xF << 12) | (2 << 10) | (3 << 8) | (0 << 7) | (1 << 4) | (2 << 5)
                    elif any("USB_ADDR" in a.upper() for a in arg_tokens):
                        word = (0xF << 12) | (2 << 10) | (3 << 8) | (0 << 7) | (1 << 4) | (3 << 5)
                    elif any("BIST_STATUS" in a.upper() or "BIST_STAT" in a.upper() for a in arg_tokens):
                        word = (0xF << 12) | (2 << 10) | (3 << 8) | (1 << 3) | 0
                    elif any("BIST_PASS" in a.upper() for a in arg_tokens):
                        word = (0xF << 12) | (2 << 10) | (3 << 8) | (1 << 3) | 1
                    elif any("BIST_FAIL" in a.upper() for a in arg_tokens):
                        word = (0xF << 12) | (2 << 10) | (3 << 8) | (1 << 3) | 2
                    elif any("BIST_VEC" in a.upper() or "BIST_VECTORS" in a.upper() or "BIST_COUNT" in a.upper() for a in arg_tokens):
                        word = (0xF << 12) | (2 << 10) | (3 << 8) | (1 << 3) | 3
                    elif any("GLITCH" in a.upper() or "MITM" in a.upper() for a in arg_tokens):
                        word = (0xF << 12) | (2 << 10) | (2 << 8) | (0 << 6) | (1 << 5)
                    elif any("I2C_ADDR" in a.upper() or "ADDR" in a.upper() for a in arg_tokens):
                        word = (0xF << 12) | (2 << 10) | (3 << 8)
                    elif any("I2C" in a.upper() for a in arg_tokens):
                        word = (0xF << 12) | (2 << 10) | (1 << 8)
                    elif any("JTAG" in a.upper() for a in arg_tokens):
                        word = (0xF << 12) | (2 << 10) | (2 << 8) | (1 << 6)
                    elif any("SWD_DATA" in a.upper() or "DATA" in a.upper() for a in arg_tokens):
                        b_idx = 0
                        for a in arg_tokens:
                            if "0" in a: b_idx = 0
                            elif "1" in a: b_idx = 1
                            elif "2" in a: b_idx = 2
                            elif "3" in a: b_idx = 3
                        word = (0xF << 12) | (2 << 10) | (2 << 8) | (3 << 6) | (b_idx << 4)
                    elif any("SWD" in a.upper() for a in arg_tokens):
                        word = (0xF << 12) | (2 << 10) | (2 << 8) | (2 << 6)
                    elif any("PAD" in a.upper() or "SNES" in a.upper() or "HIGH" in a.upper() for a in arg_tokens):
                        word = (0xF << 12) | (2 << 10) | (2 << 8)
                    else:
                        word = (0xF << 12) | (2 << 10) | (0 << 8)

                elif sub_cmd in ("PULSE_CFG", "PULSE", "PULSECFG"):
                    # ASSIST PULSE_CFG, MODE=NEOPIXEL / JOYBUS / OFF / CUSTOM
                    # Defaults:
                    pmode = 1       # 01 = Single-wire asymmetric
                    ppol = 0        # 0 = Active-High, 1 = Active-Low
                    pmsb = 0        # 0 = LSB, 1 = MSB
                    pprofile = 0    # 0 = None, 1 = NeoPixel, 2 = Joybus

                    for a in arg_tokens:
                        item = a.strip().upper()
                        if "=" in item:
                            k, v = item.split("=", 1)
                            k, v = k.strip(), v.strip()
                            if k in ("MODE", "PROFILE", "TYPE"):
                                if v in ("NEOPIXEL", "WS2812", "WS2812B", "WS2811", "PIXEL"):
                                    pprofile = 1
                                    pmode = 1
                                    ppol = 0
                                    pmsb = 1
                                elif v in ("JOYBUS", "N64", "GAMECUBE", "GC"):
                                    pprofile = 2
                                    pmode = 1
                                    ppol = 1
                                    pmsb = 0
                                elif v in ("OFF", "DISABLE", "NONE", "0"):
                                    pmode = 0
                                    pprofile = 0
                                else:
                                    pmode = eval_arg(v) & 3
                            elif k in ("POL", "POLARITY"):
                                ppol = 1 if v in ("LOW", "ACTIVE_LOW", "OD", "OPEN_DRAIN", "1") else 0
                            elif k in ("ORDER", "DIR", "MSB"):
                                pmsb = 1 if v in ("MSB", "MSB_FIRST", "1") else 0
                        else:
                            if item in ("NEOPIXEL", "WS2812", "WS2812B", "WS2811", "PIXEL"):
                                pprofile = 1
                                pmode = 1
                                ppol = 0
                                pmsb = 1
                            elif item in ("JOYBUS", "N64", "GAMECUBE", "GC"):
                                pprofile = 2
                                pmode = 1
                                ppol = 1
                                pmsb = 0
                            elif item in ("OFF", "DISABLE", "NONE"):
                                pmode = 0
                                pprofile = 0
                            elif item in ("MSB", "MSB_FIRST"):
                                pmsb = 1
                            elif item in ("LSB", "LSB_FIRST"):
                                pmsb = 0

                    word = (0xF << 12) | (3 << 10) | (0 << 8) | (pmode << 6) | (ppol << 5) | (pmsb << 4) | (pprofile << 2)

                elif sub_cmd in ("GAMEPAD_CFG", "GAMEPAD", "PAD_CFG", "PAD"):
                    # ASSIST GAMEPAD_CFG, ROLE=HOST/DEVICE, TYPE=NES/SNES, LATCH=cycles
                    role = 0      # 0 = Host (Console), 1 = Device (Gamepad)
                    snes_16b = 0  # 0 = NES 8-bit, 1 = SNES 16-bit
                    latch_t = 0   # 0 = default (60 cycles)

                    for a in arg_tokens:
                        item = a.strip().upper()
                        if "=" in item:
                            k, v = item.split("=", 1)
                            k, v = k.strip(), v.strip()
                            if k in ("ROLE", "MODE"):
                                role = 1 if v in ("DEVICE", "GAMEPAD", "CONTROLLER", "SLAVE", "1") else 0
                            elif k in ("TYPE", "CONSOLE", "PAD"):
                                snes_16b = 1 if v in ("SNES", "16", "16BIT", "SUPER") else 0
                            elif k in ("LATCH", "TIME", "PULSE"):
                                latch_t = eval_arg(v) & 0x3F
                        else:
                            if item in ("DEVICE", "GAMEPAD", "CONTROLLER", "SLAVE"):
                                role = 1
                            elif item in ("HOST", "CONSOLE", "MASTER"):
                                role = 0
                            elif item in ("SNES", "16", "16BIT", "SUPER"):
                                snes_16b = 1
                            elif item in ("NES", "8", "8BIT"):
                                snes_16b = 0

                    word = (0xF << 12) | (3 << 10) | (1 << 8) | (snes_16b << 7) | (role << 6) | latch_t

                elif sub_cmd in ("PULSE_TIME0", "TIME0", "PULSETIME0"):
                    cycles = eval_arg(arg_tokens[0]) if arg_tokens else 0
                    word = (0xF << 12) | (3 << 10) | (2 << 8) | (cycles & 0xFF)

                elif sub_cmd in ("PULSE_TIME1", "TIME1", "PULSETIME1"):
                    cycles = eval_arg(arg_tokens[0]) if arg_tokens else 0
                    word = (0xF << 12) | (3 << 10) | (3 << 8) | (cycles & 0xFF)

                elif sub_cmd in ("AUDIO_CFG", "AUDIO"):
                    # AUDIO_CFG <mode> [, PIN=<pin>] [, DIFF=<0|1>]
                    # mode: OFF=0, PCM=1, SYNTH=2, DIFF/HYBRID=3
                    amode = 1  # default PCM
                    apin = 2   # default cs_pin/2
                    adiff = 0
                    for a in arg_tokens:
                        item = a.strip().upper()
                        if "=" in item:
                            k, v = item.split("=", 1)
                            k, v = k.strip(), v.strip()
                            if k in ("MODE", "TYPE"):
                                if v in ("OFF", "0", "DISABLE"):
                                    amode = 0
                                elif v in ("PCM", "DAC", "1"):
                                    amode = 1
                                elif v in ("SYNTH", "APU", "CHIPTUNE", "2"):
                                    amode = 2
                                elif v in ("DIFF", "HYBRID", "3"):
                                    amode = 3
                            elif k in ("PIN", "GPIO"):
                                apin = eval_arg(v) & 7
                            elif k in ("DIFF", "BTL"):
                                adiff = 1 if eval_arg(v) else 0
                        else:
                            if item in ("OFF", "DISABLE"):
                                amode = 0
                            elif item in ("PCM", "DAC"):
                                amode = 1
                            elif item in ("SYNTH", "APU", "CHIPTUNE"):
                                amode = 2
                            elif item in ("DIFF", "HYBRID"):
                                amode = 3
                            elif item in ("DIFF_OUT", "DIFFERENTIAL"):
                                adiff = 1
                            else:
                                try:
                                    amode = eval_arg(item) & 3
                                except Exception:
                                    pass
                    if adiff:
                        amode = 3
                    pin_hi = (apin >> 2) & 1
                    pin_lo = apin & 3
                    word = (0xF << 12) | (0 << 10) | (pin_hi << 9) | (3 << 7) | (0 << 4) | (pin_lo << 2) | (amode & 3)

                elif sub_cmd in ("AUDIO_VOL", "VOL"):
                    vol = eval_arg(arg_tokens[0]) & 0xF if arg_tokens else 12
                    word = (0xF << 12) | (0 << 10) | (3 << 7) | (1 << 4) | (vol & 0xF)

                elif sub_cmd in ("AUDIO_SAMPLE", "SAMPLE"):
                    word = (0xF << 12) | (0 << 10) | (3 << 7) | (2 << 4)

                elif sub_cmd in ("AUDIO_DUTY", "DUTY"):
                    d0 = eval_arg(arg_tokens[0]) & 3 if len(arg_tokens) >= 1 else 2
                    d1 = eval_arg(arg_tokens[1]) & 3 if len(arg_tokens) >= 2 else d0
                    word = (0xF << 12) | (0 << 10) | (3 << 7) | (3 << 4) | ((d0 & 3) << 2) | (d1 & 3)

                elif sub_cmd in ("AUDIO_NOTE_LO", "NOTE_LO"):
                    voice = eval_arg(arg_tokens[0]) & 3 if arg_tokens else 0
                    word = (0xF << 12) | (0 << 10) | (3 << 7) | (4 << 4) | (voice & 3)

                elif sub_cmd in ("AUDIO_NOTE_HI", "NOTE_HI"):
                    voice = eval_arg(arg_tokens[0]) & 3 if arg_tokens else 0
                    word = (0xF << 12) | (0 << 10) | (3 << 7) | (5 << 4) | (voice & 3)

                elif sub_cmd in ("AUDIO_PLAY", "PLAY"):
                    PRESET_MAP = {
                        "OFF": 0, "NONE": 0, "0": 0,
                        "BEEP": 1, "1": 1,
                        "BLIP": 2, "2": 2,
                        "ERROR": 3, "3": 3,
                        "COIN": 4, "4": 4,
                        "LASER": 5, "5": 5,
                        "SIREN": 6, "6": 6,
                        "NOISE": 7, "7": 7,
                    }
                    preset = 1
                    if arg_tokens:
                        p_str = arg_tokens[0].strip().upper()
                        preset = PRESET_MAP.get(p_str, eval_arg(p_str) & 0xF if p_str.isdigit() else 1)
                    word = (0xF << 12) | (0 << 10) | (3 << 7) | (6 << 4) | (preset & 0xF)

                elif sub_cmd in ("AUDIO_STOP", "STOP_AUDIO"):
                    word = (0xF << 12) | (0 << 10) | (3 << 7) | (7 << 4)

                else:
                    raise AssemblerError(f"Line {line_num}: Unknown ASSIST sub-operation '{sub_cmd}'")

            assembled.append((addr, word, line))

        return assembled, labels


def assemble_file(filepath):
    with open(filepath, "r", encoding="utf-8") as f:
        source = f.read()
    asm = OmnibusAssembler()
    return asm.assemble(source)


def main():
    parser = argparse.ArgumentParser(description="OmniBus Microcode Assembler")
    parser.add_argument("input", help="Source assembly file (.asm)")
    parser.add_argument("-o", "--output", help="Output hex file (.hex)")
    parser.add_argument("-v", "--verilog", action="store_true", help="Print Verilog initial block")
    args = parser.parse_args()

    try:
        words, labels = assemble_file(args.input)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"Assembled {len(words)} instructions from {args.input}:")
    for addr, word, line in words:
        print(f"  [{addr:02d} | 0x{addr:02X}]: 0x{word:04X}  --  {line}")

    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            for addr, word, _ in words:
                f.write(f"@{addr:02X} {word:04X}\n")
        print(f"Wrote hex image to: {args.output}")

    if args.verilog:
        print("\n// Verilog initial block:")
        for addr, word, line in words:
            print(f"imem[{addr}] = 16'h{word:04X}; // {line}")


if __name__ == "__main__":
    main()
