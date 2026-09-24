# Task 13: Hardware CRC Generator & Checksum Accelerator

## 1. Executive Summary

In high-speed and deterministic serial communication (Dallas 1-Wire, SMBus/I2C PEC, Modbus RTU, SPI frames, XMODEM), verifying and appending frame checksums is critical for data integrity. Traditional micro-engine architectures either require multicycle software bit-shift loops or dedicated multicycle hardware LFSRs that stall execution for 8 to 16 clock cycles per byte.

**Task 13** equips the OmniBus Protocol Engine with a single-cycle, cycle-deterministic **Hardware CRC Generator & Checksum Accelerator**:
- **Opcode `0xE` (`4'hE`)**: Configures, updates, reads, and resets the CRC accumulator.
- **Opcode `0x8` (`JMP`), Condition Code `3'b111` (`JMP CRC_OK`)**: Hardware zero-overhead conditional branch that takes the target if the CRC accumulator is zero (`crc_reg == 16'h0000`).
- **Parallel Combinatorial XOR Tree Architecture**: Computes the next 8-bit or 16-bit CRC state across all 8 data bits simultaneously in a single clock cycle ($\le 3$ logic levels, delay $< 1$ ns).
- **Four Industry-Standard Polynomials**:
  1. **Dallas / Maxim 1-Wire CRC-8** ($x^8 + x^5 + x^4 + 1$, reflected polynomial `0x8C`, init `0x00`)
  2. **SMBus / I2C PEC CRC-8** ($x^8 + x^2 + x + 1$, normal polynomial `0x07`, init `0x00`)
  3. **CRC-16 CCITT / XMODEM** ($x^{16} + x^{12} + x^5 + 1$, normal polynomial `0x1021`, init `0x0000` or `0xFFFF`)
  4. **CRC-16 Modbus / IBM / USB** ($x^{16} + x^{15} + x^2 + 1$, reflected polynomial `0xA001`, init `0xFFFF`)

---

## 2. Instruction Set Architecture (ISA) Specification

### 2.1 Opcode `0xE` (`CRC`) Bitfield Encoding

All CRC operations execute in a **single clock cycle** (`delay_cnt = 0`).

| [15:12] | [11:9] | [8:7] | [6:5] | [4:0] | Mnemonic | Description |
|---|---|---|---|---|---|---|
| `4'hE` | `3'b000` | `poly[1:0]` | `seed[1:0]` | `5'b00000` | `CRC_INIT poly, seed` | Configure active polynomial and initialize accumulator |
| `4'hE` | `3'b001` | `2'b00` | `2'b00` | `5'b00000` | `CRC_BYTE OSR` | Update CRC accumulator with Output Shift Register (`osr`) |
| `4'hE` | `3'b010` | `2'b00` | `2'b00` | `5'b00000` | `CRC_BYTE ISR` | Update CRC accumulator with Input Shift Register (`isr`) |
| `4'hE` | `3'b011` | `2'b00` | `2'b00` | `5'b00000` | `CRC_BYTE DATA` | Update CRC accumulator with TX FIFO data (`i_data`) |
| `4'hE` | `3'b100` | `2'b00` | `2'b00` | `5'b00000` | `CRC_READ_LOW` | Copy `crc_reg[7:0]` to `osr` and `o_data` |
| `4'hE` | `3'b101` | `2'b00` | `2'b00` | `5'b00000` | `CRC_READ_HIGH` | Copy `crc_reg[15:8]` to `osr` and `o_data` |
| `4'hE` | `3'b110` | `2'b00` | `2'b00` | `5'b00000` | `CRC_RESET` | Reload active configured seed into `crc_reg` |

#### Polynomial Selection (`instr[8:7]`):
- `2'b00`: `DALLAS` (CRC-8 Maxim/Dallas 1-Wire, $x^8 + x^5 + x^4 + 1$, `0x8C`, LSB-first)
- `2'b01`: `SMBUS`  (CRC-8 SMBus/I2C PEC, $x^8 + x^2 + x + 1$, `0x07`, MSB-first)
- `2'b10`: `CCITT`  (CRC-16 CCITT, $x^{16} + x^{12} + x^5 + 1$, `0x1021`, MSB-first)
- `2'b11`: `MODBUS` (CRC-16 Modbus/IBM/USB, $x^{16} + x^{15} + x^2 + 1$, `0xA001`, LSB-first)

#### Seed Selection (`instr[6:5]`):
- `2'b00`: `DEFAULT` / `AUTO` (Modbus defaults to `0xFFFF`; Dallas, SMBus, CCITT default to `0x0000`)
- `2'b01`: `0` / `0x0000`
- `2'b10`, `2'b11`: `0xFFFF`

---

### 2.2 Opcode `0x8` (`JMP`), Condition Code `3'b111` (`JMP CRC_OK`)

Condition code `3'b111` in Opcode `0x8` provides instantaneous zero-overhead packet validation:

```verilog
3'b111: pc <= (crc_reg == 16'h0000) ? target : pc + 5'd1; // JMP CRC_OK, target
```

#### The Zero-Overhead Residue Check Principle
When streaming an incoming packet, each data byte is passed to `CRC_BYTE ISR`. When the final transmitted CRC byte(s) are received and fed into the accelerator, standard CRC mathematics guarantees that the accumulator evaluates to **exactly zero (`0x0000`)** if and only if all data and CRC bits were uncorrupted. 

By following the final byte with `JMP CRC_OK, frame_valid`, OmniBus evaluates packet integrity in a single clock cycle without software subtraction, comparison, or register staging.

---

## 3. Microcode Usage Example

```assembly
    ; Initialize Dallas 1-Wire CRC-8 Accelerator
    CRC_INIT DALLAS, 0
    SET_LC   LC0, 8             ; 8 data bytes

rx_payload:
    IN       1W, 8, 4           ; Read 1 byte into ISR
    CRC_BYTE ISR                ; Single-cycle CRC update
    PUSH                        ; Send byte to host
    DJNZ     LC0, rx_payload

    ; Ingest 9th received CRC byte
    IN       1W, 8, 4
    CRC_BYTE ISR

    ; Zero-overhead branch: residue is 0 if frame is valid
    JMP      CRC_OK, valid_frame

corrupted_frame:
    ; Handle error...

valid_frame:
    ; Process intact packet...
```

---

## 4. Verification & Validation

The Hardware CRC Generator & Checksum Accelerator is verified via two complementary methodologies:
1. **Cocotb Simulation (`testbench.py`)**: 31 comprehensive testcases covering standard test vectors for Dallas 1-Wire, SMBus PEC, CCITT CRC-16, Modbus CRC-16, and zero-residue `JMP CRC_OK` branching.
2. **SymbiYosys Formal Verification (`properties.v`)**: Reset safety, single-cycle execution bounds, branch invariant proofs, and functional cover traces across all modes.
