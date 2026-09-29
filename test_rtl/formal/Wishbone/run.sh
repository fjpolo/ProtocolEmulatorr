#!/bin/bash
set -e

# Source the OSS CAD Suite environment
echo "        [SBY] Sourcing OSS CAD Suite environment..."
source ~/oss-cad-suite/environment

RTL_DIR="${PWD}/../../../rtl"
RTL_FILE="${RTL_DIR}/OmniBus_Wishbone.v"
FIFO_FILE="${RTL_DIR}/omnibus_fifo.v"
PE_FILE="${RTL_DIR}/ProtocolEmulator.v"
PROF_FILE="${RTL_DIR}/OmniBus_Profiler.v"
USB_FILE="${RTL_DIR}/OmniBus_USB_SIE.v"
DMA_FILE="${RTL_DIR}/OmniBus_DMA.v"
FORMAL_FILE="${PWD}/properties.v"
CONFIG_FILE="${PWD}/Wishbone.sby"
WORK_DIR="$HOME/formal_work/wishbone"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Copy dependencies
cp "$FIFO_FILE" omnibus_fifo.v
cp "$PE_FILE" ProtocolEmulator.v
cp "$PROF_FILE" OmniBus_Profiler.v
cp "$USB_FILE" OmniBus_USB_SIE.v
cp "$DMA_FILE" OmniBus_DMA.v

# Concatenate RTL and formal properties before endmodule
awk -v f_file="$FORMAL_FILE" '/endmodule/{system("cat " f_file); print; next}1' "$RTL_FILE" > template_formal.v
cp "$CONFIG_FILE" Wishbone.sby

echo "        [SBY] Verifying Wishbone B4 Slave Handshake & Register Invariants..."
sby -f Wishbone.sby bound
sby -f Wishbone.sby prf
sby -f Wishbone.sby cvr

echo ""
echo "        [SBY] ALL WISHBONE B4 FORMAL INVARIANTS PROVEN!"
exit 0
