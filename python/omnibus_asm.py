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
    "NOP":  0x0,
    "OUT":  0x1,
    "IN":   0x2,
    "SET":  0x3,
    "WAIT": 0x4,
    "JMP":  0x8,
    "PULL": 0x9,
    "PUSH": 0xA,
    "CALL": 0xC,  # Push pc+1 to call stack, jump to target
    "RET":  0xD,  # Pop return address from call stack
}

# Task 07: SPI pin selector for SET/WAIT [11:10]
# 0=MOSI/TX (backward compat), 1=SCK, 2=CS_n, 3=MOSI alias
PIN_NAMES = {
    "MOSI": 0, "TX": 0, "MISO": 0, "RX": 0,  # pin 0 — backward compat
    "SCK":  1,                                   # pin 1 — SPI clock
    "CS":   2, "CS_N": 2, "CSN": 2,             # pin 2 — chip-select (active-low)
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
                    if len(tokens) == 2:
                        # IN delay — 8-bit default (bit_count=0)
                        bit_count = 0
                        delay = eval_arg(tokens[1])
                    elif len(tokens) >= 3:
                        # IN N, delay
                        n = eval_arg(tokens[1])
                        bit_count = 0 if n == 8 else (n & 0x7)  # 8->0 (compat), 1-7->N
                        delay = eval_arg(tokens[2])
                    else:
                        bit_count, delay = 0, 0
                    word = (opcode_val << 12) | (bit_count << 9) | (delay & 0x1FF)
                else:  # OUT
                    # Forms:
                    #   OUT delay           (pin=0, 8-bit LSB-first, backward compat)
                    #   OUT 8, delay        (same)
                    #   OUT SCK, delay      (pin=1, 8-bit MSB-first + auto-SCK toggle)
                    # Detect pin name as first arg: if it is in PIN_NAMES -> SCK mode
                    def _out_pin(s):
                        s = s.strip().upper()
                        return PIN_NAMES.get(s, None)

                    if len(tokens) >= 3 and _out_pin(tokens[1]) is not None:
                        pin_id = _out_pin(tokens[1])
                        delay  = eval_arg(tokens[2]) & 0x1FF
                    elif len(tokens) == 2:
                        pin_id, delay = 0, eval_arg(tokens[1])
                    elif len(tokens) >= 3:
                        pin_id, delay = 0, eval_arg(tokens[2])
                    else:
                        pin_id, delay = 0, 0
                    word = (opcode_val << 12) | (pin_id << 10) | (delay & 0x1FF)

            elif op in ("SET", "WAIT"):
                # Two forms:
                #   SET val, delay         (old 2-arg: pin=0=MOSI, backward compat)
                #   SET pin, val, delay    (new 3-arg: explicit pin selector)
                # pin can be a numeric ID (0-3) or a name: MOSI/TX/SCK/CS/MISO/RX
                def resolve_pin(s):
                    s = s.strip().upper()
                    if s in PIN_NAMES:
                        return PIN_NAMES[s]
                    return int(s, 0) & 0x3

                if len(tokens) >= 4:
                    # 3-arg form: SET pin, val, delay
                    pin_id  = resolve_pin(tokens[1])
                    pin_val = eval_arg(tokens[2]) & 0x1
                    delay   = eval_arg(tokens[3]) & 0x1FF
                elif len(tokens) == 3:
                    # 2-arg form: SET val, delay  (pin=0, backward compat)
                    pin_id  = 0
                    pin_val = eval_arg(tokens[1]) & 0x1
                    delay   = eval_arg(tokens[2]) & 0x1FF
                else:
                    raise AssemblerError(f"Line {line_num}: {op} requires 'val, delay' or 'pin, val, delay'")
                word = (opcode_val << 12) | (pin_id << 10) | (pin_val << 9) | delay

            elif op == "JMP":
                # JMP target
                if len(tokens) < 2:
                    raise AssemblerError(f"Line {line_num}: JMP requires target address or label")
                target = eval_arg(tokens[1]) & 0x1F
                word = (opcode_val << 12) | target

            elif op in ("PUSH", "PULL"):
                word = opcode_val << 12

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
