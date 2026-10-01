# =============================================================================
# File        : optimizer.py
# Module      : omnibus.compiler.optimizer
# Description : Peephole Optimizer and Sidecar Delay Packing for Omni-C Compiler.
# License     : MIT License
# =============================================================================

import re
from typing import List, Tuple


class PeepholeOptimizer:
    """Optimizes emitted OmniBus assembly instructions."""

    SIDECAR_INSTRUCTIONS = {
        "NOP", "SET", "WAIT", "OUT", "IN", "CFG_OD", "PINMAP"
    }

    def __init__(self, optimize_delays: bool = True, eliminate_dead_code: bool = True):
        self.optimize_delays = optimize_delays
        self.eliminate_dead_code = eliminate_dead_code

    def optimize(self, asm_lines: List[str]) -> List[str]:
        lines = [line.strip() for line in asm_lines if line.strip()]

        if self.optimize_delays:
            lines = self._coalesce_sidecar_delays(lines)

        lines = self._eliminate_redundant_moves(lines)

        if self.eliminate_dead_code:
            lines = self._eliminate_dead_code_after_returns(lines)

        lines = self._eliminate_jumps_to_next_label(lines)
        return lines

    def _coalesce_sidecar_delays(self, lines: List[str]) -> List[str]:
        """Merges standalone NOP [delay] or delay into previous compatible instruction."""
        optimized: List[str] = []
        i = 0
        while i < len(lines):
            curr = lines[i]

            # If current line is a label or comment, keep it
            if curr.endswith(":") or curr.startswith(";"):
                optimized.append(curr)
                i += 1
                continue

            # Check if next instruction is NOP [delay]
            if i + 1 < len(lines):
                nxt = lines[i + 1]
                # Match NOP [N] or NOP [time]
                nop_match = re.match(r"^NOP\s+\[(.*?)\]", nxt, re.IGNORECASE)
                if nop_match:
                    delay_val = nop_match.group(1).strip()
                    # Check if current instruction does not already have a delay bracket
                    if "[" not in curr:
                        opcode = curr.split()[0].upper()
                        if opcode in self.SIDECAR_INSTRUCTIONS:
                            # Coalesce delay into current instruction
                            merged = f"{curr} [{delay_val}]"
                            optimized.append(merged)
                            i += 2  # Skip both
                            continue

            optimized.append(curr)
            i += 1

        return optimized

    def _eliminate_redundant_moves(self, lines: List[str]) -> List[str]:
        """Eliminates redundant register moves such as MOV acc, acc."""
        optimized: List[str] = []
        for line in lines:
            # Check MOV X, X
            mov_self = re.match(r"^MOV\s+([a-zA-Z0-9_]+)\s*,\s*([a-zA-Z0-9_]+)", line, re.IGNORECASE)
            if mov_self:
                dst = mov_self.group(1).lower()
                src = mov_self.group(2).lower()
                if dst == src:
                    continue  # Skip redundant self move

            optimized.append(line)
        return optimized

    def _eliminate_dead_code_after_returns(self, lines: List[str]) -> List[str]:
        """Removes unreachable instructions after unconditional JMP or RET until next label."""
        optimized: List[str] = []
        unreachable = False

        for line in lines:
            if line.endswith(":"):
                # Reached a label, code is now reachable
                unreachable = False
                optimized.append(line)
                continue

            if unreachable:
                # Discard unreachable code
                continue

            optimized.append(line)

            # Check if line is unconditional branch or return
            clean = line.split(";")[0].strip().upper()
            if clean == "RET" or clean.startswith("JMP ") and not any(cond in clean for cond in [" JZ ", " JNZ ", " JC ", " JNC "]):
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
                # Look ahead for next non-comment line
                next_idx = i + 1
                while next_idx < len(lines) and lines[next_idx].startswith(";"):
                    next_idx += 1
                if next_idx < len(lines) and lines[next_idx].strip() == f"{target_label}:":
                    # Skip the redundant JMP
                    i += 1
                    continue

            optimized.append(curr)
            i += 1
        return optimized
