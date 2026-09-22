# Task 07C — Unified 8-Bit Bidirectional GPIO Bus & Microcode Pin Indexing

## Summary

Refactors the OmniBus pin architecture from fixed, hardwired protocol ports (`i_rx`, `o_tx`, `o_spi_sck`, `o_spi_cs_n`) to a **Unified 8-bit Bidirectional GPIO Bus (`gpio[7:0]`)** with dynamic microcode role mapping and per-pin open-drain control.

- **Dynamic Role Mapping (`PINMAP`, Opcode `0x5`)**: Allows microcode to dynamically assign any physical GPIO pin (0..7) to protocol roles:
  - `tx_pin`: Used by `OUT` serializer (UART TX / SPI MOSI / I2C SDA).
  - `rx_pin`: Used by `IN` deserializer (UART RX / SPI MISO / I2C SDA in).
  - `sck_pin`: Used by `OUT SCK` / `OUT SCL` for clock generation.
  - `cs_pin`: Used for SPI Chip Select / auxiliary control.
- **Per-Pin Open-Drain Configuration (`CFG_OD`, Opcode `0x6`)**:
  - `1` = Open-drain mode: writing `0` drives low (`oe=1, out=0`); writing `1` releases to high-impedance (`oe=0, out=1`) for external pull-up resistors.
  - `0` = Push-pull mode: writing `0` drives low, writing `1` drives high.
- **8-Pin Direct Control (`SET` / `WAIT`)**:
  - `SET <pin 0..7>, <val>, <delay>`: Drives any individual GPIO pin.
  - `WAIT <pin 0..7>, <val>, <delay>`: Waits for an edge/level on any chosen pin.
- **Backward Compatibility**:
  - Convenience output ports `o_tx`, `o_spi_sck`, `o_spi_cs_n` and legacy `i_rx` input merge remain in `ProtocolEmulator.v`.
  - Roles default at reset to `TX=0, RX=0, SCK=1, CS=2` with all push-pull drivers.

---

## Instruction Set Architecture

### Instruction Formats

| Opcode | Mnemonic | Syntax | Field Encoding | Description |
|:------:|:---------|:-------|:---------------|:------------|
| `0x5` | **PINMAP** | `PINMAP tx, rx, sck, cs` | `[15:12]=5, [11:9]=tx, [8:6]=rx, [5:3]=sck, [2:0]=cs` | Assigns physical pins (0..7) to protocol roles |
| `0x6` | **CFG_OD** | `CFG_OD mask` | `[15:12]=6, [7:0]=mask` | Configures open-drain mask (1=OD, 0=PP) |
| `0x3` | **SET** | `SET pin, val, delay` | `[15:12]=3, [11:9]=pin, [8]=val, [7:0]=delay` | Drives GPIO `pin` (0..7) to `val` |
| `0x4` | **WAIT** | `WAIT pin, val, delay` | `[15:12]=4, [11:9]=pin, [8]=val, [7:0]=delay` | Blocks until `gpio_in[pin] == val` |
| `0x1` | **OUT** | `OUT [mode,] delay` | `[15:12]=1, [11:10]=mode, [8:0]=delay` | Serializes on `tx_pin`, toggles `sck_pin` in mode `01` |
| `0x2` | **IN** | `IN [count,] delay` | `[15:12]=2, [11:9]=count, [8:0]=delay` | Deserializes `count` bits from `rx_pin` into `ISR` |

### Pin Aliases in Assembler

`TX`/`MOSI`=0, `SCK`/`SCL`=1, `CS`/`CS_N`=2, `RX`/`MISO`=3, `SDA`=4, `PIN0`..`PIN7`=0..7.

---

## Examples

### Dynamic Pin Remapping (`examples/gpio_pinmap_demo.asm`)

```asm
; Remap UART roles to alternate PMOD pins:
; TX -> Pin 4, RX -> Pin 5, SCK -> Pin 6, CS -> Pin 7
PINMAP 4, 5, 6, 7

echo_loop:
    WAIT 5, 0, $HBAUD  ; Wait for start bit on GPIO 5
    NOP  $BAUD
    IN   8, $BAUD      ; Deserializes from GPIO 5 (configured rx_pin)
    WAIT 5, 1, 0       ; Stop bit confirmation
    PUSH
    SET  4, 0, $BAUD   ; Start bit on GPIO 4 (configured tx_pin)
    OUT  8, $BAUD      ; Serializes on GPIO 4
    SET  4, 1, $BAUD   ; Stop bit on GPIO 4
    JMP  echo_loop
```

### Open-Drain Operation (`examples/gpio_od_demo.asm`)

```asm
    ; Set Pin 4 as open-drain
    CFG_OD 0x10

od_loop:
    SET 4, 0, $BAUD    ; Actively drives LOW (oe=1, out=0)
    SET 4, 1, $BAUD    ; Releases to float HIGH (oe=0, out=1)
    JMP od_loop
```

---

## Verification

- **Full Gowin EDA FPGA Build Flow**: Synthesis, PnR, Timing Analysis, and Bitstream Generation all pass with 0 errors.
- **Hardware Verified**: Tested live on Sipeed Tang Console 60K via USB-UART bridge at 115200 baud (`run_echo.bat`, `run_echo_configurable.bat`, `run_spi_loopback.bat`).
