#!/bin/bash
# =============================================================================
# File        : run_all.sh
# Description : Master Formal Verification Suite Runner (SymbiYosys / SVA)
#               Formally proves Section 7.1 of CONCEPT.md
# =============================================================================

# Source the OSS CAD Suite environment
echo "    [FORMAL] Sourcing OSS CAD Suite environment..."
source ~/oss-cad-suite/environment
if [ $? -ne 0 ]; then
    echo "    [FORMAL] ERROR: Failed to source OSS CAD Suite environment."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SUITE="$1"

ALL_SUITES=(
    "FIFO"
    "BusSafety"
    "Wishbone"
    "TimingZeroJitter"
    "CallStack"
    "ALU"
    "GlitchMitM"
    "BIST"
)

if [ -n "$TARGET_SUITE" ] && [ "$TARGET_SUITE" != "all" ]; then
    SUITES=("$TARGET_SUITE")
else
    SUITES=("${ALL_SUITES[@]}")
fi

echo "============================================================"
echo "  Task 30 - Formal Verification Suite (SymbiYosys / SVA)"
echo "  Target Suites: ${SUITES[*]}"
echo "============================================================"
echo ""

TOTAL=0
PASSED=0
FAILED=0
FAILED_NAMES=()

START_TIME=$(date +%s)

for suite in "${SUITES[@]}"; do
    suite_dir="${SCRIPT_DIR}/${suite}"
    if [ -d "$suite_dir" ] && [ -f "$suite_dir/run.sh" ]; then
        TOTAL=$((TOTAL + 1))
        echo "------------------------------------------------------------"
        echo " [*] Running Suite: ${suite}..."
        echo "------------------------------------------------------------"
        
        SUITE_START=$(date +%s)
        if (cd "$suite_dir" && chmod +x run.sh && ./run.sh); then
            SUITE_END=$(date +%s)
            SUITE_DUR=$((SUITE_END - SUITE_START))
            echo " [+] PASSED: ${suite} (${SUITE_DUR}s)"
            PASSED=$((PASSED + 1))
        else
            SUITE_END=$(date +%s)
            SUITE_DUR=$((SUITE_END - SUITE_START))
            echo " [!] FAILED: ${suite} (${SUITE_DUR}s)"
            FAILED=$((FAILED + 1))
            FAILED_NAMES+=("${suite}")
        fi
        echo ""
    else
        echo " [?] WARNING: Suite directory ${suite_dir} or run.sh not found, skipping."
    fi
done

END_TIME=$(date +%s)
TOTAL_DUR=$((END_TIME - START_TIME))

echo "============================================================"
echo "  Formal Verification Summary"
echo "  Total:  ${TOTAL}"
echo "  Passed: ${PASSED}"
echo "  Failed: ${FAILED}"
echo "  Time:   ${TOTAL_DUR}s"
echo "============================================================"

if [ $FAILED -ne 0 ]; then
    echo " [!] FAILED SUITES: ${FAILED_NAMES[*]}"
    exit 1
else
    echo " [✓] ALL FORMAL INVARIANTS MATHEMATICALLY PROVEN!"
    exit 0
fi