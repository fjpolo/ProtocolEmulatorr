#!/usr/bin/env python3
"""
Unit tests for the OmniBus Software SDK.
"""

import unittest
import os
import sys

# Ensure SDK is on python path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from omnibus.assembler import assemble, assemble_file
from omnibus.dsl import Protocol, Pin, Direction

class TestOmniBusSDK(unittest.TestCase):
    def setUp(self):
        self.examples_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "examples"))

    def test_assemble_examples(self):
        asm_files = [
            "01_uart_hello.asm",
            "02_i2c_sensor_read.asm",
            "03_ws2812_rainbow.asm",
            "04_mitm_flash_fuzzer.asm"
        ]
        for fname in asm_files:
            fpath = os.path.join(self.examples_dir, fname)
            words = assemble_file(fpath)
            self.assertGreater(len(words), 0, f"Failed assembling {fname}")
            self.assertLessEqual(len(words), 128, f"{fname} exceeds 128-word IMEM capacity")
            print(f"[+] Assembled {fname}: {len(words)} words.")

    def test_protocol_dsl_synthesis(self):
        class TestUART(Protocol):
            tx = Pin(index=0, direction=Direction.OUTPUT, idle=1)
            def send(self):
                self.tx.low(cycles=433)
                self.tx.shift_out(source="OSR", count=8, delay_cycles=433)
                self.tx.high(cycles=433)

        code = TestUART.compile()
        self.assertIn("SET uio[0], 0 [433]", code)
        self.assertIn("OUT uio[0], 8 [433]", code)
        self.assertIn("SET uio[0], 1 [433]", code)
        
        words = assemble(code)
        self.assertEqual(len(words), 3)
        print(f"[+] DSL Synthesized and Assembled: {len(words)} words.")

if __name__ == "__main__":
    unittest.main()
