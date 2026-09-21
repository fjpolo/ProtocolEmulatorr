# Task 07 — SPI Mode 0 Master in Microcode + Variable Byte Transmission

## Summary

Implements a complete SPI Mode 0 master using only the OmniBus micro-engine — no
dedicated SPI hardware. Two sub-tasks:

- **Task 07**: ISA pin-selector extension (`[11:10]`) and variable-bit `IN`; new
  `o_spi_sck`/`o_spi_cs_n` ports; `spi_loopback.asm` demonstrates bit-banged SPI
  with internal MISO loopback.
- **Task 07B**: `OUT SCK` auto-toggle instruction (pin_id=01) for MSB-first SPI
  serialization + OmniBootloader `'D'` command that pushes any host byte into
  `ProtocolEmulator.i_data` for `PULL`-based programs.

---

## Quick Start

```bat
REM Load hardcoded 0xA5 SPI loopback demo
run_spi_loopback.bat

REM Load generic SPI program and send 0xA5
run_spi_generic.bat 0xA5

REM Send different byte without reprogramming
python python\omnibus_loader.py --spi-data 0x3C

REM 5 MHz SPI clock
run_spi_generic.bat 0xFF 5000000
```

---

## Architecture

### ISA Extensions

#### Pin Selector `instr[11:10]` (SET / WAIT / OUT)

| pin_id | Token  | Output                       | Reset  |
|:------:|:-------|:-----------------------------|:------:|
| `00`   | MOSI   | `o_tx` (UART TX / SPI MOSI)  | high   |
| `01`   | SCK    | `o_spi_sck` (SPI clock)      | low    |
| `10`   | CS     | `o_spi_cs_n` (active-low)    | high   |
| `11`   | —      | MOSI alias (Task 07)         | —      |

#### Variable-Bit `IN` — `instr[11:9]`

| `instr[11:9]` | Bits sampled  |
|:-------------:|:-------------|
| `000`         | 8 (backward compat) |
| `001`–`111`   | N bits (1–7) |

#### `OUT SCK` (Task 07B) — `instr[11:10] = 01`

MSB-first full-duplex serializer with automatic SCK toggle:

```
Phase 0 (SCK rising):  MOSI = osr[7], SCK = 1, wait eff_delay
Phase 1 (SCK falling): ISR = {isr[6:0], rx_in}, SCK = 0, OSR <<= 1
                        Advance bit_cnt (0→7→6→…→1→done)
```

- **Root cause note**: `i_data` must be driven **before** the core starts executing
  (before `i_prog_en` releases) because `PULL` fires on the very first clock cycle
  after reset. Test fixture sets `i_data` prior to `load_program_direct`.

### OmniBootloader `'D'` Command

```
Host → FPGA:  [0x44 'D'] [data_byte]
FPGA → Host:  [0x06 ACK] [data_byte]   (echo-verify)
```

The byte is latched into `spi_data_reg` → exposed as `o_data_reg[7:0]` → wired to
`ProtocolEmulator.i_data`. When microcode executes `PULL`, `OSR = spi_data_reg`.

### `spi_generic.asm` — 6-instruction SPI loop

```asm
spi_loop:
    PULL                ; OSR = i_data  (host byte via 'D' command)
    SET  CS, 0, 0       ; Assert CS_n
    OUT  SCK, $HBAUD    ; 8-bit MSB-first: MOSI + auto-SCK + MISO → ISR
    SET  CS, 1, 0       ; Deassert CS_n
    PUSH                ; ISR → o_data  (LEDs show received byte)
    JMP  spi_loop
```

### MISO Sampling Timing

- **MISO is sampled at SCK falling edge (phase 1)**, after `eff_delay` hold cycles.
- With loopback (`MISO = MOSI`), `rx_in` is stable through the 2-stage synchronizer
  + loopback lag (3 cycle total) before sampling at phase 1.
- Minimum safe `eff_delay`: 3 clock cycles → minimum `i_baud_div` = 5 for SPI.

---

## Files

| File | Change |
|:-----|:-------|
| `rtl/ProtocolEmulator.v` | `+o_spi_sck`, `+o_spi_cs_n`; pin selector in SET/WAIT; `OUT SCK` phase machine; `out_sck_phase` register |
| `rtl/OmniBootloader.v` | `+spi_data_reg`; `+o_data_reg[7:0]`; `'D'` command FSM state `CMD_D_BYTE` |
| `boards/sipeed/console60k/src/top.v` | SPI PMOD pins; MISO loopback `spi_miso_in = core_tx`; wire `o_data_reg → i_data` |
| `python/omnibus_asm.py` | PIN_NAMES `SCK=1`, `CS=2`; 3-arg SET/WAIT; variable-bit IN; `OUT SCK` token detection |
| `python/omnibus_loader.py` | `set_spi_data()`; `--spi-data HEX` flag |
| `examples/spi_loopback.asm` | 24-instruction bit-bang SPI (hardcoded 0xA5) |
| `examples/spi_generic.asm` | 6-instruction PULL+OUT SCK+PUSH loop |
| `run_spi_loopback.bat` | Load spi_loopback; optional `--set-baud` |
| `run_spi_generic.bat` | Load spi_generic; optional byte + SPI Hz |

---

## Verification

- **Cocotb/Icarus**: 12/12 PASS
  - `test_spi_loopback` (Task 07): bit-bang SPI, verifies `o_spi_sck` toggle + `o_spi_cs_n` assert/deassert
  - `test_out_sck_generic` (Task 07B): programs `spi_generic.asm`, drives `i_data=0xC3`, MISO loopback, verifies `o_data=0xC3` in 2180 ns
  - All 10 Task 01–06 regression tests pass unchanged

---

## AI Experiment Notes

- **Iterative ISA design**: pin_id field `[11:10]` was introduced in Task 07 and
  immediately reused for `OUT SCK` in Task 07B, demonstrating forward-compatible ISA
  extension without reserved-bit waste.
- **Timing bug caught**: Initial `OUT SCK` test got `0x80` (only MSB correct). Root
  cause was a race: MISO was sampled at SCK rising edge, but `rx_in` lags `o_tx` by
  3 cycles through synchronizer + loopback. Fixed by moving sample to SCK falling edge.
- **Batch file gotcha**: CMD block parser treats `)` in `echo` strings as block
  terminators. `run_spi_generic.bat` was rewritten with `goto` labels to avoid the
  if/else-if/else parenthesis pitfall.
