# ProtocolEmulator Module

This Verilog module implements...

## Features

* Feature1
* Feature2
* Feature3

## Usage

1. **Instantiate the module:**

   ```verilog
   ProtocolEmulator #(
       // Optional parameters here 
   ) ProtocolEmulator (
       .clk(clk),           // Input
       .reset_n(reset_n),   // Input - active low
       .data_in(data_in),   // Input
       .data_out(data_out)  // Output
   );
   ```

## Supported FPGA Boards & Build Automation

The repository includes ready-to-build Gowin EDA projects under `boards/sipeed/` with automated PowerShell and Batch build flows:

* **Sipeed Tang Console 60K** (`GW5AT-LV60PG484AC1/I0` / `GW5AT-60B`):
  - Located in [`boards/sipeed/console60k/`](boards/sipeed/console60k/)
  - Direct build launcher: `build_console60k.bat`
* **Sipeed Tang Nano 20K** (`GW2AR-LV18QN88C8/I7`):
  - Located in [`boards/sipeed/nano20k/`](boards/sipeed/nano20k/)
* **Sipeed Tang Nano 9K** (`GW1NR-LV9QN88PC6/I5`):
  - Located in [`boards/sipeed/nano9k/`](boards/sipeed/nano9k/)

### Build Script Commands

```cmd
# Build Tang Console 60K (synthesis, PnR, bitstream generation)
build_console60k.bat

# Multi-board launcher (default: console60k)
build_gowin.bat -Board console60k
build_gowin.bat -Board nano20k
build_gowin.bat -Board nano9k

# Clean build artifacts before compiling
build_gowin.bat -Board console60k -Clean

# Run logic synthesis only
build_gowin.bat -Board console60k -Target syn

# Program directly to volatile SRAM
build_gowin.bat -Board console60k -Flash sram

# Program to persistent external SPI Flash
build_gowin.bat -Board console60k -Flash flash

# Scan for connected JTAG cables and devices
build_gowin.bat -Board console60k -Scan
```

## FPGA Debugging with Manta Logic Analyzer

This ProtocolEmulator includes built-in support for the [Manta FPGA Logic Analyzer](https://github.com/fischermoseley/manta).

### Setup (Host Machine)
1. Install Manta Python package:
   ```bash
   pip install manta-fpga
   ```

### Option A: Verilog Workflow
1. Generate the Verilog module for the logic analyzer defined in `manta.yaml`:
   ```bash
   manta gen manta.yaml manta_core.v
   ```
2. Add `manta_core.v` to your synthesis project file list (e.g. `.gprj` file).
3. Uncomment the `manta` module instantiation in `src/top.v` and map the physical UART RX/TX pins to the board pins.
4. Synthesize the project, upload it to the board, and run the host script to capture waveforms:
   ```bash
   python python/manta_test.py --port COM3  # Or your platform serial port
   ```

### Option B: Amaranth Workflow
1. Uncomment the native Manta integration code block inside `amaranth/ProtocolEmulator.py`'s `elaborate` function.
2. Build and flash using Amaranth.