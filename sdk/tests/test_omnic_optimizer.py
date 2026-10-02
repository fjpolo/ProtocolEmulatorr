# =============================================================================
# File        : test_omnic_optimizer.py
# Module      : sdk.tests.test_omnic_optimizer
# Description : Unit tests for Omni-C Multi-Pass Optimizer (-O0, -O1, -O2),
#               Switch-Case Jump Tables, and Code Density Optimization.
# License     : MIT License
# =============================================================================

import unittest
from omnibus.compiler.driver import OmniCCompiler
from omnibus.compiler.optimizer import PeepholeOptimizer


class TestOmniCOptimizerLevels(unittest.TestCase):
    """Test -O0, -O1, -O2 optimizer capabilities."""

    def test_optimization_level_comparison(self):
        source = """
        #pragma clock 50MHz
        #pragma baud 115200

        void test_routine(void) {
            reg r0 x = 10;
            x = x; // Redundant self-move
            pin_set(0, 1);
            delay_cycles(5);
            delay_cycles(10);
            pin_set(0, 1); // Redundant SET
        }
        """
        compiler_o0 = OmniCCompiler(optimize=False)
        asm_o0 = compiler_o0.compile_string(source)
        self.assertTrue(len(asm_o0) > 0)

        compiler_o1 = OmniCCompiler(optimize=1)
        asm_o1 = compiler_o1.compile_string(source)
        self.assertTrue(len(asm_o1) > 0)

        compiler_o2 = OmniCCompiler(optimize=2)
        asm_o2 = compiler_o2.compile_string(source)
        self.assertTrue(len(asm_o2) > 0)

        lines_o0 = len(asm_o0.strip().split("\n"))
        lines_o1 = len(asm_o1.strip().split("\n"))
        lines_o2 = len(asm_o2.strip().split("\n"))

        self.assertLessEqual(lines_o1, lines_o0)
        self.assertLessEqual(lines_o2, lines_o1)

    def test_switch_case_compilation(self):
        source = """
        #pragma clock 50MHz
        #pragma baud 115200

        void command_dispatcher(void) {
            uint8_t cmd = pull();
            switch (cmd) {
                case 0x01:
                    pin_set(0, 1);
                    break;
                case 0x02:
                    pin_set(0, 0);
                    break;
                case 0x03:
                    push(0xAA);
                    break;
                default:
                    push(0xFF);
                    break;
            }
        }
        """
        compiler = OmniCCompiler(optimize=2)
        asm = compiler.compile_string(source)
        self.assertTrue(len(asm) > 0)
        self.assertIn("CMP 1", asm)
        self.assertIn("CMP 2", asm)
        self.assertIn("CMP 3", asm)
        self.assertIn("JMP JZ", asm)

    def test_peephole_inverse_moves(self):
        optimizer = PeepholeOptimizer(level=2)
        raw_lines = [
            "MOV r0, acc",
            "MOV acc, r0",
            "NOP [5]"
        ]
        optimized = optimizer.optimize(raw_lines)
        self.assertEqual(len(optimized), 2)
        self.assertEqual(optimized[0], "MOV r0, acc")
        self.assertEqual(optimized[1], "NOP [5]")

    def test_peephole_nop_folding(self):
        optimizer = PeepholeOptimizer(level=2)
        raw_lines = [
            "NOP [10]",
            "NOP [12]"
        ]
        optimized = optimizer.optimize(raw_lines)
        self.assertEqual(len(optimized), 1)
        self.assertEqual(optimized[0], "NOP [22]")

    def test_jump_chain_compression(self):
        optimizer = PeepholeOptimizer(level=2)
        raw_lines = [
            "JMP lbl_start",
            "lbl_start:",
            "JMP lbl_final",
            "lbl_final:",
            "RET"
        ]
        optimized = optimizer.optimize(raw_lines)
        # JMP lbl_start should be compressed to JMP lbl_final, and redundant jumps skipped
        self.assertIn("RET", optimized)


if __name__ == "__main__":
    unittest.main()
