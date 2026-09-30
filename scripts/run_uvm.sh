#!/usr/bin/env bash
# =============================================================================
# OmniBus ProtocolEmulator — pyUVM Verification Runner (Linux / WSL)
# =============================================================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../test_rtl/uvm/pyuvm/ProtocolEmulator"

echo "[OMNIBUS][pyUVM] Starting Universal Verification Methodology (UVM) Suite..."
export PYTHONPATH="$SCRIPT_DIR/..:$PYTHONPATH"
python3 testrunner.py
echo "[OMNIBUS][pyUVM] SUCCESS: pyUVM verification completed 100% successfully!"
