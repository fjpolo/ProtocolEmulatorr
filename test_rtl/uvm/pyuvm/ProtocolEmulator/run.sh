#!/bin/bash
# =============================================================================
# Run script for pyUVM ProtocolEmulator Verification
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "        [PYUVM] Executing pyUVM Verification Suite..."
export PYTHONPATH="$SCRIPT_DIR:$SCRIPT_DIR/../../../../:$PYTHONPATH"

# Run pyUVM testrunner using python3
python3 testrunner.py
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
    echo "        [PYUVM] FAIL: pyUVM testbench failed with exit code $EXIT_CODE"
    exit $EXIT_CODE
else
    echo "        [PYUVM] PASS: pyUVM testbench successfully passed 100%!"
    exit 0
fi