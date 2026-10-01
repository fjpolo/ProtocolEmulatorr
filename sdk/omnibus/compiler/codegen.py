# =============================================================================
# File        : codegen.py
# Module      : omnibus.compiler.codegen
# Description : Code Generator emitting OmniBus 16-bit Assembly from AST.
# License     : MIT License
# =============================================================================

from typing import List, Dict, Optional, Any, Union, Tuple, Set
from .ast_nodes import (
    ASTNode, Program, FunctionDef, Block, VarDecl, AssignStmt, IfStmt,
    WhileStmt, DoWhileStmt, RepeatStmt, ReturnStmt, BreakStmt, ContinueStmt,
    GotoStmt, LabelStmt, AsmStmt, ExprStmt, BinaryOp, UnaryOp, Identifier,
    Literal, BuiltinCall, PragmaDirective
)
from .symbols import Scope, Symbol, RegisterAllocator
from .optimizer import PeepholeOptimizer


class CodeGenError(Exception):
    def __init__(self, message: str, line: int = 1, col: int = 1):
        super().__init__(f"CodeGen error at line {line}, col {col}: {message}")
        self.line = line
        self.col = col


class OmniCCodeGen:
    """Code generator that translates Omni-C AST into OmniBus 16-bit Assembly."""

    def __init__(self, optimize: bool = True):
        self.optimize = optimize
        self.lines: List[str] = []
        self.label_counter = 0
        self.loop_stack: List[Tuple[str, str]] = []  # (continue_label, break_label)
        self.current_scope = Scope()
        self.reg_alloc = RegisterAllocator()
        self.clock_freq = 50_000_000
        self.baud_rate = 115200
        self.optimizer = PeepholeOptimizer(optimize_delays=True, eliminate_dead_code=True)
        self.allocated_lcs: Set[int] = set()
        self.active_loop_counters: List[int] = []

    def _emit(self, line: str):
        self.lines.append(line)

    def _new_label(self, prefix: str = "L") -> str:
        self.label_counter += 1
        # Use alphanumeric label prefix compatible with omnibus_asm.py
        clean_prefix = prefix.replace(".", "_")
        return f"lbl_{clean_prefix}_{self.label_counter}"

    def generate(self, program: Program) -> str:
        self.lines = []
        self._emit("; ==============================================================================")
        self._emit("; OmniBus Microcode — Compiled by Omni-C (omnibus-cc)")
        self._emit("; Target Architecture: OmniBus 16-bit Deterministic Protocol Engine")
        self._emit("; ==============================================================================")
        self._emit("")

        # First pass: collect pragmas and global declarations
        for decl in program.decls:
            if isinstance(decl, PragmaDirective):
                self._gen_pragma(decl)

        self._emit(f".clock {self.clock_freq}")
        self._emit("")

        # Check if main exists, emit entry point
        has_main = any(isinstance(d, FunctionDef) and d.name == "main" for d in program.decls)
        if has_main:
            self._emit(".entry main")
            self._emit("")

        # Second pass: generate globals and functions
        for decl in program.decls:
            if isinstance(decl, PragmaDirective):
                continue  # Already processed
            elif isinstance(decl, VarDecl):
                self._gen_global_var(decl)
            elif isinstance(decl, FunctionDef):
                self._gen_function(decl)
            elif isinstance(decl, AsmStmt):
                self._gen_asm(decl)

        raw_asm = self.lines
        if self.optimize:
            optimized_lines = self.optimizer.optimize(raw_asm)
            return "\n".join(optimized_lines) + "\n"

        return "\n".join(raw_asm) + "\n"

    def _gen_pragma(self, pragma: PragmaDirective):
        key = pragma.key.lower()
        val = str(pragma.value).strip()
        if key == "clock":
            # e.g. #pragma clock 50MHz or 50000000
            val_clean = val.lower().replace("mhz", "000000").replace("khz", "000").replace("hz", "")
            try:
                self.clock_freq = int(val_clean)
            except ValueError:
                pass
        elif key == "baud":
            try:
                self.baud_rate = int(val)
            except ValueError:
                pass

    def _gen_global_var(self, var: VarDecl):
        reg = self.reg_alloc.allocate(var.name, var.reg_hint)
        sym = Symbol(var.name, var.var_type, reg=reg, is_const=var.is_const)
        self.current_scope.define(sym)

        if var.is_const and isinstance(var.init_expr, Literal):
            sym.const_value = var.init_expr.value
            if isinstance(var.init_expr.value, int):
                self._emit(f".const {var.name} {var.init_expr.value}")
        elif var.init_expr:
            # Emit initialization instruction
            val_str = self._eval_literal_or_reg(var.init_expr)
            self._emit(f"MOV {reg}, {val_str} ; init global {var.name}")

    def _gen_function(self, func: FunctionDef):
        self._emit(f"; --- Function: {func.name} ---")
        self._emit(f"{func.name}:")

        func_scope = Scope(self.current_scope)
        old_scope = self.current_scope
        self.current_scope = func_scope

        # Allocate registers for parameters
        for param in func.params:
            reg = self.reg_alloc.allocate(param.name, param.reg_hint)
            func_scope.define(Symbol(param.name, param.var_type, reg=reg))

        # Generate body
        for stmt in func.body.statements:
            self._gen_statement(stmt)

        # Append RET for non-main functions if not explicitly returned
        if not func.is_entry:
            if not self.lines or not self.lines[-1].strip().startswith("RET"):
                self._emit("RET")

        self._emit("")
        self.current_scope = old_scope

    def _gen_statement(self, stmt: ASTNode):
        if isinstance(stmt, Block):
            for s in stmt.statements:
                self._gen_statement(s)
        elif isinstance(stmt, VarDecl):
            self._gen_local_var(stmt)
        elif isinstance(stmt, AssignStmt):
            self._gen_assign(stmt)
        elif isinstance(stmt, IfStmt):
            self._gen_if(stmt)
        elif isinstance(stmt, WhileStmt):
            self._gen_while(stmt)
        elif isinstance(stmt, DoWhileStmt):
            self._gen_do_while(stmt)
        elif isinstance(stmt, RepeatStmt):
            self._gen_repeat(stmt)
        elif isinstance(stmt, ReturnStmt):
            self._gen_return(stmt)
        elif isinstance(stmt, BreakStmt):
            if not self.loop_stack:
                raise CodeGenError("'break' outside loop", stmt.line)
            self._emit(f"JMP {self.loop_stack[-1][1]}")
        elif isinstance(stmt, ContinueStmt):
            if not self.loop_stack:
                raise CodeGenError("'continue' outside loop", stmt.line)
            self._emit(f"JMP {self.loop_stack[-1][0]}")
        elif isinstance(stmt, GotoStmt):
            self._emit(f"JMP {stmt.target_label}")
        elif isinstance(stmt, LabelStmt):
            self._emit(f"{stmt.name}:")
        elif isinstance(stmt, AsmStmt):
            self._gen_asm(stmt)
        elif isinstance(stmt, ExprStmt):
            self._gen_expr_stmt(stmt)
        else:
            raise CodeGenError(f"Unhandled statement type: {type(stmt).__name__}", stmt.line)

    def _gen_local_var(self, var: VarDecl):
        reg = self.reg_alloc.allocate(var.name, var.reg_hint)
        sym = Symbol(var.name, var.var_type, reg=reg, is_const=var.is_const)
        self.current_scope.define(sym)

        if var.init_expr:
            val_str = self._eval_literal_or_reg(var.init_expr)
            self._emit(f"MOV {reg}, {val_str} ; local {var.name}")

    def _gen_assign(self, assign: AssignStmt):
        target_name = self._get_var_name(assign.target)
        target_sym = self.current_scope.lookup(target_name)
        target_reg = target_sym.reg if target_sym and target_sym.reg else target_name.lower()

        # Handle simple register assignment: target = value
        if assign.op == "=":
            if isinstance(assign.value, Literal):
                val = self._format_literal(assign.value)
                self._emit(f"MOV {target_reg}, {val}")
            elif isinstance(assign.value, Identifier):
                src_name = assign.value.name
                src_sym = self.current_scope.lookup(src_name)
                if src_sym and src_sym.is_const and src_sym.const_value is not None:
                    if isinstance(src_sym.const_value, int):
                        val = f"0x{src_sym.const_value:02X}" if src_sym.const_value > 9 else str(src_sym.const_value)
                    else:
                        val = str(src_sym.const_value)
                    self._emit(f"MOV {target_reg}, {val}")
                else:
                    src_reg = src_sym.reg if src_sym and src_sym.reg else src_name.lower()
                    self._emit(f"MOV {target_reg}, {src_reg}")
            elif isinstance(assign.value, BinaryOp):
                self._gen_binary_assign(target_reg, assign.value)
            elif isinstance(assign.value, UnaryOp):
                self._gen_unary_assign(target_reg, assign.value)
            elif isinstance(assign.value, BuiltinCall):
                self._gen_builtin_assign(target_reg, assign.value)
            else:
                val = self._eval_literal_or_reg(assign.value)
                self._emit(f"MOV {target_reg}, {val}")

        elif assign.op in ("+=", "-=", "&=", "|=", "^=", "<<=", ">>="):
            op_map = {
                "+=": "ADD", "-=": "SUB", "&=": "AND", "|=": "OR", "^=": "XOR",
                "<<=": "SHL", ">>=": "SHR"
            }
            alu_op = op_map[assign.op]
            val = self._eval_literal_or_reg(assign.value)

            if target_reg == "acc":
                self._emit(f"{alu_op} {val}")
            else:
                # Load to ACC, perform ALU op, store back
                self._emit(f"MOV acc, {target_reg}")
                self._emit(f"{alu_op} {val}")
                self._emit(f"MOV {target_reg}, acc")

    def _gen_binary_assign(self, target_reg: str, binop: BinaryOp):
        left_str = self._eval_literal_or_reg(binop.left)
        right_str = self._eval_literal_or_reg(binop.right)

        op_map = {
            "+": "ADD", "-": "SUB", "&": "AND", "|": "OR", "^": "XOR",
            "<<": "SHL", ">>": "SHR"
        }
        alu_op = op_map.get(binop.op)

        if alu_op:
            if target_reg == "acc":
                if left_str != "acc":
                    self._emit(f"MOV acc, {left_str}")
                self._emit(f"{alu_op} {right_str}")
            else:
                self._emit(f"MOV acc, {left_str}")
                self._emit(f"{alu_op} {right_str}")
                self._emit(f"MOV {target_reg}, acc")
        else:
            raise CodeGenError(f"Unsupported binary operator '{binop.op}' in assignment", binop.line)

    def _gen_unary_assign(self, target_reg: str, unop: UnaryOp):
        operand_str = self._eval_literal_or_reg(unop.expr)
        if unop.op in ("~", "not", "inv"):
            if target_reg == "acc":
                if operand_str != "acc":
                    self._emit(f"MOV acc, {operand_str}")
                self._emit("NOT")
            else:
                self._emit(f"MOV acc, {operand_str}")
                self._emit("NOT")
                self._emit(f"MOV {target_reg}, acc")
        elif unop.op == "++":
            self._emit(f"INC {target_reg}")
        elif unop.op == "--":
            self._emit(f"DEC {target_reg}")

    def _gen_builtin_assign(self, target_reg: str, call: BuiltinCall):
        name = call.name.lower()
        if name in ("rol", "ror"):
            arg_str = self._eval_literal_or_reg(call.args[0]) if call.args else "acc"
            if target_reg == "acc":
                if arg_str != "acc":
                    self._emit(f"MOV acc, {arg_str}")
                self._emit(name.upper())
            else:
                self._emit(f"MOV acc, {arg_str}")
                self._emit(name.upper())
                self._emit(f"MOV {target_reg}, acc")
        elif name.startswith("crc_read"):
            self._emit(name.upper())
            if target_reg != "acc":
                self._emit(f"MOV {target_reg}, acc")
        elif name == "pull":
            self._emit("PULL")
            if target_reg != "osr":
                self._emit(f"MOV {target_reg}, osr")
        else:
            self._gen_builtin_call(call)

    def _gen_if(self, stmt: IfStmt):
        else_label = self._new_label("else") if stmt.else_branch else None
        end_label = self._new_label("endif")

        target_false = else_label or end_label
        self._gen_condition_branch(stmt.condition, target_label=target_false, jump_if_true=False)

        self._gen_statement(stmt.then_branch)

        if stmt.else_branch:
            self._emit(f"JMP {end_label}")
            self._emit(f"{else_label}:")
            self._gen_statement(stmt.else_branch)

        self._emit(f"{end_label}:")

    def _gen_while(self, stmt: WhileStmt):
        start_label = self._new_label("while_start")
        end_label = self._new_label("while_end")

        self.loop_stack.append((start_label, end_label))
        self._emit(f"{start_label}:")

        # Evaluate condition
        self._gen_condition_branch(stmt.condition, target_label=end_label, jump_if_true=False)

        self._gen_statement(stmt.body)
        self._emit(f"JMP {start_label}")
        self._emit(f"{end_label}:")
        self.loop_stack.pop()

    def _gen_do_while(self, stmt: DoWhileStmt):
        start_label = self._new_label("do_start")
        cond_label = self._new_label("do_cond")
        end_label = self._new_label("do_end")

        self.loop_stack.append((cond_label, end_label))
        self._emit(f"{start_label}:")

        self._gen_statement(stmt.body)

        self._emit(f"{cond_label}:")
        self._gen_condition_branch(stmt.condition, target_label=start_label, jump_if_true=True)
        self._emit(f"{end_label}:")
        self.loop_stack.pop()

    def _gen_repeat(self, stmt: RepeatStmt):
        """Hardware loop counter DJNZ LC0/LC1."""
        # Dynamically allocate next available hardware loop counter (LC0 or LC1)
        if 0 not in self.active_loop_counters:
            lc_id = 0
        elif 1 not in self.active_loop_counters:
            lc_id = 1
        else:
            raise CodeGenError("Exceeded hardware loop counter nesting limit (maximum 2 nested repeat loops: LC0 and LC1)", stmt.line)

        self.active_loop_counters.append(lc_id)
        lc_name = f"LC{lc_id}"
        count_val = self._eval_literal_or_reg(stmt.count_expr)

        start_label = self._new_label(f"loop_lc{lc_id}")
        end_label = self._new_label(f"end_lc{lc_id}")

        self._emit(f"SET_LC {lc_name}, {count_val}")
        self.loop_stack.append((start_label, end_label))

        self._emit(f"{start_label}:")
        self._gen_statement(stmt.body)
        self._emit(f"DJNZ {lc_name}, {start_label}")
        self._emit(f"{end_label}:")
        self.loop_stack.pop()
        self.active_loop_counters.pop()

    def _gen_return(self, stmt: ReturnStmt):
        if stmt.value:
            val_str = self._eval_literal_or_reg(stmt.value)
            if val_str != "acc":
                self._emit(f"MOV acc, {val_str}")
        self._emit("RET")

    def _gen_asm(self, stmt: AsmStmt):
        self._emit(stmt.asm_code)

    def _gen_expr_stmt(self, stmt: ExprStmt):
        if isinstance(stmt.expr, BuiltinCall):
            self._gen_builtin_call(stmt.expr)
        elif isinstance(stmt.expr, UnaryOp):
            if stmt.expr.op in ("++", "--"):
                target = self._eval_literal_or_reg(stmt.expr.expr)
                op_name = "INC" if stmt.expr.op == "++" else "DEC"
                self._emit(f"{op_name} {target}")
        elif isinstance(stmt.expr, AssignStmt):
            self._gen_assign(stmt.expr)

    def _gen_condition_branch(self, cond: ASTNode, target_label: str, jump_if_true: bool):
        """Generates conditional branches (JZ, JNZ, JC, JNC, JMP)."""
        if isinstance(cond, BinaryOp):
            left_str = self._eval_literal_or_reg(cond.left)
            right_str = self._eval_literal_or_reg(cond.right)

            if left_str != "acc":
                self._emit(f"MOV acc, {left_str}")

            if cond.op in ("==", "!="):
                if right_str != "0":
                    self._emit(f"CMP {right_str}")
                if cond.op == "==":
                    # == 0 means ZERO flag
                    branch = "JZ" if jump_if_true else "JNZ"
                else:
                    branch = "JNZ" if jump_if_true else "JZ"
                self._emit(f"JMP {branch} {target_label}")

            elif cond.op in ("<", ">="):
                self._emit(f"CMP {right_str}")
                # CMP sets CARRY if ACC < val
                if cond.op == "<":
                    branch = "JC" if jump_if_true else "JNC"
                else:
                    branch = "JNC" if jump_if_true else "JC"
                self._emit(f"JMP {branch} {target_label}")

        elif isinstance(cond, Identifier):
            # Check if symbol is a defined constant (e.g. FLAG_I2C_MATCH -> i2c_match)
            sym = self.current_scope.lookup(cond.name)
            if sym and sym.is_const and sym.const_value is not None:
                name_lower = str(sym.const_value).lower()
            else:
                name_lower = cond.name.lower()

            if name_lower in ("zero", "z"):
                branch = "JZ" if jump_if_true else "JNZ"
                self._emit(f"JMP {branch}, {target_label}")
            elif name_lower in ("not_zero", "nz"):
                branch = "JNZ" if jump_if_true else "JZ"
                self._emit(f"JMP {branch}, {target_label}")
            elif name_lower in ("carry", "c"):
                branch = "JC" if jump_if_true else "JNC"
                self._emit(f"JMP {branch}, {target_label}")
            elif name_lower in ("not_carry", "nc"):
                branch = "JNC" if jump_if_true else "JC"
                self._emit(f"JMP {branch}, {target_label}")
            elif name_lower in ("i2c_match", "i2c_addr_match"):
                if jump_if_true:
                    self._emit(f"JMP I2C_ADDR_MATCH, {target_label}")
                else:
                    then_lbl = self._new_label("then")
                    self._emit(f"JMP I2C_ADDR_MATCH, {then_lbl}")
                    self._emit(f"JMP {target_label}")
                    self._emit(f"{then_lbl}:")
            elif name_lower in ("mitm_match", "match_found"):
                if jump_if_true:
                    self._emit(f"JMP MITM_MATCH, {target_label}")
                else:
                    then_lbl = self._new_label("then")
                    self._emit(f"JMP MITM_MATCH, {then_lbl}")
                    self._emit(f"JMP {target_label}")
                    self._emit(f"{then_lbl}:")
            elif name_lower in ("glitch_done", "glitch_fired"):
                if jump_if_true:
                    self._emit(f"JMP GLITCH_DONE, {target_label}")
                else:
                    then_lbl = self._new_label("then")
                    self._emit(f"JMP GLITCH_DONE, {then_lbl}")
                    self._emit(f"JMP {target_label}")
                    self._emit(f"{then_lbl}:")
            elif name_lower in ("is_clock", "profiler_clock"):
                if jump_if_true:
                    self._emit(f"JMP PROFILER_CLOCK, {target_label}")
                else:
                    then_lbl = self._new_label("then")
                    self._emit(f"JMP PROFILER_CLOCK, {then_lbl}")
                    self._emit(f"JMP {target_label}")
                    self._emit(f"{then_lbl}:")
            elif name_lower in ("profiler_done", "profiler_converged"):
                if jump_if_true:
                    self._emit(f"JMP PROFILER_DONE, {target_label}")
                else:
                    then_lbl = self._new_label("then")
                    self._emit(f"JMP PROFILER_DONE, {then_lbl}")
                    self._emit(f"JMP {target_label}")
                    self._emit(f"{then_lbl}:")

            else:
                # Check if register is non-zero
                reg = sym.reg if sym and sym.reg else name_lower
                if reg != "acc":
                    self._emit(f"MOV acc, {reg}")
                self._emit("CMP 0")
                branch = "JNZ" if jump_if_true else "JZ"
                self._emit(f"JMP {branch}, {target_label}")

        elif isinstance(cond, Literal):
            if cond.value:
                if jump_if_true:
                    self._emit(f"JMP {target_label}")
            else:
                if not jump_if_true:
                    self._emit(f"JMP {target_label}")


    def _gen_builtin_call(self, call: BuiltinCall):
        name = call.name.lower()
        args = [self._eval_literal_or_reg(a) for a in call.args]

        # Pin control primitives
        if name in ("pin_set", "set_pin"):
            pin, val = args[0], args[1]
            delay = f" [{args[2]}]" if len(args) > 2 else ""
            self._emit(f"SET {pin}, {val}{delay}")

        elif name == "pin_high":
            pin = args[0]
            delay = f" [{args[1]}]" if len(args) > 1 else ""
            self._emit(f"SET {pin}, 1{delay}")

        elif name == "pin_low":
            pin = args[0]
            delay = f" [{args[1]}]" if len(args) > 1 else ""
            self._emit(f"SET {pin}, 0{delay}")

        elif name in ("pin_wait", "wait_pin"):
            pin, val = args[0], args[1]
            delay = f" [{args[2]}]" if len(args) > 2 else ""
            self._emit(f"WAIT {pin}, {val}{delay}")

        elif name == "pin_map":
            # pin_map(tx, rx, sck, cs)
            self._emit(f"PINMAP tx={args[0]}, rx={args[1]}, sck={args[2]}, cs={args[3]}")

        elif name == "cfg_od":
            self._emit(f"CFG_OD {args[0]}")

        # FIFO streaming primitives
        elif name == "pull":
            self._emit("PULL")
        elif name == "pull_block":
            self._emit("PULL BLOCK")
        elif name == "push":
            self._emit("PUSH")
        elif name == "push_block":
            self._emit("PUSH BLOCK")

        # Serializer / Deserializer stream primitives
        elif name == "out_shift":
            count = args[0] if args else "8"
            delay = f" [{args[1]}]" if len(args) > 1 else ""
            self._emit(f"OUT {count}{delay}")

        elif name == "out_sck":
            count = args[0] if args else "8"
            delay = f" [{args[1]}]" if len(args) > 1 else ""
            self._emit(f"OUT SCK, {count}{delay}")

        elif name == "in_shift":
            count = args[0] if args else "8"
            delay = f" [{args[1]}]" if len(args) > 1 else ""
            self._emit(f"IN {count}{delay}")

        elif name == "in_sck":
            count = args[0] if args else "8"
            delay = f" [{args[1]}]" if len(args) > 1 else ""
            self._emit(f"IN SCK, {count}{delay}")

        # Delays
        elif name == "delay_cycles":
            self._emit(f"NOP [{args[0]}]")
        elif name == "delay_baud":
            self._emit("NOP [$BAUD]")
        elif name == "delay_hbaud":
            self._emit("NOP [$HBAUD]")
        elif name == "delay_us":
            cycles = max(1, round(float(args[0]) * 1e-6 * self.clock_freq))
            self._emit(f"NOP [{cycles}]")
        elif name == "delay_ns":
            cycles = max(1, round(float(args[0]) * 1e-9 * self.clock_freq))
            self._emit(f"NOP [{cycles}]")
        elif name == "nop":
            self._emit("NOP")

        # Bank switching
        elif name == "set_bank":
            self._emit(f"SET_BANK {args[0]}")

        # CRC Assist
        elif name == "crc_init":
            self._emit(f"CRC_INIT {args[0]}")
        elif name == "crc_byte":
            self._emit(f"CRC_BYTE {args[0]}")
        elif name.startswith("crc_read"):
            self._emit(name.upper())
        elif name == "crc_reset":
            self._emit("CRC_RESET")

        # General Hardware Assists
        elif name == "assist_nrzi":
            self._emit(f"ASSIST_CFG nrzi={args[0]}")
        elif name == "assist_bitstuff":
            self._emit(f"ASSIST_CFG stuff={args[0]}")
        elif name == "assist_manchester":
            self._emit(f"ASSIST_CFG manch={args[0]}")
        elif name == "assist_pulse_cfg":
            self._emit(f"PULSE_CFG {args[0]}")
        elif name == "assist_pulse_time0":
            self._emit(f"PULSE_TIME0 {args[0]}, {args[1]}")
        elif name == "assist_pulse_time1":
            self._emit(f"PULSE_TIME1 {args[0]}, {args[1]}")
        elif name == "assist_gamepad_cfg":
            self._emit(f"GAMEPAD_CFG {args[0]}")
        elif name == "assist_audio_vol":
            self._emit(f"AUDIO_VOL {args[0]}")
        elif name == "assist_audio_sample":
            self._emit(f"AUDIO_SAMPLE {args[0]}")
        elif name == "assist_audio_duty":
            self._emit(f"AUDIO_DUTY {args[0]}")
        elif name == "assist_audio_note":
            self._emit(f"AUDIO_NOTE_LO {args[0]}")
            self._emit(f"AUDIO_NOTE_HI {args[1]}")
        elif name == "assist_audio_play":
            self._emit(f"AUDIO_PLAY {args[0]}, {args[1]}")
        elif name == "assist_audio_stop":
            self._emit("AUDIO_STOP")
        elif name == "assist_glitch_cfg":
            self._emit(f"GLITCH_CFG {args[0]}")
        elif name == "assist_glitch_arm":
            self._emit("GLITCH_ARM")
        elif name == "assist_glitch_disarm":
            self._emit("GLITCH_DISARM")
        elif name == "assist_mitm_cfg":
            self._emit(f"MITM_CFG {args[0]}")
        elif name == "assist_mitm_match":
            self._emit(f"MITM_MATCH {args[0]}")
        elif name == "assist_mitm_replace":
            self._emit(f"MITM_REPLACE {args[0]}")
        elif name == "assist_mitm_enable":
            self._emit("MITM_ENABLE")
        elif name == "assist_mitm_disable":
            self._emit("MITM_DISABLE")
        elif name == "assist_i2c_slave_cfg":
            self._emit(f"I2C_SLAVE_CFG {args[0]}")
        elif name == "assist_i2c_release_scl":
            self._emit("I2C_RELEASE_SCL")
        elif name == "assist_i2c_slave_disable":
            self._emit("I2C_SLAVE_DISABLE")
        elif name == "assist_jtag_cfg":
            self._emit(f"JTAG_CFG {args[0]}")
        elif name == "assist_swd_cfg":
            self._emit(f"SWD_CFG {args[0]}")
        elif name == "assist_qspi_cfg":
            self._emit(f"QSPI_CFG {args[0]}")
        elif name == "assist_reset":
            self._emit("ASSIST_RESET")

        # User-defined function call
        else:
            self._emit(f"CALL {name}")

    def _eval_literal_or_reg(self, node: ASTNode) -> str:
        if isinstance(node, Literal):
            return self._format_literal(node)
        elif isinstance(node, Identifier):
            sym = self.current_scope.lookup(node.name)
            if sym and sym.is_const and sym.const_value is not None:
                return str(sym.const_value)
            if sym and sym.reg:
                return sym.reg
            return node.name
        elif isinstance(node, BinaryOp):
            # Try constant evaluation
            if isinstance(node.left, Literal) and isinstance(node.right, Literal):
                try:
                    res = eval(f"{node.left.value} {node.op} {node.right.value}")
                    return str(int(res))
                except Exception:
                    pass
        return "acc"

    def _format_literal(self, lit: Literal) -> str:
        if isinstance(lit.value, int):
            return f"0x{lit.value:02X}" if lit.value > 9 else str(lit.value)
        return str(lit.value)

    def _get_var_name(self, node: ASTNode) -> str:
        if isinstance(node, Identifier):
            return node.name
        elif isinstance(node, Literal):
            return str(node.value)
        return "acc"
