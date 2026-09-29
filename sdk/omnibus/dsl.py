# =============================================================================
# File        : dsl.py
# Module      : omnibus.dsl
# Description : High-Level Declarative Protocol DSL & Timing Synthesizer (omnibus-cc).
# License     : MIT License
# =============================================================================

from enum import Enum
from typing import List, Optional, Dict, Any
import math


class Direction(Enum):
    INPUT = 0
    OUTPUT = 1
    OPEN_DRAIN = 2


class ClockEdge(Enum):
    RISING = 0
    FALLING = 1


class Pin:
    def __init__(self, index: int, direction: Direction = Direction.OUTPUT, idle: int = 1):
        self.index = index
        self.direction = direction
        self.idle = idle
        self._protocol: Optional["Protocol"] = None

    def _bind(self, protocol: "Protocol"):
        self._protocol = protocol

    def high(self, cycles: int = 0, ns: float = 0):
        delay = self._calc_delay(cycles, ns)
        delay_str = f" [{delay}]" if delay > 0 else ""
        self._protocol._emit(f"SET uio[{self.index}], 1{delay_str}")

    def low(self, cycles: int = 0, ns: float = 0):
        delay = self._calc_delay(cycles, ns)
        delay_str = f" [{delay}]" if delay > 0 else ""
        self._protocol._emit(f"SET uio[{self.index}], 0{delay_str}")

    def shift_out(self, source: str = "OSR", count: int = 1, delay_cycles: int = 0):
        delay_str = f" [{delay_cycles}]" if delay_cycles > 0 else ""
        self._protocol._emit(f"OUT uio[{self.index}], {count}{delay_str}")

    def shift_in(self, destination: str = "ISR", count: int = 1, delay_cycles: int = 0):
        delay_str = f" [{delay_cycles}]" if delay_cycles > 0 else ""
        self._protocol._emit(f"IN uio[{self.index}], {count}{delay_str}")

    def wait_for(self, value: int, timeout_cycles: int = 1000):
        self._protocol._emit(f"WAIT uio[{self.index}], {value} [{timeout_cycles}]")

    def _calc_delay(self, cycles: int, ns: float) -> int:
        if cycles > 0:
            return cycles
        if ns > 0 and self._protocol:
            return max(0, round(ns * 1e-9 * self._protocol.clock_freq_hz) - 1)
        return 0


class _LoopContext:
    def __init__(self, protocol: "Protocol", count: int, lc: int = 0):
        self.protocol = protocol
        self.count = count
        self.lc = lc
        self.loop_id = protocol._next_loop_id()

    def __enter__(self):
        self.protocol._emit(f"SET_LC LC{self.lc}, {self.count}")
        self.protocol._emit(f"loop_{self.loop_id}:")
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.protocol._emit(f"DJNZ LC{self.lc}, loop_{self.loop_id}")


class Protocol:
    """Base class for Declarative Protocol Synthesis."""

    clock_freq_hz: int = 50_000_000

    def __init__(self):
        self._instructions: List[str] = []
        self._loop_counter = 0

        # Bind declared pin attributes
        for attr_name in dir(self.__class__):
            attr = getattr(self.__class__, attr_name)
            if isinstance(attr, Pin):
                attr._bind(self)

    def _next_loop_id(self) -> int:
        self._loop_counter += 1
        return self._loop_counter

    def _emit(self, asm_line: str):
        self._instructions.append(asm_line)

    def delay(self, cycles: int = 0, ns: float = 0, us: float = 0):
        total_delay = cycles
        if ns > 0:
            total_delay += max(0, round(ns * 1e-9 * self.clock_freq_hz) - 1)
        if us > 0:
            total_delay += max(0, round(us * 1e-6 * self.clock_freq_hz) - 1)
        if total_delay > 0:
            self._emit(f"NOP [{total_delay}]")

    def pull_tx(self, block: bool = True):
        self._emit(f"PULL {'BLOCK' if block else ''}".strip())

    def push_rx(self, block: bool = False):
        self._emit(f"PUSH {'BLOCK' if block else ''}".strip())

    def loop(self, count: int, lc: int = 0) -> _LoopContext:
        return _LoopContext(self, count, lc)

    @classmethod
    def compile(cls, output_file: Optional[str] = None) -> str:
        """Synthesizes protocol class methods into cycle-exact microcode."""
        instance = cls()
        instance._emit(f"; Synthesized Protocol: {cls.__name__}")
        instance._emit(f".clock {instance.clock_freq_hz}")
        instance._emit("")
        instance._emit("main:")

        base_methods = {"compile", "delay", "pull_tx", "push_rx", "loop", "_emit", "_next_loop_id"}
        for name in dir(instance):
            if not name.startswith("_") and name not in base_methods:
                attr = getattr(instance, name)
                if callable(attr) and not isinstance(attr, type):
                    attr()

        code = "\n".join(instance._instructions)
        if output_file:
            with open(output_file, "w", encoding="utf-8") as f:
                f.write(code + "\n")
        return code
