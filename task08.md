# Task 08 — I2C Master in Microcode (Loopback Mode)

## Summary

Implements an I2C Mode 0 Master using only the OmniBus micro-engine — no dedicated
I2C hardware. Built on top of the **Unified 8-Bit GPIO Bus (Task 07C)**:
- Uses `CFG_OD` for open-drain SDA/SCL pin control (0 pulls low, 1 releases Hi-Z).
- Uses `PINMAP` to assign any GPIO pins to SDA (`tx_pin` / data) and SCL (`sck_pin` / clock).
- Adds `OUT SDA` (mode=11) for MSB-first byte serialization with automatic SCL toggling and ACK sampling.
- Adds `I2CSlaveStub.v` RTL module that auto-ACKs every 9th SCL pulse for internal loopback testing without any external I2C device.

---

## Quick Start

```bat
REM Load I2C write program and send address byte 0xA0 (device 0x50, write)
run_i2c_loopback.bat 0xA0

REM Send to address 0x68 (MPU-6050)
run_i2c_loopback.bat 0xD0

REM Push different byte without reprogramming
python python\omnibus_loader.py --spi-data 0xD0

REM Slower I2C clock (100 kHz standard mode)
run_i2c_loopback.bat 0xA0 100000
```

---

## Architecture

### I2C vs SPI on the OmniBus GPIO Bus

| Feature | SPI | I2C |
|:--------|:----|:----|
| Data pin | MOSI (push-pull, `tx_pin`) | SDA (open-drain via `CFG_OD`, `tx_pin`) |
| Clock pin | SCK (push-pull, `sck_pin`) | SCL (open-drain via `CFG_OD`, `sck_pin`) |
| Framing | CS_n assert/deassert | START / STOP conditions on SDA while SCL high |
| ACK | N/A | Slave pulls SDA low on 9th SCL pulse |
| Byte TX | `OUT SCK, $HBAUD` | `OUT SDA, $HBAUD` |

### Pin Configuration via `PINMAP` & `CFG_OD`

At the start of the I2C routine, microcode configures the bus:
```asm
; Configure SDA on Pin 4, SCL on Pin 1 (or any pins 0..7)
PINMAP TX=4, RX=4, SCK=1, CS=2
; Enable open-drain on Pin 4 (SDA) and Pin 1 (SCL): mask = 0x12 (bits 4 and 1)
CFG_OD 0x12
```

#### `SET pin, val, delay` in Open-Drain Mode
When a pin is marked open-drain in `CFG_OD`:
- `val = 0`: Drives LOW actively (`out=0, oe=1`).
- `val = 1`: Releases to Hi-Z (`out=1, oe=0`), external or on-chip pull-up pulls line HIGH.

#### `WAIT SDA, val, delay`
Monitors the SDA input line until it matches `val`. Used for ACK detection:
```asm
WAIT 4, 0, $HBAUD    ; Wait until slave pulls SDA low (ACK)
```

#### `OUT SDA, $HBAUD` (mode=11)
Two-phase serialization machine sharing `out_sck_phase` and `bit_cnt`:
```
Phase 0 (SCL rising):  drive SDA = osr[7] (via open-drain)
                       raise SCL = 1, wait eff_delay (slave samples here)
Phase 1 (SCL falling): sample SDA into ISR = {isr[6:0], gpio_in[rx_pin]}
                       lower SCL = 0, OSR <<= 1, advance bit_cnt
```

### `i2c_write.asm` — 14-instruction I2C frame

```asm
start:
    PINMAP 4, 4, 1, 2      ; SDA=Pin 4, SCL=Pin 1
    CFG_OD 0x12            ; Open-drain on Pins 4 & 1

i2c_loop:
    PULL                   ; OSR = i_data (host byte via 'D' command)
    SET SDA, 1, 0          ; SDA idle high
    SET SCL, 1, $HBAUD     ; SCL idle high
    SET SDA, 0, $HBAUD     ; START: SDA↓ while SCL high
    SET SCL, 0, 0          ; SCL low → data phase begins
    OUT SDA, $HBAUD        ; Send 8 bits MSB-first + auto SCL + sample
    SET SDA, 1, 0          ; Release SDA for slave ACK
    SET SCL, 1, $HBAUD     ; SCL high (slave holds SDA low = ACK)
    SET SCL, 0, 0          ; SCL low → end ACK
    SET SDA, 0, 0          ; SDA low (STOP setup)
    SET SCL, 1, $HBAUD     ; SCL high
    SET SDA, 1, $HBAUD     ; STOP: SDA↑ while SCL high
    PUSH                   ; ISR → o_data (ACK bits on LEDs)
    JMP  i2c_loop          ; Next frame
```

### `I2CSlaveStub.v` (Loopback Testing)

Combinational/sequential auto-ACK slave for loopback:
1. Detects START: SDA 1→0 while SCL high
2. Counts SCL rising edges
3. On every 9th pulse: drives `o_sda_drive = 1` for that SCL cycle (ACK)
4. Detects STOP: SDA 0→1 while SCL high → resets bit counter

---

## Files

| File | Change |
|:-----|:-------|
| `rtl/ProtocolEmulator.v` | Add `OUT SDA` mode (mode=11) in OUT serializer |
| `rtl/I2CSlaveStub.v` | **NEW** — auto-ACK I2C slave stub for loopback |
| `boards/sipeed/console60k/src/top.v` | Instantiate `I2CSlaveStub` on GPIO I2C pins for loopback testing |
| `python/omnibus_asm.py` | `OUT SDA` token handling (already prepared in Task 07C) |
| `examples/i2c_write.asm` | I2C master write loop |
| `run_i2c_loopback.bat` | Load + optional byte + optional I2C Hz |
