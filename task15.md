# Task 15: 8-bit Micro-ALU & Arithmetic Engine (Opcode 0xB)

## 1. Overview & Motivation

While OmniBus excels at cycle-deterministic serialization, bitwise manipulation, hardware looping (`DJNZ`), and multi-polynomial CRC checksumming, real-world protocol engines frequently require autonomous mathematical manipulation and decision-making on payload fields, such as:
- Parsing variable-length packet headers (e.g. reading payload length $N$ and computing $LC0 = N - 1$).
- Sequence number checking and packet acknowledgment.
- Field masking and bitfield unpacking (e.g. protocol command extraction via `AND`).
- Message authentication code and magic header validation via `CMP`.

**Task 15** introduces a dedicated **8-bit Micro-ALU & Arithmetic Engine** occupying Opcode `0xB`, complete with an 8-bit Accumulator (`acc`), condition flags (`zero_flag`, `carry_flag`), extended `JMP` conditions (0x8..0xE), assembler syntax support, formal verification proofs, and Cocotb simulation tests.

---

## 2. Architecture & Register Specifications

### Accumulator & Flag Registers
- **Accumulator (`acc`)**: 8-bit general-purpose arithmetic register. Reset to `8'h00` on hardware reset and programming mode.
- **Zero Flag (`zero_flag`)**: Set to `1` whenever an ALU operation evaluates to `8'h00` (or `CMP` detects equality).
- **Carry Flag (`carry_flag`)**:
  - In `ADD`: Set to `1` on arithmetic unsigned overflow ($> 255$).
  - In `SUB` / `CMP`: Set to `1` on unsigned borrow ($A < B$, unsigned less than).
  - In `SHL`: Receives former bit 7.
  - In `SHR`: Receives former bit 0.

---

## 3. 16-Bit Instruction Set Encodings (Opcode `0xB`)

### Format A: Immediate Mode (`instr[11] == 0`)

```
+---------------+-------+---------------+-------------------------------+
| [15:12] (4b)  | [11]  | [10:8] (3b)   | [7:0] (8b)                    |
| 4'hB (ALU)    | 1'b0  | Sub-Opcode    | 8-bit Immediate (imm8)        |
+---------------+-------+---------------+-------------------------------+
```

| Sub-Op `[10:8]` | Mnemonic | RTL Operation | Flags Updated |
| :---: | :--- | :--- | :--- |
| `3'b000` | `ADD acc, imm8` | `{carry_flag, acc} <= acc + imm8` | Zero, Carry |
| `3'b001` | `SUB acc, imm8` | `{carry_flag, acc} <= acc - imm8` | Zero, Carry (Borrow) |
| `3'b010` | `CMP acc, imm8` | Evaluates `acc - imm8` (`acc` unchanged) | Zero, Carry (Borrow) |
| `3'b011` | `AND acc, imm8` | `acc <= acc & imm8` | Zero, Carry=0 |
| `3'b100` | `OR  acc, imm8` | `acc <= acc \| imm8` | Zero, Carry=0 |
| `3'b101` | `XOR acc, imm8` | `acc <= acc ^ imm8` | Zero, Carry=0 |
| `3'b110` | `MOV acc, imm8` | `acc <= imm8` | Zero, Carry=0 |
| `3'b111` | `NOT acc` / `INV` | `acc <= ~acc` | Zero, Carry=0 |

---

### Format B: Register Transfer & Register-ALU Mode (`instr[11] == 1`)

```
+---------------+-------+---------------+---------------+---------------+
| [15:12] (4b)  | [11]  | [10:8] (3b)   | [5:3] (3b)    | [2:0] (3b)    |
| 4'hB (ALU)    | 1'b1  | Sub-Opcode    | Dst / Sub-sel | Src Register  |
+---------------+-------+---------------+---------------+---------------+
```

#### Register IDs (`src_reg` / `dst_reg`)

| Reg ID `[2:0]` / `[5:3]` | Source Read (`src_reg`) | Destination Write (`dst_reg`) |
| :---: | :--- | :--- |
| `3'b000` | `OSR` (Output Shift Register) | `OSR` |
| `3'b001` | `ISR` (Input Shift Register) | `ISR` |
| `3'b010` | `LC0` (Loop Counter 0) | `LC0` |
| `3'b011` | `LC1` (Loop Counter 1) | `LC1` |
| `3'b100` | `i_data` (Host/FIFO Input) | `o_data` |
| `3'b101` | `acc` | `acc` |
| `3'b110` | `crc_reg[7:0]` (CRC Low) | `crc_seed[7:0]` |
| `3'b111` | `crc_reg[15:8]` (CRC High) | `crc_seed[15:8]` |

#### Operations

| Sub-Op `[10:8]` | Sub-Selector `[5:3]` | Mnemonic | Description |
| :---: | :---: | :--- | :--- |
| `3'b000` | `3'b000` | `MOV acc, reg` | Loads `acc` from source register (OSR, ISR, LC0, LC1, DATA, CRC) |
| `3'b001` | `dst_reg` | `MOV reg, acc` | Stores `acc` into destination register (`LC0`, `LC1`, `OSR`, `o_data`) |
| `3'b010` | `3'b000` | `ADD acc, reg` | `{carry_flag, acc} <= acc + reg` |
| `3'b011` | `3'b000` | `SUB acc, reg` | `{carry_flag, acc} <= acc - reg` |
| `3'b100` | `3'b000` | `CMP acc, reg` | Evaluates `acc - reg` (`acc` unchanged) |
| `3'b101` | `3'b000`<br>`3'b001`<br>`3'b010` | `AND acc, reg`<br>`OR acc, reg`<br>`XOR acc, reg` | Bitwise logic between `acc` and register |
| `3'b110` | `3'b000`<br>`3'b001`<br>`3'b010` | `INC acc`<br>`DEC acc`<br>`CLR acc` | Unary operations on `acc` |
| `3'b111` | `3'b000`<br>`3'b001`<br>`3'b010`<br>`3'b011` | `SHL acc`<br>`SHR acc`<br>`ROL acc`<br>`ROR acc` | Logical shifts and rotates through carry |

---

## 4. Extended Condition Codes for `JMP` (Opcode `0x8`)

The condition field `instr[11:8]` in Opcode `0x8` is expanded to 4 bits:

| Code `[11:8]` | Mnemonic | Condition Tested | Jump Taken When |
| :---: | :--- | :--- | :--- |
| `0x0` | `ALWAYS` | Unconditional | Always |
| `0x1` | `TX_VALID` | Hardware FIFO | `i_tx_valid == 1` |
| `0x2` | `TX_EMPTY` | Hardware FIFO | `i_tx_valid == 0` |
| `0x3` | `RX_FULL` | Hardware FIFO | `i_rx_full == 1` |
| `0x4` | `RX_READY` | Hardware FIFO | `i_rx_full == 0` |
| `0x5` | `PIN_HI` | GPIO Pin | `gpio_in[rx_pin] == 1` |
| `0x6` | `PIN_LO` | GPIO Pin | `gpio_in[rx_pin] == 0` |
| `0x7` | `CRC_OK` | Hardware CRC | `crc_reg == 16'h0000` |
| **`0x8`** | **`ZERO` / `EQ`** | **ALU Zero Flag** | `zero_flag == 1` |
| **`0x9`** | **`NOT_ZERO` / `NE`** | **ALU Zero Flag** | `zero_flag == 0` |
| **`0xA`** | **`CARRY` / `ULT`** | **ALU Carry Flag** | `carry_flag == 1` |
| **`0xB`** | **`NOT_CARRY` / `UGE`**| **ALU Carry Flag** | `carry_flag == 0` |
| **`0xC`** | **`NEG` / `SIGN`** | **ALU Sign Bit** | `acc[7] == 1` |
| **`0xD`** | **`POS`** | **ALU Sign Bit** | `acc[7] == 0` |
| **`0xE`** | **`CRC_ERR`** | **Hardware CRC** | `crc_reg != 16'h0000` |

---

## 5. Microcode Example: Variable-Length Packet Ingestion

```asm
start:
    ; 1. Ingest Magic framing byte
    PULL BLOCK
    MOV acc, OSR
    CMP acc, 0x5A           ; Expected header
    JMP NOT_ZERO, bad_magic

    ; 2. Read length byte N and dynamically configure loop counter
    PULL BLOCK
    MOV acc, OSR
    SUB acc, 1              ; acc <= N - 1
    MOV LC0, acc            ; LC0 <= N - 1

    ; 3. Ingest N payload bytes into hardware CRC accelerator
    CRC_INIT DALLAS, ZERO
loop:
    PULL BLOCK
    CRC_BYTE OSR
    DJNZ LC0, loop

    ; 4. Verify packet residue
    PULL BLOCK
    CRC_BYTE OSR
    JMP CRC_OK, send_ack

send_nak:
    MOV acc, 0x15           ; NAK (0x15)
    MOV OSR, acc
    PUSH
    JMP start

send_ack:
    MOV acc, 0x06           ; ACK (0x06)
    MOV OSR, acc
    PUSH
    JMP start

bad_magic:
    MOV acc, 0xFF           ; Error (0xFF)
    MOV OSR, acc
    PUSH
    JMP start
```

---

## 6. Real FPGA Hardware Testing (Sipeed Tang Console 60K)

Dedicated batch runners are provided to test the 8-bit Micro-ALU on physical FPGA hardware:

- **Interactive Echo & Case Conversion**:
  ```cmd
  run_alu_demo.bat
  # or alias
  run_alu.bat
  ```
  Uploads `examples\alu_interactive.asm` into FPGA IMEM in ~20ms and opens an interactive serial terminal. When characters are typed:
  - Lowercase `'a'..'z'` (0x61..0x7A) are converted in real-time hardware to `'A'..'Z'` via `CMP acc, 0x61` / `CMP acc, 0x7B` + `SUB acc, 0x20`.
  - Non-lowercase characters, numbers, and symbols are echoed as-is.

- **Autonomous Micro-ALU Self-Test**:
  ```cmd
  run_alu_demo.bat selftest
  ```
  Loads `examples\alu_selftest.asm` into IMEM and opens a monitor terminal. The FPGA continuously exercises:
  - Immediate addition (`ADD acc, imm8`)
  - Immediate subtraction (`SUB acc, imm8`)
  - Bitwise masking (`AND acc, imm8`)
  - Unary increment (`INC`) and logical shift (`SHL`)
  - Comparison (`CMP acc, imm8`) and zero-flag branching (`JMP NOT_ZERO`)
  - Continuously streams `OK\n` over UART @ 115200 baud on success (or `E\n` on error).

- **Board Bitstream Programming**:
  ```cmd
  run_alu_demo.bat flash    # Program SRAM via Gowin Programmer
  run_alu_demo.bat build    # Full Gowin synthesis & place-and-route
  ```
