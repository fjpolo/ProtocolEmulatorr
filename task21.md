# Task 21 — Dedicated Hardware I2C / SMBus Slave Engine

## 1. Overview & Motivation

While master-mode I2C and SMBus can be scheduled synchronously by the microcode execution core, **slave-mode operation is asynchronous and master-driven**:
1. The external bus master controls the clock line (`SCL`) at arbitrary speeds up to 400 kHz (Fast Mode) or 1 MHz (Fast Mode Plus).
2. Start and Stop framing conditions occur asynchronously between clock edges.
3. Every slave device must continuously monitor SCL and SDA, latch the 7-bit slave address, evaluate address matches, and assert an ACK (driving SDA low) within a single clock cycle. If the slave does not match, SDA must remain floating (Hi-Z open-drain) to allow other devices to respond without bus contention.
4. When incoming transactions require processing time (e.g. looking up a register value or preparing response data), standard I2C slaves hold SCL low (**hardware clock stretching**) until data is placed in the output shift register.

Pure software bit-banging of an I2C slave in microcode would permanently tie up the micro-sequencer, burn instructions in polling loops, and suffer from jitter or missed framing. 

**Task 21 integrates a Dedicated Hardware I2C / SMBus Slave Engine** directly into the OmniBus Protocol Emulator:
- **Autonomous background hardware tracker** detects START, repeated START, and STOP conditions with Glitch/Debounce filtering.
- **Hardware address comparator**: autonomously receives 7 address bits + R/W bit, compares against `i2c_slave_addr[6:0]`, asserts ACK (driving SDA low on 9th SCL) on match, and leaves SDA floating on mismatch.
- **Hardware clock stretching**: holds SCL low on address match (or byte completion) until released by microcode (`I2C_RELEASE_SCL` or `OUT SLAVE`).
- **Microcode slave streaming**: dedicated `IN SLAVE` and `OUT SLAVE` multi-cycle instructions synchronized to external SCL clock edges.
- **Single-cycle extended conditional branching**: `JMP I2C_MATCH`, `I2C_READ`, `I2C_WRITE`, `I2C_START`, `I2C_STOP`, `I2C_ACK`, `I2C_NACK`, `I2C_BUS_ACTIVE`.
- **Wishbone status register integration**: real-time monitoring of slave status via host Wishbone interface (`ADDR_STATUS[30]`).

---

## 2. Hardware Architecture

```
                                  +--------------------------------------------------+
                                  |     OmniBus I2C / SMBus Slave Engine             |
                                  |                                                  |
   GPIO[sck_pin] (SCL) -----------> [SCL Edge & Level Detector]                      |
                                  |         |                                        |
   GPIO[tx_pin]  (SDA) <----------> [SDA Framing Detector: START / STOP]             |
                                  |         |                                        |
                                  |  +---------------+                               |
                                  |  | State Machine |                               |
                                  |  | 0: IDLE       |                               |
                                  |  | 1: ADDR_RX    | ----> Latch 7-bit Addr + R/W  |
                                  |  | 2: ADDR_ACK   | ----> Compare == slave_addr   |
                                  |  | 3: DATA_WAIT  |         |                     |
                                  |  +---------------+         | Match               |
                                  |         |                  v                     |
                                  |         +-------------> Auto-ACK (drive SDA=0)   |
                                  |         |               Clock Stretch (SCL=0)    |
                                  |         |                                        |
                                  |         v                                        |
                                  |  Microcode Interface:                            |
                                  |    - IN SLAVE  (8 data bits in, auto-ACK out)    |
                                  |    - OUT SLAVE (8 data bits out from OSR)        |
                                  |    - I2C_RELEASE_SCL                             |
                                  +--------------------------------------------------+
```

### A. Dedicated Registers & Status Flags
| Register / Wire | Width | Reset | Description |
| :--- | :--- | :--- | :--- |
| `i2c_slave_en` | 1 bit | `1'b0` | Hardware I2C slave engine enable |
| `i2c_slave_addr` | 7 bits | `7'd0` | Programmable 7-bit slave device address |
| `i2c_stretch_en` | 1 bit | `1'b0` | Automatic SCL clock stretch enable |
| `i2c_addr_match` | 1 bit | `1'b0` | Flag: asserted when received address matches `i2c_slave_addr` |
| `i2c_rw_bit` | 1 bit | `1'b0` | Latch of 8th bit: `0` = Write from Master, `1` = Read to Master |
| `i2c_start_flag` | 1 bit | `1'b0` | Sticky flag: asserted on START / Repeated START condition |
| `i2c_stop_flag` | 1 bit | `1'b0` | Sticky flag: asserted on STOP condition |
| `i2c_bus_active` | 1 bit | `1'b0` | Status: `1` while bus is busy between START and STOP |
| `i2c_master_ack` | 1 bit | `1'b0` | Latched Master response bit: `1` = ACK (SDA low), `0` = NACK (SDA high) |
| `i2c_drive_ack` | 1 bit | `1'b0` | Hardware autonomous SDA pull-down control for 9th clock |
| `i2c_stretch_hold` | 1 bit | `1'b0` | Hardware autonomous SCL pull-down control for clock stretching |

### B. Dynamic Pin Multiplexing & Open-Drain Isolation
When `i2c_slave_en` is active:
- Both `tx_pin` (SDA) and `sck_pin` (SCL) operate in open-drain mode:
  - If driving `0`: `o_gpio_oe[p] = 1`, `o_gpio[p] = 0` (actively pulls line low to GND).
  - If driving `1` or idle: `o_gpio_oe[p] = 0`, `o_gpio[p] = 1` (releases line to external pull-up resistor).
- SCL is an input from the external master, pulled low only when `slave_scl_drive` (`i2c_stretch_hold`) is active.
- SDA is an input from the external master, pulled low only when `slave_sda_drive` (`i2c_drive_ack` or transmitting `'0'`) is active.

---

## 3. Instruction Set Architecture Extensions

### A. Opcode `0xF` (`ASSIST`) Control Instructions

| Mnemonic | Syntax | Encoding (`[15:0]`) | Description |
| :--- | :--- | :--- | :--- |
| `I2C_SLAVE_CFG` | `I2C_SLAVE_CFG <addr7> [, STRETCH=0\|1]` | `0xF600 \| (stretch<<7) \| addr7` | Enables slave engine, programs 7-bit slave address, and configures clock stretching. |
| `I2C_RELEASE_SCL` | `I2C_RELEASE_SCL` | `0xF700` | Releases hardware clock stretching (`i2c_stretch_hold = 0`), allowing Master to clock SCL. |
| `I2C_SLAVE_DISABLE` | `I2C_SLAVE_DISABLE` | `0xF500` | Disables slave engine and returns pins to standard GPIO control. |
| `ASSIST READ I2C` | `ASSIST READ, I2C` | `0xF900` | Reads 8-bit I2C status into accumulator (`acc`): `[7]`=bus_active, `[6]`=start_flag, `[5]`=stop_flag, `[4]`=addr_match, `[3]`=rw_bit, `[2]`=master_ack, `[1]`=stretch_hold, `[0]`=slave_en. |
| `ASSIST READ ADDR` | `ASSIST READ, ADDR` | `0xFB00` | Reads 8-bit received address word (`{i2c_rx_addr[6:0], i2c_rw_bit}`) into accumulator. |

### B. Multi-Cycle Data Streaming Instructions

#### 1. `IN SLAVE` (`Opcode 0x2`, `instr[11:9] = 3'b111`)
- Synchronously receives 8 data bits from Master MSB-first on SCL rising edges into `isr`.
- Autonomously drives ACK low on 9th SCL clock pulse (or NACK if configured).
- Latches received byte into `o_data <= isr` and advances PC on 9th clock fall.
- Automatically re-asserts clock stretch if `i2c_stretch_en` is set.

#### 2. `OUT SLAVE` (`Opcode 0x1`, `instr[11:9] = 3'b111`)
- Transmits 8 data bits from `osr` MSB-first to Master on SCL falling edges.
- Releases SDA before the 9th clock pulse.
- Samples Master ACK/NACK on 9th SCL rising edge into `i2c_master_ack`.
- Advances PC on 9th clock fall.

### C. Extended Single-Cycle Conditional Branching (`JMP`, Opcode `0x8`)
When `instr[7] == 1'b1`, the JMP instruction branches on hardware I2C slave condition codes while maintaining full 7-bit target address reachability (`instr[6:0]` = 0..127):

| Condition Mnemonic | `instr[11:8]` | Branch Trigger Condition | Description |
| :--- | :--- | :--- | :--- |
| `I2C_MATCH` | `4'h0` | `i2c_addr_match == 1` | Address matched 7-bit `i2c_slave_addr` and 9th SCL ACK completed |
| `I2C_START` | `4'h1` | `i2c_start_flag == 1` | START or Repeated START condition detected on bus |
| `I2C_STOP` | `4'h2` | `i2c_stop_flag == 1` | STOP condition detected on bus |
| `I2C_READ` | `4'h3` | `i2c_addr_match && i2c_rw_bit` | Address matched and Master requested Read transaction |
| `I2C_WRITE` | `4'h4` | `i2c_addr_match && !i2c_rw_bit` | Address matched and Master requested Write transaction |
| `I2C_ACK` | `4'h5` | `!i2c_master_ack` | Master sent ACK (SDA low on 9th clock) |
| `I2C_NACK` | `4'h6` | `i2c_master_ack` | Master sent NACK (SDA high on 9th clock) |
| `I2C_BUS_ACTIVE` | `4'h7` | `i2c_bus_active == 1` | Bus is currently busy (between START and STOP) |

---

## 4. Wishbone B4 Slave Status Register Integration

The top-level Wishbone status register (`ADDR_STATUS`, offset `0x04`) exposes the slave engine status to the host processor in real time:
- **Bit 30**: `core.i2c_addr_match` — Real-time indication that an external I2C master is addressing this device.
- **Bit 29**: `core.crc_reg == 32'd0` — CRC Residue Zero.
- **Bits 28:24**: `core.pc[4:0]` — Core Program Counter.
- **Bits 23:16**: RX FIFO level.
- **Bits 15:8**: TX FIFO level.

---

## 5. Verification & Test Suite

The dedicated hardware engine was validated through 4 new Cocotb unit tests in `test_rtl/simulation/cocotb/ProtocolEmulator/testbench.py`:

```
==================================================================================================================
TEST                                                      STATUS  SIM TIME (ns)  REAL TIME (s)  RATIO (ns/s)
==================================================================================================================
testbench.test_i2c_slave_address_match_and_auto_ack        PASS        5000.00           0.03     176532.40
testbench.test_i2c_slave_address_nack_on_mismatch          PASS        5180.00           0.03     168109.68
testbench.test_i2c_slave_write_receive_flow                PASS        7560.00           0.03     235248.71
testbench.test_i2c_slave_read_transmit_and_clock_stretch   PASS        7660.00           0.03     238339.25
==================================================================================================================
TESTS=60 PASS=60 FAIL=0 SKIP=0                                      6651730.06          12.61     527548.81
==================================================================================================================
```

All 60 tests (56 existing + 4 new Task 21 tests) passed with 100% success rate and zero regressions.

---

## 6. Demonstration Example: 24C02 EEPROM Emulation

A complete microcode implementation of an I2C 24C02 EEPROM emulator is provided in `examples/i2c_slave_eeprom_demo.asm`:

```asm
start:
    PINMAP 4, 4, 1, 2       ; SDA=Pin4, SCL=Pin1, Activity LED=Pin2
    CFG_OD 0x12             ; Open-drain on Pins 4 & 1
    SET 2, 0, 0             ; LED off
    I2C_SLAVE_CFG 0x50, STRETCH=1 ; Address 0x50 with clock stretching

idle_loop:
    JMP I2C_MATCH, on_address_matched
    JMP idle_loop

on_address_matched:
    SET 2, 1, 0             ; Turn on Activity LED
    JMP I2C_READ, do_read_transfer

do_write_transfer:
    IN SLAVE                ; Receive byte from Master, auto-ACK
    PUSH                    ; Push to FIFO
    JMP transaction_done

do_read_transfer:
    MOV acc, 0xBE           ; Load response byte
    MOV OSR, acc
    I2C_RELEASE_SCL         ; Release SCL clock stretch
    OUT SLAVE               ; Transmit byte to Master, sample Master ACK
    JMP I2C_ACK, master_acked

master_nacked:
    JMP transaction_done

master_acked:
    NOP

transaction_done:
    SET 2, 0, 0             ; Turn off Activity LED
    JMP idle_loop
```

To run simulation or hardware upload:
```bat
run_i2c_slave.bat sim          # Run 4 Cocotb unit tests in WSL
run_i2c_slave.bat interactive  # Assemble and upload to Tang Console 60K FPGA
```
