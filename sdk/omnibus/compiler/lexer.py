# =============================================================================
# File        : lexer.py
# Module      : omnibus.compiler.lexer
# Description : Lexer / Tokenizer for the Omni-C Language.
# License     : MIT License
# =============================================================================

import re
from typing import List, Optional, Tuple, NamedTuple, Any


class TokenType:
    # End of File
    EOF = "EOF"

    # Literals & Identifiers
    IDENTIFIER = "IDENTIFIER"
    INT_LITERAL = "INT_LITERAL"
    STR_LITERAL = "STR_LITERAL"
    CHAR_LITERAL = "CHAR_LITERAL"
    SENTINEL = "SENTINEL"  # $BAUD, $HBAUD

    # Keywords
    VOID = "void"
    UINT8_T = "uint8_t"
    INT8_T = "int8_t"
    UINT16_T = "uint16_t"
    INT = "int"
    UNSIGNED = "unsigned"
    SIGNED = "signed"
    CHAR = "char"
    BOOL = "bool"
    CONST = "const"
    REG = "reg"
    IF = "if"
    ELSE = "else"
    WHILE = "while"
    DO = "do"
    FOR = "for"
    REPEAT = "repeat"
    SWITCH = "switch"
    CASE = "case"
    DEFAULT = "default"
    RETURN = "return"
    BREAK = "break"
    CONTINUE = "continue"
    GOTO = "goto"
    ASM = "asm"
    PRAGMA = "pragma"

    # Operators
    PLUS = "+"
    MINUS = "-"
    STAR = "*"
    SLASH = "/"
    PERCENT = "%"
    AMP = "&"
    PIPE = "|"
    CARET = "^"
    TILDE = "~"
    BANG = "!"
    LSHIFT = "<<"
    RSHIFT = ">>"
    EQ = "=="
    NEQ = "!="
    LT = "<"
    LEQ = "<="
    GT = ">"
    GEQ = ">="
    AND = "&&"
    OR = "||"
    ASSIGN = "="
    PLUS_ASSIGN = "+="
    MINUS_ASSIGN = "-="
    AMP_ASSIGN = "&="
    PIPE_ASSIGN = "|="
    CARET_ASSIGN = "^="
    LSHIFT_ASSIGN = "<<="
    RSHIFT_ASSIGN = ">>="
    INC = "++"
    DEC = "--"

    # Delimiters
    SEMICOLON = ";"
    COMMA = ","
    COLON = ":"
    LPAREN = "("
    RPAREN = ")"
    LBRACE = "{"
    RBRACE = "}"
    LBRACKET = "["
    RBRACKET = "]"


KEYWORDS = {
    "void": TokenType.VOID,
    "uint8_t": TokenType.UINT8_T,
    "int8_t": TokenType.INT8_T,
    "uint16_t": TokenType.UINT16_T,
    "int": TokenType.INT,
    "unsigned": TokenType.UNSIGNED,
    "signed": TokenType.SIGNED,
    "char": TokenType.CHAR,
    "bool": TokenType.BOOL,
    "const": TokenType.CONST,
    "reg": TokenType.REG,
    "if": TokenType.IF,
    "else": TokenType.ELSE,
    "while": TokenType.WHILE,
    "do": TokenType.DO,
    "for": TokenType.FOR,
    "repeat": TokenType.REPEAT,
    "switch": TokenType.SWITCH,
    "case": TokenType.CASE,
    "default": TokenType.DEFAULT,
    "return": TokenType.RETURN,
    "break": TokenType.BREAK,
    "continue": TokenType.CONTINUE,
    "goto": TokenType.GOTO,
    "asm": TokenType.ASM,
    "__asm__": TokenType.ASM,
    "__asm": TokenType.ASM,
}


class Token(NamedTuple):
    type: str
    value: Any = None
    line: int = 1
    col: int = 1
    raw: str = ""

    def __repr__(self) -> str:
        return f"Token({self.type}, {repr(self.value)}, L{self.line}:C{self.col})"


class LexerError(Exception):
    def __init__(self, message: str, line: int, col: int):
        super().__init__(f"Lexer error at line {line}, col {col}: {message}")
        self.line = line
        self.col = col


class OmniCLexer:
    """Lexical analyzer for Omni-C source code."""

    def __init__(self, source: str, filename: str = "<stdin>"):
        self.source = source
        self.filename = filename
        self.pos = 0
        self.line = 1
        self.col = 1
        self.length = len(source)

    def _peek(self, offset: int = 0) -> str:
        idx = self.pos + offset
        if idx < self.length:
            return self.source[idx]
        return ""

    def _advance(self) -> str:
        if self.pos < self.length:
            ch = self.source[self.pos]
            self.pos += 1
            if ch == "\n":
                self.line += 1
                self.col = 1
            else:
                self.col += 1
            return ch
        return ""

    def _skip_whitespace_and_comments(self):
        while self.pos < self.length:
            ch = self._peek()
            if ch in (" ", "\t", "\r", "\n"):
                self._advance()
            elif ch == "/" and self._peek(1) == "/":
                # Single-line comment
                while self.pos < self.length and self._peek() != "\n":
                    self._advance()
            elif ch == "/" and self._peek(1) == "*":
                # Multi-line comment
                self._advance()  # /
                self._advance()  # *
                start_line, start_col = self.line, self.col
                while self.pos < self.length:
                    if self._peek() == "*" and self._peek(1) == "/":
                        self._advance()
                        self._advance()
                        break
                    self._advance()
                else:
                    raise LexerError("Unterminated multi-line comment", start_line, start_col)
            else:
                break

    def tokenize(self) -> List[Token]:
        tokens: List[Token] = []

        while self.pos < self.length:
            self._skip_whitespace_and_comments()
            if self.pos >= self.length:
                break

            start_line = self.line
            start_col = self.col
            ch = self._peek()

            # Preprocessor Directives (#define, `define, #pragma, #include, `include)
            if ch in ("#", "`"):
                tokens.append(self._read_preprocessor())
                continue

            # Special Sentinels ($BAUD, $HBAUD)
            if ch == "$":
                self._advance()
                ident_start = self.pos
                while self.pos < self.length and (self._peek().isalnum() or self._peek() == "_"):
                    self._advance()
                sentinel_name = "$" + self.source[ident_start:self.pos]
                tokens.append(Token(TokenType.SENTINEL, sentinel_name, start_line, start_col, sentinel_name))
                continue

            # Numbers (Hex, Binary, Decimal)
            if ch.isdigit():
                tokens.append(self._read_number())
                continue

            # Identifiers and Keywords
            if ch.isalpha() or ch == "_":
                tokens.append(self._read_identifier_or_keyword())
                continue

            # String Literals
            if ch == '"':
                tokens.append(self._read_string())
                continue

            # Character Literals
            if ch == "'":
                tokens.append(self._read_char())
                continue

            # Two-character and Three-character Operators
            two_ch = ch + self._peek(1)
            three_ch = two_ch + self._peek(2)

            if three_ch in (TokenType.LSHIFT_ASSIGN, TokenType.RSHIFT_ASSIGN):
                self._advance()
                self._advance()
                self._advance()
                tokens.append(Token(three_ch, three_ch, start_line, start_col, three_ch))
                continue

            if two_ch in (TokenType.EQ, TokenType.NEQ, TokenType.LEQ, TokenType.GEQ,
                          TokenType.AND, TokenType.OR, TokenType.LSHIFT, TokenType.RSHIFT,
                          TokenType.PLUS_ASSIGN, TokenType.MINUS_ASSIGN, TokenType.AMP_ASSIGN,
                          TokenType.PIPE_ASSIGN, TokenType.CARET_ASSIGN,
                          TokenType.INC, TokenType.DEC):
                self._advance()
                self._advance()
                tokens.append(Token(two_ch, two_ch, start_line, start_col, two_ch))
                continue

            # Single-character Operators and Punctuation
            if ch in ("+", "-", "*", "/", "%", "&", "|", "^", "~", "!",
                      "<", ">", "=", ";", ",", ":", "(", ")", "{", "}", "[", "]"):
                self._advance()
                tokens.append(Token(ch, ch, start_line, start_col, ch))
                continue

            raise LexerError(f"Unexpected character '{ch}'", start_line, start_col)

        tokens.append(Token(TokenType.EOF, None, self.line, self.col, ""))
        return tokens

    def _read_number(self) -> Token:
        start_line = self.line
        start_col = self.col
        start_pos = self.pos

        # Check Hex (0x...) or Binary (0b...)
        if self._peek() == "0" and self._peek(1) in ("x", "X"):
            self._advance()
            self._advance()
            while self.pos < self.length and (self._peek().isdigit() or self._peek().lower() in "abcdef"):
                self._advance()
            raw_str = self.source[start_pos:self.pos]
            val = int(raw_str, 16)
            return Token(TokenType.INT_LITERAL, val, start_line, start_col, raw_str)

        if self._peek() == "0" and self._peek(1) in ("b", "B"):
            self._advance()
            self._advance()
            while self.pos < self.length and self._peek() in "01_":
                self._advance()
            raw_str = self.source[start_pos:self.pos]
            clean_str = raw_str[2:].replace("_", "")
            val = int(clean_str, 2)
            return Token(TokenType.INT_LITERAL, val, start_line, start_col, raw_str)

        # Decimal
        while self.pos < self.length and (self._peek().isdigit() or self._peek() == "_"):
            self._advance()
        raw_str = self.source[start_pos:self.pos]
        val = int(raw_str.replace("_", ""), 10)
        return Token(TokenType.INT_LITERAL, val, start_line, start_col, raw_str)

    def _read_identifier_or_keyword(self) -> Token:
        start_line = self.line
        start_col = self.col
        start_pos = self.pos

        while self.pos < self.length and (self._peek().isalnum() or self._peek() == "_"):
            self._advance()

        text = self.source[start_pos:self.pos]
        token_type = KEYWORDS.get(text, TokenType.IDENTIFIER)
        return Token(token_type, text, start_line, start_col, text)

    def _read_string(self) -> Token:
        start_line = self.line
        start_col = self.col
        self._advance()  # Skip opening "
        content = []

        while self.pos < self.length and self._peek() != '"':
            ch = self._advance()
            if ch == "\\":
                esc = self._advance()
                if esc == "n": content.append("\n")
                elif esc == "t": content.append("\t")
                elif esc == "r": content.append("\r")
                elif esc == "\\": content.append("\\")
                elif esc == '"': content.append('"')
                elif esc == "0": content.append("\0")
                else: content.append(esc)
            else:
                content.append(ch)

        if self.pos >= self.length or self._peek() != '"':
            raise LexerError("Unterminated string literal", start_line, start_col)

        self._advance()  # Skip closing "
        s_val = "".join(content)
        return Token(TokenType.STR_LITERAL, s_val, start_line, start_col, s_val)

    def _read_char(self) -> Token:
        start_line = self.line
        start_col = self.col
        self._advance()  # Skip opening '
        if self._peek() == "\\":
            self._advance()
            esc = self._advance()
            if esc == "n": val = ord("\n")
            elif esc == "t": val = ord("\t")
            elif esc == "0": val = 0
            else: val = ord(esc)
        else:
            val = ord(self._advance())

        if self._peek() != "'":
            raise LexerError("Unterminated character literal", start_line, start_col)
        self._advance()  # Skip closing '
        return Token(TokenType.CHAR_LITERAL, val, start_line, start_col, chr(val))

    def _read_preprocessor(self) -> Token:
        start_line = self.line
        start_col = self.col
        self._advance()  # Skip '#'

        start_pos = self.pos
        while self.pos < self.length and self._peek().isalpha():
            self._advance()
        directive = self.source[start_pos:self.pos]

        # Read rest of line
        line_start = self.pos
        while self.pos < self.length and self._peek() != "\n":
            self._advance()
        rest = self.source[line_start:self.pos].strip()

        # Strip trailing // comments
        if "//" in rest:
            rest = rest.split("//")[0].strip()
        # Strip trailing /* ... */ comments
        if "/*" in rest and "*/" in rest:
            rest = re.sub(r"/\*.*?\*/", "", rest).strip()

        return Token(TokenType.IDENTIFIER, f"#{directive} {rest}", start_line, start_col, f"#{directive} {rest}")
