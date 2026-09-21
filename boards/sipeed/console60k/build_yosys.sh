#!/bin/bash
# =============================================================================
# Open-source Yosys build script for Sipeed Tang Console 60K
# =============================================================================

set -e

# Source OSS CAD Suite environment if available
if [ -f ~/oss-cad-suite/environment ]; then
    source ~/oss-cad-suite/environment
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "============================================================"
echo "  Synthesizing Tang Console 60K with Yosys (GW5A / Arora-V)"
echo "============================================================"

mkdir -p impl/pnr

yosys console60k.ys

echo "============================================================"
echo "  Yosys synthesis for Tang Console 60K PASSED!"
echo "  Output netlist: impl/pnr/console60k_synth.v"
echo "  JSON netlist  : impl/pnr/console60k_synth.json"
echo "============================================================"
