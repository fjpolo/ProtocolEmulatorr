# Task 09 — Zero-Overhead Hardware Loop Counters (`LC0`, `LC1`, `DJNZ`)

## Summary

Implements dedicated zero-overhead hardware loop counters (`LC0`, `LC1`) and control instructions in the OmniBus microcode engine, enabling compact multi-byte packet bursts, streaming buffers, and nested loop iterations without IMEM unrolling.

In accordance with [CONCEPT.md §4.1](CONCEPT.md#L156), opcode `0x7` is allocated to hardware loop counter operations.

---

## Instruction Encoding (Opcode `0x7`)

All loop counter operations fit into opcode `0x7` using sub-opcode bit `[10]`:

```
+---------------+---------------+---------------+-------------------------------+
| [15:12] (4b)  |    [11] (1b)  |    [10] (1b)  |  [9:8] (2b)  |  [7:0] (8b)    |
| Opcode = 0x7  |  Counter Sel  |   Operation   |    Sub-Op    |  Count/Target  |
+---------------+---------------+---------------+-------------------------------+
```

### 1. `DJNZ LCx, target` (Decrement and Jump if Not Zero)
- `instr[15:12] = 4'h7`
- `instr[11]    = lc_sel` (`0` = `LC0`, `1` = `LC1`)
- `instr[10]    = 1'b0` (Branch mode)
- `instr[4:0]   = target` (5-bit destination address `0..31`)
- **Behavior**:
  - Decrements selected counter (`LCx <= LCx - 1`).
  - If counter was not `1` on entry (`LCx != 1`), jumps to `target`.
  - When counter reaches `1` on entry, decrements to `0` and falls through to next instruction (`pc <= pc + 1`).
  - If counter is `0` on entry, it wraps to `255`, executing 256 loop iterations (standard assembly behavior).
  - Single cycle, zero branching overhead.

### 2. `SET_LC LCx, count` (Immediate Load)
- `instr[15:12] = 4'h7`
- `instr[11]    = lc_sel` (`0` = `LC0`, `1` = `LC1`)
- `instr[10]    = 1'b1` (Load/Store mode)
- `instr[9:8]   = 2'b00`
- `instr[7:0]   = count` (8-bit immediate count `1..255`)

### 3. `PULL_LC LCx` (Dynamic Host Load)
- `instr[15:12] = 4'h7`
- `instr[11]    = lc_sel`
- `instr[10]    = 1'b1`
- `instr[9:8]   = 2'b01`
- **Behavior**: Loads loop counter directly from `i_data` (set at runtime via bootloader `'D'` command). Enables dynamic packet sizing from host.

### 4. `PUSH_LC LCx` (Counter State Latch)
- `instr[15:12] = 4'h7`
- `instr[11]    = lc_sel`
- `instr[10]    = 1'b1`
- `instr[9:8]   = 2'b10`
- **Behavior**: Copies `LCx` into `o_data` (visible on LEDs) and `OSR`.

### 5. `MOV_LC LCx, OSR` (Register Transfer)
- `instr[15:12] = 4'h7`
- `instr[11]    = lc_sel`
- `instr[10]    = 1'b1`
- `instr[9:8]   = 2'b11`
- **Behavior**: Loads `LCx` from current `OSR` register value.

---

## Nested Loop Example (`loop_countdown.asm`)

```asm
start:
    SET_LC  LC1, 4          ; Outer loop repeats 4 cycles

outer_loop:
    SET_LC  LC0, 15         ; Inner loop counts down 15 -> 0

inner_loop:
    PUSH_LC LC0             ; Output count to LEDs
    NOP     $BAUD
    DJNZ    LC0, inner_loop ; Inner loop branch

    DJNZ    LC1, outer_loop ; Outer loop branch

done:
    JMP     done
```

---

## Multi-Byte SPI Burst Example (`spi_burst.asm`)

```asm
start:
    SET     CS, 0, 0        ; Assert CS_n low
    SET_LC  LC0, 4          ; Send 4 bytes in a single transaction

burst_loop:
    PULL                    ; Load next byte from host
    OUT     SCK, $HBAUD     ; Send 8 bits with auto-SCK clocking
    DJNZ    LC0, burst_loop ; Loop 4 times

    SET     CS, 1, 0        ; Deassert CS_n high
    PUSH
```

---

## Quick Start & Verification

```bat
REM Run countdown demo on Tang Console 60K FPGA
run_loop_demo.bat

REM Run 4-byte SPI burst demo
run_loop_demo.bat burst
```
