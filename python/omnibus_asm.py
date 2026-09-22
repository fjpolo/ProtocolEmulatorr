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
    "CALL":   0xC,  # Push pc+1 to call stack, jump to target
    "RET":    0xD,  # Pop return address from call stack
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

            parsed_instructions.append((line_num, current_addr, line))
            current_addr += 1
            if current_addr > 32:
                raise AssemblerError(f"Program exceeds 32 words of IMEM at line {line_num}")

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
                    #   IN delay            (mode=0, 8-bit default LSB-first UART)
                    #   IN N, delay         (mode=0, variable N-bit LSB-first UART, N=8 -> 0)
                    #   IN SCK, delay       (mode=1, 8-bit MSB-first SPI Master Read + auto-SCK toggle)
                    #   IN SDA, delay       (mode=3, 8-bit MSB-first I2C Master Read + auto-SCL toggle)
                    def _in_mode(s):
                        s = s.strip().upper()
                        if s in ("SCK", "SCLK", "CLK", "SPI"):
                            return 1
                        elif s in ("SDA", "SCL", "I2C"):
                            return 3
                        return 0

                    if len(tokens) >= 3 and _in_mode(tokens[1]) != 0:
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
                    #   OUT SDA, delay      (mode=3, 8-bit MSB-first I2C + auto-SCL toggle)
                    def _out_mode(s):
                        s = s.strip().upper()
                        if s in ("SCK", "SCLK", "CLK"):
                            return 1
                        elif s in ("SDA", "SCL", "I2C"):
                            return 3
                        return 0

                    if len(tokens) >= 3 and _out_mode(tokens[1]) != 0:
                        mode  = _out_mode(tokens[1])
                        delay = eval_arg(tokens[2]) & 0x1FF
                    elif len(tokens) == 2:
                        mode, delay = 0, eval_arg(tokens[1]) & 0x1FF
                    elif len(tokens) >= 3:
                        mode, delay = 0, eval_arg(tokens[2]) & 0x1FF
                    else:
                        mode, delay = 0, 0
                    word = (opcode_val << 12) | (mode << 10) | (delay & 0x1FF)

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
                    target = eval_arg(tokens[1]) & 0x1F
                else:
                    if len(tokens) >= 3:
                        lc_sel = parse_lc(tokens[1])
                        target = eval_arg(tokens[2]) & 0x1F
                    elif len(tokens) == 2:
                        lc_sel = 0
                        target = eval_arg(tokens[1]) & 0x1F
                    else:
                        raise AssemblerError(f"Line {line_num}: DJNZ requires [LCx,] target")
                # Format: [15:12]=0x7, [11]=lc_sel, [10]=0, [4:0]=target
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
                    "ALWAYS": 0,
                    "TX_VALID": 1,
                    "TX_RDY": 1,
                    "TX_READY": 1,
                    "TX_EMPTY": 2,
                    "NO_TX": 2,
                    "RX_FULL": 3,
                    "RX_READY": 4,
                    "RX_RDY": 4,
                    "NOT_FULL": 4,
                    "PIN_HI": 5,
                    "PIN_HIGH": 5,
                    "PIN_1": 5,
                    "PIN_LO": 6,
                    "PIN_LOW": 6,
                    "PIN_0": 6,
                }
                if len(tokens) >= 3:
                    cond_name = tokens[1].strip().upper()
                    if cond_name not in CONDITIONS:
                        raise AssemblerError(f"Line {line_num}: Unknown JMP condition '{tokens[1]}'")
                    cond = CONDITIONS[cond_name]
                    target = eval_arg(tokens[2]) & 0x1F
                elif len(tokens) == 2:
                    cond = 0
                    target = eval_arg(tokens[1]) & 0x1F
                else:
                    raise AssemblerError(f"Line {line_num}: JMP requires target address or label")
                word = (opcode_val << 12) | (cond << 8) | target

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
                target = eval_arg(tokens[1]) & 0x1F
                word = (opcode_val << 12) | target

            elif op == "RET":
                # RET — no operands
                word = opcode_val << 12

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
