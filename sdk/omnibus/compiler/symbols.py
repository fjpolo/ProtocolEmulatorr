# =============================================================================
# File        : symbols.py
# Module      : omnibus.compiler.symbols
# Description : Symbol Table, Scope, and Register Allocation for Omni-C Compiler.
# License     : MIT License
# =============================================================================

from typing import Dict, List, Optional, Set, Any


class Symbol:
    def __init__(self, name: str, sym_type: str, reg: Optional[str] = None,
                 is_const: bool = False, const_value: Any = None):
        self.name = name
        self.sym_type = sym_type  # 'uint8_t', 'reg', 'func', 'const'
        self.reg = reg            # 'acc', 'r0'..'r7', 'osr', 'isr', 'lc0', 'lc1'
        self.is_const = is_const
        self.const_value = const_value

    def __repr__(self) -> str:
        return f"Symbol({self.name}, {self.sym_type}, reg={self.reg}, const={self.const_value})"


class Scope:
    def __init__(self, parent: Optional["Scope"] = None):
        self.parent = parent
        self.symbols: Dict[str, Symbol] = {}

    def define(self, symbol: Symbol):
        self.symbols[symbol.name] = symbol

    def lookup(self, name: str) -> Optional[Symbol]:
        if name in self.symbols:
            return self.symbols[name]
        if self.parent:
            return self.parent.lookup(name)
        return None


class RegisterAllocator:
    """Allocates hardware registers (R0-R7, ACC) to local and global variables."""

    ALL_REGISTERS = ["r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7"]
    SPECIAL_REGISTERS = {"acc", "osr", "isr", "lc0", "lc1", "bank"}

    def __init__(self):
        self.free_registers = list(self.ALL_REGISTERS)
        self.allocated: Dict[str, str] = {}  # var_name -> reg_name

    def allocate(self, var_name: str, reg_hint: Optional[str] = None) -> str:
        if var_name in self.allocated:
            return self.allocated[var_name]

        # If user explicitly requested a register (e.g. reg r2 x;)
        if reg_hint:
            hint_lower = reg_hint.lower()
            if hint_lower in self.SPECIAL_REGISTERS:
                self.allocated[var_name] = hint_lower
                return hint_lower
            if hint_lower in self.free_registers:
                self.free_registers.remove(hint_lower)
                self.allocated[var_name] = hint_lower
                return hint_lower
            elif hint_lower in self.ALL_REGISTERS:
                self.allocated[var_name] = hint_lower
                return hint_lower

        # Allocate next free general register
        if self.free_registers:
            reg = self.free_registers.pop(0)
            self.allocated[var_name] = reg
            return reg

        # Fallback to R7 or ACC with register reuse
        return "r7"

    def free(self, var_name: str):
        if var_name in self.allocated:
            reg = self.allocated.pop(var_name)
            if reg in self.ALL_REGISTERS and reg not in self.free_registers:
                self.free_registers.append(reg)
                self.free_registers.sort()
