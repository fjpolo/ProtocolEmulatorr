# OmniBus ASIC: Adaptive Protocol Chameleon and Security Fuzzing Micro-Engine

An open-source, general-purpose protocol emulator ASIC targeting the **Jane Street and Tiny Tapeout ASIC Competition** (IHP 130nm CMOS5L process, 6x4 tile allocation).

> Detailed Specifications:
> - Hardware Datasheet & Terminal Specifications: [DATASHEET.md](documentation/DATASHEET.md)
> - Glitch / Fault Injector & MitM Engine User Guide: [GLITCH_MITM_USER_GUIDE.md](documentation/GLITCH_MITM_USER_GUIDE.md)
> - Architecture and Hardware ISA: [CONCEPT.md](documentation/CONCEPT.md)
> - Assembler, Compiler, and Toolchain: [TOOLCHAIN_CONCEPT.md](documentation/TOOLCHAIN_CONCEPT.md)

## Overview
**OmniBus** operates in three distinct modes:
1. **The Impersonator**: Cycle-exact protocol emulator for UART, SPI, I2C, USB 1.1, CAN, 10Mbit Ethernet, and retro gamepads.
2. **The Detective**: Autonomous reverse-engineering profiler with hardware pulse-width histogramming and auto-baud / clock-phase discovery.
3. **The Chameleon**: Wire-speed active Man-in-the-Middle (MitM) packet mutator and cycle-accurate glitch/fault fuzzer for hardware security testing.

## Key Innovations

* **Deterministic 16-bit ISA**: Single-cycle execution with hardware sidecar delays (0-31 cycles)
* **Autonomous Stream Accelerators**: On-the-fly NRZI, Bit-Stuffing (USB/CAN), Manchester encoding, multi-polynomial CRC (CRC-5/8/16/32 Ethernet FCS), dedicated hardware I2C / SMBus slave engine with autonomous address matching and clock stretching, 1-Bit Delta-Sigma Audio DAC & Chiptune PDM Synthesizer, IEEE 1149.1 JTAG TAP Controller & ARM SWD Sequencer, and Quad-SPI (QSPI) / Dual / Octal-SPI Multi-Lane Flash & PSRAM Host Controller
* **Wire-Speed MitM and Glitch Injection**: Dynamic rule-based byte replacement and sub-cycle fault triggering
* **Retro and Creative Physical Protocols**: Native support for N64/GameCube Joybus, NES/SNES gamepads, NeoPixel LED strips, and 4-voice polyphonic chiptune audio APU
* **Unified 8-Bit Bidirectional GPIO Bus**: Dynamic role mapping (`PINMAP`) and per-pin open-drain configuration (`CFG_OD`) allowing arbitrary protocol routing across GPIOs 0..7
* **Multi-Target Prototyping**: Complete build and test flows for Sipeed Tang Console 60K, Nano 20K, and Nano 9K before CMOS5L tapeout


## Demonstration & Protocol Scripts

All ready-to-run microcode demonstrators, interactive terminals, and test harnesses are located in [`scripts/`](scripts/):

| Script | Protocol / Feature | Mode & Description |
| :--- | :--- | :--- |
| [`scripts/run_glitch.bat`](scripts/run_glitch.bat) | **Hardware Glitch & MitM Engine** | Sub-cycle crowbar pulse generator, wire-speed pattern matching & real-time byte mutation terminal. |
| [`scripts/run_qspi.bat`](scripts/run_qspi.bat) | **Quad-SPI / Octal Host** | Autonomous Winbond W25Q Quad Fast Read (`0xEB`), 24/32-bit address & dummy cycles. |
| [`scripts/run_jtag.bat`](scripts/run_jtag.bat) | **JTAG & ARM SWD** | IEEE 1149.1 TAP state navigation, RISC-V IDCODE scan, and ARM CoreSight SWD probe. |
| [`scripts/run_audio.bat`](scripts/run_audio.bat) | **Audio DAC & Chiptune APU** | 50 MHz 1st-order Delta-Sigma ($\Sigma$-$\Delta$) PDM DAC & 4-voice polyphonic synthesizer. |
| [`scripts/run_i2c_slave.bat`](scripts/run_i2c_slave.bat) | **Hardware I2C Slave** | Autonomous SCL/SDA framing, hardware address matching, clock stretching & 24C02 EEPROM. |
| [`scripts/run_crc32.bat`](scripts/run_crc32.bat) | **Hardware CRC-32 / CRC-5** | IEEE 802.3 Ethernet FCS 32-bit CRC calculation & USB 1.1 token CRC-5 verification. |
| [`scripts/run_manch.bat`](scripts/run_manch.bat) | **Manchester / BMC Engine** | 10BASE-T Ethernet, S/PDIF, and DALI transceiver with hardware violation detection. |
| [`scripts/run_pulse.bat`](scripts/run_pulse.bat) | **Pulse & Retro Gamepads** | WS2812B NeoPixel RGB LED streaming, Nintendo N64/GC Joybus, and NES/SNES controllers. |
| [`scripts/run_usb.bat`](scripts/run_usb.bat) | **Stream Accelerators** | Autonomous NRZI encoding/decoding and USB 1.1 / CAN bit-stuffing/de-stuffing. |
| [`scripts/run_imem.bat`](scripts/run_imem.bat) | **IMEM Bank Switching** | 128-word microcode execution across Banks 0..3 with hot-reloading. |
| [`scripts/run_alu.bat`](scripts/run_alu.bat) | **8-Bit Micro-ALU** | Interactive ASCII classification, uppercase conversion, and self-test harness. |
| [`scripts/run_echo_configurable.bat`](scripts/run_echo_configurable.bat) | **Configurable UART Echo** | Dynamic runtime baud rate divisor configuration (300 baud – 25 Mbps). |
| [`scripts/run_spi_generic.bat`](scripts/run_spi_generic.bat) | **SPI Master** | Full-duplex synchronous SPI transmission and reception with auto-SCK generation. |

## Architecture Specifications

* [Task 01 — Baseline Engine & ALU](documentation/task01.md)
* [Task 02 — Sidecar Delays & Opcode Decoding](documentation/task02.md)
* [Task 03 — Mid-Bit Deserialization & Edge Wait](documentation/task03.md)
* [Task 04 — In-Band Microcode Bootloader](documentation/task04.md)
* [Task 05 — Hardware Subroutine Call Stack](documentation/task05.md)
* [Task 06 — Runtime-Configurable Baud Divisor](documentation/task06.md)
* [Task 07 — SPI Master & Auto-SCK Serialization](documentation/task07.md)
* [Task 07C — Unified 8-Bit GPIO Bus & Dynamic Pin Mapping](documentation/task07c.md)
* [Task 08 — I2C Master in Microcode (Loopback Mode)](documentation/task08.md)
* [Task 09 — Zero-Overhead Hardware Loop Counters](documentation/task09.md)
* [Task 10 — Bidirectional SERDES & Full-Duplex Architecture](documentation/task10.md)
* [Task 11 — Hardware FIFO Handshaking & Status Flags](documentation/task11.md)
* [Task 12 — 1-Wire Protocol & Hardware Serializer/Deserializer](documentation/task12.md)
* [Task 13 — Hardware CRC Generator & Checksum Accelerator](documentation/task13.md)
* [Task 14 — Parameterized FIFO Subsystem & Wishbone B4 Slave Wrapper](documentation/task14.md)
* [Task 15 — 8-bit Micro-ALU & Arithmetic Engine](documentation/task15.md)
* [Task 16 — 128-Word IMEM Expansion & 4-Bank Switching](documentation/task16.md)
* [Task 17 — Autonomous Stream Accelerators: NRZI & Bit-Stuffer/De-stuffer](documentation/task17.md)
* [Task 18 — Asymmetric Single-Wire & Retro Physical Protocol Accelerators](documentation/task18.md)
* [Task 19 — Autonomous Manchester / Biphase Mark Stream Accelerator](documentation/task19.md)
* [Task 20 — Hardware CRC-32 (Ethernet FCS) & CRC-5 Engine](documentation/task20.md)
* [Task 21 — Dedicated Hardware I2C / SMBus Slave Engine](documentation/task21.md)
* [Task 22 — 1-Bit Delta-Sigma Audio DAC & Chiptune PDM Synthesizer Engine](documentation/task22.md)
* [Task 23 — Dedicated Hardware JTAG TAP Controller & ARM SWD Sequencer](documentation/task23.md)
* [Task 24 — Quad-SPI & Multi-Lane Flash/PSRAM Hardware Host Controller](documentation/task24.md)
* [Task 25 — Hardware Glitch / Fault Injection & Active Wire-Speed MitM Fuzzing Engine](documentation/task25.md)

---

## OmniBus Lite: The Complete Architectural Foundation (Tasks 01–25)

Tasks 01 through 25 establish **OmniBus Lite**—a production-grade, self-contained, silicon-ready protocol processor core:
* **100% Regression Pass Rate**: All **82 self-checking Cocotb testcases** (75 core + 7 Wishbone) pass with 0 failures, 0 skips, and 0 regressions.
* **Proven Silicon Footprint**: ~22,000 standard cells, fitting comfortably within the Tiny Tapeout 6×4 tile allocation on IHP 130nm CMOS5L (~0.72 mm²).
* **Broad Physical Protocol Coverage**:
  - **Hardware Security & Fuzzing**: Sub-cycle precision crowbar & glitch pulse generation (1..255 cycles, 20 ns resolution @ 50 MHz), 16-bit countdown delay (0..65535 cycles), autonomous wire-speed pattern matching with wildcard bitmask, real-time in-flight byte mutation, and Wishbone telemetry (`0x24`).
  - **Serial & Industrial**: UART (300 baud – 25 Mbps), SPI (Modes 0–3 up to 25 MHz), I2C Master & Autonomous Hardware Slave with Clock Stretching, 1-Wire, USB 1.1 (NRZI & Bit-Stuffing), CAN 2.0.
  - **High-Speed Multi-Lane**: Single, Dual, Quad, and Octal-SPI (xSPI / OSPI) NOR Flash and PSRAM host engine.
  - **Embedded Debug**: IEEE 1149.1 16-State JTAG TAP Controller & ARM SWD (ADIv5) with RISC-V DTM and ARM CoreSight compatibility.
  - **Networking & Telecom**: 10BASE-T Ethernet Manchester encoding/decoding, Biphase Mark Code (BMC / S/PDIF / DALI), 32-bit Ethernet FCS CRC-32, USB CRC-5, and multi-polynomial CRC-8/16.
  - **Audio & Creative**: 1-Bit Delta-Sigma Audio DAC ($OSR=1250\times$), 4-voice polyphonic chiptune APU, WS2812B NeoPixel, Nintendo N64/GameCube Joybus, NES/SNES gamepads.
* **Deterministic Real-Time Core**: 16-bit unified ISA, dual-port 128-word IMEM (4 banks), 8-bit Micro-ALU, 4-deep call stack, dual zero-overhead loop counters, and parameterized Wishbone B4 slave interconnect.

---

## Usage

1. **Instantiate the module:**

   ```verilog
   ProtocolEmulator ProtocolEmulator (
       .i_clk(i_clk),                   // 50 MHz clock
       .i_reset_n(i_reset_n),           // Active-low synchronous reset
       .i_data(i_data),                 // 8-bit host byte for PULL
       .o_data(o_data),                 // 8-bit output register
       .i_baud_div(i_baud_div),         // Runtime baud rate divisor (cycles/bit - 1)
       .i_gpio(i_gpio),                 // 8-bit bidirectional GPIO inputs
       .o_gpio(o_gpio),                 // 8-bit bidirectional GPIO outputs
       .o_gpio_oe(o_gpio_oe),           // 8-bit GPIO output enables (1=drive, 0=Hi-Z)
       // Microcode programming port
       .i_prog_en(i_prog_en),
       .i_prog_we(i_prog_we),
       .i_prog_addr(i_prog_addr),
       .i_prog_data(i_prog_data),
       .o_prog_rdata(o_prog_rdata)
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

# Build Tang Nano 20K launcher (default: nano20k)
build_gowin_nano20k.bat
build_gowin_nano20k.bat -Board nano20k
build_gowin_nano20k.bat -Board nano9k

# Clean build artifacts before compiling
build_gowin_nano20k.bat -Clean

# Run logic synthesis only
build_gowin_nano20k.bat -Target syn

# Program directly to volatile SRAM
build_gowin_nano20k.bat -Flash sram

# Program to persistent external SPI Flash
build_gowin_nano20k.bat -Flash flash

# Scan for connected JTAG cables and devices
build_gowin_nano20k.bat -Scan
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