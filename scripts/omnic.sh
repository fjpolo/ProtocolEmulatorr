#!/usr/bin/env bash
# =============================================================================
# Omni-C High-Level Protocol Compiler CLI Wrapper (Linux / macOS / WSL)
# Usage: ./scripts/omnic.sh <source.c> [options]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${SCRIPT_DIR}/../python/omnic.py" "$@"
