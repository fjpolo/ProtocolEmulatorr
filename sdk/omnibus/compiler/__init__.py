# =============================================================================
# File        : __init__.py
# Module      : omnibus.compiler
# Description : High-Level Omni-C Protocol Compiler Module.
# License     : MIT License
# =============================================================================

from .lexer import OmniCLexer, Token, TokenType, LexerError
from .parser import OmniCParser, ParserError
from .ast_nodes import ASTNode, Program, FunctionDef, Block, VarDecl, IfStmt, WhileStmt
from .codegen import OmniCCodeGen, CodeGenError
from .optimizer import PeepholeOptimizer
from .symbols import Scope, Symbol, RegisterAllocator
from .driver import OmniCCompiler, Preprocessor, get_default_include_dir

__all__ = [
    "OmniCLexer",
    "OmniCParser",
    "OmniCCodeGen",
    "PeepholeOptimizer",
    "OmniCCompiler",
    "Preprocessor",
    "Scope",
    "Symbol",
    "RegisterAllocator",
    "get_default_include_dir",
]
