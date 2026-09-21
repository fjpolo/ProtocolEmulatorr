# Task 02: Dynamic Register Serialization with Output Shift Register (OSR)

> **Specification & Verification Document for Task 02**  
> **Target**: Physical FPGA (Tang Console 60K), Cocotb Simulation, and SymbiYosys Formal Verification  
> **Objective**: Evolve the OmniBus core from a static constant generator into a dynamic protocol transceiver. Add the Output Shift Register (`OSR`), the multi-cycle bit serializer `OUT` (Opcode `0x1`), and the data latch instruction `PULL` (Opcode `0x9`), enabling transmission of arbitrary dynamic byte streams over 115200-baud UART.

---

## 1. Task Objective and Rationale

In **Task 01**, the OmniBus core proved the foundational **zero-jitter sidecar delay execution model** by emitting a hardcoded character (`'U'` = `0x55`) across 12 individual microcode instructions.

Following the Jane Street challenge guidance (*"Start by getting a UART transmitter out of a pin. Then make it programmable."*), **Task 02** establishes the dynamic data path:
1. **Dynamic Data Transmission**: Instead of burning payload bits into ROM words, the core dynamically transmits whatever byte is supplied to `i_data[7:0]`.
2. **First SERDES Component (OSR)**: Introduces the Output Shift Register (`OSR`), the foundational serializer used across all OmniBus serial protocols (UART, SPI, I2C, USB 1.1, CAN).
3. **Microcode Compaction**: Replaces 8 individual single-bit `SET` instructions with a single **`OUT`** instruction, slashing microcode size from 12 instructions down to just **6 instructions**.

---

## 2. Micro-Architecture Specification

### 2.1. Datapath Registers

| Register | Width | Description |
| :--- | :--- | :--- |
| `pc` | 4 bits | Program Counter addressing 16-word microcode ROM |
| `delay_cnt` | 9 bits | Hardware sidecar delay down-counter (0 to 511 clock cycles) |
| `tx_reg` | 1 bit | Registered output state of the physical UART TX pin |
| `osr` | 8 bits | **Output Shift Register**: holds the byte being serialized |
| `bit_cnt` | 4 bits | **Serialization Counter**: tracks remaining bits in active `OUT` instruction |

---

### 2.2. Opcode Table

| Opcode | Mnemonic | Syntax | Description | Cycle Duration |
| :--- | :--- | :--- | :--- | :--- |
| `0x0` | **NOP** | `NOP [delay]` | Pauses execution for `delay` cycles | $1 + \text{delay}$ |
| `0x1` | **OUT** | `OUT pin, count [delay]` | Serializes `count` bits from `osr` to `pin` @ `delay` cycles/bit | $\text{count} \times (1 + \text{delay})$ |
| `0x3` | **SET** | `SET pin, val [delay]` | Drives `pin` to immediate `val` for `delay` cycles | $1 + \text{delay}$ |
| `0x8` | **JMP** | `JMP target` | Unconditional jump to address `target` | $1$ |
| `0x9` | **PULL** | `PULL` | Latches `i_data[7:0]` into `osr` | $1$ |

---

### 2.3. Instruction Word Encoding (16-Bit)

#### `OUT` Instruction (Opcode `0x1`)
```
[15:12] (4 bits) : Opcode 0x1 (OUT)
[11:10] (2 bits) : Pin Index (0 = TX pin)
[9]     (1 bit)  : Shift Direction (0 = LSB first, 1 = MSB first)
[8:0]   (9 bits) : Sidecar Delay per bit (433 = 115200 baud @ 50 MHz)
```

#### `PULL` Instruction (Opcode `0x9`)
```
[15:12] (4 bits) : Opcode 0x9 (PULL)
[11:0]  (12 bits): Reserved (0x000)
```

---

### 2.4. Serialization FSM and Timing: `OUT` Instruction

When `rom[pc]` decodes an `OUT` instruction:
1. **Initiation**: `tx_reg` is driven with `osr[0]` (LSB), `bit_cnt` is initialized to `4'd8`, and `delay_cnt` is loaded with `delay` (433).
2. **Holding Phase**: For 433 clock cycles, `delay_cnt` decrements while `tx_reg` remains frozen on `osr[0]`.
3. **Shift Phase**: When `delay_cnt == 0`:
   - `osr` is shifted right by 1: `osr <= {1'b0, osr[7:1]}`.
   - `tx_reg` is updated with the new `osr[1]`.
   - `bit_cnt` decrements: `bit_cnt <= bit_cnt - 1`.
   - `delay_cnt` is reloaded with `delay`.
4. **Completion**: When `bit_cnt == 0`, the `OUT` instruction finishes and `pc <= pc + 1`.

Total bit duration for every single bit:
$$\text{Bit Duration} = 1 \text{ (shift cycle)} + 433 \text{ (delay cycles)} = 434 \text{ clock cycles} \equiv 8.6805\,\mu\text{s}$$
$$\text{Total 8-bit Payload Duration} = 8 \times 434 = 3472 \text{ clock cycles} \equiv 69.44\,\mu\text{s}$$

---

## 3. Microcode Specification

With `PULL` and `OUT`, the microcode program is reduced from 12 instructions to just **6 instructions**:

| Address | Hex Word | Instruction Equivalent | Function | Duration |
| :--- | :--- | :--- | :--- | :--- |
| `0x0` | `16'h9000` | `PULL` | Latch `i_data[7:0]` into `osr` | 1 cycle |
| `0x1` | `16'h31B1` | `SET tx=0 [433]` | Transmit Start Bit (logic 0) | 434 cycles |
| `0x2` | `16'h11B1` | `OUT tx, 8 [433]` | Serializes 8 data bits dynamically from `osr` | 3472 cycles |
| `0x3` | `16'h33B1` | `SET tx=1 [433]` | Transmit Stop Bit (logic 1) | 434 cycles |
| `0x4` | `16'h01B1` | `NOP [433]` | Inter-character idle pause | 434 cycles |
| `0x5` | `16'h8000` | `JMP 0x0` | Loop to fetch next byte and repeat | 1 cycle |

**Total Frame Interval**: $1 + 434 + 3472 + 434 + 434 + 1 = 4776$ clock cycles ($95.52\,\mu\text{s}$).

---

## 4. Hardware Implementation Details

### 4.1. Core RTL: `rtl/ProtocolEmulator.v`
* Implements `osr` and `bit_cnt`.
* Modifies execution loop:
  - Supports multi-cycle `OUT` holding state until `bit_cnt == 0`.
  - Supports `PULL` single-cycle data latching from `i_data`.
* Telemetry & Status Outputs (`o_data`):
  - `o_data[0]`: UART TX line.
  - `o_data[4:1]`: Current `pc`.
  - `o_data[7]`: `tx_busy` (asserted while frame is being transmitted).

---

## 5. Verification Plan

### 5.1. Cocotb Simulation Testbench
1. **Dynamic Byte Testing**:
   - Transmit arbitrary bytes: `0xAA`, `0x55`, `0x00`, `0xFF`, `0x12`, `0x89`.
   - Verify that received 8N1 frames match the exact bytes driven on `i_data`.
2. **String Stream Validation**:
   - Stream ASCII strings (e.g. `"Hello, OmniBus!\n"`) across back-to-back frames.
   - Decode and assert that reconstructed string matches byte-for-byte.
3. **Zero-Jitter Timing Verification**:
   - Verify every bit produced by `OUT` measures exactly 434 clock cycles (0 cycle jitter).

### 5.2. SymbiYosys Formal Verification
1. **`PULL` Contract**: Formally prove that `osr` accurately latches `i_data`.
2. **`OUT` Shift Invariant**: Formally prove that during `OUT`, bits are shifted strictly LSB-first without corruption or glitching.
3. **Freezing Invariant**: Formally prove that during `OUT` sidecar countdown, `tx_reg` is completely stable.
4. **k-Induction Proof**: Prove bounded and unbounded temporal induction across all instruction sequences.

### 5.3. Physical Hardware Validation
* Compile and program to Tang Console 60K.
* Connect USB serial monitor at 115200 baud.
* Observe streaming characters and verify error-free reception.
