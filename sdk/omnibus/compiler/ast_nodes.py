# =============================================================================
# File        : ast_nodes.py
# Module      : omnibus.compiler.ast_nodes
# Description : Abstract Syntax Tree (AST) Node Definitions for Omni-C Compiler.
# License     : MIT License
# =============================================================================

from typing import List, Optional, Any, Union


class ASTNode:
    """Base class for all Omni-C AST nodes."""
    def __init__(self, line: int = 1, col: int = 1):
        self.line = line
        self.col = col

    def __repr__(self) -> str:
        return f"<{self.__class__.__name__} line={self.line}>"


class Program(ASTNode):
    """Root node representing the entire Omni-C translation unit."""
    def __init__(self, decls: List[ASTNode], line: int = 1, col: int = 1):
        super().__init__(line, col)
        self.decls = decls


class FunctionDef(ASTNode):
    """Function declaration and body."""
    def __init__(self, return_type: str, name: str, params: List["VarDecl"],
                 body: Optional["Block"] = None, is_entry: bool = False, is_prototype: bool = False,
                 line: int = 1, col: int = 1):
        super().__init__(line, col)
        self.return_type = return_type
        self.name = name
        self.params = params
        self.body = body
        self.is_entry = is_entry
        self.is_prototype = is_prototype


class Block(ASTNode):
    """Compound statement block { ... }."""
    def __init__(self, statements: List[ASTNode], line: int = 1, col: int = 1):
        super().__init__(line, col)
        self.statements = statements


class VarDecl(ASTNode):
    """Variable declaration (e.g. uint8_t x = 5; or reg r0 y;)."""
    def __init__(self, var_type: str, name: str, init_expr: Optional[ASTNode] = None,
                 reg_hint: Optional[str] = None, is_const: bool = False,
                 line: int = 1, col: int = 1):
        super().__init__(line, col)
        self.var_type = var_type
        self.name = name
        self.init_expr = init_expr
        self.reg_hint = reg_hint
        self.is_const = is_const


class AssignStmt(ASTNode):
    """Assignment statement (e.g. acc = acc + 1; or r0 = 0x55;)."""
    def __init__(self, target: ASTNode, op: str, value: ASTNode, line: int = 1, col: int = 1):
        super().__init__(line, col)
        self.target = target
        self.op = op  # '=', '+=', '-=', '&=', '|=', '^=', '<<=', '>>='
        self.value = value


class IfStmt(ASTNode):
    """Conditional branching if (cond) { ... } else { ... }."""
    def __init__(self, condition: ASTNode, then_branch: ASTNode,
                 else_branch: Optional[ASTNode] = None, line: int = 1, col: int = 1):
        super().__init__(line, col)
        self.condition = condition
        self.then_branch = then_branch
        self.else_branch = else_branch


class WhileStmt(ASTNode):
    """While loop while (cond) { ... }."""
    def __init__(self, condition: ASTNode, body: ASTNode, line: int = 1, col: int = 1):
        super().__init__(line, col)
        self.condition = condition
        self.body = body


class DoWhileStmt(ASTNode):
    """Do-While loop do { ... } while (cond);."""
    def __init__(self, body: ASTNode, condition: ASTNode, line: int = 1, col: int = 1):
        super().__init__(line, col)
        self.body = body
        self.condition = condition


class RepeatStmt(ASTNode):
    """Hardware counter loop repeat (N) { ... } or for (LC0=N; LC0>0; LC0--)."""
    def __init__(self, count_expr: ASTNode, body: ASTNode, counter_id: int = 0,
                 line: int = 1, col: int = 1):
        super().__init__(line, col)
        self.count_expr = count_expr
        self.body = body
        self.counter_id = counter_id  # 0 for LC0, 1 for LC1


class CaseClause(ASTNode):
    """Case or Default clause in a switch statement."""
    def __init__(self, match_expr: Optional[ASTNode], statements: List[ASTNode],
                 line: int = 1, col: int = 1):
        super().__init__(line, col)
        self.match_expr = match_expr  # None for default
        self.statements = statements


class SwitchStmt(ASTNode):
    """Switch statement switch (expr) { case V: ... default: ... }."""
    def __init__(self, expr: ASTNode, cases: List[CaseClause], line: int = 1, col: int = 1):
        super().__init__(line, col)
        self.expr = expr
        self.cases = cases


class ReturnStmt(ASTNode):
    """Function return statement (RET)."""
    def __init__(self, value: Optional[ASTNode] = None, line: int = 1, col: int = 1):
        super().__init__(line, col)
        self.value = value


class BreakStmt(ASTNode):
    """Loop break statement."""
    pass


class ContinueStmt(ASTNode):
    """Loop continue statement."""
    pass


class GotoStmt(ASTNode):
    """Unconditional jump to label (JMP)."""
    def __init__(self, target_label: str, line: int = 1, col: int = 1):
        super().__init__(line, col)
        self.target_label = target_label


class LabelStmt(ASTNode):
    """Target label statement (e.g. loop_start:)."""
    def __init__(self, name: str, line: int = 1, col: int = 1):
        super().__init__(line, col)
        self.name = name


class AsmStmt(ASTNode):
    """Inline raw assembly instruction (__asm__("..."))."""
    def __init__(self, asm_code: str, line: int = 1, col: int = 1):
        super().__init__(line, col)
        self.asm_code = asm_code


class ExprStmt(ASTNode):
    """Standalone expression statement (e.g. pull(); or pin_set(...);)."""
    def __init__(self, expr: ASTNode, line: int = 1, col: int = 1):
        super().__init__(line, col)
        self.expr = expr


class BinaryOp(ASTNode):
    """Binary operation (e.g. a + b, a == b, a & b)."""
    def __init__(self, left: ASTNode, op: str, right: ASTNode, line: int = 1, col: int = 1):
        super().__init__(line, col)
        self.left = left
        self.op = op
        self.right = right


class UnaryOp(ASTNode):
    """Unary operation (e.g. ~a, !a, -a, ++a, --a)."""
    def __init__(self, op: str, expr: ASTNode, is_postfix: bool = False,
                 line: int = 1, col: int = 1):
        super().__init__(line, col)
        self.op = op
        self.expr = expr
        self.is_postfix = is_postfix


class Identifier(ASTNode):
    """Variable or register identifier (e.g. acc, r0, temp, my_var)."""
    def __init__(self, name: str, line: int = 1, col: int = 1):
        super().__init__(line, col)
        self.name = name


class Literal(ASTNode):
    """Integer or string constant literal (e.g. 42, 0xFF, 'A', "string")."""
    def __init__(self, value: Any, raw: str = "", line: int = 1, col: int = 1):
        super().__init__(line, col)
        self.value = value
        self.raw = raw


class BuiltinCall(ASTNode):
    """Call to a built-in hardware instruction/primitive (e.g. pin_set, pull, push, out_shift)."""
    def __init__(self, name: str, args: List[ASTNode], line: int = 1, col: int = 1):
        super().__init__(line, col)
        self.name = name
        self.args = args


class PragmaDirective(ASTNode):
    """Pragma configuration directive (e.g. #pragma clock 50MHz)."""
    def __init__(self, key: str, value: Any, line: int = 1, col: int = 1):
        super().__init__(line, col)
        self.key = key
        self.value = value
