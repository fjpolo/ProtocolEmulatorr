# Task 10 — Bidirectional SERDES & Full-Duplex Architecture (`IN SCK`, `IN SDA`)

## Summary

Establishes a unified **Bidirectional SERDES & Full-Duplex Architecture** in the OmniBus microcode engine.

In previous tasks, the hardware serializer (`OUT SCK` and `OUT SDA`) enabled high-performance SPI and I2C transmission, but synchronous reception required either simultaneous `OUT SCK` sampling or manual bit-banging. **Task 10** extends opcode `0x2` (`IN`) with dedicated hardware clock generation and open-drain bus release:
- **`IN SCK, delay`**: Generates 8 SCK clock pulses while deserializing MISO (`rx_pin`) into `ISR` MSB-first.
- **`IN SDA, delay`**: Releases SDA (`tx_pin` Hi-Z open-drain), generates 8 SCL clock pulses, and deserializes slave data into `ISR` MSB-first while SCL is high.
- **Full-Duplex SPI**: Enables simultaneous transmit (`osr[7]` $\rightarrow$ MOSI) and receive (MISO $\rightarrow$ `isr[0]`) in hardware.

---

## Instruction Encoding: Opcode `0x2` (`IN`)

Opcode `0x2` uses bits `[11:10]` to select the deserialization mode, mirroring opcode `0x1` (`OUT`):

```
+---------------+---------------+---------------+-------------------------------+
| [15:12] (4b)  |  [11:10] (2b) |    [9] (1b)   |          [8:0] (9b)           |
| Opcode = 0x2  |   Mode Sel    |  Bit Count    |         Sidecar Delay         |
+---------------+---------------+---------------+-------------------------------+
```

| Mode `[11:10]` | Mnemonic | Description | Physical Actions |
| :---: | :--- | :--- | :--- |
| `2'b00` | `IN [8,] delay` | Asynchronous UART RX | LSB-first shift into `ISR`, samples `rx_pin` |
| `2'b01` | `IN SCK, delay` | Synchronous SPI Master Read | Generates 8 SCK pulses, samples `rx_pin` (MISO) MSB-first into `ISR` |
| `2'b11` | `IN SDA, delay` | Synchronous I2C Master Read | Releases `tx_pin` (SDA Hi-Z), pulses SCL 8 times, samples `rx_pin` MSB-first |

---

## Timing & Phase Sequence

### 1. SPI Master Read (`IN SCK, delay`)
- **Phase 0** (`in_sck_phase = 0`):
  - Drives `sck_pin` HIGH (or releases if open-drain).
  - Waits `eff_delay` cycles.
- **Phase 1** (`in_sck_phase = 1`):
  - Samples `gpio_in[rx_pin]` into `isr <= {isr[6:0], gpio_in[rx_pin]}`.
  - Drives `sck_pin` LOW.
  - Waits `eff_delay` cycles.
  - Decrements 8-bit counter; on 8th bit, advances `pc <= pc + 1`.

### 2. I2C Master Read (`IN SDA, delay`)
- **Setup & Release**:
  - Automatically asserts `gpio_out_reg[tx_pin] <= 1'b1` and `gpio_oe_reg[tx_pin] <= 1'b0` (releases SDA so slave can drive data).
- **Phase 0** (`in_sck_phase = 0`):
  - Releases `sck_pin` (SCL) HIGH.
  - Samples `gpio_in[rx_pin]` (SDA) into `isr <= {isr[6:0], gpio_in[rx_pin]}` while SCL is high.
  - Waits `eff_delay` cycles.
- **Phase 1** (`in_sck_phase = 1`):
  - Drives `sck_pin` (SCL) LOW.
  - Waits `eff_delay` cycles.
  - Decrements 8-bit counter; on 8th bit, advances `pc <= pc + 1`.

---

## Full-Duplex SPI Streaming Example (`spi_full_duplex.asm`)

```asm
; Full-duplex SPI exchange: transmit 0xA5 and receive slave byte simultaneously
start:
    SET     CS, 0, 0        ; Assert CS_n low
    PULL                    ; Load TX byte into OSR (e.g. 0xA5)
    OUT     SCK, $HBAUD     ; Send OSR to MOSI while receiving MISO into ISR!
    SET     CS, 1, 0        ; Deassert CS_n high
    PUSH                    ; Transfer received byte from ISR to RX FIFO
    JMP     start
```

---

## Quick Start & Verification

```bat
REM Run full-duplex SPI demo on Tang Console 60K FPGA
run_spi_full_duplex.bat
```
