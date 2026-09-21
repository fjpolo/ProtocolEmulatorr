# Task 08 — I2C Master in Microcode (Loopback Mode)

## Summary

Implements an I2C Mode 0 Master using only the OmniBus micro-engine — no dedicated
I2C hardware. Extends the pin selector to `SDA` (pin_id=11), adds `OUT SDA` for
open-drain MSB-first byte serialization with automatic SCL toggling, and adds an
`I2CSlaveStub.v` RTL module that auto-ACKs every 9th SCL pulse for internal
loopback testing without any external I2C device.

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

### I2C vs SPI in the OmniBus ISA

| Feature | SPI | I2C |
|:--------|:----|:----|
| Data pin | MOSI (push-pull) | SDA (open-drain, bidirectional) |
| Clock pin | SCK | SCL (reuses `sck_reg`) |
| Framing | CS_n assert/deassert | START / STOP conditions on SDA while SCL high |
| ACK | N/A | Slave pulls SDA low on 9th SCL pulse |
| Byte TX | `OUT SCK, $HBAUD` | `OUT SDA, $HBAUD` |

### ISA Extension — pin_id=11 is now `SDA`

Previously an undocumented MOSI alias; repurposed in Task 08:

| pin_id | Token | Direction | Meaning |
|:------:|:------|:---------:|:--------|
| `00`   | MOSI  | out  | UART TX / SPI MOSI (push-pull) |
| `01`   | SCK / SCL | out | SPI clock / I2C clock (shared `sck_reg`) |
| `10`   | CS    | out  | SPI CS_n |
| `11`   | **SDA** | bidirectional | I2C SDA (open-drain via `sda_oe_reg`) |

#### `SET SDA, val, delay`

| `pin_val` | `sda_oe_reg` | SDA wire state |
|:---------:|:------------:|:--------------|
| `1`       | 0 (release)  | HIGH (pull-up) |
| `0`       | 1 (drive)    | LOW (open-drain) |

#### `WAIT SDA, val, delay`

Polls `i_i2c_sda_in` until it matches `val`. Used for ACK detection:
```asm
WAIT SDA, 0, $HBAUD    ; Wait until slave pulls SDA low (ACK)
```

#### `OUT SDA, $HBAUD` (pin_id=11)

Same two-phase machine as `OUT SCK` — shares `out_sck_phase` and `bit_cnt`:

```
Phase 0 (SCL rising):  sda_oe = ~osr[7]  (0→drive low, 1→release high)
                       SCL = 1, wait eff_delay (slave samples here)
Phase 1 (SCL falling): ISR = {isr[6:0], i_i2c_sda_in}  (sample SDA)
                       SCL = 0, OSR <<= 1, advance bit_cnt
```

### `i2c_write.asm` — 14-instruction I2C frame

```asm
i2c_loop:
    PULL                   ; OSR = i_data (host byte via 'D' command)
    SET SDA, 1, 0          ; SDA idle high
    SET SCL, 1, $HBAUD     ; SCL idle high
    SET SDA, 0, $HBAUD     ; START: SDA↓ while SCL high
    SET SCL, 0, 0          ; SCL low → data phase begins
    OUT SDA, $HBAUD        ; Send 8 bits MSB-first + auto SCL + MISO sample
    SET SDA, 1, 0          ; Release SDA for slave ACK
    SET SCL, 1, $HBAUD     ; SCL high (slave holds SDA low = ACK)
    SET SCL, 0, 0          ; SCL low → end ACK
    SET SDA, 0, 0          ; SDA low (STOP setup)
    SET SCL, 1, $HBAUD     ; SCL high
    SET SDA, 1, $HBAUD     ; STOP: SDA↑ while SCL high
    PUSH                   ; ISR → o_data (ACK bits on LEDs)
    JMP  i2c_loop          ; Next frame
```

22 IMEM slots remain free.

### Open-Drain SDA Loopback (`top.v`)

```
i2c_sda_in = !(core_sda_oe | slave_ack)
```

- `core_sda_oe = 1` → master drives low → `sda_in = 0`
- `slave_ack = 1`  → slave pulls low on ACK bit → `sda_in = 0`
- Both release   → pull-up → `sda_in = 1`

### `I2CSlaveStub.v`

Combinational/sequential auto-ACK slave for loopback:

1. Detects START: SDA 1→0 while SCL high
2. Counts SCL rising edges
3. On every 9th pulse: drives `o_sda_drive = 1` for that SCL cycle (ACK)
4. Detects STOP: SDA 0→1 while SCL high → resets bit counter

No clock-stretching (slave follows master SCL unconditionally).

### I2C Clock Rate via `$HBAUD`

| Target SCL | `--set-baud` arg | Divisor | SCL period |
|:----------:|:----------------:|:-------:|:----------:|
| ~216 kHz   | (default)        | 433     | ~4.6 µs    |
| 400 kHz    | 800000           | 61      | 2.5 µs     |
| 100 kHz    | 200000           | 249     | 10 µs      |

---

## Files

| File | Change |
|:-----|:-------|
| `rtl/ProtocolEmulator.v` | `+o_i2c_scl`, `+o_i2c_sda_oe`, `+i_i2c_sda_in`; `sda_oe_reg`; pin_id=11 in SET/WAIT; `OUT SDA` phase machine |
| `rtl/I2CSlaveStub.v` | **NEW** — auto-ACK I2C slave stub for loopback |
| `boards/sipeed/console60k/src/top.v` | Wire I2C ports; instantiate `I2CSlaveStub`; open-drain `sda_in` logic; PMOD I2C pins |
| `python/omnibus_asm.py` | `PIN_NAMES` += `SDA=3`, `SCL=1` alias; `OUT SDA` token detection |
| `examples/i2c_write.asm` | 14-instruction I2C master write loop |
| `run_i2c_loopback.bat` | Load + optional byte + optional I2C Hz |

---

## Verification

- **Cocotb/Icarus**: 13/13 PASS
  - `test_i2c_write_byte` (Task 08): programs `i2c_write.asm`, drives `i_data=0xA0`,
    testbench acts as I2C slave (drives `i_i2c_sda_in=0` on ACK bits). Verifies:
    - START condition (SDA_OE 0→1 while SCL stays 1) ✓
    - 8 transmitted bits = 0xA0 MSB-first on `o_i2c_sda_oe` ✓
    - ACK bit sampled into ISR ✓
    - STOP condition (SDA_OE 1→0 while SCL stays 1) ✓
  - All 12 Task 01–07 regression tests pass unchanged

---

## AI Experiment Notes

- **Protocol complexity jump**: I2C required a bidirectional open-drain pin, which
  the push-pull ISA did not previously model. Solved by introducing `sda_oe_reg`
  (output enable, active-high) with inverted pin_val convention (`SET SDA, 1` →
  release, `SET SDA, 0` → drive low) — matches real hardware behaviour.
- **ISA reuse**: `OUT SDA` shares the same `out_sck_phase` / `bit_cnt` registers
  introduced for `OUT SCK` in Task 07B. No additional state registers were needed.
- **pin_id=11 repurposed**: Previously an undocumented MOSI alias; now carries the
  `SDA` semantic. Backward-compatible because no existing microcode used pin_id=11
  as anything other than a harmless MOSI duplicate.
- **Clock sharing**: SCL reuses `sck_reg` (exposed as both `o_spi_sck` and
  `o_i2c_scl`). Since SPI and I2C programs are mutually exclusive, no conflict arises.
