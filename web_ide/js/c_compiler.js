// =============================================================================
// File        : c_compiler.js
// Module      : OmniBus MP In-Browser Omni-C Compiler Engine
// Description : Full-featured browser-native C compiler for OmniBus ASIC:
//               Preprocessor, Lexer, Parser, Symbol Table, Register Allocator,
//               Code Generator (16-bit Assembly), and Peephole Optimizer.
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
    "return": TokenType.RETURN,
    "break": TokenType.BREAK,
    "continue": TokenType.CONTINUE,
    "goto": TokenType.GOTO,
    "asm": TokenType.ASM,
    "__asm__": TokenType.ASM,
    "__asm": TokenType.ASM
};

export class Token {
    constructor(type, value = null, line = 1, col = 1, raw = "") {
        this.type = type;
        this.value = value;
        this.line = line;
        this.col = col;
        this.raw = raw;
    }
}

export class OmniCLexer {
    constructor(source, filename = "<stdin>") {
        this.source = source;
        this.filename = filename;
        this.pos = 0;
        this.line = 1;
        this.col = 1;
        this.length = source.length;
    }

    _peek(offset = 0) {
        const idx = this.pos + offset;
        return idx < this.length ? this.source[idx] : "";
    }

    _advance() {
        if (this.pos < this.length) {
            const ch = this.source[this.pos++];
            if (ch === "\n") {
                this.line++;
                this.col = 1;
            } else {
                this.col++;
            }
            return ch;
        }
        return "";
    }

    tokenize() {
        const tokens = [];
        while (this.pos < this.length) {
            const ch = this._peek();

            // Whitespace
            if (/\s/.test(ch)) {
                this._advance();
                continue;
            }

            // Comments
            if (ch === "/" && this._peek(1) === "/") {
                while (this.pos < this.length && this._peek() !== "\n") {
                    this._advance();
                }
                continue;
            }
            if (ch === "/" && this._peek(1) === "*") {
                this._advance(); // /
                this._advance(); // *
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

            // Sentinels ($BAUD, $HBAUD)
            if (ch === "$") {
                this._advance();
                let ident = "$";
                while (/[a-zA-Z0-9_]/.test(this._peek())) {
                    ident += this._advance();
                }
                tokens.push(new Token(TokenType.SENTINEL, ident, startLine, startCol, ident));
                continue;
            }

            // Numbers: Hex (0x..), Binary (0b..), Decimal
            if (/\d/.test(ch)) {
                let numStr = "";
                if (ch === "0" && (this._peek(1) === "x" || this._peek(1) === "X")) {
                    numStr += this._advance(); // 0
                    numStr += this._advance(); // x
                    while (/[0-9a-fA-F_]/.test(this._peek())) {
                        const c = this._advance();
                        if (c !== "_") numStr += c;
                    }
                    const val = parseInt(numStr, 16);
                    tokens.push(new Token(TokenType.INT_LITERAL, val, startLine, startCol, numStr));
                } else if (ch === "0" && (this._peek(1) === "b" || this._peek(1) === "B")) {
                    numStr += this._advance(); // 0
                    numStr += this._advance(); // b
                    while (/[01_]/.test(this._peek())) {
                        const c = this._advance();
                        if (c !== "_") numStr += c;
                    }
                    const val = parseInt(numStr.substring(2), 2);
                    tokens.push(new Token(TokenType.INT_LITERAL, val, startLine, startCol, numStr));
                } else {
                    while (/[0-9_]/.test(this._peek())) {
                        const c = this._advance();
                        if (c !== "_") numStr += c;
                    }
                    const val = parseInt(numStr, 10);
                    tokens.push(new Token(TokenType.INT_LITERAL, val, startLine, startCol, numStr));
                }
                continue;
            }

            // Identifiers or Keywords
            if (/[a-zA-Z_]/.test(ch)) {
                let ident = "";
                while (/[a-zA-Z0-9_]/.test(this._peek())) {
                    ident += this._advance();
                }
                if (KEYWORDS.hasOwnProperty(ident)) {
                    tokens.push(new Token(KEYWORDS[ident], ident, startLine, startCol, ident));
                } else {
                    tokens.push(new Token(TokenType.IDENTIFIER, ident, startLine, startCol, ident));
                }
                continue;
            }

            // String Literals
            if (ch === '"') {
                this._advance();
                let strVal = "";
                while (this.pos < this.length && this._peek() !== '"') {
                    if (this._peek() === "\\") {
                        this._advance();
                        const esc = this._advance();
                        if (esc === "n") strVal += "\n";
                        else if (esc === "t") strVal += "\t";
                        else if (esc === "r") strVal += "\r";
                        else strVal += esc;
                    } else {
                        strVal += this._advance();
                    }
                }
                this._advance(); // closing quote
                tokens.push(new Token(TokenType.STR_LITERAL, strVal, startLine, startCol, `"${strVal}"`));
                continue;
            }

            // Char Literals
            if (ch === "'") {
                this._advance();
                let charVal = 0;
                if (this._peek() === "\\") {
                    this._advance();
                    const esc = this._advance();
                    if (esc === "n") charVal = 10;
                    else if (esc === "t") charVal = 9;
                    else if (esc === "r") charVal = 13;
                    else if (esc === "0") charVal = 0;
                    else charVal = esc.charCodeAt(0);
                } else {
                    charVal = this._advance().charCodeAt(0);
                }
                this._advance(); // closing single quote
                tokens.push(new Token(TokenType.INT_LITERAL, charVal, startLine, startCol, `'${charVal}'`));
                continue;
            }

            // Multi-char operators
            const twoChar = ch + this._peek(1);
            const threeChar = twoChar + this._peek(2);

            if (threeChar === "<<=" || threeChar === ">>=") {
                this._advance(); this._advance(); this._advance();
                tokens.push(new Token(threeChar === "<<=" ? TokenType.LSHIFT_ASSIGN : TokenType.RSHIFT_ASSIGN, threeChar, startLine, startCol, threeChar));
                continue;
            }

            const twoCharOps = {
                "==": TokenType.EQ, "!=": TokenType.NEQ, "<=": TokenType.LEQ, ">=": TokenType.GEQ,
                "<<": TokenType.LSHIFT, ">>": TokenType.RSHIFT, "&&": TokenType.AND, "||": TokenType.OR,
                "+=": TokenType.PLUS_ASSIGN, "-=": TokenType.MINUS_ASSIGN, "&=": TokenType.AMP_ASSIGN,
                "|=": TokenType.PIPE_ASSIGN, "^=": TokenType.CARET_ASSIGN, "++": TokenType.INC, "--": TokenType.DEC
            };

            if (twoCharOps.hasOwnProperty(twoChar)) {
                this._advance(); this._advance();
                tokens.push(new Token(twoCharOps[twoChar], twoChar, startLine, startCol, twoChar));
                continue;
            }

            // Single char tokens
            const singleCharOps = {
                "+": TokenType.PLUS, "-": TokenType.MINUS, "*": TokenType.STAR, "/": TokenType.SLASH, "%": TokenType.PERCENT,
                "&": TokenType.AMP, "|": TokenType.PIPE, "^": TokenType.CARET, "~": TokenType.TILDE, "!": TokenType.BANG,
                "<": TokenType.LT, ">": TokenType.GT, "=": TokenType.ASSIGN, ";": TokenType.SEMICOLON, ",": TokenType.COMMA,
                ":": TokenType.COLON, "(": TokenType.LPAREN, ")": TokenType.RPAREN, "{": TokenType.LBRACE, "}": TokenType.RBRACE,
                "[": TokenType.LBRACKET, "]": TokenType.RBRACKET
            };

            if (singleCharOps.hasOwnProperty(ch)) {
                this._advance();
                tokens.push(new Token(singleCharOps[ch], ch, startLine, startCol, ch));
                continue;
            }

            // Unknown character
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

            // Skip conditional compilation guards
            if (/^[#`]?(ifndef|endif|ifdef|else|elif)/.test(trimmed)) {
                continue;
            }

            // #pragma directive
            const pragmaMatch = trimmed.match(/^[#`]?pragma\s+([a-zA-Z0-9_]+)\s*(.*)/i);
            if (pragmaMatch) {
                const key = pragmaMatch[1].trim();
                const val = pragmaMatch[2].trim();
                this.pragmas.push({ key, value: val, line: i + 1 });
                outputLines.push(`// [Pragma: ${key} ${val}]`);
                continue;
            }

            // #include directive
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

            // Function-like macro: #define FOO(a,b) (a + b)
            const funcMacroMatch = trimmed.match(/^[#`]?define\s+([a-zA-Z0-9_]+)\s*\((.*?)\)\s*(.*)/);
            if (funcMacroMatch) {
                const name = funcMacroMatch[1];
                const params = funcMacroMatch[2].split(",").map(p => p.trim()).filter(Boolean);
                let body = funcMacroMatch[3].trim();
                if (body.includes("//")) body = body.split("//")[0].trim();
                this.funcMacros.set(name, { params, body });
                continue;
            }

            // Object-like macro: #define FOO or #define FOO 0x55
            const objMacroMatch = trimmed.match(/^[#`]?define\s+([a-zA-Z0-9_]+)(?:\s+(.+))?$/);
            if (objMacroMatch) {
                const name = objMacroMatch[1];
                let body = objMacroMatch[2] ? objMacroMatch[2].trim() : "";
                if (body.includes("//")) body = body.split("//")[0].trim();
                this.objMacros.set(name, body);
                continue;
            }

            // Skip any unrecognized preprocessor directives starting with # or `
            if (trimmed.startsWith("#") || trimmed.startsWith("`")) {
                continue;
            }

            outputLines.push(line);
        }

        let fullText = outputLines.join("\n");

        // Object Macro substitution
        const sortedMacros = Array.from(this.objMacros.entries()).sort((a, b) => b[0].length - a[0].length);
        for (const [name, val] of sortedMacros) {
            if (val) {
                const regex = new RegExp(`\\b${name}\\b`, "g");
                fullText = fullText.replace(regex, val);
            }
        }

        // Function Macro substitution
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

        // Check if function definition or prototype
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
                const pNameTok = this._expect(TokenType.IDENTIFIER, "Expected parameter name");
                params.push(new VarDecl(pType, pNameTok.value, null, null, false, pNameTok.line, pNameTok.col));
                if (!this._match(TokenType.COMMA)) break;
            }
            this._expect(TokenType.RPAREN);

            // Function prototype
            if (this._match(TokenType.SEMICOLON)) {
                return new FunctionDef(typeName, name, params, null, name === "main", true, nameTok.line, nameTok.col);
            }

            // Function body
            const body = this._parseBlock();
            return new FunctionDef(typeName, name, params, body, name === "main", false, nameTok.line, nameTok.col);
        }

        // Variable declaration
        let initExpr = null;
        if (this._match(TokenType.ASSIGN)) {
            initExpr = this._parseExpression();
        }
        this._expect(TokenType.SEMICOLON);
        return new VarDecl(typeName, name, initExpr, regHint, isConst, nameTok.line, nameTok.col);
    }

    _parseBlock() {
        const startTok = this._expect(TokenType.LBRACE);
        const stmts = [];
        while (this._peek().type !== TokenType.RBRACE && this._peek().type !== TokenType.EOF) {
            stmts.push(this._parseStatement());
        }
        this._expect(TokenType.RBRACE);
        return new Block(stmts, startTok.line, startTok.col);
    }

    _parseStatement() {
        const tok = this._peek();

        if (tok.type === TokenType.LBRACE) return this._parseBlock();
        if (tok.type === TokenType.IF) return this._parseIf();
        if (tok.type === TokenType.WHILE) return this._parseWhile();
        if (tok.type === TokenType.DO) return this._parseDoWhile();
        if (tok.type === TokenType.REPEAT) return this._parseRepeat();
        if (tok.type === TokenType.RETURN) return this._parseReturn();
        if (tok.type === TokenType.BREAK) {
            const bTok = this._advance();
            this._expect(TokenType.SEMICOLON);
            return new BreakStmt(bTok.line, bTok.col);
        }
        if (tok.type === TokenType.CONTINUE) {
            const cTok = this._advance();
            this._expect(TokenType.SEMICOLON);
            return new ContinueStmt(cTok.line, cTok.col);
        }
        if (tok.type === TokenType.ASM) return this._parseAsmStmt();
        if (TYPE_TOKENS.has(tok.type) || tok.type === TokenType.CONST || tok.type === TokenType.REG) {
            return this._parseLocalVar();
        }

        // Expression or Assignment statement
        const expr = this._parseExpression();
        this._expect(TokenType.SEMICOLON);
        return new ExprStmt(expr, tok.line, tok.col);
    }

    _parseLocalVar() {
        let isConst = false;
        let regHint = null;
        if (this._match(TokenType.CONST)) isConst = true;
        if (this._match(TokenType.REG)) {
            regHint = this._expect(TokenType.IDENTIFIER).value;
        }
        let typeName = "uint8_t";
        if (TYPE_TOKENS.has(this._peek().type)) typeName = this._advance().value;
        const nameTok = this._expect(TokenType.IDENTIFIER);
        let initExpr = null;
        if (this._match(TokenType.ASSIGN)) {
            initExpr = this._parseExpression();
        }
        this._expect(TokenType.SEMICOLON);
        return new VarDecl(typeName, nameTok.value, initExpr, regHint, isConst, nameTok.line, nameTok.col);
    }

    _parseIf() {
        const ifTok = this._advance(); // if
        this._expect(TokenType.LPAREN);
        const cond = this._parseExpression();
        this._expect(TokenType.RPAREN);
        const thenBranch = this._parseStatement();
        let elseBranch = null;
        if (this._match(TokenType.ELSE)) {
            elseBranch = this._parseStatement();
        }
        return new IfStmt(cond, thenBranch, elseBranch, ifTok.line, ifTok.col);
    }

    _parseWhile() {
        const wTok = this._advance(); // while
        this._expect(TokenType.LPAREN);
        const cond = this._parseExpression();
        this._expect(TokenType.RPAREN);
        const body = this._parseStatement();
        return new WhileStmt(cond, body, wTok.line, wTok.col);
    }

    _parseDoWhile() {
        const dTok = this._advance(); // do
        const body = this._parseStatement();
        this._expect(TokenType.WHILE);
        this._expect(TokenType.LPAREN);
        const cond = this._parseExpression();
        this._expect(TokenType.RPAREN);
        this._expect(TokenType.SEMICOLON);
        return new DoWhileStmt(body, cond, dTok.line, dTok.col);
    }

    _parseRepeat() {
        const rTok = this._advance(); // repeat
        this._expect(TokenType.LPAREN);
        const countExpr = this._parseExpression();
        this._expect(TokenType.RPAREN);
        const body = this._parseStatement();
        return new RepeatStmt(countExpr, body, rTok.line, rTok.col);
    }

    _parseReturn() {
        const rTok = this._advance(); // return
        let val = null;
        if (this._peek().type !== TokenType.SEMICOLON) {
            val = this._parseExpression();
        }
        this._expect(TokenType.SEMICOLON);
        return new ReturnStmt(val, rTok.line, rTok.col);
    }

    _parseAsmStmt() {
        const asmTok = this._advance();
        this._expect(TokenType.LPAREN);
        const codeTok = this._expect(TokenType.STR_LITERAL);
        this._expect(TokenType.RPAREN);
        this._match(TokenType.SEMICOLON);
        return new AsmStmt(codeTok.value, asmTok.line, asmTok.col);
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
            const value = this._parseAssignment();
            return new AssignStmt(expr, opTok.type, value, opTok.line, opTok.col);
        }
        return expr;
    }

    _parseLogicalOr() {
        let left = this._parseLogicalAnd();
        while (this._match(TokenType.OR)) {
            const right = this._parseLogicalAnd();
            left = new BinaryOp(left, "||", right, left.line, left.col);
        }
        return left;
    }

    _parseLogicalAnd() {
        let left = this._parseBitwiseOr();
        while (this._match(TokenType.AND)) {
            const right = this._parseBitwiseOr();
            left = new BinaryOp(left, "&&", right, left.line, left.col);
        }
        return left;
    }

    _parseBitwiseOr() {
        let left = this._parseBitwiseXor();
        while (this._match(TokenType.PIPE)) {
            const right = this._parseBitwiseXor();
            left = new BinaryOp(left, "|", right, left.line, left.col);
        }
        return left;
    }

    _parseBitwiseXor() {
        let left = this._parseBitwiseAnd();
        while (this._match(TokenType.CARET)) {
            const right = this._parseBitwiseAnd();
            left = new BinaryOp(left, "^", right, left.line, left.col);
        }
        return left;
    }

    _parseBitwiseAnd() {
        let left = this._parseEquality();
        while (this._match(TokenType.AMP)) {
            const right = this._parseEquality();
            left = new BinaryOp(left, "&", right, left.line, left.col);
        }
        return left;
    }

    _parseEquality() {
        let left = this._parseRelational();
        while (true) {
            const tok = this._peek();
            if (tok.type === TokenType.EQ || tok.type === TokenType.NEQ) {
                this._advance();
                const right = this._parseRelational();
                left = new BinaryOp(left, tok.type, right, left.line, left.col);
            } else {
                break;
            }
        }
        return left;
    }

    _parseRelational() {
        let left = this._parseShift();
        while (true) {
            const tok = this._peek();
            if ([TokenType.LT, TokenType.LEQ, TokenType.GT, TokenType.GEQ].includes(tok.type)) {
                this._advance();
                const right = this._parseShift();
                left = new BinaryOp(left, tok.type, right, left.line, left.col);
            } else {
                break;
            }
        }
        return left;
    }

    _parseShift() {
        let left = this._parseAdditive();
        while (true) {
            const tok = this._peek();
            if (tok.type === TokenType.LSHIFT || tok.type === TokenType.RSHIFT) {
                this._advance();
                const right = this._parseAdditive();
                left = new BinaryOp(left, tok.type, right, left.line, left.col);
            } else {
                break;
            }
        }
        return left;
    }

    _parseAdditive() {
        let left = this._parseMultiplicative();
        while (true) {
            const tok = this._peek();
            if (tok.type === TokenType.PLUS || tok.type === TokenType.MINUS) {
                this._advance();
                const right = this._parseMultiplicative();
                left = new BinaryOp(left, tok.type, right, left.line, left.col);
            } else {
                break;
            }
        }
        return left;
    }

    _parseMultiplicative() {
        let left = this._parseUnary();
        while (true) {
            const tok = this._peek();
            if ([TokenType.STAR, TokenType.SLASH, TokenType.PERCENT].includes(tok.type)) {
                this._advance();
                const right = this._parseUnary();
                left = new BinaryOp(left, tok.type, right, left.line, left.col);
            } else {
                break;
            }
        }
        return left;
    }

    _parseUnary() {
        const tok = this._peek();
        if ([TokenType.BANG, TokenType.TILDE, TokenType.MINUS, TokenType.INC, TokenType.DEC].includes(tok.type)) {
            this._advance();
            const expr = this._parseUnary();
            return new UnaryOp(tok.type, expr, tok.line, tok.col);
        }
        return this._parsePrimary();
    }

    _parsePrimary() {
        const tok = this._peek();

        // Integer literal
        if (tok.type === TokenType.INT_LITERAL) {
            this._advance();
            return new Literal(tok.value, tok.raw, tok.line, tok.col);
        }

        // Sentinel ($BAUD, $HBAUD)
        if (tok.type === TokenType.SENTINEL) {
            this._advance();
            return new Literal(tok.value, tok.value, tok.line, tok.col);
        }

        // Parentheses
        if (this._match(TokenType.LPAREN)) {
            const expr = this._parseExpression();
            this._expect(TokenType.RPAREN);
            return expr;
        }

        // Identifier or Function / Built-in Call
        if (tok.type === TokenType.IDENTIFIER) {
            this._advance();
            if (this._match(TokenType.LPAREN)) {
                const args = [];
                while (this._peek().type !== TokenType.RPAREN && this._peek().type !== TokenType.EOF) {
                    args.push(this._parseExpression());
                    if (!this._match(TokenType.COMMA)) break;
                }
                this._expect(TokenType.RPAREN);
                return new BuiltinCall(tok.value, args, tok.line, tok.col);
            }
            return new Identifier(tok.value, tok.line, tok.col);
        }

        throw new Error(`Unexpected token '${tok.value}' (L${tok.line}:C${tok.col})`);
    }
}

// =============================================================================
// 5. REGISTER ALLOCATOR & SYMBOLS
// =============================================================================

class SymbolEntry {
    constructor(name, symType, reg = null, isConst = false, constVal = null) {
        this.name = name;
        this.symType = symType;
        this.reg = reg;
        this.isConst = isConst;
        this.constVal = constVal;
    }
}

class Scope {
    constructor(parent = null) {
        this.parent = parent;
        this.symbols = new Map();
    }
    define(sym) { this.symbols.set(sym.name, sym); }
    lookup(name) {
        if (this.symbols.has(name)) return this.symbols.get(name);
        if (this.parent) return this.parent.lookup(name);
        return null;
    }
}

class RegisterAllocator {
    constructor() {
        this.allRegisters = ["r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7"];
        this.freeRegisters = [...this.allRegisters];
        this.allocated = new Map();
    }

    allocate(varName, regHint = null) {
        if (this.allocated.has(varName)) return this.allocated.get(varName);

        if (regHint) {
            const hint = regHint.toLowerCase();
            this.allocated.set(varName, hint);
            const idx = this.freeRegisters.indexOf(hint);
            if (idx !== -1) this.freeRegisters.splice(idx, 1);
            return hint;
        }

        if (this.freeRegisters.length > 0) {
            const reg = this.freeRegisters.shift();
            this.allocated.set(varName, reg);
            return reg;
        }
        return "r7";
    }

    free(varName) {
        if (this.allocated.has(varName)) {
            const reg = this.allocated.get(varName);
            this.allocated.delete(varName);
            if (this.allRegisters.includes(reg) && !this.freeRegisters.includes(reg)) {
                this.freeRegisters.push(reg);
                this.freeRegisters.sort();
            }
        }
    }
}

// =============================================================================
// 6. CODE GENERATOR & OPTIMIZER
// =============================================================================

export class OmniCCodeGen {
    constructor(optimize = true) {
        this.optimize = optimize;
        this.lines = [];
        this.labelCounter = 0;
        this.loopStack = [];
        this.currentScope = new Scope();
        this.regAlloc = new RegisterAllocator();
        this.activeLoopCounters = [];
        this.clockFreq = 50000000;
        this.baudRate = 115200;
    }

    _emit(line) { this.lines.push(line); }

    _newLabel(prefix = "L") {
        this.labelCounter++;
        return `lbl_${prefix}_${this.labelCounter}`;
    }

    generate(program) {
        this.lines = [];
        this._emit("; ==============================================================================");
        this._emit("; OmniBus Microcode — Compiled by Omni-C In-Browser Engine");
        this._emit("; Target Architecture: OmniBus 16-bit Deterministic Multi-Engine");
        this._emit("; ==============================================================================");

        // Pragmas
        if (program.pragmas) {
            for (const p of program.pragmas) {
                const k = p.key.toLowerCase();
                const v = p.value;
                if (k === "clock") {
                    const clean = v.toLowerCase().replace("mhz", "000000").replace("khz", "000").replace("hz", "");
                    const parsed = parseInt(clean, 10);
                    if (!isNaN(parsed)) this.clockFreq = parsed;
                } else if (k === "baud") {
                    const parsed = parseInt(v, 10);
                    if (!isNaN(parsed)) this.baudRate = parsed;
                } else if (k === "core" || k === "bank") {
                    this._emit(`.bank ${v}`);
                }
            }
        }

        this._emit(`.clock ${this.clockFreq}`);

        const hasMain = program.decls.some(d => d instanceof FunctionDef && d.name === "main");
        if (hasMain) {
            this._emit(".entry main");
            this._emit("");
        }

        // Global Declarations & Functions
        for (const decl of program.decls) {
            if (decl instanceof VarDecl) {
                this._genGlobalVar(decl);
            } else if (decl instanceof FunctionDef) {
                this._genFunction(decl);
            } else if (decl instanceof AsmStmt) {
                this._emit(decl.asmCode);
            }
        }

        if (this.optimize) {
            return this._optimize(this.lines).join("\n") + "\n";
        }
        return this.lines.join("\n") + "\n";
    }

    _genGlobalVar(decl) {
        const reg = this.regAlloc.allocate(decl.name, decl.regHint);
        const sym = new SymbolEntry(decl.name, decl.varType, reg, decl.isConst);
        this.currentScope.define(sym);

        if (decl.isConst && decl.initExpr instanceof Literal) {
            sym.constVal = decl.initExpr.value;
            this._emit(`.const ${decl.name} ${decl.initExpr.value}`);
        } else if (decl.initExpr) {
            const val = this._evalLiteralOrReg(decl.initExpr);
            this._emit(`MOV ${reg}, ${val} ; init global ${decl.name}`);
        }
    }

    _genFunction(func) {
        if (func.isPrototype || !func.body) return;

        this._emit(`; --- Function: ${func.name} ---`);
        this._emit(`${func.name}:`);

        const oldScope = this.currentScope;
        this.currentScope = new Scope(oldScope);

        for (const param of func.params) {
            const reg = this.regAlloc.allocate(param.name, param.regHint);
            this.currentScope.define(new SymbolEntry(param.name, param.varType, reg));
        }

        for (const stmt of func.body.statements) {
            this._genStatement(stmt);
        }

        if (!func.isEntry) {
            const lastLine = this.lines.length > 0 ? this.lines[this.lines.length - 1].trim() : "";
            if (!lastLine.startsWith("RET") && !lastLine.startsWith("JMP")) {
                this._emit("RET");
            }
        }

        this._emit("");
        this.currentScope = oldScope;
    }

    _genStatement(stmt) {
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
        } else if (stmt instanceof ReturnStmt) {
            if (stmt.value) {
                const val = this._evalLiteralOrReg(stmt.value);
                if (val !== "acc") this._emit(`MOV acc, ${val}`);
            }
            this._emit("RET");
        } else if (stmt instanceof BreakStmt) {
            if (this.loopStack.length === 0) throw new Error("Break outside loop");
            this._emit(`JMP ${this.loopStack[this.loopStack.length - 1].breakLabel}`);
        } else if (stmt instanceof ContinueStmt) {
            if (this.loopStack.length === 0) throw new Error("Continue outside loop");
            this._emit(`JMP ${this.loopStack[this.loopStack.length - 1].contLabel}`);
        } else if (stmt instanceof AsmStmt) {
            this._emit(stmt.asmCode);
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
                    this._emit(`MOV acc, ${val}`);
                } else {
                    this._emit(`MOV acc, ${val}`);
                    this._emit(`MOV ${reg}, acc`);
                }
            }
        }
    }

    _genAssign(assign) {
        const targetName = this._getVarName(assign.target);
        const targetSym = this.currentScope.lookup(targetName);
        const targetReg = targetSym && targetSym.reg ? targetSym.reg : targetName.toLowerCase();

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
                    this._emit(`MOV acc, ${val}`);
                } else {
                    this._emit(`MOV acc, ${val}`);
                    this._emit(`MOV ${targetReg}, acc`);
                }
            }
        } else {
            const opMap = {
                "+=": "ADD", "-=": "SUB", "&=": "AND", "|=": "OR", "^=": "XOR",
                "<<=": "SHL", ">>=": "SHR"
            };
            const aluOp = opMap[assign.op];
            const val = this._evalLiteralOrReg(assign.value);
            if (targetReg === "acc") {
                this._emit(`${aluOp} ${val}`);
            } else {
                this._emit(`MOV acc, ${targetReg}`);
                this._emit(`${aluOp} ${val}`);
                this._emit(`MOV ${targetReg}, acc`);
            }
        }
    }

    _genBinaryAssign(targetReg, binop) {
        const left = this._evalLiteralOrReg(binop.left);
        const right = this._evalLiteralOrReg(binop.right);
        const opMap = { "+": "ADD", "-": "SUB", "&": "AND", "|": "OR", "^": "XOR", "<<": "SHL", ">>": "SHR" };
        const aluOp = opMap[binop.op] || "ADD";

        if (targetReg === "acc") {
            if (left !== "acc") this._emit(`MOV acc, ${left}`);
            this._emit(`${aluOp} ${right}`);
        } else {
            this._emit(`MOV acc, ${left}`);
            this._emit(`${aluOp} ${right}`);
            this._emit(`MOV ${targetReg}, acc`);
        }
    }

    _genUnaryAssign(targetReg, unop) {
        const opStr = this._evalLiteralOrReg(unop.expr);
        if (unop.op === "~" || unop.op === "not") {
            if (targetReg === "acc") {
                if (opStr !== "acc") this._emit(`MOV acc, ${opStr}`);
                this._emit("NOT");
            } else {
                this._emit(`MOV acc, ${opStr}`);
                this._emit("NOT");
                this._emit(`MOV ${targetReg}, acc`);
            }
        } else if (unop.op === "++") {
            this._emit(`INC ${targetReg}`);
        } else if (unop.op === "--") {
            this._emit(`DEC ${targetReg}`);
        }
    }

    _genBuiltinAssign(targetReg, call) {
        const name = call.name.toLowerCase();
        if (name === "pull") {
            this._emit("PULL");
            if (targetReg !== "osr") this._emit(`MOV ${targetReg}, osr`);
        } else if (name === "core_id") {
            this._emit("CORE_ID");
            if (targetReg !== "acc") this._emit(`MOV ${targetReg}, acc`);
        } else if (name === "spinlock_acquire" || name === "spinlock_acq") {
            const lockId = call.args.length > 0 ? this._evalLiteralOrReg(call.args[0]) : "0";
            this._emit(`SPINLOCK_ACQ ${lockId}`);
            if (targetReg !== "acc") this._emit(`MOV ${targetReg}, acc`);
        } else if (name === "mailbox_read" || name === "mb_read") {
            const mbId = call.args.length > 0 ? this._evalLiteralOrReg(call.args[0]) : "0";
            this._emit(`MB_READ ${mbId}`);
            if (targetReg !== "acc") this._emit(`MOV ${targetReg}, acc`);
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
        const lcId = !this.activeLoopCounters.includes(0) ? 0 : 1;
        this.activeLoopCounters.push(lcId);
        const lcName = `LC${lcId}`;
        const countVal = this._evalLiteralOrReg(stmt.countExpr);

        const startLabel = this._newLabel(`loop_lc${lcId}`);
        const endLabel = this._newLabel(`end_lc${lcId}`);

        this._emit(`SET_LC ${countVal}`);
        this.loopStack.push({ contLabel: startLabel, breakLabel: endLabel });

        this._emit(`${startLabel}:`);
        this._genStatement(stmt.body);
        this._emit(`DJNZ ${startLabel}`);
        this._emit(`${endLabel}:`);

        this.loopStack.pop();
        this.activeLoopCounters.pop();
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
        const args = call.args.map(a => this._evalLiteralOrReg(a));

        if (name === "pin_set") {
            const delay = args[2] ? ` [${args[2]}]` : "";
            this._emit(`SET ${args[0]}, ${args[1]}${delay}`);
        } else if (name === "pin_high") {
            const delay = args[1] ? ` [${args[1]}]` : "";
            this._emit(`SET ${args[0]}, 1${delay}`);
        } else if (name === "pin_low") {
            const delay = args[1] ? ` [${args[1]}]` : "";
            this._emit(`SET ${args[0]}, 0${delay}`);
        } else if (name === "pin_wait") {
            const timeout = args[2] !== undefined ? ` [${args[2]}]` : "";
            this._emit(`WAIT ${args[0]}, ${args[1]}${timeout}`);
        } else if (name === "pin_map") {
            this._emit(`PINMAP tx=${args[0]}, rx=${args[1]}, sck=${args[2]}, cs=${args[3]}`);
        } else if (name === "cfg_od") {
            this._emit(`CFG_OD ${args[0]}`);
        } else if (name === "pull") {
            this._emit("PULL");
        } else if (name === "pull_block") {
            this._emit("PULL BLOCK");
        } else if (name === "push") {
            this._emit("PUSH");
        } else if (name === "push_block") {
            this._emit("PUSH BLOCK");
        } else if (name === "out_shift") {
            const delay = args[1] ? ` [${args[1]}]` : "";
            this._emit(`OUT ${args[0]}${delay}`);
        } else if (name === "out_sck") {
            const count = args[0] || "8";
            const delay = args[1] ? ` [${args[1]}]` : "";
            this._emit(`OUT SCK, ${count}${delay}`);
        } else if (name === "in_shift") {
            const delay = args[1] ? ` [${args[1]}]` : "";
            this._emit(`IN ${args[0]}${delay}`);
        } else if (name === "in_sck") {
            const count = args[0] || "8";
            const delay = args[1] ? ` [${args[1]}]` : "";
            this._emit(`IN SCK, ${count}${delay}`);
        } else if (name === "delay_cycles") {
            this._emit(`NOP [${args[0]}]`);
        } else if (name === "delay_baud") {
            this._emit("NOP [$BAUD]");
        } else if (name === "delay_hbaud") {
            this._emit("NOP [$HBAUD]");
        } else if (name === "nop") {
            this._emit("NOP");
        } else if (name === "barrier_wait") {
            this._emit("BARRIER_WAIT");
        } else if (name === "spinlock_release" || name === "spinlock_rel") {
            this._emit(`SPINLOCK_REL ${args[0] || "0"}`);
        } else if (name === "mailbox_write" || name === "mb_write") {
            if (args[1]) this._emit(`MOV acc, ${args[1]}`);
            this._emit(`MB_WRITE ${args[0] || "0"}`);
        } else if (name === "assist_pulse_cfg") {
            this._emit(`ASSIST PULSE_CFG ${args[0]}`);
        } else if (name === "assist_pulse_time0") {
            this._emit(`ASSIST PULSE_TIME0 ${args[0]}, ${args[1]}`);
        } else if (name === "assist_pulse_time1") {
            this._emit(`ASSIST PULSE_TIME1 ${args[0]}, ${args[1]}`);
        } else if (name === "assist_glitch_arm") {
            this._emit("ASSIST GLITCH_ARM");
        } else if (name === "assist_audio_vol") {
            this._emit(`ASSIST AUDIO_VOL ${args[0]}`);
        } else if (name === "assist_audio_play") {
            this._emit(`ASSIST AUDIO_PLAY ${args[0]}, ${args[1]}`);
        } else if (name === "assist_audio_stop") {
            this._emit("ASSIST AUDIO_STOP");
        } else {
            // General function call: CALL func
            this._emit(`CALL ${call.name}`);
        }
    }

    _genConditionBranch(cond, targetLabel, jumpIfTrue) {
        if (cond instanceof Literal) {
            if (cond.value === 1 || cond.value === true) {
                if (jumpIfTrue) this._emit(`JMP ${targetLabel}`);
            } else if (cond.value === 0 || cond.value === false) {
                if (!jumpIfTrue) this._emit(`JMP ${targetLabel}`);
            }
            return;
        }

        if (cond instanceof BinaryOp) {
            const left = this._evalLiteralOrReg(cond.left);
            const right = this._evalLiteralOrReg(cond.right);

            if (left !== "acc") this._emit(`MOV acc, ${left}`);
            this._emit(`CMP ${right}`);

            const op = cond.op;
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

    _optimize(lines) {
        const optimized = [];
        for (let i = 0; i < lines.length; i++) {
            const curr = lines[i].trim();
            if (!curr) continue;

            // Coalesce NOP [delay] into previous instruction
            if (i + 1 < lines.length) {
                const next = lines[i + 1].trim();
                const nopMatch = next.match(/^NOP\s+\[(.*?)\]$/i);
                if (nopMatch && !curr.includes("[") && !curr.endsWith(":")) {
                    const opcode = curr.split(/\s+/)[0].toUpperCase();
                    if (["SET", "WAIT", "OUT", "IN", "CFG_OD", "PINMAP"].includes(opcode)) {
                        optimized.push(`${curr} [${nopMatch[1]}]`);
                        i++;
                        continue;
                    }
                }
            }

            // Skip redundant self-moves: MOV X, X
            const movMatch = curr.match(/^MOV\s+([a-zA-Z0-9_]+)\s*,\s*([a-zA-Z0-9_]+)$/i);
            if (movMatch && movMatch[1].toLowerCase() === movMatch[2].toLowerCase()) {
                continue;
            }

            optimized.push(curr);
        }
        return optimized;
    }
}

// =============================================================================
// 7. HIGH-LEVEL COMPILER INTERFACE
// =============================================================================

export class OmniCCompiler {
    constructor(virtualHeaders = VIRTUAL_HEADERS) {
        this.virtualHeaders = virtualHeaders;
    }

    compile(cSource, options = { optimize: true }) {
        try {
            // Step 1: Preprocessor & Header Expansion
            const preprocessor = new Preprocessor(this.virtualHeaders);
            const preprocessed = preprocessor.process(cSource);

            // Step 2: Lexical Analysis
            const lexer = new OmniCLexer(preprocessed);
            const tokens = lexer.tokenize();

            // Step 3: Parsing & AST Construction
            const parser = new OmniCParser(tokens, preprocessor.pragmas);
            const ast = parser.parse();

            // Step 4: Code Generation & Optimization
            const codegen = new OmniCCodeGen(options.optimize !== false);
            const asmOutput = codegen.generate(ast);

            return {
                success: true,
                asmSource: asmOutput,
                errors: [],
                warnings: [],
                ast: ast
            };
        } catch (err) {
            return {
                success: false,
                asmSource: "",
                errors: [err.message || String(err)],
                warnings: [],
                ast: null
            };
        }
    }
}
