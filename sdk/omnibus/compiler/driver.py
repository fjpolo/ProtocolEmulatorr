# =============================================================================
# File        : driver.py
# Module      : omnibus.compiler.driver
# Description : Turnkey Compiler Driver for Omni-C (omnibus-cc).
# License     : MIT License
# =============================================================================

import os
import sys
import re
from typing import List, Optional, Tuple, Dict, Any, Set
from .lexer import OmniCLexer
from .parser import OmniCParser
from .codegen import OmniCCodeGen


def get_default_include_dir() -> str:
    """Returns the path to sdk/include/omnic/."""
    current_dir = os.path.dirname(os.path.abspath(__file__))
    sdk_include = os.path.abspath(os.path.join(current_dir, "..", "..", "include", "omnic"))
    return sdk_include


class Preprocessor:
    """Handles #include, #define macro expansions, and header guards."""

    def __init__(self, include_paths: Optional[List[str]] = None):
        self.include_paths = include_paths or []
        default_inc = get_default_include_dir()
        if os.path.isdir(default_inc) and default_inc not in self.include_paths:
            self.include_paths.append(default_inc)
        self.included_files: Set[str] = set()
        self.func_macros: Dict[str, Tuple[List[str], str]] = {}  # name -> (param_list, body)
        self.obj_macros: Dict[str, str] = {}  # name -> value

    def process(self, source: str, base_dir: str = ".") -> str:
        # Pass 1: Resolve #include and extract macros
        lines = source.splitlines()
        expanded_lines: List[str] = []

        for line in lines:
            stripped = line.strip()

            # Skip header guards
            if stripped.startswith("#ifndef") or stripped.startswith("#endif"):
                continue

            # Match #include "..." or #include <...>
            inc_match = re.match(r'^\s*#include\s+["<](.*?)[">]', stripped)
            if inc_match:
                header_name = inc_match.group(1)
                header_path = self._resolve_header(header_name, base_dir)
                if header_path:
                    if header_path not in self.included_files:
                        self.included_files.add(header_path)
                        with open(header_path, "r", encoding="utf-8") as hf:
                            header_content = hf.read()
                        expanded_lines.append(f"// === Begin Include: {header_name} ===")
                        processed_header = self.process(header_content, os.path.dirname(header_path))
                        expanded_lines.append(processed_header)
                        expanded_lines.append(f"// === End Include: {header_name} ===")
                else:
                    expanded_lines.append(f"// [Warning: Include not found: {header_name}]")
                continue

            # Match function-like macro: #define NAME(a, b) REPLACEMENT
            func_macro_match = re.match(r'^\s*#define\s+([a-zA-Z0-9_]+)\s*\((.*?)\)\s+(.*)', stripped)
            if func_macro_match:
                macro_name = func_macro_match.group(1)
                params = [p.strip() for p in func_macro_match.group(2).split(",") if p.strip()]
                body = func_macro_match.group(3).strip()
                # Strip trailing comments from body
                if "//" in body:
                    body = body.split("//")[0].strip()
                self.func_macros[macro_name] = (params, body)
                continue

            expanded_lines.append(line)

        # Pass 2: Expand function-like macros across lines
        text = "\n".join(expanded_lines)
        for macro_name, (params, body) in self.func_macros.items():
            # Match macro_name(...)
            pattern = re.compile(rf'\b{macro_name}\s*\((.*?)\)', re.DOTALL)
            def replace_macro(m):
                args_str = m.group(1)
                args = [a.strip() for a in args_str.split(",") if a.strip()]
                replaced_body = body
                for param, arg in zip(params, args):
                    replaced_body = re.sub(rf'\b{param}\b', arg, replaced_body)
                return replaced_body
            text = pattern.sub(replace_macro, text)

        return text


    def _resolve_header(self, header_name: str, base_dir: str) -> Optional[str]:
        # Check base_dir first
        candidate = os.path.join(base_dir, header_name)
        if os.path.isfile(candidate):
            return os.path.abspath(candidate)

        # Check include search paths
        for inc_dir in self.include_paths:
            candidate = os.path.join(inc_dir, header_name)
            if os.path.isfile(candidate):
                return os.path.abspath(candidate)

        return None


class OmniCCompiler:
    """Turnkey High-Level Omni-C Compiler."""

    def __init__(self, include_paths: Optional[List[str]] = None, optimize: bool = True):
        self.include_paths = include_paths or []
        self.optimize = optimize

    def compile_source(self, source: str, base_dir: str = ".", filename: str = "<stdin>") -> str:
        # Step 1: Preprocessor & Includes
        preprocessor = Preprocessor(self.include_paths)
        preprocessed_source = preprocessor.process(source, base_dir)

        # Step 2: Lexical Analysis
        lexer = OmniCLexer(preprocessed_source, filename)
        tokens = lexer.tokenize()

        # Step 3: Parsing & AST Construction
        parser = OmniCParser(tokens, filename)
        program_ast = parser.parse()

        # Step 4: Code Generation & Optimization
        codegen = OmniCCodeGen(optimize=self.optimize)
        asm_output = codegen.generate(program_ast)

        return asm_output

    def compile_file(self, filepath: str, output_asm: Optional[str] = None) -> str:
        base_dir = os.path.dirname(os.path.abspath(filepath))
        with open(filepath, "r", encoding="utf-8") as f:
            source = f.read()

        asm_output = self.compile_source(source, base_dir=base_dir, filename=filepath)

        if output_asm:
            with open(output_asm, "w", encoding="utf-8") as out_f:
                out_f.write(asm_output)

        return asm_output
