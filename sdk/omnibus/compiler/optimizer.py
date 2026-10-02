# =============================================================================
# File        : optimizer.py
# Module      : omnibus.compiler.optimizer
# Description : Multi-Pass Peephole Optimizer and Code Density Packer for Omni-C.
#               Supports Optimization Levels -O0 (None), -O1 (Standard), -O2 (Aggressive).
# License     : MIT License
# =============================================================================

import re
from typing import List, Tuple, Set, Dict


class PeepholeOptimizer:
    """Multi-pass optimizer for OmniBus 16-bit microcode and assembly."""

    SIDECAR_INSTRUCTIONS = {
        "NOP", "SET", "WAIT", "OUT", "IN", "CFG_OD", "PINMAP"
    }

    LEVEL_0 = 0  # No optimizations
    LEVEL_1 = 1  # Standard peephole (delays, self moves, dead code, next jumps)
    LEVEL_2 = 2  # Aggressive (inverse moves, consecutive SETs, jump chains, unused labels)

    def __init__(self, level: int = 1, optimize_delays: bool = True, eliminate_dead_code: bool = True):
        self.level = level
        self.optimize_delays = optimize_delays
        self.eliminate_dead_code = eliminate_dead_code

    def optimize(self, asm_lines: List[str]) -> List[str]:
        if self.level == 0:
            return [line.strip() for line in asm_lines if line.strip()]

        lines = [line.strip() for line in asm_lines if line.strip()]

        # Multi-pass optimization loop until convergence or max iterations
        for _ in range(5):
            prev_len = len(lines)

            if self.optimize_delays:
                lines = self._coalesce_sidecar_delays(lines)
                if self.level >= 2:
                    lines = self._fold_consecutive_nops(lines)

            lines = self._eliminate_redundant_moves(lines)

            if self.level >= 2:
                lines = self._eliminate_inverse_moves(lines)
                lines = self._eliminate_redundant_set_pins(lines)

            if self.eliminate_dead_code:
                lines = self._eliminate_dead_code_after_returns(lines)

            lines = self._eliminate_jumps_to_next_label(lines)

            if self.level >= 2:
                lines = self._compress_jump_chains(lines)
                lines = self._eliminate_unused_labels(lines)

            if len(lines) == prev_len:
                break

        return lines

    def _coalesce_sidecar_delays(self, lines: List[str]) -> List[str]:
        """Merges standalone NOP [delay] into previous compatible instruction."""
        optimized: List[str] = []
        i = 0
        while i < len(lines):
            curr = lines[i]

            # If current line is a label or comment, keep it
            if curr.endswith(":") or curr.startswith(";"):
                optimized.append(curr)
                i += 1
                continue

            # Look ahead for NOP [delay]
            if i + 1 < len(lines):
                nxt = lines[i + 1]
                nop_match = re.match(r"^NOP\s+\[(.*?)\]", nxt, re.IGNORECASE)
                if nop_match:
                    delay_val = nop_match.group(1).strip()
                    # Check if current instruction does not already have a sidecar delay bracket
                    if "[" not in curr:
                        opcode = curr.split()[0].upper()
                        if opcode in self.SIDECAR_INSTRUCTIONS:
                            merged = f"{curr} [{delay_val}]"
                            optimized.append(merged)
                            i += 2  # Skip both
                            continue

            optimized.append(curr)
            i += 1

        return optimized

    def _fold_consecutive_nops(self, lines: List[str]) -> List[str]:
        """Coalesces consecutive NOP [A] and NOP [B] into NOP [min(31, A+B)] when numeric."""
        optimized: List[str] = []
        i = 0
        while i < len(lines):
            curr = lines[i]
            nop_curr = re.match(r"^NOP\s+\[(\d+)\]", curr, re.IGNORECASE)

            if nop_curr and i + 1 < len(lines):
                nxt = lines[i + 1]
                nop_nxt = re.match(r"^NOP\s+\[(\d+)\]", nxt, re.IGNORECASE)
                if nop_nxt:
                    d1 = int(nop_curr.group(1))
                    d2 = int(nop_nxt.group(1))
                    if d1 + d2 <= 31:
                        optimized.append(f"NOP [{d1 + d2}]")
                        i += 2
                        continue

            optimized.append(curr)
            i += 1
        return optimized

    def _eliminate_redundant_moves(self, lines: List[str]) -> List[str]:
        """Eliminates redundant register moves such as MOV X, X."""
        optimized: List[str] = []
        for line in lines:
            mov_self = re.match(r"^MOV\s+([a-zA-Z0-9_]+)\s*,\s*([a-zA-Z0-9_]+)", line, re.IGNORECASE)
            if mov_self:
                dst = mov_self.group(1).lower()
                src = mov_self.group(2).lower()
                if dst == src:
                    continue  # Skip redundant self move
            optimized.append(line)
        return optimized

    def _eliminate_inverse_moves(self, lines: List[str]) -> List[str]:
        """Eliminates MOV B, A immediately following MOV A, B."""
        optimized: List[str] = []
        i = 0
        while i < len(lines):
            curr = lines[i]
            mov_curr = re.match(r"^MOV\s+([a-zA-Z0-9_]+)\s*,\s*([a-zA-Z0-9_]+)", curr, re.IGNORECASE)

            if mov_curr and i + 1 < len(lines):
                nxt = lines[i + 1]
                mov_nxt = re.match(r"^MOV\s+([a-zA-Z0-9_]+)\s*,\s*([a-zA-Z0-9_]+)", nxt, re.IGNORECASE)
                if mov_nxt:
                    dst1, src1 = mov_curr.group(1).lower(), mov_curr.group(2).lower()
                    dst2, src2 = mov_nxt.group(1).lower(), mov_nxt.group(2).lower()
                    if dst1 == src2 and src1 == dst2:
                        # Keep the first move, discard the redundant inverse move
                        optimized.append(curr)
                        i += 2
                        continue

            optimized.append(curr)
            i += 1
        return optimized

    def _eliminate_redundant_set_pins(self, lines: List[str]) -> List[str]:
        """Eliminates consecutive identical SET pin, val instructions."""
        optimized: List[str] = []
        i = 0
        while i < len(lines):
            curr = lines[i]
            set_curr = re.match(r"^SET\s+([a-zA-Z0-9_\[\]]+)\s*,\s*([01])(?:\s*\[.*?\])?", curr, re.IGNORECASE)

            if set_curr and "[" not in curr and i + 1 < len(lines):
                nxt = lines[i + 1]
                set_nxt = re.match(r"^SET\s+([a-zA-Z0-9_\[\]]+)\s*,\s*([01])(?:\s*\[.*?\])?", nxt, re.IGNORECASE)
                if set_nxt and "[" not in nxt:
                    pin1, val1 = set_curr.group(1).lower(), set_curr.group(2)
                    pin2, val2 = set_nxt.group(1).lower(), set_nxt.group(2)
                    if pin1 == pin2 and val1 == val2:
                        # Discard duplicate SET without delay
                        optimized.append(curr)
                        i += 2
                        continue

            optimized.append(curr)
            i += 1
        return optimized

    def _eliminate_dead_code_after_returns(self, lines: List[str]) -> List[str]:
        """Removes unreachable instructions after unconditional JMP or RET until next label."""
        optimized: List[str] = []
        unreachable = False

        for line in lines:
            if line.endswith(":") or line.startswith("."):
                unreachable = False
                optimized.append(line)
                continue

            if line.startswith(";"):
                if not unreachable:
                    optimized.append(line)
                continue

            if unreachable:
                continue

            optimized.append(line)

            clean = line.split(";")[0].strip().upper()
            if clean == "RET" or (clean.startswith("JMP ") and not any(cond in clean for cond in [" JZ ", " JNZ ", " JC ", " JNC "])):
                unreachable = True

        return optimized

    def _eliminate_jumps_to_next_label(self, lines: List[str]) -> List[str]:
        """Removes JMP label if label: is immediately the next non-comment line."""
        optimized: List[str] = []
        i = 0
        while i < len(lines):
            curr = lines[i]
            jmp_match = re.match(r"^JMP\s+([a-zA-Z0-9_]+)", curr, re.IGNORECASE)
            if jmp_match:
                target_label = jmp_match.group(1).strip()
                next_idx = i + 1
                while next_idx < len(lines) and lines[next_idx].startswith(";"):
                    next_idx += 1
                if next_idx < len(lines) and lines[next_idx].strip() == f"{target_label}:":
                    i += 1
                    continue

            optimized.append(curr)
            i += 1
        return optimized

    def _compress_jump_chains(self, lines: List[str]) -> List[str]:
        """Compresses JMP L1 where L1: contains JMP L2 into JMP L2."""
        label_targets: Dict[str, str] = {}
        for i, line in enumerate(lines):
            if line.endswith(":"):
                lbl = line[:-1].strip()
                next_idx = i + 1
                while next_idx < len(lines) and lines[next_idx].startswith(";"):
                    next_idx += 1
                if next_idx < len(lines):
                    jmp_match = re.match(r"^JMP\s+([a-zA-Z0-9_]+)", lines[next_idx], re.IGNORECASE)
                    if jmp_match:
                        label_targets[lbl] = jmp_match.group(1).strip()

        if not label_targets:
            return lines

        optimized: List[str] = []
        for line in lines:
            jmp_match = re.match(r"^(JMP(?:_[A-Z]+)?\s+)([a-zA-Z0-9_]+)(.*)$", line, re.IGNORECASE)
            if jmp_match:
                prefix = jmp_match.group(1)
                target = jmp_match.group(2)
                suffix = jmp_match.group(3)
                if target in label_targets and label_targets[target] != target:
                    resolved = label_targets[target]
                    line = f"{prefix}{resolved}{suffix}"
            optimized.append(line)

        return optimized

    def _eliminate_unused_labels(self, lines: List[str]) -> List[str]:
        """Removes compiler-generated labels that are never referenced by any JMP or CALL."""
        referenced_labels: Set[str] = set()

        for line in lines:
            clean = line.split(";")[0].strip()
            # Match JMP label, CALL label, DJNZ label
            refs = re.findall(r"\b(?:JMP|CALL|DJNZ)\s+(?:[A-Z]+\s+)?([a-zA-Z0-9_]+)", clean, re.IGNORECASE)
            for r in refs:
                referenced_labels.add(r.strip())

        optimized: List[str] = []
        for line in lines:
            if line.endswith(":") and not line.startswith(";"):
                lbl = line[:-1].strip()
                # Keep entry points, main, or referenced labels
                if lbl.startswith("__") or lbl in ["main", "entry", "_entry"] or lbl in referenced_labels:
                    optimized.append(line)
                else:
                    # Unused internal label, omit
                    continue
            else:
                optimized.append(line)

        return optimized
