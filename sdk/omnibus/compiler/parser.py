# =============================================================================
# File        : parser.py
# Module      : omnibus.compiler.parser
# Description : Recursive Descent Parser for Omni-C Compiler.
# License     : MIT License
# =============================================================================

from typing import List, Optional, Any, Union
from .lexer import Token, TokenType, OmniCLexer, LexerError
from .ast_nodes import (
    ASTNode, Program, FunctionDef, Block, VarDecl, AssignStmt, IfStmt,
    WhileStmt, DoWhileStmt, RepeatStmt, ReturnStmt, BreakStmt, ContinueStmt,
    GotoStmt, LabelStmt, AsmStmt, ExprStmt, BinaryOp, UnaryOp, Identifier,
    Literal, BuiltinCall, PragmaDirective
)


class ParserError(Exception):
    def __init__(self, message: str, line: int = 1, col: int = 1):
        super().__init__(f"Parser error at line {line}, col {col}: {message}")
        self.line = line
        self.col = col


BUILTIN_FUNCTIONS = {
    "pin_set", "pin_high", "pin_low", "pin_wait", "pin_map", "cfg_od",
    "pull", "pull_block", "push", "push_block",
    "out_shift", "out_sck", "out_1wire", "out_sda", "out_audio", "out_slave", "out_qspi",
    "in_shift", "in_sck", "in_1wire", "in_sda", "in_slave", "in_qspi",
    "delay_cycles", "delay_us", "delay_ns", "delay_baud", "delay_hbaud", "nop",
    "set_bank", "jmp_bank",
    "crc_init", "crc_byte", "crc_read_b0", "crc_read_b1", "crc_read_b2", "crc_read_b3",
    "crc_read_low", "crc_read_high", "crc_reset",
    "assist_nrzi", "assist_bitstuff", "assist_manchester", "assist_reset",
    "assist_pulse_cfg", "assist_gamepad_cfg", "assist_pulse_time0", "assist_pulse_time1",
    "assist_i2c_slave_cfg", "assist_i2c_release_scl", "assist_i2c_slave_disable",
    "assist_audio_cfg", "assist_audio_vol", "assist_audio_sample", "assist_audio_duty",
    "assist_audio_note", "assist_audio_play", "assist_audio_stop",
    "assist_jtag_cfg", "assist_jtag_tms", "assist_jtag_nav", "assist_jtag_shift",
    "assist_swd_cfg", "assist_swd_req", "assist_swd_reset", "assist_swd_rd32", "assist_swd_wr32",
    "assist_qspi_cfg", "assist_qspi_cs", "assist_qspi_cmd",
    "assist_glitch_cfg", "assist_glitch_arm", "assist_mitm_cfg", "assist_mitm_rule",
    "rol", "ror", "not", "inv", "clr", "cmp", "set_lc", "mov_lc"
}

TYPE_TOKENS = (
    TokenType.VOID, TokenType.UINT8_T, TokenType.INT8_T,
    TokenType.UINT16_T, TokenType.INT, TokenType.UNSIGNED, TokenType.SIGNED,
    TokenType.CHAR, TokenType.BOOL
)


class OmniCParser:
    """Parser for the Omni-C Language."""

    def __init__(self, tokens: List[Token], filename: str = "<stdin>"):
        self.tokens = tokens
        self.filename = filename
        self.pos = 0
        self.length = len(tokens)

    def _peek(self, offset: int = 0) -> Token:
        idx = self.pos + offset
        if idx < self.length:
            return self.tokens[idx]
        return self.tokens[-1]  # EOF token

    def _advance(self) -> Token:
        tok = self._peek()
        if self.pos < self.length:
            self.pos += 1
        return tok

    def _match(self, *expected_types: str) -> bool:
        if self._peek().type in expected_types:
            self._advance()
            return True
        return False

    def _expect(self, expected_type: str, msg: Optional[str] = None) -> Token:
        tok = self._peek()
        if tok.type != expected_type:
            err_msg = msg or f"Expected '{expected_type}', got '{tok.type}' (value: {tok.value})"
            raise ParserError(err_msg, tok.line, tok.col)
        return self._advance()

    def parse(self) -> Program:
        decls: List[ASTNode] = []
        while not self._match(TokenType.EOF):
            # Check for preprocessor or global declaration
            tok = self._peek()
            if tok.type == TokenType.IDENTIFIER and isinstance(tok.value, str) and tok.value.startswith("#"):
                decls.append(self._parse_preprocessor())
            elif tok.type in TYPE_TOKENS or tok.type in (TokenType.REG, TokenType.CONST):
                decls.append(self._parse_global_decl_or_func())
            elif tok.type == TokenType.ASM:
                decls.append(self._parse_asm_stmt())
            elif tok.type == TokenType.SEMICOLON:
                self._advance()
            else:
                raise ParserError(f"Unexpected top-level token: {tok}", tok.line, tok.col)

        return Program(decls, line=1, col=1)

    def _parse_preprocessor(self) -> ASTNode:
        tok = self._advance()
        text = tok.value
        parts = text.split(maxsplit=2)
        cmd = parts[0]  # #pragma, #define, #include
        if cmd == "#pragma" and len(parts) >= 3:
            return PragmaDirective(parts[1], parts[2], line=tok.line, col=tok.col)
        elif cmd == "#define" and len(parts) >= 3:
            raw_val = parts[2].strip()
            val = raw_val
            try:
                if raw_val.lower().startswith("0x"):
                    val = int(raw_val, 16)
                elif raw_val.lower().startswith("0b"):
                    val = int(raw_val, 2)
                elif raw_val.isdigit() or (raw_val.startswith("-") and raw_val[1:].isdigit()):
                    val = int(raw_val, 10)
            except ValueError:
                val = raw_val
            return VarDecl("const", parts[1], Literal(val, raw=raw_val, line=tok.line, col=tok.col),
                           is_const=True, line=tok.line, col=tok.col)
        return PragmaDirective(cmd, text, line=tok.line, col=tok.col)

    def _parse_global_decl_or_func(self) -> ASTNode:
        start_tok = self._peek()
        is_const = False
        reg_hint = None
        has_reg_keyword = False

        if self._match(TokenType.CONST):
            is_const = True

        if self._match(TokenType.REG):
            has_reg_keyword = True
            # Optional register name: reg r0 my_var; or reg acc;
            next_tok = self._peek()
            if next_tok.value in ("acc", "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7",
                                 "osr", "isr", "lc0", "lc1", "bank"):
                reg_hint = self._advance().value

        if self._peek().type in TYPE_TOKENS:
            type_tok = self._advance()
            type_name = type_tok.value
        elif has_reg_keyword:
            type_name = "reg"
        else:
            type_tok = self._advance()
            type_name = type_tok.value

        name_tok = self._expect(TokenType.IDENTIFIER, "Expected identifier after type")
        name = name_tok.value

        # Check if function: name(...) { ... }
        if self._match(TokenType.LPAREN):
            params = self._parse_param_list()
            self._expect(TokenType.RPAREN, "Expected ')' after parameter list")
            body = self._parse_block()
            is_entry = (name == "main")
            return FunctionDef(type_name, name, params, body, is_entry=is_entry,
                               line=start_tok.line, col=start_tok.col)
        else:
            # Global variable declaration
            init_expr = None
            if self._match(TokenType.ASSIGN):
                init_expr = self._parse_expression()
            self._expect(TokenType.SEMICOLON, "Expected ';' after variable declaration")
            return VarDecl(type_name, name, init_expr=init_expr, reg_hint=reg_hint,
                           is_const=is_const, line=start_tok.line, col=start_tok.col)

    def _parse_param_list(self) -> List[VarDecl]:
        params: List[VarDecl] = []
        if self._peek().type == TokenType.RPAREN:
            return params

        while True:
            if self._peek().type == TokenType.VOID and self._peek(1).type == TokenType.RPAREN:
                self._advance()
                break

            reg_hint = None
            has_reg_keyword = False
            if self._match(TokenType.REG):
                has_reg_keyword = True
                if self._peek().value in ("acc", "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7"):
                    reg_hint = self._advance().value

            if self._peek().type in TYPE_TOKENS:
                type_tok = self._advance()
                type_name = type_tok.value
            elif has_reg_keyword:
                type_name = "reg"
            else:
                type_tok = self._advance()
                type_name = type_tok.value

            name_tok = self._expect(TokenType.IDENTIFIER, "Expected parameter name")
            params.append(VarDecl(type_name, name_tok.value, reg_hint=reg_hint,
                                  line=name_tok.line, col=name_tok.col))

            if not self._match(TokenType.COMMA):
                break
        return params

    def _parse_block(self) -> Block:
        start_tok = self._expect(TokenType.LBRACE, "Expected '{' to begin block")
        statements: List[ASTNode] = []

        while not self._match(TokenType.RBRACE):
            if self._peek().type == TokenType.EOF:
                raise ParserError("Unclosed block, expected '}'", start_tok.line, start_tok.col)
            statements.append(self._parse_statement())

        return Block(statements, line=start_tok.line, col=start_tok.col)

    def _parse_statement(self) -> ASTNode:
        tok = self._peek()

        # Block
        if tok.type == TokenType.LBRACE:
            return self._parse_block()

        # Inline Assembly: __asm__("..."); or asm("...");
        if tok.type == TokenType.ASM:
            return self._parse_asm_stmt()

        # Variable Declaration: uint8_t x; reg r0 y;
        if tok.type in TYPE_TOKENS or tok.type in (TokenType.REG, TokenType.CONST):
            return self._parse_local_var_decl()

        # If Statement
        if tok.type == TokenType.IF:
            return self._parse_if_stmt()

        # While Loop
        if tok.type == TokenType.WHILE:
            return self._parse_while_stmt()

        # Do-While Loop
        if tok.type == TokenType.DO:
            return self._parse_do_while_stmt()

        # Repeat / For Loop
        if tok.type == TokenType.REPEAT:
            return self._parse_repeat_stmt()

        if tok.type == TokenType.FOR:
            return self._parse_for_stmt()

        # Return Statement
        if tok.type == TokenType.RETURN:
            self._advance()
            val = None
            if self._peek().type != TokenType.SEMICOLON:
                val = self._parse_expression()
            self._expect(TokenType.SEMICOLON, "Expected ';' after return")
            return ReturnStmt(val, line=tok.line, col=tok.col)

        # Break / Continue
        if tok.type == TokenType.BREAK:
            self._advance()
            self._expect(TokenType.SEMICOLON, "Expected ';' after break")
            return BreakStmt(line=tok.line, col=tok.col)

        if tok.type == TokenType.CONTINUE:
            self._advance()
            self._expect(TokenType.SEMICOLON, "Expected ';' after continue")
            return ContinueStmt(line=tok.line, col=tok.col)

        # Goto Statement: goto label;
        if tok.type == TokenType.GOTO:
            self._advance()
            target = self._expect(TokenType.IDENTIFIER, "Expected label name after goto").value
            self._expect(TokenType.SEMICOLON, "Expected ';' after goto target")
            return GotoStmt(target, line=tok.line, col=tok.col)

        # Label Statement: label_name:
        if tok.type == TokenType.IDENTIFIER and self._peek(1).type == TokenType.COLON:
            label_name = self._advance().value
            self._advance()  # Skip ':'
            return LabelStmt(label_name, line=tok.line, col=tok.col)

        # Expression Statement or Assignment
        expr = self._parse_expression()
        self._expect(TokenType.SEMICOLON, "Expected ';' after statement")
        return ExprStmt(expr, line=tok.line, col=tok.col)

    def _parse_asm_stmt(self) -> AsmStmt:
        start_tok = self._advance()  # asm / __asm__
        self._expect(TokenType.LPAREN, "Expected '(' after asm")
        asm_code_tok = self._expect(TokenType.STR_LITERAL, "Expected string literal for inline assembly")
        self._expect(TokenType.RPAREN, "Expected ')' after asm string")
        self._expect(TokenType.SEMICOLON, "Expected ';' after asm statement")
        return AsmStmt(asm_code_tok.value, line=start_tok.line, col=start_tok.col)

    def _parse_local_var_decl(self) -> VarDecl:

        start_tok = self._peek()
        is_const = False
        reg_hint = None
        has_reg_keyword = False

        if self._match(TokenType.CONST):
            is_const = True

        if self._match(TokenType.REG):
            has_reg_keyword = True
            if self._peek().value in ("acc", "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7",
                                      "osr", "isr", "lc0", "lc1"):
                reg_hint = self._advance().value

        if self._peek().type in TYPE_TOKENS:
            type_tok = self._advance()
            type_name = type_tok.value
        elif has_reg_keyword:
            type_name = "reg"
        else:
            type_tok = self._advance()
            type_name = type_tok.value

        name_tok = self._expect(TokenType.IDENTIFIER, "Expected variable name")

        init_expr = None
        if self._match(TokenType.ASSIGN):
            init_expr = self._parse_expression()

        self._expect(TokenType.SEMICOLON, "Expected ';' after variable declaration")
        return VarDecl(type_name, name_tok.value, init_expr=init_expr,
                       reg_hint=reg_hint, is_const=is_const, line=start_tok.line, col=start_tok.col)


    def _parse_if_stmt(self) -> IfStmt:
        start_tok = self._advance()  # 'if'
        self._expect(TokenType.LPAREN, "Expected '(' after if")
        cond = self._parse_expression()
        self._expect(TokenType.RPAREN, "Expected ')' after if condition")

        then_branch = self._parse_statement()
        else_branch = None
        if self._match(TokenType.ELSE):
            else_branch = self._parse_statement()

        return IfStmt(cond, then_branch, else_branch, line=start_tok.line, col=start_tok.col)

    def _parse_while_stmt(self) -> WhileStmt:
        start_tok = self._advance()  # 'while'
        self._expect(TokenType.LPAREN, "Expected '(' after while")
        cond = self._parse_expression()
        self._expect(TokenType.RPAREN, "Expected ')' after while condition")
        body = self._parse_statement()
        return WhileStmt(cond, body, line=start_tok.line, col=start_tok.col)

    def _parse_do_while_stmt(self) -> DoWhileStmt:
        start_tok = self._advance()  # 'do'
        body = self._parse_statement()
        self._expect(TokenType.WHILE, "Expected 'while' after do block")
        self._expect(TokenType.LPAREN, "Expected '(' after while")
        cond = self._parse_expression()
        self._expect(TokenType.RPAREN, "Expected ')' after while condition")
        self._expect(TokenType.SEMICOLON, "Expected ';' after do-while")
        return DoWhileStmt(body, cond, line=start_tok.line, col=start_tok.col)

    def _parse_repeat_stmt(self) -> RepeatStmt:
        start_tok = self._advance()  # 'repeat'
        self._expect(TokenType.LPAREN, "Expected '(' after repeat")
        count_expr = self._parse_expression()
        self._expect(TokenType.RPAREN, "Expected ')' after repeat count")
        body = self._parse_statement()
        return RepeatStmt(count_expr, body, counter_id=0, line=start_tok.line, col=start_tok.col)

    def _ast_contains_var(self, node: Optional[ASTNode], var_name: str) -> bool:
        """Checks recursively whether an AST subtree references a variable name."""
        if node is None:
            return False
        if isinstance(node, Identifier):
            return node.name == var_name
        if isinstance(node, (Literal, BreakStmt, ContinueStmt, AsmStmt, PragmaDirective, GotoStmt, LabelStmt)):
            return False
        if isinstance(node, Block):
            return any(self._ast_contains_var(s, var_name) for s in node.statements)
        if isinstance(node, VarDecl):
            return self._ast_contains_var(node.init_expr, var_name)
        if isinstance(node, AssignStmt):
            return self._ast_contains_var(node.target, var_name) or self._ast_contains_var(node.value, var_name)
        if isinstance(node, IfStmt):
            return (self._ast_contains_var(node.condition, var_name) or
                    self._ast_contains_var(node.then_branch, var_name) or
                    self._ast_contains_var(node.else_branch, var_name))
        if isinstance(node, WhileStmt):
            return self._ast_contains_var(node.condition, var_name) or self._ast_contains_var(node.body, var_name)
        if isinstance(node, DoWhileStmt):
            return self._ast_contains_var(node.body, var_name) or self._ast_contains_var(node.condition, var_name)
        if isinstance(node, RepeatStmt):
            return self._ast_contains_var(node.count_expr, var_name) or self._ast_contains_var(node.body, var_name)
        if isinstance(node, ReturnStmt):
            return self._ast_contains_var(node.value, var_name)
        if isinstance(node, ExprStmt):
            return self._ast_contains_var(node.expr, var_name)
        if isinstance(node, BinaryOp):
            return self._ast_contains_var(node.left, var_name) or self._ast_contains_var(node.right, var_name)
        if isinstance(node, UnaryOp):
            return self._ast_contains_var(node.expr, var_name)
        if isinstance(node, BuiltinCall):
            return any(self._ast_contains_var(arg, var_name) for arg in node.args)
        return False

    def _try_optimize_for_to_repeat(self, init_stmt: Optional[ASTNode],
                                    cond_expr: Optional[ASTNode],
                                    step_expr: Optional[ASTNode],
                                    body: ASTNode,
                                    line: int, col: int) -> Optional[ASTNode]:
        """
        Attempts to recognize standard count-based for loops and optimize them
        into zero-overhead hardware RepeatStmt (using LC0/LC1 and single-cycle DJNZ).

        Recognized patterns:
          for (uint8_t i = 0; i < N; i++)
          for (int i = 0; i < N; i++)
          for (i = 0; i < N; ++i)
          for (i = N; i > 0; i--)
          for (i = 1; i <= N; i++)
        """
        if cond_expr is None or step_expr is None:
            return None

        var_name = None
        start_val = None

        if isinstance(init_stmt, VarDecl):
            var_name = init_stmt.name
            if isinstance(init_stmt.init_expr, Literal) and isinstance(init_stmt.init_expr.value, int):
                start_val = init_stmt.init_expr.value
        elif isinstance(init_stmt, ExprStmt) and isinstance(init_stmt.expr, AssignStmt):
            assign = init_stmt.expr
            if isinstance(assign.target, Identifier) and assign.op == "=":
                var_name = assign.target.name
                if isinstance(assign.value, Literal) and isinstance(assign.value.value, int):
                    start_val = assign.value.value
        elif isinstance(init_stmt, AssignStmt):
            if isinstance(init_stmt.target, Identifier) and init_stmt.op == "=":
                var_name = init_stmt.target.name
                if isinstance(init_stmt.value, Literal) and isinstance(init_stmt.value.value, int):
                    start_val = init_stmt.value.value

        if not var_name:
            return None

        # Check step
        step_dir = None
        if isinstance(step_expr, UnaryOp):
            if step_expr.op == "++" and isinstance(step_expr.expr, Identifier) and step_expr.expr.name == var_name:
                step_dir = +1
            elif step_expr.op == "--" and isinstance(step_expr.expr, Identifier) and step_expr.expr.name == var_name:
                step_dir = -1
        elif isinstance(step_expr, AssignStmt):
            if isinstance(step_expr.target, Identifier) and step_expr.target.name == var_name:
                if step_expr.op == "+=" and isinstance(step_expr.value, Literal) and step_expr.value.value == 1:
                    step_dir = +1
                elif step_expr.op == "-=" and isinstance(step_expr.value, Literal) and step_expr.value.value == 1:
                    step_dir = -1
                elif step_expr.op == "=" and isinstance(step_expr.value, BinaryOp):
                    b = step_expr.value
                    if b.op == "+" and isinstance(b.left, Identifier) and b.left.name == var_name:
                        if isinstance(b.right, Literal) and b.right.value == 1:
                            step_dir = +1
                    elif b.op == "-" and isinstance(b.left, Identifier) and b.left.name == var_name:
                        if isinstance(b.right, Literal) and b.right.value == 1:
                            step_dir = -1

        if step_dir is None:
            return None

        count_node = None

        if step_dir == +1:
            # for (i = 0; i < N; i++) or for (i = 0; i <= N; i++)
            if isinstance(cond_expr, BinaryOp):
                if isinstance(cond_expr.left, Identifier) and cond_expr.left.name == var_name:
                    if cond_expr.op == "<":
                        if start_val == 0:
                            count_node = cond_expr.right
                        elif isinstance(start_val, int) and isinstance(cond_expr.right, Literal) and isinstance(cond_expr.right.value, int):
                            count_node = Literal(cond_expr.right.value - start_val, line=line, col=col)
                    elif cond_expr.op == "<=":
                        if start_val == 0 and isinstance(cond_expr.right, Literal) and isinstance(cond_expr.right.value, int):
                            count_node = Literal(cond_expr.right.value + 1, line=line, col=col)
                        elif start_val == 1:
                            count_node = cond_expr.right
                        elif isinstance(start_val, int) and isinstance(cond_expr.right, Literal) and isinstance(cond_expr.right.value, int):
                            count_node = Literal(cond_expr.right.value - start_val + 1, line=line, col=col)

        elif step_dir == -1:
            # for (i = N; i > 0; i--) or for (i = N; i >= 1; i--) or for (i = N; i != 0; i--)
            if isinstance(cond_expr, BinaryOp):
                if isinstance(cond_expr.left, Identifier) and cond_expr.left.name == var_name:
                    if cond_expr.op in (">", "!="):
                        if isinstance(cond_expr.right, Literal) and cond_expr.right.value == 0:
                            if start_val is not None:
                                count_node = Literal(start_val, line=line, col=col)
                    elif cond_expr.op == ">=":
                        if isinstance(cond_expr.right, Literal) and cond_expr.right.value == 1:
                            if start_val is not None:
                                count_node = Literal(start_val, line=line, col=col)

        if count_node is None:
            return None

        # Check if the induction variable is used in the body
        if self._ast_contains_var(body, var_name):
            return None

        # Successfully synthesized zero-overhead RepeatStmt!
        return RepeatStmt(count_node, body, counter_id=0, line=line, col=col)

    def _parse_for_stmt(self) -> ASTNode:
        start_tok = self._advance()  # 'for'
        self._expect(TokenType.LPAREN, "Expected '(' after for")

        init_stmt = None
        if self._peek().type != TokenType.SEMICOLON:
            if self._peek().type in TYPE_TOKENS or self._peek().type in (TokenType.REG, TokenType.CONST):
                init_stmt = self._parse_local_var_decl()
            else:
                init_expr = self._parse_expression()
                self._expect(TokenType.SEMICOLON, "Expected ';' after for init")
                init_stmt = ExprStmt(init_expr, line=start_tok.line, col=start_tok.col)
        else:
            self._advance()

        cond_expr = None
        if self._peek().type != TokenType.SEMICOLON:
            cond_expr = self._parse_expression()
        self._expect(TokenType.SEMICOLON, "Expected ';' after for condition")

        step_expr = None
        if self._peek().type != TokenType.RPAREN:
            step_expr = self._parse_expression()
        self._expect(TokenType.RPAREN, "Expected ')' after for clauses")

        body = self._parse_statement()

        # Optimize for-loops into zero-overhead hardware RepeatStmt if applicable
        repeat_stmt = self._try_optimize_for_to_repeat(init_stmt, cond_expr, step_expr, body,
                                                       start_tok.line, start_tok.col)
        if repeat_stmt is not None:
            return repeat_stmt

        # Fallback: General for loop desugaring -> { init; while (cond) { body; step; } }
        loop_stmts = [body]
        if step_expr:
            loop_stmts.append(ExprStmt(step_expr, line=start_tok.line, col=start_tok.col))
        while_body = Block(loop_stmts, line=start_tok.line, col=start_tok.col)
        while_stmt = WhileStmt(cond_expr or Literal(1, line=start_tok.line, col=start_tok.col),
                               while_body, line=start_tok.line, col=start_tok.col)

        if init_stmt:
            return Block([init_stmt, while_stmt], line=start_tok.line, col=start_tok.col)
        return while_stmt

    # -------------------------------------------------------------------------
    # Expression Parsing (Precedence Climbing)
    # -------------------------------------------------------------------------

    def _parse_expression(self) -> ASTNode:
        return self._parse_assignment()

    def _parse_assignment(self) -> ASTNode:
        expr = self._parse_logical_or()

        assign_ops = (TokenType.ASSIGN, TokenType.PLUS_ASSIGN, TokenType.MINUS_ASSIGN,
                      TokenType.AMP_ASSIGN, TokenType.PIPE_ASSIGN, TokenType.CARET_ASSIGN,
                      TokenType.LSHIFT_ASSIGN, TokenType.RSHIFT_ASSIGN)

        if self._peek().type in assign_ops:
            op_tok = self._advance()
            val = self._parse_assignment()
            return AssignStmt(expr, op_tok.type, val, line=op_tok.line, col=op_tok.col)

        return expr

    def _parse_logical_or(self) -> ASTNode:
        expr = self._parse_logical_and()
        while self._match(TokenType.OR):
            op = "||"
            right = self._parse_logical_and()
            expr = BinaryOp(expr, op, right, line=expr.line, col=expr.col)
        return expr

    def _parse_logical_and(self) -> ASTNode:
        expr = self._parse_bitwise_or()
        while self._match(TokenType.AND):
            op = "&&"
            right = self._parse_bitwise_or()
            expr = BinaryOp(expr, op, right, line=expr.line, col=expr.col)
        return expr

    def _parse_bitwise_or(self) -> ASTNode:
        expr = self._parse_bitwise_xor()
        while self._match(TokenType.PIPE):
            op = "|"
            right = self._parse_bitwise_xor()
            expr = BinaryOp(expr, op, right, line=expr.line, col=expr.col)
        return expr

    def _parse_bitwise_xor(self) -> ASTNode:
        expr = self._parse_bitwise_and()
        while self._match(TokenType.CARET):
            op = "^"
            right = self._parse_bitwise_and()
            expr = BinaryOp(expr, op, right, line=expr.line, col=expr.col)
        return expr

    def _parse_bitwise_and(self) -> ASTNode:
        expr = self._parse_equality()
        while self._match(TokenType.AMP):
            op = "&"
            right = self._parse_equality()
            expr = BinaryOp(expr, op, right, line=expr.line, col=expr.col)
        return expr

    def _parse_equality(self) -> ASTNode:
        expr = self._parse_relational()
        while self._peek().type in (TokenType.EQ, TokenType.NEQ):
            op_tok = self._advance()
            right = self._parse_relational()
            expr = BinaryOp(expr, op_tok.type, right, line=op_tok.line, col=op_tok.col)
        return expr

    def _parse_relational(self) -> ASTNode:
        expr = self._parse_shift()
        while self._peek().type in (TokenType.LT, TokenType.LEQ, TokenType.GT, TokenType.GEQ):
            op_tok = self._advance()
            right = self._parse_shift()
            expr = BinaryOp(expr, op_tok.type, right, line=op_tok.line, col=op_tok.col)
        return expr

    def _parse_shift(self) -> ASTNode:
        expr = self._parse_additive()
        while self._peek().type in (TokenType.LSHIFT, TokenType.RSHIFT):
            op_tok = self._advance()
            right = self._parse_additive()
            expr = BinaryOp(expr, op_tok.type, right, line=op_tok.line, col=op_tok.col)
        return expr

    def _parse_additive(self) -> ASTNode:
        expr = self._parse_multiplicative()
        while self._peek().type in (TokenType.PLUS, TokenType.MINUS):
            op_tok = self._advance()
            right = self._parse_multiplicative()
            expr = BinaryOp(expr, op_tok.type, right, line=op_tok.line, col=op_tok.col)
        return expr

    def _parse_multiplicative(self) -> ASTNode:
        expr = self._parse_unary()
        while self._peek().type in (TokenType.STAR, TokenType.SLASH, TokenType.PERCENT):
            op_tok = self._advance()
            right = self._parse_unary()
            expr = BinaryOp(expr, op_tok.type, right, line=op_tok.line, col=op_tok.col)
        return expr

    def _parse_unary(self) -> ASTNode:
        tok = self._peek()
        if tok.type in (TokenType.PLUS, TokenType.MINUS, TokenType.TILDE, TokenType.BANG,
                        TokenType.INC, TokenType.DEC):
            op_tok = self._advance()
            operand = self._parse_unary()
            return UnaryOp(op_tok.type, operand, is_postfix=False, line=op_tok.line, col=op_tok.col)
        return self._parse_postfix()

    def _parse_postfix(self) -> ASTNode:
        expr = self._parse_primary()
        while self._peek().type in (TokenType.INC, TokenType.DEC):
            op_tok = self._advance()
            expr = UnaryOp(op_tok.type, expr, is_postfix=True, line=op_tok.line, col=op_tok.col)
        return expr

    def _parse_primary(self) -> ASTNode:
        tok = self._peek()

        # Integer Literal
        if tok.type == TokenType.INT_LITERAL:
            self._advance()
            return Literal(tok.value, raw=tok.raw, line=tok.line, col=tok.col)

        # Character Literal
        if tok.type == TokenType.CHAR_LITERAL:
            self._advance()
            return Literal(tok.value, raw=tok.raw, line=tok.line, col=tok.col)

        # String Literal
        if tok.type == TokenType.STR_LITERAL:
            self._advance()
            return Literal(tok.value, raw=tok.raw, line=tok.line, col=tok.col)

        # Sentinel ($BAUD, $HBAUD)
        if tok.type == TokenType.SENTINEL:
            self._advance()
            return Literal(tok.value, raw=tok.raw, line=tok.line, col=tok.col)

        # Parenthesized Expression: (expr)
        if self._match(TokenType.LPAREN):
            expr = self._parse_expression()
            self._expect(TokenType.RPAREN, "Expected ')' to close parenthesized expression")
            return expr

        # Identifier or Function/Builtin Call
        if tok.type == TokenType.IDENTIFIER:
            name_tok = self._advance()
            name = name_tok.value

            # Check if Function or Builtin Call: name(...)
            if self._match(TokenType.LPAREN):
                args = self._parse_arg_list()
                self._expect(TokenType.RPAREN, "Expected ')' after argument list")
                if name in BUILTIN_FUNCTIONS:
                    return BuiltinCall(name, args, line=name_tok.line, col=name_tok.col)
                return BuiltinCall(name, args, line=name_tok.line, col=name_tok.col)

            return Identifier(name, line=name_tok.line, col=name_tok.col)

        raise ParserError(f"Unexpected token in expression: {tok}", tok.line, tok.col)

    def _parse_arg_list(self) -> List[ASTNode]:
        args: List[ASTNode] = []
        if self._peek().type == TokenType.RPAREN:
            return args

        while True:
            args.append(self._parse_expression())
            if not self._match(TokenType.COMMA):
                break
        return args
