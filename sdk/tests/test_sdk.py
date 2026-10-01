#!/usr/bin/env python3
"""
Unit tests for the OmniBus Software SDK (Dual Track: Assembly and C).
"""

import unittest
import os
import sys

# Ensure SDK is on python path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "python")))

from omnibus.assembler import assemble, assemble_file
from omnibus.compiler import OmniCCompiler
from omnibus.dsl import Protocol, Pin, Direction

class TestOmniBusSDK(unittest.TestCase):
    def setUp(self):
        self.sdk_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
        self.examples_dir = os.path.join(self.sdk_dir, "examples")
        self.asm_dir = os.path.join(self.examples_dir, "asm")
        self.c_dir = os.path.join(self.examples_dir, "c")
        self.include_dir = os.path.join(self.sdk_dir, "include", "omnic")

    def test_assemble_asm_examples(self):
        asm_files = [
            "01_uart_hello.asm",
            "02_i2c_sensor_read.asm",
            "03_ws2812_rainbow.asm",
            "04_mitm_flash_fuzzer.asm"
        ]
        for fname in asm_files:
            fpath = os.path.join(self.asm_dir, fname)
            words = assemble_file(fpath)
            self.assertGreater(len(words), 0, f"Failed assembling {fname}")
            self.assertLessEqual(len(words), 128, f"{fname} exceeds 128-word IMEM capacity")
            print(f"[+] [ASM Track] Assembled {fname}: {len(words)} words.")

    def test_compile_c_examples(self):
        c_files = [
            "uart_echo.c",
            "i2c_eeprom.c",
            "spi_flash.c",
            "ws2812_rainbow.c",
            "dht11_sensor.c",
            "mitm_fuzzer.c",
            "chiptune_player.c"
        ]
        compiler = OmniCCompiler(include_paths=[self.include_dir])
        for fname in c_files:
            fpath = os.path.join(self.c_dir, fname)
            asm_code = compiler.compile_file(fpath)
            self.assertGreater(len(asm_code), 0, f"Failed compiling {fname}")
            words = assemble(asm_code)
            self.assertGreater(len(words), 0, f"Failed assembling compiled {fname}")
            self.assertLessEqual(len(words), 128, f"{fname} exceeds 128-word IMEM capacity")
            print(f"[+] [C Track] Compiled & Assembled {fname}: {len(words)} words.")

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
        print(f"[+] [DSL Track] DSL Synthesized and Assembled: {len(words)} words.")

if __name__ == "__main__":
    unittest.main()

