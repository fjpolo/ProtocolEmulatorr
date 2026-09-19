#!/bin/bash

# Source the OSS CAD Suite environment
echo "        [YOSYS] Sourcing OSS CAD Suite environment..."
if [ -f ~/oss-cad-suite/environment ]; then
    source ~/oss-cad-suite/environment
fi

# Compile RTL module with yosys
echo "        [YOSYS] Compiling console60k top module with yosys..."
yosys console60k.ys

if [ $? -ne 0 ]; then
  echo "        [YOSYS] ERROR: Compilation failed."
  exit 1
fi

echo "        [YOSYS] PASS: console60k synthesis passed!"
