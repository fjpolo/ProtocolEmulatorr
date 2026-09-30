#!/bin/bash
# =============================================================================
# Run script for all Mutation Testing suites
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "    [MUTATION] Starting RTL Mutation Testing Suites..."

for dir in */; do
  if [ -f "$dir/run.sh" ]; then
    echo "    [MUTATION] Running $dir/run.sh..."
    (cd "$dir" && ./run.sh)
    exit_status=$?

    if [ $exit_status -ne 0 ]; then
      echo "    [MUTATION] FAIL: $dir failed!"
      exit $exit_status
    else
      echo "    [MUTATION] PASS: $dir passed 100%!"
    fi
  fi
done

echo "    [MUTATION] All mutation testing suites PASSED with 100% kill-rate!"
exit 0