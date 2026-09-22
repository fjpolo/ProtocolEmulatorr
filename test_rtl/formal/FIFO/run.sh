#!/bin/bash

# Source the OSS CAD Suite environment
echo "        [SBY] Sourcing OSS CAD Suite environment..."
source ~/oss-cad-suite/environment
if [ $? -ne 0 ]; then
    echo "        [SBY] Failed to source OSS CAD Suite environment. Exiting script."
    exit 1
fi

# Input files
ORIGINAL_FILE="${PWD}/../../../rtl/omnibus_fifo.v"
FORMAL_FILE="properties.v"
CONFIG_FILE="omnibus_fifo.sby"

# Generate a temporary file
TEMP_FILE="template_formal.v"
echo -n > $TEMP_FILE

# Check if required files exist
echo "        [SBY] Checking if required files exist..."
for FILE in "$ORIGINAL_FILE" "$FORMAL_FILE"; do
    if [ ! -f "$FILE" ]; then
        echo "        [SBY] ERROR: File $FILE not found. Exiting script."
        exit 1
    fi
done

# Insert formal properties into the original master before `endmodule`
awk -v f_file="$FORMAL_FILE" '/endmodule/{system("cat " f_file); print; next}1' "$ORIGINAL_FILE" > "$TEMP_FILE"

# Run SymbiYosys (sby) tasks sequentially on the temporary file
echo "        [SBY] Verifying $ORIGINAL_FILE with formal properties (bound, prf, cvr)..."
sby -f $CONFIG_FILE bound && sby -f $CONFIG_FILE prf && sby -f $CONFIG_FILE cvr

# Check if sby succeeded
if [ $? -ne 0 ]; then
    echo "        [SBY] FAIL: sby failed for $ORIGINAL_FILE. Exiting script."
    rm $TEMP_FILE
    exit 1
fi

echo ""
echo "        [SBY] ALL FIFO FORMAL TASKS PASSED!"
rm -f $TEMP_FILE
exit 0
