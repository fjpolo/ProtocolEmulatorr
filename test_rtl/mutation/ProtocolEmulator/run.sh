#!/bin/bash
# =============================================================================
# Run script for RTL Mutation Testing of ProtocolEmulator
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "        [MUTATION] Executing RTL Mutation Testing Campaign..."
export PYTHONPATH="$SCRIPT_DIR:$SCRIPT_DIR/../../../..:$PYTHONPATH"

python3 mutation_runner.py
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
    echo "        [MUTATION] FAIL: Mutation testing suite failed with exit code $EXIT_CODE"
    exit $EXIT_CODE
else
    echo "        [MUTATION] PASS: Mutation testing completed with 100% kill-rate!"
    exit 0
fi