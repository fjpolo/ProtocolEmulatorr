# OmniBus Software Development Kit (SDK)

Welcome to the official **OmniBus Software Development Kit (SDK)** for the **OmniBus Protocol Emulator ASIC**.

OmniBus executes 16-bit deterministic microcode assembly (`.asm`) directly in custom silicon. This SDK provides the complete software toolchain for writing, assembling, synthesizing, simulating, and flashing microcode into physical FPGA boards and taped-out ASIC hardware.

---

## 1. Directory Structure

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

## 2. Installation

Install the Python SDK in editable development mode:
```bash
pip install -e sdk/
```

---

## 3. Quickstart Examples

### 3.1. Writing & Assembling Microcode in Assembly

```asm
; File: my_uart.asm
.clock 50MHz
tx_pin = uio[0]

main:
    SET tx_pin, 1 [$BAUD]

loop:
    PULL
    SET tx_pin, 0 [$BAUD]      ; Start bit
    OUT tx_pin, 8 [$BAUD]      ; 8 data bits
    SET tx_pin, 1 [$BAUD]      ; Stop bit
    JMP loop
```

Assemble and upload directly to physical hardware via CLI:
```bash
omnibus load my_uart.asm --port COM3 --baud 115200
```

### 3.2. Controlling OmniBus from Python

```python
from omnibus import OmniBus

# Connect to physical board (Tang Console 60K, Tang Nano 20K, or Nano 9K)
with OmniBus(port="COM3", baudrate=115200) as bus:
    # 1. Flash microcode into IMEM
    bus.load_microcode("sdk/examples/01_uart_hello.asm")

    # 2. Stream data to TX FIFO and read response
    bus.stream.write("Hello Silicon!\r\n")
    response = bus.stream.read(max_bytes=32)
    print(f"Echoed: {response}")
```

### 3.3. Declarative Protocol DSL (`omnibus.dsl`)

Synthesize timing-exact assembly from high-level Python protocol specifications:

```python
from omnibus.dsl import Protocol, Pin, Direction

class SPIMaster(Protocol):
    clock_freq_hz = 50_000_000

    mosi = Pin(index=0, direction=Direction.OUTPUT, idle=0)
    miso = Pin(index=1, direction=Direction.INPUT)
    sck  = Pin(index=2, direction=Direction.OUTPUT, idle=0)
    cs_n = Pin(index=3, direction=Direction.OUTPUT, idle=1)

    def transfer_byte(self):
        self.cs_n.low(ns=100)
        with self.loop(count=8):
            self.mosi.shift_out(source="OSR", count=1)
            self.sck.low(cycles=2)
            self.sck.high(cycles=1)
            self.miso.shift_in(destination="ISR", count=1)
            self.sck.high(cycles=2)
        self.cs_n.high(ns=100)
        self.push_rx()

# Generate cycle-exact Assembly:
asm_code = SPIMaster.compile()
print(asm_code)
```

---

## 4. Running Tests

Run the automated test suite:
```bash
python sdk/tests/test_sdk.py
```
