#!/bin/bash
set -e

# Source the OSS CAD Suite environment
echo "        [SBY] Sourcing OSS CAD Suite environment..."
source ~/oss-cad-suite/environment

RTL_DIR="${PWD}/../../../rtl"
RTL_FILE="${RTL_DIR}/ProtocolEmulator.v"
FORMAL_FILE="${PWD}/properties.v"
CONFIG_FILE="${PWD}/TimingZeroJitter.sby"
WORK_DIR="$HOME/formal_work/timingzerojitter"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Copy submodules
cp "${RTL_DIR}/OmniBus_Profiler.v" .
cp "${RTL_DIR}/OmniBus_USB_SIE.v" .

# Concatenate RTL and formal properties before endmodule
awk -v f_file="$FORMAL_FILE" '/endmodule/{system("cat " f_file); print; next}1' "$RTL_FILE" > template_formal.v
cp "$CONFIG_FILE" TimingZeroJitter.sby

echo "        [SBY] Verifying Deterministic Timing & Zero-Jitter Invariants..."
sby -f TimingZeroJitter.sby bound
sby -f TimingZeroJitter.sby prf
sby -f TimingZeroJitter.sby cvr

echo ""
echo "        [SBY] ALL TIMING ZERO-JITTER FORMAL INVARIANTS PROVEN!"
exit 0
