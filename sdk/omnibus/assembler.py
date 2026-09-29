# =============================================================================
# File        : assembler.py
# Module      : omnibus.assembler
# Description : Python macro assembler interface for the OmniBus 16-bit ISA.
# License     : MIT License
# =============================================================================

import sys
import os
from typing import List, Union

# Import reference implementation from repository root python/
try:
    from ...python.omnibus_asm import OmnibusAssembler
except Exception:
    # Direct fallback if imported standalone
    sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "python")))
    try:
        from omnibus_asm import OmnibusAssembler
    except ImportError:
        OmnibusAssembler = None


def assemble(source_code: str, clk_freq: int = 50_000_000, baud: int = 115_200) -> List[int]:
    """
    Assembles OmniBus microcode assembly text into a list of 16-bit integer words.
    
    :param source_code: Assembly string with instructions and directives.
    :param clk_freq: Master core clock frequency in Hz.
    :param baud: Default baud rate for $BAUD macros.
    :return: List of 16-bit instruction words.
    """
    if OmnibusAssembler is None:
        raise ImportError("Could not load OmnibusAssembler engine.")
    asm = OmnibusAssembler(clk_freq=clk_freq, default_baud=baud)
    result = asm.assemble(source_code)
    if isinstance(result, tuple) and len(result) == 2:
        parsed, labels = result
    else:
        parsed = result
    return [word for (_, word, _) in parsed]


def assemble_file(filepath: str, clk_freq: int = 50_000_000, baud: int = 115_200) -> List[int]:
    """
    Reads an assembly file from disk and returns assembled 16-bit machine code words.
    """
    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()
    return assemble(content, clk_freq=clk_freq, baud=baud)
