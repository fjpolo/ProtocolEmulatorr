#!/usr/bin/env bash
# =============================================================================
#  OmniBus Protocol Emulator - Load & Run 'Hello' Microcode
#  Uploads examples/hello.asm to FPGA IMEM and opens the interactive terminal.
#  Usage: ./run_hello.sh [--port /dev/ttyUSB1]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "${SCRIPT_DIR}/python/omnibus_loader.py" --file "${SCRIPT_DIR}/examples/hello.asm" --terminal "$@"
