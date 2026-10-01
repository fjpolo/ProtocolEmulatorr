# OmniBus Software Development Kit (SDK)

Welcome to the official **OmniBus Software Development Kit (SDK)** for the **OmniBus Protocol Emulator ASIC**.

OmniBus provides a unified, dual-track programming model supporting both **Microcode Assembly** for sub-cycle hardware control and **Omni-C** for high-level structured C protocol development. This SDK provides standard library headers, optimizing compilers, host drivers, and test suites for FPGA prototypes and CMOS5L taped-out silicon.

---

## 1. Directory Structure

```
sdk/
├── include/                   # Standard Header Libraries
│   ├── omnibus.inc            # Assembly: Core opcodes, registers, ALU, jump flags
│   ├── uart.inc               # Assembly: UART 8N1 bit timing macros & pin aliases
│   ├── i2c.inc                # Assembly: I2C START/STOP, open-drain mask & timing
│   ├── spi.inc                # Assembly: SPI Mode 0/1/2/3 clock timing & pin aliases
│   ├── ws2812.inc             # Assembly: 800 kHz asymmetric NeoPixel pulse constants
│   ├── joybus.inc             # Assembly: N64 / GameCube 250 kbps open-collector macros
│   ├── chiptune.inc           # Assembly: 1-bit Delta-Sigma PDM DAC note frequencies
│   ├── mitm.inc               # Assembly: Glitch trigger & MitM pattern matcher
│   └── omnic/                 # Omni-C Standard C Library Headers (.h)
│       ├── omnibus.h          # C: Core registers, logic levels, GPIO aliases, pragmas
│       ├── uart.h             # C: Full-duplex UART 8N1 initialization & TX/RX
│       ├── i2c.h              # C: Open-drain I2C master with clock stretching
│       ├── spi.h              # C: Mode 0 SPI master with multi-byte streaming
│       ├── ws2812.h           # C: 800 kHz asymmetric NeoPixel RGB driver
│       ├── onewire.h          # C: Dallas 1-Wire reset & bit/byte read/write
│       ├── audio.h            # C: 1-bit Delta-Sigma Audio DAC & Chiptune notes
│       └── mitm.h             # C: Active MitM match/replace & glitch fault injector
├── omnibus/                   # Python Toolchain, Compiler & Host Driver Package
│   ├── compiler/              # Omni-C High-Level Compiler (Lexer, Parser, AST, Codegen)
│   ├── assembler.py           # 16-bit Macro Assembler wrapper (omnibus_asm.py)
│   ├── core.py                # Hardware connection, IMEM flasher, registers
│   ├── streaming.py           # TX/RX FIFO streaming channel driver
│   ├── profiler.py            # Hardware Waveform Profiler & Auto-baud detector
│   ├── fuzzer.py              # Glitch pulse generator & active MitM mutator
│   ├── dma.py                 # Wishbone Scatter-Gather DMA descriptors
│   ├── usb_sie.py             # USB 1.1 Full-Speed SIE controller
│   ├── bist.py                # Autonomous BIST Crossbar & PRBS-7 LFSR
│   ├── dsl.py                 # Declarative Protocol DSL (omnibus-cc)
│   └── cli.py                 # Unified CLI: compile, assemble, load, fuzz, profiler
├── examples/                  # Dual-Track Example Suites
│   ├── asm/                   # Track 1: Assembly Microcode Examples (.asm)
│   │   ├── 01_uart_hello.asm
│   │   ├── 02_i2c_sensor_read.asm
│   │   ├── 03_ws2812_rainbow.asm
│   │   └── 04_mitm_flash_fuzzer.asm
│   ├── c/                     # Track 2: Omni-C High-Level Examples (.c)
│   │   ├── uart_echo.c
│   │   ├── i2c_eeprom.c
│   │   ├── spi_flash.c
│   │   ├── ws2812_rainbow.c
│   │   ├── dht11_sensor.c
│   │   ├── mitm_fuzzer.c
│   │   └── chiptune_player.c
│   ├── 05_python_host_driver.py # Track 3: Python host connect, flash, & streaming
│   └── 06_protocol_dsl.py     # Track 4: Declarative Protocol DSL synthesis
├── tests/                     # Automated Dual-Track Verification Suites
│   ├── test_sdk.py            # Dual-track Assembly and C example regression
│   └── test_omnic.py          # Deep unit & integration tests for Omni-C compiler
├── pyproject.toml             # Python build configuration
└── setup.py                   # pip installation script
```

---

## 2. Installation

Install the Python SDK and command-line utilities in editable development mode:
```bash
pip install -e sdk/
```

---

## 3. Dual-Track Programming Quickstarts

### 3.1. Track 1: Programming in Microcode Assembly (`.asm`)

Write cycle-exact microcode with sidecar delays:

```asm
; File: my_uart.asm
.clock 50MHz
tx_pin = uio[0]

main:
    SET tx_pin, 1 [$BAUD]

loop:
    PULL BLOCK
    SET tx_pin, 0 [$BAUD]      ; Start bit
    OUT tx_pin, 8 [$BAUD]      ; 8 data bits
    SET tx_pin, 1 [$BAUD]      ; Stop bit
    JMP loop
```

Assemble and upload directly to physical hardware:
```bash
python python/omnibus_asm.py my_uart.asm -o my_uart.hex
omnibus load my_uart.asm --port COM3 --baud 115200
```

---

### 3.2. Track 2: Programming in High-Level Omni-C (`.c`)

Write structured protocols with zero-overhead hardware loops and standard library headers:

```c
// File: my_i2c.c
#include <omnibus.h>
#include <i2c.h>

#pragma clock 50MHz
#pragma entry main

void main(void) {
    i2c_init(); // Configure open-drain GPIO 0 (SDA) and GPIO 1 (SCL)

    // Write byte to 24C02 EEPROM at device 0xA0, address 0x05
    i2c_start();
    acc = 0xA0; osr = acc; i2c_write_byte();
    acc = 0x05; osr = acc; i2c_write_byte();
    pull(BLOCK);            i2c_write_byte();
    i2c_stop();

    nop(20); // EEPROM write cycle delay

    // Read byte back
    i2c_start();
    acc = 0xA0; osr = acc; i2c_write_byte();
    acc = 0x05; osr = acc; i2c_write_byte();
    i2c_start();
    acc = 0xA1; osr = acc; i2c_write_byte();
    i2c_read_byte_ack();
    push(BLOCK);
    i2c_stop();
}
```

Compile and assemble to Intel/Verilog hex in a single command:
```bash
# Using turnkey batch script:
omnic my_i2c.c -o my_i2c.asm --hex my_i2c.hex

# Or via Master SDK CLI:
python sdk/omnibus/cli.py compile my_i2c.c -o my_i2c.asm --hex my_i2c.hex
```

> 📖 **Comprehensive C Programming Guide**: See [`documentation/C_PROGRAMMING_GUIDE.md`](file:///c:/Workspace/ASIC/ProtocolEmulator/documentation/C_PROGRAMMING_GUIDE.md) for full language specifications, hardware builtins, register models, and tutorials.

---

### 3.3. Track 3: Python Host Runtime & Streaming (`sdk/omnibus/`)

Connect to physical hardware (Tang Console 60K, Tang Nano 20K, Nano 9K, or taped-out ASIC) from Python:

```python
from omnibus import OmniBus

with OmniBus(port="COM3", baudrate=115200) as bus:
    # 1. Flash microcode into IMEM
    bus.load_microcode("sdk/examples/asm/01_uart_hello.asm")

    # 2. Stream data to TX FIFO and read response
    bus.stream.write("Hello Silicon!\r\n")
    response = bus.stream.read(max_bytes=32)
    print(f"Echoed: {response}")
```

---

### 3.4. Track 4: Declarative Protocol DSL (`omnibus.dsl`)

Synthesize timing-exact assembly from high-level declarative Python protocol specifications:

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

asm_code = SPIMaster.compile()
print(asm_code)
```

---

## 4. Running Verification Tests

Run the dual-track SDK test suite (covering Assembly assembling, C compilation, and DSL synthesis):
```bash
python sdk/tests/test_sdk.py
```

Run the deep Omni-C compiler test suite:
```bash
python -m unittest sdk/tests/test_omnic.py
```

Run the turnkey all-example C demonstration script:
```cmd
cmd.exe /c scripts\run_omnic_demo.bat
```
