#!/usr/bin/env python3
# =============================================================================
# File        : test_omnic.py
# Module      : sdk.tests.test_omnic
# Description : Complete Unit and Integration Test Suite for Omni-C Compiler.
# License     : MIT License
# =============================================================================

import unittest
import os
import sys

# Add project root and sdk to sys.path
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
SDK_DIR = os.path.join(PROJECT_ROOT, "sdk")

if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)
if SDK_DIR not in sys.path:
    sys.path.insert(0, SDK_DIR)

from omnibus.compiler.lexer import OmniCLexer, TokenType
from omnibus.compiler.parser import OmniCParser
from omnibus.compiler.ast_nodes import (
    Program, FunctionDef, Block, VarDecl, AssignStmt, IfStmt, WhileStmt,
    RepeatStmt, BinaryOp, UnaryOp, Literal, Identifier, BuiltinCall
)
from omnibus.compiler.symbols import Scope, Symbol, RegisterAllocator
from omnibus.compiler.optimizer import PeepholeOptimizer
from omnibus.compiler.codegen import OmniCCodeGen
from omnibus.compiler.driver import OmniCCompiler, Preprocessor
import python.omnibus_asm as asm_tool


class TestOmniCLexer(unittest.TestCase):
    """Test suite for the Omni-C Lexer."""

    def test_keywords_and_types(self):
        code = "void uint8_t int8_t bool reg const if else while do for repeat return break continue goto asm"
        lexer = OmniCLexer(code)
        tokens = lexer.tokenize()
        types = [t.type for t in tokens if t.type != TokenType.EOF]
        expected = [
            TokenType.VOID, TokenType.UINT8_T, TokenType.INT8_T, TokenType.BOOL,
            TokenType.REG, TokenType.CONST, TokenType.IF, TokenType.ELSE,
            TokenType.WHILE, TokenType.DO, TokenType.FOR, TokenType.REPEAT,
            TokenType.RETURN, TokenType.BREAK, TokenType.CONTINUE, TokenType.GOTO,
            TokenType.ASM
        ]
        self.assertEqual(types, expected)

    def test_number_literals(self):
        code = "123 0xFF 0b1010_0101 'A'"
        lexer = OmniCLexer(code)
        tokens = lexer.tokenize()
        self.assertEqual(tokens[0].value, 123)
        self.assertEqual(tokens[1].value, 255)
        self.assertEqual(tokens[2].value, 0b10100101)
        self.assertEqual(tokens[3].value, ord('A'))

    def test_sentinels(self):
        code = "$BAUD $HBAUD"
        lexer = OmniCLexer(code)
        tokens = lexer.tokenize()
        self.assertEqual(tokens[0].value, "$BAUD")
        self.assertEqual(tokens[1].value, "$HBAUD")

    def test_comments_stripping(self):
        code = """
        // Single-line comment
        uint8_t x = 5; /* Multi-line
        comment */
        reg r0 y;
        """
        lexer = OmniCLexer(code)
        tokens = lexer.tokenize()
        names = [t.value for t in tokens if t.type == TokenType.IDENTIFIER]
        self.assertIn("x", names)
        self.assertIn("y", names)


class TestOmniCParser(unittest.TestCase):
    """Test suite for the Omni-C Recursive Descent Parser."""

    def test_parse_function_and_block(self):
        code = """
        void my_func() {
            uint8_t a = 10;
            reg r1 b = 20;
            a = a + b;
        }
        """
        lexer = OmniCLexer(code)
        tokens = lexer.tokenize()
        parser = OmniCParser(tokens)
        ast = parser.parse()

        self.assertIsInstance(ast, Program)
        self.assertEqual(len(ast.decls), 1)
        func = ast.decls[0]
        self.assertIsInstance(func, FunctionDef)
        self.assertEqual(func.name, "my_func")
        self.assertEqual(len(func.body.statements), 3)

    def test_parse_control_flow(self):
        code = """
        void main() {
            if (acc == 0) {
                pin_high(0, 10);
            } else {
                pin_low(0, 5);
            }

            repeat (8) {
                out_shift(1, 0);
            }

            while (1) {
                pull();
            }
        }
        """
        lexer = OmniCLexer(code)
        tokens = lexer.tokenize()
        parser = OmniCParser(tokens)
        ast = parser.parse()

        func = ast.decls[0]
        stmts = func.body.statements
        self.assertIsInstance(stmts[0], IfStmt)
        self.assertIsInstance(stmts[1], RepeatStmt)
        self.assertIsInstance(stmts[2], WhileStmt)

    def test_parse_for_loop_to_repeat(self):
        code = """
        void main() {
            // Should optimize into RepeatStmt(8)
            for (uint8_t i = 0; i < 8; i++) {
                pull_block();
                out_shift(1, 0);
            }

            // Decrement should also optimize into RepeatStmt(16)
            for (int k = 16; k > 0; k--) {
                push_block();
            }
        }
        """
        lexer = OmniCLexer(code)
        tokens = lexer.tokenize()
        parser = OmniCParser(tokens)
        ast = parser.parse()

        func = ast.decls[0]
        stmts = func.body.statements
        self.assertEqual(len(stmts), 2)
        self.assertIsInstance(stmts[0], RepeatStmt)
        self.assertEqual(stmts[0].count_expr.value, 8)
        self.assertIsInstance(stmts[1], RepeatStmt)
        self.assertEqual(stmts[1].count_expr.value, 16)


class TestRegisterAllocator(unittest.TestCase):
    """Test suite for register allocation."""

    def test_allocator(self):
        alloc = RegisterAllocator()
        r_a = alloc.allocate("var_a")
        r_b = alloc.allocate("var_b")
        r_hint = alloc.allocate("var_hint", reg_hint="r5")

        self.assertEqual(r_a, "r0")
        self.assertEqual(r_b, "r1")
        self.assertEqual(r_hint, "r5")


class TestPeepholeOptimizer(unittest.TestCase):
    """Test suite for peephole optimizer."""

    def test_sidecar_coalescing(self):
        asm = [
            "SET 0, 1",
            "NOP [15]",
            "OUT 8",
            "NOP [$BAUD]"
        ]
        opt = PeepholeOptimizer(optimize_delays=True)
        optimized = opt.optimize(asm)
        self.assertEqual(optimized, [
            "SET 0, 1 [15]",
            "OUT 8 [$BAUD]"
        ])

    def test_redundant_moves(self):
        asm = [
            "MOV acc, acc",
            "MOV r0, acc",
            "MOV r1, r1"
        ]
        opt = PeepholeOptimizer()
        optimized = opt.optimize(asm)
        self.assertEqual(optimized, ["MOV r0, acc"])


class TestOmniCIntegration(unittest.TestCase):
    """End-to-End integration tests compiling and validating OmniBus assembly."""

    def setUp(self):
        self.compiler = OmniCCompiler(optimize=True)

    def _assemble(self, asm: str):
        assembler = asm_tool.OmnibusAssembler()
        words, labels = assembler.assemble(asm)
        return words

    def test_compile_uart_echo(self):
        src_path = os.path.join(PROJECT_ROOT, "examples", "omnic", "uart_echo.c")
        asm = self.compiler.compile_file(src_path)
        self.assertIn("PINMAP", asm)
        self.assertIn("CALL uart_tx_byte", asm)
        self.assertIn("CALL uart_rx_byte", asm)

        words = self._assemble(asm)
        self.assertGreater(len(words), 5)

    def test_compile_i2c_eeprom(self):
        src_path = os.path.join(PROJECT_ROOT, "examples", "omnic", "i2c_eeprom.c")
        asm = self.compiler.compile_file(src_path)
        self.assertIn("CFG_OD", asm)
        self.assertIn("CALL i2c_start", asm)
        self.assertIn("CALL i2c_stop", asm)

        words = self._assemble(asm)
        self.assertGreater(len(words), 20)

    def test_compile_spi_flash(self):
        src_path = os.path.join(PROJECT_ROOT, "examples", "omnic", "spi_flash.c")
        asm = self.compiler.compile_file(src_path)
        self.assertIn("SET_LC LC0, 3", asm)
        self.assertIn("DJNZ LC0", asm)

        words = self._assemble(asm)
        self.assertGreater(len(words), 15)

    def test_compile_dht11_nested_loops(self):
        src_path = os.path.join(PROJECT_ROOT, "examples", "omnic", "dht11_sensor.c")
        asm = self.compiler.compile_file(src_path)
        self.assertIn("SET_LC LC0, 5", asm)
        self.assertIn("SET_LC LC1, 8", asm)
        self.assertIn("DJNZ LC1", asm)
        self.assertIn("DJNZ LC0", asm)

        words = self._assemble(asm)
        self.assertGreater(len(words), 20)

    def test_compile_mitm_fuzzer(self):
        src_path = os.path.join(PROJECT_ROOT, "examples", "omnic", "mitm_fuzzer.c")
        asm = self.compiler.compile_file(src_path)
        self.assertIn("GLITCH_CFG", asm)
        self.assertIn("MITM_MATCH", asm)
        self.assertIn("MITM_REPLACE", asm)

        words = self._assemble(asm)
        self.assertGreater(len(words), 5)

    def test_compile_chiptune_player(self):
        src_path = os.path.join(PROJECT_ROOT, "examples", "omnic", "chiptune_player.c")
        asm = self.compiler.compile_file(src_path)
        self.assertIn("AUDIO_VOL", asm)
        self.assertIn("AUDIO_PLAY", asm)
        self.assertIn("AUDIO_STOP", asm)

        words = self._assemble(asm)
        self.assertGreater(len(words), 5)

    def test_compile_for_to_repeat_hardware_loop(self):
        code = """
        #include <omnibus.h>

        void main(void) {
            // Nested for loops replacing with LC0 and LC1
            for (uint8_t i = 0; i < 4; i++) {
                for (int j = 8; j > 0; j--) {
                    out_shift(1, 0);
                }
                push(BLOCK);
            }
        }
        """
        asm = self.compiler.compile_source(code)
        self.assertIn("SET_LC LC0, 4", asm)
        self.assertIn("SET_LC LC1, 8", asm)
        self.assertIn("DJNZ LC1", asm)
        self.assertIn("DJNZ LC0", asm)

        words = self._assemble(asm)
        self.assertGreater(len(words), 5)
        self.assertLessEqual(len(words), 128)


if __name__ == "__main__":
    unittest.main()
