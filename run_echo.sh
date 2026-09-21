#!/usr/bin/env bash
# =============================================================================
#  OmniBus Protocol Emulator - Load & Run 'Echo' Microcode
#  Uploads examples/echo.asm to FPGA IMEM and opens the interactive terminal.
#  Usage: ./run_echo.sh [--port /dev/ttyUSB1]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${SCRIPT_DIR}/python/omnibus_loader.py" --file "${SCRIPT_DIR}/examples/echo.asm" --terminal "$@"
