# ProtocolEmulator on Sipeed Tang Console 60K

This project targets the **Sipeed Tang Console 60K** retro-gaming / FPGA development board featuring the Gowin Arora V **GW5AT-LV60PG484AC1/I0** (`GW5AT-60B`) FPGA.

## Hardware Resource Mapping

| Signal | Board Location / Net | FPGA Pin | IO Type | Description |
| :--- | :--- | :--- | :--- | :--- |
| `i_sys_clk` | Onboard Crystal Osc | **V22** | LVCMOS33 | 50.000 MHz main clock |
| `i_sys_rst_n` | Button S0 | **AA13** | LVCMOS15 (PULL_UP) | Active-low system reset |
| `o_led[0]` | PMOD1 Pin 10 (IO7) | **D21** | LVCMOS33 | Data bit 0 output indicator |
| `o_led[1]` | PMOD1 Pin 4 (IO6) | **E21** | LVCMOS33 | Data bit 1 output indicator |
| `o_led[2]` | PMOD1 Pin 9 (IO5) | **D22** | LVCMOS33 | Data bit 2 output indicator |
| `o_led[3]` | PMOD1 Pin 3 (IO4) | **E22** | LVCMOS33 | Data bit 3 output indicator |
| `o_led[4]` | PMOD1 Pin 8 (IO3) | **F20** | LVCMOS33 | Data bit 4 output indicator |
| `o_led[5]` | PMOD1 Pin 2 (IO2) | **F19** | LVCMOS33 | Data bit 5 output indicator |
| `o_led[6]` | PMOD1 Pin 7 (IO1) | **W20** | LVCMOS33 | Data bit 6 output indicator |
| `o_led[7]` | PMOD1 Pin 1 (IO0) | **W19** | LVCMOS33 | Data bit 7 output indicator |
| `uart_tx` *(optional)* | BL616 MCU RX | **U15** | LVCMOS33 | Manta Logic Analyzer TX |
| `uart_rx` *(optional)* | BL616 MCU TX | **V14** | LVCMOS33 | Manta Logic Analyzer RX |

## Quick Start / Build Flow

The project provides automated build and programming scripts using Gowin EDA (`gw_sh.exe` and `programmer_cli.exe`).

### Windows Command Prompt (`build.bat`)
```cmd
# Full build: synthesis, placement, routing, bitstream generation
build.bat

# Clean build artifacts before rebuilding
build.bat -Clean

# Run logic synthesis only
build.bat -Target syn

# Build and program bitstream directly to volatile SRAM
build.bat -Flash sram

# Build and write bitstream to non-volatile external SPI Flash
build.bat -Flash flash

# Scan for connected Gowin USB cables and JTAG devices
build.bat -Scan
```

### PowerShell (`build.ps1`)
```powershell
# Full build
.\build.ps1

# Clean and rebuild
.\build.ps1 -Clean

# Flash existing bitstream to SRAM without rebuilding
.\build.ps1 -NoBuild -Flash sram

# Flash to persistent SPI Flash
.\build.ps1 -NoBuild -Flash flash
```

### Open-Source Yosys Flow (`build_yosys.sh`)
```bash
# Synthesize top module for GW5AT-60B (Arora-V) using Yosys
./build_yosys.sh
```

