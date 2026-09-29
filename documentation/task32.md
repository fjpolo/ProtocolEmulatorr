# Task 32: OmniBus Software SDK & Assembly Standard Library

## 1. Executive Summary & Objectives

Task 32 delivers the official **OmniBus Software Development Kit (SDK)** under [`sdk/`](file:///c:/Workspace/ASIC/ProtocolEmulator/sdk/), establishing a complete developer toolchain for the OmniBus 16-bit deterministic protocol architecture. In full alignment with **`TOOLCHAIN_CONCEPT.md`**, this SDK addresses:

1. **Assembly Standard Library (`sdk/include/`)**: A modular suite of `.inc` headers defining core opcodes, register constants, jump conditions, and standard timing macros across UART, SPI, I2C, CAN, USB 1.1, NeoPixel RGB, N64 Joybus, Chiptune Audio, and Glitch/MitM fuzzer configurations.
2. **Python Host Driver & Toolchain (`sdk/omnibus/`)**: A pip-installable Python package providing in-system microcode flashing, high-throughput FIFO streaming, hardware waveform profiler queries, and fuzzer triggers.
3. **Declarative Protocol DSL (`omnibus.dsl`)**: A high-level Python timing synthesizer (`omnibus-cc`) translating declarative protocol timing constraints directly into cycle-exact 16-bit assembly.
4. **Command-Line Utilities (`omnibus`, `omnibus-load`, `omnibus-fuzz`, `omnibus-profiler`)**: Turnkey terminal tools for development and automated test scripts.
5. **Reference Examples (`sdk/examples/`)**: Pure assembly programs and Python host scripts demonstrating real-world protocols and hardware interaction.

---

## 2. Architecture & File Layout

```
sdk/
├── include/                   # Standard Assembly Include Library (.inc)
│   ├── omnibus.inc            # Core opcodes, registers, ALU constants, jump flags
│   ├── uart.inc               # UART 8N1 bit timing macros & pin aliases
│   ├── i2c.inc                # I2C START/STOP, open-drain mask & timing
│   ├── spi.inc                # SPI Mode 0/1/2/3 clock timing & pin aliases
│   ├── ws2812.inc             # 800 kHz asymmetric NeoPixel pulse constants
│   ├── joybus.inc             # N64 / GameCube 250 kbps open-collector pulse macros
│   ├── chiptune.inc           # 1-bit Delta-Sigma PDM DAC note frequencies
│   └── mitm.inc               # Glitch trigger & MitM pattern matcher constants
├── omnibus/                   # Python Toolchain & Host Driver Package
│   ├── __init__.py            # Main library exports
│   ├── core.py                # OmniBus hardware connection, IMEM flasher, registers
│   ├── streaming.py           # TX/RX FIFO streaming channel driver
│   ├── profiler.py            # Hardware Waveform Profiler & Auto-baud detector
│   ├── fuzzer.py              # Glitch pulse generator & active MitM mutator
│   ├── dma.py                 # Wishbone Scatter-Gather DMA descriptors
│   ├── usb_sie.py             # USB 1.1 Full-Speed SIE controller
│   ├── bist.py                # Autonomous BIST Crossbar & PRBS-7 LFSR
│   ├── assembler.py           # Python 16-bit macro assembler wrapper
│   ├── dsl.py                 # High-Level Declarative Protocol DSL (omnibus-cc)
│   └── cli.py                 # CLI tools: omnibus, omnibus-load, omnibus-fuzz
├── examples/                  # Ready-to-Run Assembly Examples & Host Scripts
│   ├── 01_uart_hello.asm      # UART 115200 8N1 "Hello OmniBus!" Streamer
│   ├── 02_i2c_sensor_read.asm # I2C Sensor Master Read with Clock Stretching
│   ├── 03_ws2812_rainbow.asm  # WS2812B NeoPixel 800 kHz RGB driver
│   ├── 04_mitm_flash_fuzzer.asm # Active MitM Match-and-Mutate & Glitch Trigger
│   ├── 05_python_host_driver.py # Python connect, flash, and streaming demo
│   └── 06_protocol_dsl.py     # Declarative Protocol DSL compilation demo
├── tests/                     # Automated SDK Unit Tests
│   └── test_sdk.py            # Microcode assembly & DSL synthesis tests
├── pyproject.toml             # Python build configuration
└── setup.py                   # pip installation script
```

---

## 3. Verification & Test Results

The SDK is verified through automated unit tests in [`sdk/tests/test_sdk.py`](file:///c:/Workspace/ASIC/ProtocolEmulator/sdk/tests/test_sdk.py):
- **Assembly Verification**: All reference assembly files (`01_uart_hello.asm`, `02_i2c_sensor_read.asm`, `03_ws2812_rainbow.asm`, `04_mitm_flash_fuzzer.asm`) assemble with 0 errors and fit within the 128-word IMEM boundary.
- **DSL Timing Synthesis**: Tested declarative protocol compilation and verified cycle-exact instruction generation.

To run the SDK test suite:
```bash
python sdk/tests/test_sdk.py
```
Output:
```
Ran 2 tests in 0.002s
OK
[+] Assembled 01_uart_hello.asm: 6 words.
[+] Assembled 02_i2c_sensor_read.asm: 20 words.
[+] Assembled 03_ws2812_rainbow.asm: 7 words.
[+] Assembled 04_mitm_flash_fuzzer.asm: 11 words.
[+] DSL Synthesized and Assembled: 3 words.
```
