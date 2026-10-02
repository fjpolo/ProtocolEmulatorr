// =============================================================================
// File        : c_compiler.js
// Module      : OmniBus MP In-Browser Omni-C Compiler & Optimizing Engine
// Description : Full-featured browser-native C compiler for OmniBus ASIC:
//               Preprocessor, Lexer, Parser, AST, Symbol Table, Register Allocator,
//               Multi-Pass Optimizing Code Generator (-O0, -O1, -O2), Switch-Case
//               Jump Tables, and Source-to-Binary Line Location Mapping.
// License     : MIT License
// =============================================================================

import { VIRTUAL_HEADERS } from "./c_headers.js";

// =============================================================================
// 1. TOKEN TYPES & LEXER
// =============================================================================

export const TokenType = {
    EOF: "EOF",
    IDENTIFIER: "IDENTIFIER",
    INT_LITERAL: "INT_LITERAL",
    STR_LITERAL: "STR_LITERAL",
    CHAR_LITERAL: "CHAR_LITERAL",
    SENTINEL: "SENTINEL", // $BAUD, $HBAUD

    // Keywords
    VOID: "void",
    UINT8_T: "uint8_t",
    INT8_T: "int8_t",
    UINT16_T: "uint16_t",
    INT: "int",
    UNSIGNED: "unsigned",
    SIGNED: "signed",
    CHAR: "char",
    BOOL: "bool",
    CONST: "const",
    REG: "reg",
    IF: "if",
    ELSE: "else",
    WHILE: "while",
    DO: "do",
    FOR: "for",
    REPEAT: "repeat",
    SWITCH: "switch",
    CASE: "case",
    DEFAULT: "default",
    RETURN: "return",
    BREAK: "break",
    CONTINUE: "continue",
    GOTO: "goto",
    ASM: "asm",

    // Operators
    PLUS: "+",
    MINUS: "-",
    STAR: "*",
    SLASH: "/",
    PERCENT: "%",
    AMP: "&",
    PIPE: "|",
    CARET: "^",
    TILDE: "~",
    BANG: "!",
    LSHIFT: "<<",
    RSHIFT: ">>",
    EQ: "==",
    NEQ: "!=",
    LT: "<",
    LEQ: "<=",
    GT: ">",
    GEQ: ">=",
    AND: "&&",
    OR: "||",
    ASSIGN: "=",
    PLUS_ASSIGN: "+=",
    MINUS_ASSIGN: "-=",
    AMP_ASSIGN: "&=",
    PIPE_ASSIGN: "|=",
    CARET_ASSIGN: "^=",
    LSHIFT_ASSIGN: "<<=",
    RSHIFT_ASSIGN: ">>=",
    INC: "++",
    DEC: "--",

    // Delimiters
    SEMICOLON: ";",
    COMMA: ",",
    COLON: ":",
    LPAREN: "(",
    RPAREN: ")",
    LBRACE: "{",
    RBRACE: "}",
    LBRACKET: "[",
    RBRACKET: "]"
};

const KEYWORDS = {
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
    "__asm": TokenType.ASM
};

export class Token {
    constructor(type, value, line = 1, col = 1, raw = "") {
        this.type = type;
        this.value = value;
        this.line = line;
        this.col = col;
        this.raw = raw;
    }
}

export class OmniCLexer {
    constructor(source) {
        this.source = source;
        this.pos = 0;
        this.line = 1;
        this.col = 1;
        this.length = source.length;
    }

    _peek(offset = 0) {
        const idx = this.pos + offset;
        return idx < this.length ? this.source[idx] : "\0";
    }

    _advance() {
        const ch = this._peek();
        if (this.pos < this.length) {
            this.pos++;
            if (ch === "\n") {
                this.line++;
                this.col = 1;
            } else {
                this.col++;
            }
        }
        return ch;
    }

    tokenize() {
        const tokens = [];

        while (this.pos < this.length) {
            const ch = this._peek();

            // 1. Whitespace
            if (/\s/.test(ch)) {
                this._advance();
                continue;
            }

            // 2. Comments (// single line or /* multi line */)
            if (ch === "/" && this._peek(1) === "/") {
                while (this.pos < this.length && this._peek() !== "\n") {
                    this._advance();
                }
                continue;
            }

            if (ch === "/" && this._peek(1) === "*") {
                this._advance();
                this._advance();
                while (this.pos < this.length && !(this._peek() === "*" && this._peek(1) === "/")) {
                    this._advance();
                }
                if (this.pos < this.length) {
                    this._advance(); // *
                    this._advance(); // /
                }
                continue;
            }

            const startLine = this.line;
            const startCol = this.col;

            // 3. Sentinels ($BAUD, $HBAUD)
            if (ch === "$") {
                this._advance();
                let ident = "";
                while (/[a-zA-Z0-9_]/.test(this._peek())) {
                    ident += this._advance();
                }
                tokens.push(new Token(TokenType.SENTINEL, "$" + ident.toUpperCase(), startLine, startCol, "$" + ident));
                continue;
            }

            // 4. Numbers (Hex: 0x55, Binary: 0b1010, Dec: 42)
            if (/[0-9]/.test(ch)) {
                let numStr = "";
                if (ch === "0" && (this._peek(1) === "x" || this._peek(1) === "X")) {
                    numStr += this._advance(); // 0
                    numStr += this._advance(); // x
                    while (/[0-9a-fA-F_]/.test(this._peek())) {
                        const digit = this._advance();
                        if (digit !== "_") numStr += digit;
                    }
                    const val = parseInt(numStr, 16);
                    tokens.push(new Token(TokenType.INT_LITERAL, val, startLine, startCol, numStr));
                } else if (ch === "0" && (this._peek(1) === "b" || this._peek(1) === "B")) {
                    numStr += this._advance(); // 0
                    numStr += this._advance(); // b
                    while (/[01_]/.test(this._peek())) {
                        const digit = this._advance();
                        if (digit !== "_") numStr += digit;
                    }
                    const val = parseInt(numStr.substring(2), 2);
                    tokens.push(new Token(TokenType.INT_LITERAL, val, startLine, startCol, numStr));
                } else {
                    while (/[0-9_]/.test(this._peek())) {
                        const digit = this._advance();
                        if (digit !== "_") numStr += digit;
                    }
                    const val = parseInt(numStr, 10);
                    tokens.push(new Token(TokenType.INT_LITERAL, val, startLine, startCol, numStr));
                }
                continue;
            }

            // 5. String Literals ("...")
            if (ch === '"') {
                this._advance();
                let strVal = "";
                while (this.pos < this.length && this._peek() !== '"') {
                    if (this._peek() === "\\") {
                        this._advance();
                        const esc = this._advance();
                        if (esc === "n") strVal += "\n";
                        else if (esc === "r") strVal += "\r";
                        else if (esc === "t") strVal += "\t";
                        else strVal += esc;
                    } else {
                        strVal += this._advance();
                    }
                }
                if (this._peek() === '"') this._advance();
                tokens.push(new Token(TokenType.STR_LITERAL, strVal, startLine, startCol, `"${strVal}"`));
                continue;
            }

            // 6. Character Literals ('A', '\n')
            if (ch === "'") {
                this._advance();
                let charCode = 0;
                if (this._peek() === "\\") {
                    this._advance();
                    const esc = this._advance();
                    if (esc === "n") charCode = 10;
                    else if (esc === "r") charCode = 13;
                    else if (esc === "0") charCode = 0;
                    else charCode = esc.charCodeAt(0);
                } else {
                    charCode = this._advance().charCodeAt(0);
                }
                if (this._peek() === "'") this._advance();
                tokens.push(new Token(TokenType.INT_LITERAL, charCode, startLine, startCol, `'${String.fromCharCode(charCode)}'`));
                continue;
            }

            // 7. Identifiers & Keywords
            if (/[a-zA-Z_]/.test(ch)) {
                let ident = "";
                while (/[a-zA-Z0-9_]/.test(this._peek())) {
                    ident += this._advance();
                }
                const lower = ident.toLowerCase();
                if (lower in KEYWORDS) {
                    tokens.push(new Token(KEYWORDS[lower], lower, startLine, startCol, ident));
                } else {
                    tokens.push(new Token(TokenType.IDENTIFIER, ident, startLine, startCol, ident));
                }
                continue;
            }

            // 8. Multi-character Operators
            const twoChar = ch + this._peek(1);
            const threeChar = ch + this._peek(1) + this._peek(2);

            if (threeChar === "<<=") {
                this._advance(); this._advance(); this._advance();
                tokens.push(new Token(TokenType.LSHIFT_ASSIGN, "<<=", startLine, startCol, threeChar));
                continue;
            }
            if (threeChar === ">>=") {
                this._advance(); this._advance(); this._advance();
                tokens.push(new Token(TokenType.RSHIFT_ASSIGN, ">>=", startLine, startCol, threeChar));
                continue;
            }

            if (twoChar === "==") { this._advance(); this._advance(); tokens.push(new Token(TokenType.EQ, "==", startLine, startCol, twoChar)); continue; }
            if (twoChar === "!=") { this._advance(); this._advance(); tokens.push(new Token(TokenType.NEQ, "!=", startLine, startCol, twoChar)); continue; }
            if (twoChar === "<=") { this._advance(); this._advance(); tokens.push(new Token(TokenType.LEQ, "<=", startLine, startCol, twoChar)); continue; }
            if (twoChar === ">=") { this._advance(); this._advance(); tokens.push(new Token(TokenType.GEQ, ">=", startLine, startCol, twoChar)); continue; }
            if (twoChar === "&&") { this._advance(); this._advance(); tokens.push(new Token(TokenType.AND, "&&", startLine, startCol, twoChar)); continue; }
            if (twoChar === "||") { this._advance(); this._advance(); tokens.push(new Token(TokenType.OR, "||", startLine, startCol, twoChar)); continue; }
            if (twoChar === "<<") { this._advance(); this._advance(); tokens.push(new Token(TokenType.LSHIFT, "<<", startLine, startCol, twoChar)); continue; }
            if (twoChar === ">>") { this._advance(); this._advance(); tokens.push(new Token(TokenType.RSHIFT, ">>", startLine, startCol, twoChar)); continue; }
            if (twoChar === "+=") { this._advance(); this._advance(); tokens.push(new Token(TokenType.PLUS_ASSIGN, "+=", startLine, startCol, twoChar)); continue; }
            if (twoChar === "-=") { this._advance(); this._advance(); tokens.push(new Token(TokenType.MINUS_ASSIGN, "-=", startLine, startCol, twoChar)); continue; }
            if (twoChar === "&=") { this._advance(); this._advance(); tokens.push(new Token(TokenType.AMP_ASSIGN, "&=", startLine, startCol, twoChar)); continue; }
            if (twoChar === "|=") { this._advance(); this._advance(); tokens.push(new Token(TokenType.PIPE_ASSIGN, "|=", startLine, startCol, twoChar)); continue; }
            if (twoChar === "^=") { this._advance(); this._advance(); tokens.push(new Token(TokenType.CARET_ASSIGN, "^=", startLine, startCol, twoChar)); continue; }
            if (twoChar === "++") { this._advance(); this._advance(); tokens.push(new Token(TokenType.INC, "++", startLine, startCol, twoChar)); continue; }
            if (twoChar === "--") { this._advance(); this._advance(); tokens.push(new Token(TokenType.DEC, "--", startLine, startCol, twoChar)); continue; }

            // 9. Single-character delimiters & operators
            const singleChars = {
                "+": TokenType.PLUS, "-": TokenType.MINUS, "*": TokenType.STAR, "/": TokenType.SLASH, "%": TokenType.PERCENT,
                "&": TokenType.AMP, "|": TokenType.PIPE, "^": TokenType.CARET, "~": TokenType.TILDE, "!": TokenType.BANG,
                "<": TokenType.LT, ">": TokenType.GT, "=": TokenType.ASSIGN,
                ";": TokenType.SEMICOLON, ",": TokenType.COMMA, ":": TokenType.COLON,
                "(": TokenType.LPAREN, ")": TokenType.RPAREN, "{": TokenType.LBRACE, "}": TokenType.RBRACE,
                "[": TokenType.LBRACKET, "]": TokenType.RBRACKET
            };

            if (ch in singleChars) {
                this._advance();
                tokens.push(new Token(singleChars[ch], ch, startLine, startCol, ch));
                continue;
            }

            this._advance();
        }

        tokens.push(new Token(TokenType.EOF, "", this.line, this.col, ""));
        return tokens;
    }
}

// =============================================================================
// 2. PREPROCESSOR
// =============================================================================

export class Preprocessor {
    constructor(virtualHeaders = VIRTUAL_HEADERS) {
        this.headers = { ...virtualHeaders };
        this.includedFiles = new Set();
        this.funcMacros = new Map();
        this.objMacros = new Map();
        this.pragmas = [];
    }

    process(source) {
        const lines = source.split(/\r?\n/);
        const outputLines = [];

        for (let i = 0; i < lines.length; i++) {
            const line = lines[i];
            const trimmed = line.trim();

            if (/^[#`]?(ifndef|endif|ifdef|else|elif)/.test(trimmed)) {
                continue;
            }

            const pragmaMatch = trimmed.match(/^[#`]?pragma\s+([a-zA-Z0-9_]+)\s*(.*)/i);
            if (pragmaMatch) {
                const key = pragmaMatch[1].trim();
                const val = pragmaMatch[2].trim();
                this.pragmas.push({ key, value: val, line: i + 1 });
                outputLines.push(`// [Pragma: ${key} ${val}]`);
                continue;
            }

            const incMatch = trimmed.match(/^[#`]?include\s+["<](.*?)[">]/);
            if (incMatch) {
                const headerName = incMatch[1].trim();
                if (this.headers[headerName] && !this.includedFiles.has(headerName)) {
                    this.includedFiles.add(headerName);
                    outputLines.push(`// === Begin Include: ${headerName} ===`);
                    const nested = this.process(this.headers[headerName]);
                    outputLines.push(nested);
                    outputLines.push(`// === End Include: ${headerName} ===`);
                } else if (!this.headers[headerName]) {
                    outputLines.push(`// [Warning: Header <${headerName}> not found in virtual library]`);
                }
                continue;
            }

            const funcMacroMatch = trimmed.match(/^[#`]?define\s+([a-zA-Z0-9_]+)\s*\((.*?)\)\s*(.*)/);
            if (funcMacroMatch) {
                const name = funcMacroMatch[1];
                const params = funcMacroMatch[2].split(",").map(p => p.trim()).filter(Boolean);
                let body = funcMacroMatch[3].trim();
                if (body.includes("//")) body = body.split("//")[0].trim();
                this.funcMacros.set(name, { params, body });
                continue;
            }

            const objMacroMatch = trimmed.match(/^[#`]?define\s+([a-zA-Z0-9_]+)(?:\s+(.+))?$/);
            if (objMacroMatch) {
                const name = objMacroMatch[1];
                let body = objMacroMatch[2] ? objMacroMatch[2].trim() : "";
                if (body.includes("//")) body = body.split("//")[0].trim();
                this.objMacros.set(name, body);
                continue;
            }

            if (trimmed.startsWith("#") || trimmed.startsWith("`")) {
                continue;
            }

            outputLines.push(line);
        }

        let fullText = outputLines.join("\n");

        const sortedMacros = Array.from(this.objMacros.entries()).sort((a, b) => b[0].length - a[0].length);
        for (const [name, val] of sortedMacros) {
            if (val) {
                const regex = new RegExp(`\\b${name}\\b`, "g");
                fullText = fullText.replace(regex, val);
            }
        }

        for (const [name, { params, body }] of this.funcMacros.entries()) {
            const regex = new RegExp(`\\b${name}\\s*\\((.*?)\\)`, "g");
            fullText = fullText.replace(regex, (match, argsStr) => {
                const args = argsStr.split(",").map(a => a.trim()).filter(Boolean);
                let replaced = body;
                params.forEach((param, idx) => {
                    const argVal = args[idx] !== undefined ? args[idx] : "";
                    replaced = replaced.replace(new RegExp(`\\b${param}\\b`, "g"), argVal);
                });
                return replaced;
            });
        }

        return fullText;
    }
}

// =============================================================================
// 3. AST NODES
// =============================================================================

export class ASTNode { constructor(line = 1, col = 1) { this.line = line; this.col = col; } }
export class Program extends ASTNode { constructor(decls, pragmas = [], line = 1, col = 1) { super(line, col); this.decls = decls; this.pragmas = pragmas; } }
export class FunctionDef extends ASTNode { constructor(returnType, name, params, body, isEntry = false, isPrototype = false, line = 1, col = 1) { super(line, col); this.returnType = returnType; this.name = name; this.params = params; this.body = body; this.isEntry = isEntry; this.isPrototype = isPrototype; } }
export class Block extends ASTNode { constructor(statements, line = 1, col = 1) { super(line, col); this.statements = statements; } }
export class VarDecl extends ASTNode { constructor(varType, name, initExpr = null, regHint = null, isConst = false, line = 1, col = 1) { super(line, col); this.varType = varType; this.name = name; this.initExpr = initExpr; this.regHint = regHint; this.isConst = isConst; } }
export class AssignStmt extends ASTNode { constructor(target, op, value, line = 1, col = 1) { super(line, col); this.target = target; this.op = op; this.value = value; } }
export class IfStmt extends ASTNode { constructor(condition, thenBranch, elseBranch = null, line = 1, col = 1) { super(line, col); this.condition = condition; this.thenBranch = thenBranch; this.elseBranch = elseBranch; } }
export class WhileStmt extends ASTNode { constructor(condition, body, line = 1, col = 1) { super(line, col); this.condition = condition; this.body = body; } }
export class DoWhileStmt extends ASTNode { constructor(body, condition, line = 1, col = 1) { super(line, col); this.body = body; this.condition = condition; } }
export class RepeatStmt extends ASTNode { constructor(countExpr, body, line = 1, col = 1) { super(line, col); this.countExpr = countExpr; this.body = body; } }
export class CaseClause extends ASTNode { constructor(matchExpr, statements, line = 1, col = 1) { super(line, col); this.matchExpr = matchExpr; this.statements = statements; } }
export class SwitchStmt extends ASTNode { constructor(expr, cases, line = 1, col = 1) { super(line, col); this.expr = expr; this.cases = cases; } }
export class ReturnStmt extends ASTNode { constructor(value = null, line = 1, col = 1) { super(line, col); this.value = value; } }
export class BreakStmt extends ASTNode { constructor(line = 1, col = 1) { super(line, col); } }
export class ContinueStmt extends ASTNode { constructor(line = 1, col = 1) { super(line, col); } }
export class AsmStmt extends ASTNode { constructor(asmCode, line = 1, col = 1) { super(line, col); this.asmCode = asmCode; } }
export class ExprStmt extends ASTNode { constructor(expr, line = 1, col = 1) { super(line, col); this.expr = expr; } }
export class BinaryOp extends ASTNode { constructor(left, op, right, line = 1, col = 1) { super(line, col); this.left = left; this.op = op; this.right = right; } }
export class UnaryOp extends ASTNode { constructor(op, expr, line = 1, col = 1) { super(line, col); this.op = op; this.expr = expr; } }
export class Identifier extends ASTNode { constructor(name, line = 1, col = 1) { super(line, col); this.name = name; } }
export class Literal extends ASTNode { constructor(value, raw = "", line = 1, col = 1) { super(line, col); this.value = value; this.raw = raw; } }
export class BuiltinCall extends ASTNode { constructor(name, args = [], line = 1, col = 1) { super(line, col); this.name = name; this.args = args; } }

// =============================================================================
// 4. PARSER
// =============================================================================

const TYPE_TOKENS = new Set([
    TokenType.VOID, TokenType.UINT8_T, TokenType.INT8_T, TokenType.UINT16_T,
    TokenType.INT, TokenType.UNSIGNED, TokenType.SIGNED, TokenType.CHAR, TokenType.BOOL
]);

export class OmniCParser {
    constructor(tokens, pragmas = []) {
        this.tokens = tokens;
        this.pragmas = pragmas;
        this.pos = 0;
        this.length = tokens.length;
    }

    _peek(offset = 0) {
        const idx = this.pos + offset;
        return idx < this.length ? this.tokens[idx] : this.tokens[this.length - 1];
    }

    _advance() {
        const tok = this._peek();
        if (this.pos < this.length) this.pos++;
        return tok;
    }

    _match(...types) {
        if (types.includes(this._peek().type)) {
            return this._advance();
        }
        return null;
    }

    _expect(type, msg = null) {
        const tok = this._peek();
        if (tok.type !== type) {
            throw new Error(msg || `Parser Error at line ${tok.line}, col ${tok.col}: Expected '${type}', got '${tok.type}' (${tok.value})`);
        }
        return this._advance();
    }

    parse() {
        const decls = [];
        while (this._peek().type !== TokenType.EOF) {
            const tok = this._peek();
            if (TYPE_TOKENS.has(tok.type) || tok.type === TokenType.CONST || tok.type === TokenType.REG) {
                decls.push(this._parseGlobalDeclOrFunc());
            } else if (tok.type === TokenType.ASM) {
                decls.push(this._parseAsmStmt());
            } else if (tok.type === TokenType.SEMICOLON) {
                this._advance();
            } else {
                throw new Error(`Unexpected token at top level: '${tok.value}' (L${tok.line})`);
            }
        }
        return new Program(decls, this.pragmas);
    }

    _parseGlobalDeclOrFunc() {
        let isConst = false;
        let regHint = null;

        if (this._match(TokenType.CONST)) isConst = true;
        if (this._match(TokenType.REG)) {
            const regTok = this._expect(TokenType.IDENTIFIER, "Expected register name after 'reg'");
            regHint = regTok.value;
        }

        let typeName = "uint8_t";
        if (TYPE_TOKENS.has(this._peek().type)) {
            typeName = this._advance().value;
        }

        const nameTok = this._expect(TokenType.IDENTIFIER, "Expected identifier");
        const name = nameTok.value;

        if (this._peek().type === TokenType.LPAREN) {
            this._advance(); // (
            const params = [];
            while (this._peek().type !== TokenType.RPAREN && this._peek().type !== TokenType.EOF) {
                if (this._peek().type === TokenType.VOID && (this._peek(1).type === TokenType.RPAREN || this._peek(1).type === TokenType.COMMA)) {
                    this._advance();
                    break;
                }
                let pType = "uint8_t";
                if (TYPE_TOKENS.has(this._peek().type)) pType = this._advance().value;
                const pName = this._expect(TokenType.IDENTIFIER, "Expected parameter name").value;
                params.push(new VarDecl(pType, pName, null, null, false, nameTok.line, nameTok.col));
                if (this._peek().type === TokenType.COMMA) this._advance();
            }
            this._expect(TokenType.RPAREN, "Expected ')' after parameter list");

            if (this._peek().type === TokenType.SEMICOLON) {
                this._advance();
                return new FunctionDef(typeName, name, params, null, false, true, nameTok.line, nameTok.col);
            }

            const body = this._parseBlock();
            return new FunctionDef(typeName, name, params, body, name === "main" || name === "entry", false, nameTok.line, nameTok.col);
        }

        let initExpr = null;
        if (this._match(TokenType.ASSIGN)) {
            initExpr = this._parseExpression();
        }
        this._expect(TokenType.SEMICOLON, "Expected ';' after variable declaration");
        return new VarDecl(typeName, name, initExpr, regHint, isConst, nameTok.line, nameTok.col);
    }

    _parseBlock() {
        const startTok = this._expect(TokenType.LBRACE, "Expected '{' to start block");
        const statements = [];
        while (this._peek().type !== TokenType.RBRACE && this._peek().type !== TokenType.EOF) {
            statements.push(this._parseStatement());
        }
        this._expect(TokenType.RBRACE, "Expected '}' to close block");
        return new Block(statements, startTok.line, startTok.col);
    }

    _parseStatement() {
        const tok = this._peek();

        if (tok.type === TokenType.LBRACE) return this._parseBlock();
        if (tok.type === TokenType.ASM) return this._parseAsmStmt();
        if (TYPE_TOKENS.has(tok.type) || tok.type === TokenType.CONST || tok.type === TokenType.REG) {
            return this._parseLocalVarDecl();
        }
        if (tok.type === TokenType.IF) return this._parseIfStmt();
        if (tok.type === TokenType.WHILE) return this._parseWhileStmt();
        if (tok.type === TokenType.DO) return this._parseDoWhileStmt();
        if (tok.type === TokenType.REPEAT) return this._parseRepeatStmt();
        if (tok.type === TokenType.FOR) return this._parseForStmt();
        if (tok.type === TokenType.SWITCH) return this._parseSwitchStmt();

        if (tok.type === TokenType.RETURN) {
            this._advance();
            let val = null;
            if (this._peek().type !== TokenType.SEMICOLON) {
                val = this._parseExpression();
            }
            this._expect(TokenType.SEMICOLON, "Expected ';' after return");
            return new ReturnStmt(val, tok.line, tok.col);
        }

        if (tok.type === TokenType.BREAK) {
            this._advance();
            this._expect(TokenType.SEMICOLON, "Expected ';' after break");
            return new BreakStmt(tok.line, tok.col);
        }

        if (tok.type === TokenType.CONTINUE) {
            this._advance();
            this._expect(TokenType.SEMICOLON, "Expected ';' after continue");
            return new ContinueStmt(tok.line, tok.col);
        }

        const expr = this._parseExpression();
        this._expect(TokenType.SEMICOLON, "Expected ';' after statement");
        return new ExprStmt(expr, tok.line, tok.col);
    }

    _parseLocalVarDecl() {
        const startTok = this._peek();
        let isConst = false;
        let regHint = null;

        if (this._match(TokenType.CONST)) isConst = true;
        if (this._match(TokenType.REG)) {
            const regTok = this._expect(TokenType.IDENTIFIER, "Expected register name after 'reg'");
            regHint = regTok.value;
        }

        let typeName = "uint8_t";
        if (TYPE_TOKENS.has(this._peek().type)) {
            typeName = this._advance().value;
        }

        const nameTok = this._expect(TokenType.IDENTIFIER, "Expected variable name");
        let initExpr = null;
        if (this._match(TokenType.ASSIGN)) {
            initExpr = this._parseExpression();
        }
        this._expect(TokenType.SEMICOLON, "Expected ';' after local variable declaration");
        return new VarDecl(typeName, nameTok.value, initExpr, regHint, isConst, startTok.line, startTok.col);
    }

    _parseIfStmt() {
        const startTok = this._advance(); // if
        this._expect(TokenType.LPAREN, "Expected '(' after if");
        const cond = this._parseExpression();
        this._expect(TokenType.RPAREN, "Expected ')' after if condition");
        const thenBranch = this._parseStatement();
        let elseBranch = null;
        if (this._match(TokenType.ELSE)) {
            elseBranch = this._parseStatement();
        }
        return new IfStmt(cond, thenBranch, elseBranch, startTok.line, startTok.col);
    }

    _parseWhileStmt() {
        const startTok = this._advance(); // while
        this._expect(TokenType.LPAREN, "Expected '(' after while");
        const cond = this._parseExpression();
        this._expect(TokenType.RPAREN, "Expected ')' after while condition");
        const body = this._parseStatement();
        return new WhileStmt(cond, body, startTok.line, startTok.col);
    }

    _parseDoWhileStmt() {
        const startTok = this._advance(); // do
        const body = this._parseStatement();
        this._expect(TokenType.WHILE, "Expected 'while' after do-while body");
        this._expect(TokenType.LPAREN, "Expected '(' after while");
        const cond = this._parseExpression();
        this._expect(TokenType.RPAREN, "Expected ')' after condition");
        this._expect(TokenType.SEMICOLON, "Expected ';' after do-while");
        return new DoWhileStmt(body, cond, startTok.line, startTok.col);
    }

    _parseRepeatStmt() {
        const startTok = this._advance(); // repeat
        this._expect(TokenType.LPAREN, "Expected '(' after repeat");
        const count = this._parseExpression();
        this._expect(TokenType.RPAREN, "Expected ')' after count");
        const body = this._parseStatement();
        return new RepeatStmt(count, body, startTok.line, startTok.col);
    }

    _parseForStmt() {
        const startTok = this._advance(); // for
        this._expect(TokenType.LPAREN, "Expected '(' after for");
        let init = null;
        if (this._peek().type !== TokenType.SEMICOLON) {
            init = this._parseStatement();
        } else {
            this._advance();
        }
        let cond = null;
        if (this._peek().type !== TokenType.SEMICOLON) {
            cond = this._parseExpression();
        }
        this._expect(TokenType.SEMICOLON, "Expected ';' after for condition");
        let step = null;
        if (this._peek().type !== TokenType.RPAREN) {
            step = this._parseExpression();
        }
        this._expect(TokenType.RPAREN, "Expected ')' after for clauses");
        const body = this._parseStatement();

        const loopStmts = [body];
        if (step) loopStmts.push(new ExprStmt(step, startTok.line, startTok.col));
        const whileBody = new Block(loopStmts, startTok.line, startTok.col);
        const whileStmt = new WhileStmt(cond || new Literal(1, "1", startTok.line, startTok.col), whileBody, startTok.line, startTok.col);
        return init ? new Block([init, whileStmt], startTok.line, startTok.col) : whileStmt;
    }

    _parseSwitchStmt() {
        const startTok = this._advance(); // switch
        this._expect(TokenType.LPAREN, "Expected '(' after switch");
        const expr = this._parseExpression();
        this._expect(TokenType.RPAREN, "Expected ')' after switch expression");
        this._expect(TokenType.LBRACE, "Expected '{' to start switch body");

        const cases = [];
        while (this._peek().type !== TokenType.RBRACE && this._peek().type !== TokenType.EOF) {
            if (this._match(TokenType.CASE)) {
                const caseTok = this._peek(-1);
                const matchExpr = this._parseExpression();
                this._expect(TokenType.COLON, "Expected ':' after case value");
                const stmts = [];
                while (![TokenType.CASE, TokenType.DEFAULT, TokenType.RBRACE, TokenType.EOF].includes(this._peek().type)) {
                    stmts.push(this._parseStatement());
                }
                cases.push(new CaseClause(matchExpr, stmts, caseTok.line, caseTok.col));
            } else if (this._match(TokenType.DEFAULT)) {
                const defTok = this._peek(-1);
                this._expect(TokenType.COLON, "Expected ':' after default");
                const stmts = [];
                while (![TokenType.CASE, TokenType.DEFAULT, TokenType.RBRACE, TokenType.EOF].includes(this._peek().type)) {
                    stmts.push(this._parseStatement());
                }
                cases.push(new CaseClause(null, stmts, defTok.line, defTok.col));
            } else {
                throw new Error(`Unexpected token in switch body: '${this._peek().value}' (L${this._peek().line})`);
            }
        }
        this._expect(TokenType.RBRACE, "Expected '}' to close switch body");
        return new SwitchStmt(expr, cases, startTok.line, startTok.col);
    }

    _parseAsmStmt() {
        const startTok = this._advance(); // asm
        this._expect(TokenType.LPAREN, "Expected '(' after asm");
        const asmTok = this._expect(TokenType.STR_LITERAL, "Expected string literal for inline assembly");
        this._expect(TokenType.RPAREN, "Expected ')' after asm string");
        this._expect(TokenType.SEMICOLON, "Expected ';' after asm statement");
        return new AsmStmt(asmTok.value, startTok.line, startTok.col);
    }

    _parseExpression() {
        return this._parseAssignment();
    }

    _parseAssignment() {
        const expr = this._parseLogicalOr();
        const assignOps = [
            TokenType.ASSIGN, TokenType.PLUS_ASSIGN, TokenType.MINUS_ASSIGN,
            TokenType.AMP_ASSIGN, TokenType.PIPE_ASSIGN, TokenType.CARET_ASSIGN,
            TokenType.LSHIFT_ASSIGN, TokenType.RSHIFT_ASSIGN
        ];

        if (assignOps.includes(this._peek().type)) {
            const opTok = this._advance();
            const right = this._parseAssignment();
            return new AssignStmt(expr, opTok.value, right, opTok.line, opTok.col);
        }
        return expr;
    }

    _parseLogicalOr() {
        let left = this._parseLogicalAnd();
        while (this._peek().type === TokenType.OR) {
            const opTok = this._advance();
            const right = this._parseLogicalAnd();
            left = new BinaryOp(left, opTok.value, right, opTok.line, opTok.col);
        }
        return left;
    }

    _parseLogicalAnd() {
        let left = this._parseBitwiseOr();
        while (this._peek().type === TokenType.AND) {
            const opTok = this._advance();
            const right = this._parseBitwiseOr();
            left = new BinaryOp(left, opTok.value, right, opTok.line, opTok.col);
        }
        return left;
    }

    _parseBitwiseOr() {
        let left = this._parseBitwiseXor();
        while (this._peek().type === TokenType.PIPE) {
            const opTok = this._advance();
            const right = this._parseBitwiseXor();
            left = new BinaryOp(left, opTok.value, right, opTok.line, opTok.col);
        }
        return left;
    }

    _parseBitwiseXor() {
        let left = this._parseBitwiseAnd();
        while (this._peek().type === TokenType.CARET) {
            const opTok = this._advance();
            const right = this._parseBitwiseAnd();
            left = new BinaryOp(left, opTok.value, right, opTok.line, opTok.col);
        }
        return left;
    }

    _parseBitwiseAnd() {
        let left = this._parseEquality();
        while (this._peek().type === TokenType.AMP) {
            const opTok = this._advance();
            const right = this._parseEquality();
            left = new BinaryOp(left, opTok.value, right, opTok.line, opTok.col);
        }
        return left;
    }

    _parseEquality() {
        let left = this._parseRelational();
        while ([TokenType.EQ, TokenType.NEQ].includes(this._peek().type)) {
            const opTok = this._advance();
            const right = this._parseRelational();
            left = new BinaryOp(left, opTok.value, right, opTok.line, opTok.col);
        }
        return left;
    }

    _parseRelational() {
        let left = this._parseShift();
        while ([TokenType.LT, TokenType.LEQ, TokenType.GT, TokenType.GEQ].includes(this._peek().type)) {
            const opTok = this._advance();
            const right = this._parseShift();
            left = new BinaryOp(left, opTok.value, right, opTok.line, opTok.col);
        }
        return left;
    }

    _parseShift() {
        let left = this._parseAdditive();
        while ([TokenType.LSHIFT, TokenType.RSHIFT].includes(this._peek().type)) {
            const opTok = this._advance();
            const right = this._parseAdditive();
            left = new BinaryOp(left, opTok.value, right, opTok.line, opTok.col);
        }
        return left;
    }

    _parseAdditive() {
        let left = this._parseMultiplicative();
        while ([TokenType.PLUS, TokenType.MINUS].includes(this._peek().type)) {
            const opTok = this._advance();
            const right = this._parseMultiplicative();
            left = new BinaryOp(left, opTok.value, right, opTok.line, opTok.col);
        }
        return left;
    }

    _parseMultiplicative() {
        let left = this._parseUnary();
        while ([TokenType.STAR, TokenType.SLASH, TokenType.PERCENT].includes(this._peek().type)) {
            const opTok = this._advance();
            const right = this._parseUnary();
            left = new BinaryOp(left, opTok.value, right, opTok.line, opTok.col);
        }
        return left;
    }

    _parseUnary() {
        const tok = this._peek();
        if ([TokenType.BANG, TokenType.TILDE, TokenType.MINUS, TokenType.INC, TokenType.DEC].includes(tok.type)) {
            this._advance();
            const expr = this._parseUnary();
            return new UnaryOp(tok.value, expr, tok.line, tok.col);
        }
        return this._parsePrimary();
    }

    _parsePrimary() {
        const tok = this._peek();

        if (tok.type === TokenType.INT_LITERAL || tok.type === TokenType.SENTINEL) {
            this._advance();
            return new Literal(tok.value, tok.raw, tok.line, tok.col);
        }

        if (tok.type === TokenType.LPAREN) {
            this._advance();
            const expr = this._parseExpression();
            this._expect(TokenType.RPAREN, "Expected ')' after grouped expression");
            return expr;
        }

        if (tok.type === TokenType.IDENTIFIER) {
            const idTok = this._advance();
            if (this._peek().type === TokenType.LPAREN) {
                this._advance(); // (
                const args = [];
                while (this._peek().type !== TokenType.RPAREN && this._peek().type !== TokenType.EOF) {
                    args.push(this._parseExpression());
                    if (this._peek().type === TokenType.COMMA) this._advance();
                }
                this._expect(TokenType.RPAREN, "Expected ')' after function arguments");
                return new BuiltinCall(idTok.value, args, idTok.line, idTok.col);
            }
            return new Identifier(idTok.value, idTok.line, idTok.col);
        }

        throw new Error(`Unexpected token in expression: '${tok.value}' (L${tok.line}:C${tok.col})`);
    }
}

// =============================================================================
// 5. SYMBOLS & REGISTER ALLOCATOR
// =============================================================================

export class SymbolEntry {
    constructor(name, type, reg = null, isConst = false, constVal = null) {
        this.name = name;
        this.type = type;
        this.reg = reg;
        this.isConst = isConst;
        this.constVal = constVal;
    }
}

export class Scope {
    constructor(parent = null) {
        this.parent = parent;
        this.symbols = new Map();
    }

    define(sym) {
        this.symbols.set(sym.name.toLowerCase(), sym);
    }

    lookup(name) {
        const lower = name.toLowerCase();
        if (this.symbols.has(lower)) return this.symbols.get(lower);
        if (this.parent) return this.parent.lookup(name);
        return null;
    }
}

export class RegisterAllocator {
    constructor() {
        this.available = ["r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7"];
        this.allocated = new Map();
    }

    allocate(varName, hint = null) {
        const lower = varName.toLowerCase();
        if (this.allocated.has(lower)) return this.allocated.get(lower);

        if (hint && this.available.includes(hint.toLowerCase())) {
            const h = hint.toLowerCase();
            this.available = this.available.filter(r => r !== h);
            this.allocated.set(lower, h);
            return h;
        }

        if (this.available.length === 0) {
            return "r0"; // fallback
        }

        const reg = this.available.shift();
        this.allocated.set(lower, reg);
        return reg;
    }
}

// =============================================================================
// 6. MULTI-PASS OPTIMIZING CODE GENERATOR
// =============================================================================

export class OmniCCodeGen {
    constructor(options = { optimize: 1, emitLocComments: true }) {
        this.optLevel = typeof options.optimize === "number" ? options.optimize : (options.optimize === false ? 0 : 1);
        this.emitLocComments = options.emitLocComments !== false;
        this.lines = [];
        this.labelCounter = 0;
        this.loopStack = [];
        this.globalScope = new Scope();
        this.currentScope = this.globalScope;
        this.regAlloc = new RegisterAllocator();
        this.functions = [];
        this.sourceMap = {
            cToAsm: {},
            asmToC: {},
            functions: [],
            stats: {}
        };
    }

    _emit(line, cLine = null) {
        if (cLine && this.emitLocComments && !line.startsWith(";") && !line.endsWith(":")) {
            this.lines.push(`${line} ; #loc:${cLine}`);
        } else {
            this.lines.push(line);
        }
    }

    _newLabel(prefix = "L") {
        this.labelCounter++;
        return `lbl_${prefix}_${this.labelCounter}`;
    }

    generate(programAst) {
        this.lines = [];
        this.lines.push("; =============================================================================");
        this.lines.push("; Emitted by OmniBus MP High-Level Omni-C Optimizing Compiler");
        this.lines.push(`; Optimization Level: -O${this.optLevel}`);
        this.lines.push("; =============================================================================");
        this.lines.push("");

        // Pass 1: Global declarations
        for (const decl of programAst.decls) {
            if (decl instanceof VarDecl) {
                const reg = this.regAlloc.allocate(decl.name, decl.regHint);
                this.globalScope.define(new SymbolEntry(decl.name, decl.varType, reg, decl.isConst));
            }
        }

        // Pass 2: Functions
        for (const decl of programAst.decls) {
            if (decl instanceof FunctionDef && !decl.isPrototype) {
                this._genFunction(decl);
            }
        }

        const rawLines = [...this.lines];
        const optimizer = new OmniCPeepholeOptimizer(this.optLevel);
        const optimizedLines = optimizer.optimize(rawLines);

        this._buildSourceMap(optimizedLines, rawLines.length);
        return optimizedLines.join("\n");
    }

    _buildSourceMap(finalLines, rawCount) {
        this.sourceMap.cToAsm = {};
        this.sourceMap.asmToC = {};
        this.sourceMap.functions = this.functions;

        finalLines.forEach((line, idx) => {
            const asmLine = idx + 1;
            const locMatch = line.match(/;\s*#loc:(\d+)/);
            if (locMatch) {
                const cLine = parseInt(locMatch[1], 10);
                this.sourceMap.asmToC[asmLine] = cLine;
                if (!this.sourceMap.cToAsm[cLine]) this.sourceMap.cToAsm[cLine] = [];
                this.sourceMap.cToAsm[cLine].push(asmLine);
            }
        });

        this.sourceMap.stats = {
            rawLines: rawCount,
            optimizedLines: finalLines.length,
            reductionPercent: rawCount > 0 ? Math.round(((rawCount - finalLines.length) / rawCount) * 100) : 0,
            optLevel: this.optLevel
        };
    }

    _genFunction(func) {
        const oldScope = this.currentScope;
        this.currentScope = new Scope(oldScope);
        this.regAlloc = new RegisterAllocator();

        this.functions.push({
            name: func.name,
            line: func.line,
            isEntry: func.isEntry
        });

        this._emit(`; --- Function: ${func.name} ---`);
        this._emit(`${func.name}:`);

        func.params.forEach(p => {
            const reg = this.regAlloc.allocate(p.name);
            this.currentScope.define(new SymbolEntry(p.name, p.varType, reg));
        });

        if (func.body) {
            for (const s of func.body.statements) {
                this._genStatement(s);
            }
            if (this.lines.length === 0 || !this.lines[this.lines.length - 1].trim().startsWith("RET")) {
                this._emit("RET");
            }
        }

        this._emit("");
        this.currentScope = oldScope;
    }

    _genStatement(stmt) {
        const cLine = stmt.line;

        if (stmt instanceof Block) {
            for (const s of stmt.statements) this._genStatement(s);
        } else if (stmt instanceof VarDecl) {
            this._genLocalVar(stmt);
        } else if (stmt instanceof AssignStmt) {
            this._genAssign(stmt);
        } else if (stmt instanceof IfStmt) {
            this._genIf(stmt);
        } else if (stmt instanceof WhileStmt) {
            this._genWhile(stmt);
        } else if (stmt instanceof DoWhileStmt) {
            this._genDoWhile(stmt);
        } else if (stmt instanceof RepeatStmt) {
            this._genRepeat(stmt);
        } else if (stmt instanceof SwitchStmt) {
            this._genSwitch(stmt);
        } else if (stmt instanceof ReturnStmt) {
            if (stmt.value) {
                const val = this._evalLiteralOrReg(stmt.value);
                if (val !== "acc") this._emit(`MOV acc, ${val}`, cLine);
            }
            this._emit("RET", cLine);
        } else if (stmt instanceof BreakStmt) {
            if (this.loopStack.length === 0) throw new Error("Break outside loop");
            this._emit(`JMP ${this.loopStack[this.loopStack.length - 1].breakLabel}`, cLine);
        } else if (stmt instanceof ContinueStmt) {
            if (this.loopStack.length === 0) throw new Error("Continue outside loop");
            this._emit(`JMP ${this.loopStack[this.loopStack.length - 1].contLabel}`, cLine);
        } else if (stmt instanceof AsmStmt) {
            this._emit(stmt.asmCode, cLine);
        } else if (stmt instanceof ExprStmt) {
            this._genExprStmt(stmt);
        }
    }

    _genLocalVar(decl) {
        const reg = this.regAlloc.allocate(decl.name, decl.regHint);
        this.currentScope.define(new SymbolEntry(decl.name, decl.varType, reg, decl.isConst));

        if (decl.initExpr) {
            if (decl.initExpr instanceof BuiltinCall) {
                this._genBuiltinAssign(reg, decl.initExpr);
            } else {
                const val = this._evalLiteralOrReg(decl.initExpr);
                if (reg === "acc") {
                    this._emit(`MOV acc, ${val}`, decl.line);
                } else {
                    this._emit(`MOV acc, ${val}`, decl.line);
                    this._emit(`MOV ${reg}, acc`, decl.line);
                }
            }
        }
    }

    _genAssign(assign) {
        const targetName = this._getVarName(assign.target);
        const targetSym = this.currentScope.lookup(targetName);
        const targetReg = targetSym && targetSym.reg ? targetSym.reg : targetName.toLowerCase();
        const cLine = assign.line;

        if (assign.op === "=") {
            if (assign.value instanceof BuiltinCall) {
                this._genBuiltinAssign(targetReg, assign.value);
            } else if (assign.value instanceof BinaryOp) {
                this._genBinaryAssign(targetReg, assign.value);
            } else if (assign.value instanceof UnaryOp) {
                this._genUnaryAssign(targetReg, assign.value);
            } else {
                const val = this._evalLiteralOrReg(assign.value);
                if (targetReg === "acc") {
                    this._emit(`MOV acc, ${val}`, cLine);
                } else {
                    this._emit(`MOV acc, ${val}`, cLine);
                    this._emit(`MOV ${targetReg}, acc`, cLine);
                }
            }
        } else {
            const opMap = {
                "+=": "ADD", "-=": "SUB", "&=": "AND", "|=": "OR", "^=": "XOR",
                "<<=": "SHL", ">>=": "SHR"
            };
            const aluOp = opMap[assign.op] || "ADD";
            const val = this._evalLiteralOrReg(assign.value);
            if (targetReg === "acc") {
                this._emit(`${aluOp} ${val}`, cLine);
            } else {
                this._emit(`MOV acc, ${targetReg}`, cLine);
                this._emit(`${aluOp} ${val}`, cLine);
                this._emit(`MOV ${targetReg}, acc`, cLine);
            }
        }
    }

    _genBinaryAssign(targetReg, binop) {
        const left = this._evalLiteralOrReg(binop.left);
        const right = this._evalLiteralOrReg(binop.right);
        const opMap = { "+": "ADD", "-": "SUB", "&": "AND", "|": "OR", "^": "XOR", "<<": "SHL", ">>": "SHR" };
        const aluOp = opMap[binop.op] || "ADD";
        const cLine = binop.line;

        if (targetReg === "acc") {
            if (left !== "acc") this._emit(`MOV acc, ${left}`, cLine);
            this._emit(`${aluOp} ${right}`, cLine);
        } else {
            this._emit(`MOV acc, ${left}`, cLine);
            this._emit(`${aluOp} ${right}`, cLine);
            this._emit(`MOV ${targetReg}, acc`, cLine);
        }
    }

    _genUnaryAssign(targetReg, unop) {
        const opStr = this._evalLiteralOrReg(unop.expr);
        const cLine = unop.line;

        if (unop.op === "~" || unop.op === "not") {
            if (targetReg === "acc") {
                if (opStr !== "acc") this._emit(`MOV acc, ${opStr}`, cLine);
                this._emit("NOT", cLine);
            } else {
                this._emit(`MOV acc, ${opStr}`, cLine);
                this._emit("NOT", cLine);
                this._emit(`MOV ${targetReg}, acc`, cLine);
            }
        } else if (unop.op === "++") {
            this._emit(`INC ${targetReg}`, cLine);
        } else if (unop.op === "--") {
            this._emit(`DEC ${targetReg}`, cLine);
        }
    }

    _genBuiltinAssign(targetReg, call) {
        const name = call.name.toLowerCase();
        const cLine = call.line;

        if (name === "pull") {
            this._emit("PULL", cLine);
            if (targetReg !== "osr") this._emit(`MOV ${targetReg}, osr`, cLine);
        } else if (name === "core_id") {
            this._emit("CORE_ID", cLine);
            if (targetReg !== "acc") this._emit(`MOV ${targetReg}, acc`, cLine);
        } else if (name === "spinlock_acquire" || name === "spinlock_acq") {
            const lockId = call.args.length > 0 ? this._evalLiteralOrReg(call.args[0]) : "0";
            this._emit(`SPINLOCK_ACQ ${lockId}`, cLine);
            if (targetReg !== "acc") this._emit(`MOV ${targetReg}, acc`, cLine);
        } else if (name === "mailbox_read" || name === "mb_read") {
            const mbId = call.args.length > 0 ? this._evalLiteralOrReg(call.args[0]) : "0";
            this._emit(`MB_READ ${mbId}`, cLine);
            if (targetReg !== "acc") this._emit(`MOV ${targetReg}, acc`, cLine);
        } else {
            this._genBuiltinCall(call);
        }
    }

    _genIf(stmt) {
        const elseLabel = stmt.elseBranch ? this._newLabel("else") : null;
        const endLabel = this._newLabel("endif");
        const targetFalse = elseLabel || endLabel;

        this._genConditionBranch(stmt.condition, targetFalse, false);
        this._genStatement(stmt.thenBranch);

        if (stmt.elseBranch) {
            this._emit(`JMP ${endLabel}`);
            this._emit(`${elseLabel}:`);
            this._genStatement(stmt.elseBranch);
        }
        this._emit(`${endLabel}:`);
    }

    _genWhile(stmt) {
        const startLabel = this._newLabel("while_start");
        const endLabel = this._newLabel("while_end");

        this.loopStack.push({ contLabel: startLabel, breakLabel: endLabel });
        this._emit(`${startLabel}:`);

        this._genConditionBranch(stmt.condition, endLabel, false);
        this._genStatement(stmt.body);

        this._emit(`JMP ${startLabel}`);
        this._emit(`${endLabel}:`);
        this.loopStack.pop();
    }

    _genDoWhile(stmt) {
        const startLabel = this._newLabel("do_start");
        const condLabel = this._newLabel("do_cond");
        const endLabel = this._newLabel("do_end");

        this.loopStack.push({ contLabel: condLabel, breakLabel: endLabel });
        this._emit(`${startLabel}:`);
        this._genStatement(stmt.body);

        this._emit(`${condLabel}:`);
        this._genConditionBranch(stmt.condition, startLabel, true);
        this._emit(`${endLabel}:`);
        this.loopStack.pop();
    }

    _genRepeat(stmt) {
        const startLabel = this._newLabel("repeat_start");
        const endLabel = this._newLabel("repeat_end");
        const countVal = this._evalLiteralOrReg(stmt.countExpr);

        this._emit(`SET_LC ${countVal}`, stmt.line);
        this.loopStack.push({ contLabel: startLabel, breakLabel: endLabel });

        this._emit(`${startLabel}:`);
        this._genStatement(stmt.body);
        this._emit(`DJNZ ${startLabel}`);
        this._emit(`${endLabel}:`);

        this.loopStack.pop();
    }

    _genSwitch(stmt) {
        const valStr = this._evalLiteralOrReg(stmt.expr);
        const tempReg = "r0";
        this._emit(`MOV acc, ${valStr}`, stmt.line);
        this._emit(`MOV ${tempReg}, acc`, stmt.line);

        const endLabel = this._newLabel("sw_end");
        this.loopStack.push({ contLabel: endLabel, breakLabel: endLabel });

        const casePairs = [];
        let defaultPair = null;

        for (const c of stmt.cases) {
            if (c.matchExpr !== null) {
                const lbl = this._newLabel("sw_case");
                casePairs.push({ caseObj: c, label: lbl });
            } else {
                const lbl = this._newLabel("sw_default");
                defaultPair = { caseObj: c, label: lbl };
            }
        }

        // Branch tests
        for (const cp of casePairs) {
            const matchVal = this._evalLiteralOrReg(cp.caseObj.matchExpr);
            this._emit(`MOV acc, ${tempReg}`, cp.caseObj.line);
            this._emit(`CMP ${matchVal}`, cp.caseObj.line);
            this._emit(`JMP ZERO, ${cp.label}`, cp.caseObj.line);
        }

        if (defaultPair) {
            this._emit(`JMP ${defaultPair.label}`);
        } else {
            this._emit(`JMP ${endLabel}`);
        }

        // Case bodies
        for (const cp of casePairs) {
            this._emit(`${cp.label}:`);
            for (const s of cp.caseObj.statements) {
                this._genStatement(s);
            }
        }

        if (defaultPair) {
            this._emit(`${defaultPair.label}:`);
            for (const s of defaultPair.caseObj.statements) {
                this._genStatement(s);
            }
        }

        this._emit(`${endLabel}:`);
        this.loopStack.pop();
    }

    _genExprStmt(stmt) {
        if (stmt.expr instanceof BuiltinCall) {
            this._genBuiltinCall(stmt.expr);
        } else if (stmt.expr instanceof AssignStmt) {
            this._genAssign(stmt.expr);
        }
    }

    _genBuiltinCall(call) {
        const name = call.name.toLowerCase();
        const args = call.args;
        const cLine = call.line;

        if (name === "pin_set") {
            const pin = this._evalLiteralOrReg(args[0]);
            const val = this._evalLiteralOrReg(args[1]);
            this._emit(`SET ${pin}, ${val}`, cLine);
        } else if (name === "pin_high") {
            const pin = this._evalLiteralOrReg(args[0]);
            this._emit(`SET ${pin}, 1`, cLine);
        } else if (name === "pin_low") {
            const pin = this._evalLiteralOrReg(args[0]);
            this._emit(`SET ${pin}, 0`, cLine);
        } else if (name === "pin_wait") {
            const pin = this._evalLiteralOrReg(args[0]);
            const val = this._evalLiteralOrReg(args[1]);
            this._emit(`WAIT ${pin} == ${val}`, cLine);
        } else if (name === "pull") {
            this._emit("PULL", cLine);
        } else if (name === "push") {
            const val = args.length > 0 ? this._evalLiteralOrReg(args[0]) : "0";
            if (val !== "acc") this._emit(`MOV acc, ${val}`, cLine);
            this._emit("PUSH", cLine);
        } else if (name === "out_shift") {
            const count = args.length > 0 ? this._evalLiteralOrReg(args[0]) : "8";
            this._emit(`OUT ${count}`, cLine);
        } else if (name === "in_shift") {
            const count = args.length > 0 ? this._evalLiteralOrReg(args[0]) : "8";
            this._emit(`IN ${count}`, cLine);
        } else if (name === "out_sck") {
            const count = args.length > 0 ? this._evalLiteralOrReg(args[0]) : "8";
            this._emit(`OUT SCK, ${count}`, cLine);
        } else if (name === "in_sck") {
            const count = args.length > 0 ? this._evalLiteralOrReg(args[0]) : "8";
            this._emit(`IN SCK, ${count}`, cLine);
        } else if (name === "delay_cycles" || name === "nop") {
            const cycles = args.length > 0 ? this._evalLiteralOrReg(args[0]) : "0";
            this._emit(`NOP [${cycles}]`, cLine);
        } else if (name === "barrier_wait" || name === "barrier") {
            this._emit("BARRIER_WAIT", cLine);
        } else if (name === "spinlock_release" || name === "spinlock_rel") {
            const lockId = args.length > 0 ? this._evalLiteralOrReg(args[0]) : "0";
            this._emit(`SPINLOCK_REL ${lockId}`, cLine);
        } else if (name === "mailbox_write" || name === "mb_write") {
            const mbId = args.length > 0 ? this._evalLiteralOrReg(args[0]) : "0";
            const val = args.length > 1 ? this._evalLiteralOrReg(args[1]) : "0";
            if (val !== "acc") this._emit(`MOV acc, ${val}`, cLine);
            this._emit(`MB_WRITE ${mbId}`, cLine);
        } else {
            // Function call or generic instruction
            const targetName = call.name;
            this._emit(`CALL ${targetName}`, cLine);
        }
    }

    _genConditionBranch(cond, targetLabel, jumpIfTrue = true) {
        if (cond instanceof BinaryOp) {
            const left = this._evalLiteralOrReg(cond.left);
            const right = this._evalLiteralOrReg(cond.right);
            const op = cond.op;

            if (left !== "acc") this._emit(`MOV acc, ${left}`);
            this._emit(`CMP ${right}`);

            if (op === "==") {
                this._emit(jumpIfTrue ? `JMP ZERO, ${targetLabel}` : `JMP NOT_ZERO, ${targetLabel}`);
            } else if (op === "!=") {
                this._emit(jumpIfTrue ? `JMP NOT_ZERO, ${targetLabel}` : `JMP ZERO, ${targetLabel}`);
            } else if (op === "<") {
                this._emit(jumpIfTrue ? `JMP CARRY, ${targetLabel}` : `JMP NOT_CARRY, ${targetLabel}`);
            } else if (op === ">=") {
                this._emit(jumpIfTrue ? `JMP NOT_CARRY, ${targetLabel}` : `JMP CARRY, ${targetLabel}`);
            }
            return;
        }

        const val = this._evalLiteralOrReg(cond);
        if (val !== "acc") this._emit(`MOV acc, ${val}`);
        this._emit("CMP 0");
        this._emit(jumpIfTrue ? `JMP NOT_ZERO, ${targetLabel}` : `JMP ZERO, ${targetLabel}`);
    }

    _evalLiteralOrReg(node) {
        if (node instanceof Literal) {
            if (typeof node.value === "number") {
                return node.value > 9 ? `0x${node.value.toString(16).toUpperCase()}` : node.value.toString();
            }
            return node.value.toString();
        }
        if (node instanceof Identifier) {
            const sym = this.currentScope.lookup(node.name);
            if (sym && sym.isConst && sym.constVal !== null) {
                return sym.constVal.toString();
            }
            if (sym && sym.reg) return sym.reg;
            return node.name.toLowerCase();
        }
        return "acc";
    }

    _getVarName(node) {
        if (node instanceof Identifier) return node.name;
        if (typeof node === "string") return node;
        return "temp";
    }
}

// =============================================================================
// 7. MULTI-PASS PEEPHOLE OPTIMIZER
// =============================================================================

export class OmniCPeepholeOptimizer {
    constructor(level = 1) {
        this.level = level; // 0=None, 1=Standard, 2=Aggressive
    }

    optimize(lines) {
        if (this.level === 0) {
            return lines.filter(l => l.trim().length > 0);
        }

        let current = lines.map(l => l.trim()).filter(l => l.length > 0);

        for (let pass = 0; pass < 5; pass++) {
            const prevLen = current.length;

            current = this._coalesceDelays(current);
            if (this.level >= 2) {
                current = this._foldNops(current);
            }

            current = this._eliminateRedundantMoves(current);

            if (this.level >= 2) {
                current = this._eliminateInverseMoves(current);
                current = this._eliminateConsecutiveSetPins(current);
            }

            current = this._eliminateDeadCode(current);
            current = this._eliminateJumpsToNext(current);

            if (this.level >= 2) {
                current = this._compressJumpChains(current);
                current = this._eliminateUnusedLabels(current);
            }

            if (current.length === prevLen) break;
        }

        return current;
    }

    _coalesceDelays(lines) {
        const optimized = [];
        let i = 0;
        while (i < lines.length) {
            const curr = lines[i];
            if (curr.endsWith(":") || curr.startsWith(";")) {
                optimized.push(curr);
                i++;
                continue;
            }

            if (i + 1 < lines.length) {
                const nxt = lines[i + 1];
                const nopMatch = nxt.match(/^NOP\s+\[(.*?)\](?:\s*;.*)?$/i);
                if (nopMatch && !curr.includes("[") && !curr.endsWith(":")) {
                    const clean = curr.split(";")[0].trim();
                    const loc = curr.includes("; #loc:") ? (" ; " + curr.split(";").find(x => x.includes("#loc")).trim()) : "";
                    const opcode = clean.split(/\s+/)[0].toUpperCase();
                    if (["SET", "WAIT", "OUT", "IN", "CFG_OD", "PINMAP", "NOP"].includes(opcode)) {
                        optimized.push(`${clean} [${nopMatch[1]}]${loc}`);
                        i += 2;
                        continue;
                    }
                }
            }

            optimized.push(curr);
            i++;
        }
        return optimized;
    }

    _foldNops(lines) {
        const optimized = [];
        let i = 0;
        while (i < lines.length) {
            const curr = lines[i];
            const nop1 = curr.match(/^NOP\s+\[(\d+)\](?:\s*;.*)?$/i);

            if (nop1 && i + 1 < lines.length) {
                const nxt = lines[i + 1];
                const nop2 = nxt.match(/^NOP\s+\[(\d+)\](?:\s*;.*)?$/i);
                if (nop2) {
                    const d1 = parseInt(nop1[1], 10);
                    const d2 = parseInt(nop2[1], 10);
                    if (d1 + d2 <= 31) {
                        const loc = curr.includes("; #loc:") ? (" ; " + curr.split(";").find(x => x.includes("#loc")).trim()) : "";
                        optimized.push(`NOP [${d1 + d2}]${loc}`);
                        i += 2;
                        continue;
                    }
                }
            }

            optimized.push(curr);
            i++;
        }
        return optimized;
    }

    _eliminateRedundantMoves(lines) {
        const optimized = [];
        for (const line of lines) {
            const clean = line.split(";")[0].trim();
            const movMatch = clean.match(/^MOV\s+([a-zA-Z0-9_]+)\s*,\s*([a-zA-Z0-9_]+)$/i);
            if (movMatch && movMatch[1].toLowerCase() === movMatch[2].toLowerCase()) {
                continue;
            }
            optimized.push(line);
        }
        return optimized;
    }

    _eliminateInverseMoves(lines) {
        const optimized = [];
        let i = 0;
        while (i < lines.length) {
            const curr = lines[i];
            const clean1 = curr.split(";")[0].trim();
            const m1 = clean1.match(/^MOV\s+([a-zA-Z0-9_]+)\s*,\s*([a-zA-Z0-9_]+)$/i);

            if (m1 && i + 1 < lines.length) {
                const nxt = lines[i + 1];
                const clean2 = nxt.split(";")[0].trim();
                const m2 = clean2.match(/^MOV\s+([a-zA-Z0-9_]+)\s*,\s*([a-zA-Z0-9_]+)$/i);
                if (m2) {
                    const d1 = m1[1].toLowerCase(), s1 = m1[2].toLowerCase();
                    const d2 = m2[1].toLowerCase(), s2 = m2[2].toLowerCase();
                    if (d1 === s2 && s1 === d2) {
                        optimized.push(curr);
                        i += 2;
                        continue;
                    }
                }
            }

            optimized.push(curr);
            i++;
        }
        return optimized;
    }

    _eliminateConsecutiveSetPins(lines) {
        const optimized = [];
        let i = 0;
        while (i < lines.length) {
            const curr = lines[i];
            const clean1 = curr.split(";")[0].trim();
            const set1 = clean1.match(/^SET\s+([a-zA-Z0-9_\[\]]+)\s*,\s*([01])$/i);

            if (set1 && i + 1 < lines.length) {
                const nxt = lines[i + 1];
                const clean2 = nxt.split(";")[0].trim();
                const set2 = clean2.match(/^SET\s+([a-zA-Z0-9_\[\]]+)\s*,\s*([01])$/i);
                if (set2 && set1[1].toLowerCase() === set2[1].toLowerCase() && set1[2] === set2[2]) {
                    optimized.push(curr);
                    i += 2;
                    continue;
                }
            }

            optimized.push(curr);
            i++;
        }
        return optimized;
    }

    _eliminateDeadCode(lines) {
        const optimized = [];
        let unreachable = false;

        for (const line of lines) {
            if (line.endsWith(":") || line.startsWith(".")) {
                unreachable = false;
                optimized.push(line);
                continue;
            }

            if (line.startsWith(";")) {
                if (!unreachable) optimized.push(line);
                continue;
            }

            if (unreachable) continue;

            optimized.push(line);

            const clean = line.split(";")[0].trim().toUpperCase();
            if (clean === "RET" || (clean.startsWith("JMP ") && !clean.includes("ZERO") && !clean.includes("CARRY"))) {
                unreachable = true;
            }
        }
        return optimized;
    }

    _eliminateJumpsToNext(lines) {
        const optimized = [];
        let i = 0;
        while (i < lines.length) {
            const curr = lines[i];
            const clean = curr.split(";")[0].trim();
            const jmpMatch = clean.match(/^JMP\s+([a-zA-Z0-9_]+)$/i);

            if (jmpMatch) {
                const target = jmpMatch[1].trim();
                let nextIdx = i + 1;
                while (nextIdx < lines.length && lines[nextIdx].startsWith(";")) {
                    nextIdx++;
                }
                if (nextIdx < lines.length && lines[nextIdx].trim() === `${target}:`) {
                    i++;
                    continue;
                }
            }

            optimized.push(curr);
            i++;
        }
        return optimized;
    }

    _compressJumpChains(lines) {
        const targets = {};
        for (let i = 0; i < lines.length; i++) {
            if (lines[i].endsWith(":")) {
                const lbl = lines[i].slice(0, -1).trim();
                let nextIdx = i + 1;
                while (nextIdx < lines.length && lines[nextIdx].startsWith(";")) nextIdx++;
                if (nextIdx < lines.length) {
                    const clean = lines[nextIdx].split(";")[0].trim();
                    const m = clean.match(/^JMP\s+([a-zA-Z0-9_]+)$/i);
                    if (m) targets[lbl] = m[1].trim();
                }
            }
        }

        return lines.map(line => {
            const m = line.match(/^(JMP(?:\s+[A-Z_]+,)?\s+)([a-zA-Z0-9_]+)(.*)$/i);
            if (m) {
                const prefix = m[1];
                const tgt = m[2];
                const rest = m[3];
                if (targets[tgt] && targets[tgt] !== tgt) {
                    return `${prefix}${targets[tgt]}${rest}`;
                }
            }
            return line;
        });
    }

    _eliminateUnusedLabels(lines) {
        const referenced = new Set();
        for (const line of lines) {
            const clean = line.split(";")[0].trim();
            const matches = clean.match(/\b(?:JMP|CALL|DJNZ)(?:\s+[A-Z_]+,)?\s+([a-zA-Z0-9_]+)/gi);
            if (matches) {
                matches.forEach(m => {
                    const parts = m.trim().split(/\s+/);
                    referenced.add(parts[parts.length - 1].trim());
                });
            }
        }

        const optimized = [];
        for (const line of lines) {
            if (line.endsWith(":") && !line.startsWith(";")) {
                const lbl = line.slice(0, -1).trim();
                if (lbl.startsWith("__") || ["main", "entry", "_entry"].includes(lbl) || referenced.has(lbl)) {
                    optimized.push(line);
                }
            } else {
                optimized.push(line);
            }
        }
        return optimized;
    }
}

// =============================================================================
// 8. HIGH-LEVEL COMPILER INTERFACE
// =============================================================================

export class OmniCCompiler {
    constructor(virtualHeaders = VIRTUAL_HEADERS) {
        this.virtualHeaders = virtualHeaders;
    }

    compile(cSource, options = { optimize: 1 }) {
        try {
            const preprocessor = new Preprocessor(this.virtualHeaders);
            const preprocessed = preprocessor.process(cSource);

            const lexer = new OmniCLexer(preprocessed);
            const tokens = lexer.tokenize();

            const parser = new OmniCParser(tokens, preprocessor.pragmas);
            const ast = parser.parse();

            const optLevel = typeof options.optimize === "number" ? options.optimize : (options.optimize === false ? 0 : 1);
            const codegen = new OmniCCodeGen({ optimize: optLevel, emitLocComments: true });
            const asmOutput = codegen.generate(ast);

            return {
                success: true,
                asmSource: asmOutput,
                errors: [],
                warnings: [],
                ast: ast,
                sourceMap: codegen.sourceMap
            };
        } catch (err) {
            return {
                success: false,
                asmSource: "",
                errors: [err.message || String(err)],
                warnings: [],
                ast: null,
                sourceMap: null
            };
        }
    }
}
