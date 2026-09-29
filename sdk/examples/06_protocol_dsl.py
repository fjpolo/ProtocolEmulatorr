#!/usr/bin/env python3
"""
OmniBus Example 06: Declarative Protocol DSL (omnibus-cc)
Compiles a high-level protocol timing specification directly into cycle-exact microcode.
"""

import os
import sys

# Ensure omnibus SDK is in python path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from omnibus.dsl import Protocol, Pin, Direction

class SPIMaster(Protocol):
    """Declarative SPI Mode 0 Full-Duplex Master Protocol."""
    clock_freq_hz = 50_000_000

    mosi = Pin(index=0, direction=Direction.OUTPUT, idle=0)
    miso = Pin(index=1, direction=Direction.INPUT)
    sck  = Pin(index=2, direction=Direction.OUTPUT, idle=0)
    cs_n = Pin(index=3, direction=Direction.OUTPUT, idle=1)

    def transfer_byte(self):
        # Assert Chip Select Low
        self.cs_n.low(ns=100)

        # Shift 8 bits with cycle-accurate SCK toggling
        with self.loop(count=8):
            self.mosi.shift_out(source="OSR", count=1)
            self.sck.low(cycles=2)
            self.sck.high(cycles=1)
            self.miso.shift_in(destination="ISR", count=1)
            self.sck.high(cycles=2)

        # Deassert Chip Select High
        self.cs_n.high(ns=100)
        self.push_rx()

def main():
    print("[*] Compiling SPIMaster protocol via Declarative DSL...")
    asm_output = SPIMaster.compile()
    print("\n--- Synthesized OmniBus Microcode ---")
    print(asm_output)
    print("-------------------------------------")

if __name__ == "__main__":
    main()
