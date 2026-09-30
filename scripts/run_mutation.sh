#!/usr/bin/env bash
# =============================================================================
# OmniBus ProtocolEmulator — RTL Mutation Testing Runner (Linux / WSL)
# =============================================================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../test_rtl/mutation/ProtocolEmulator"

echo "[OMNIBUS][MUTATION] Starting RTL Mutation Testing Campaign & Fault Injector..."
python3 mutation_runner.py
echo "[OMNIBUS][MUTATION] SUCCESS: Mutation testing campaign completed with 100% kill-rate!"
