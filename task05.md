# Task 05 — Hardware Subroutine Stack (CALL/RET)

## Objective

Extend the OmniBus ISA with a **4-deep hardware call stack** and two new opcodes (`CALL`, `RET`), enabling microcode subroutines. This eliminates code duplication in complex programs — a common `tx_byte` subroutine can be called from multiple places without manually inlining 10+ `SET` instructions each time.

---

## ISA Extension

### New Opcodes

| Opcode | Mnemonic | Encoding                          | Operation                                      |
|:------:|:---------|:----------------------------------|:-----------------------------------------------|
| `0xC`  | `CALL`   | `[15:12]=4'hC [4:0]=target_addr` | Push `pc+1` → stack; jump to `target_addr`     |
| `0xD`  | `RET`    | `[15:12]=4'hD (rest unused)`     | Pop top of stack → `pc`                        |

### Hardware Stack

- **Depth**: 4 levels (supports 4 nested subroutine calls)
- **Width**: 5 bits (one return address per slot)
- **Pointer**: 2-bit `sp` register, wraps on overflow (saturating for safety)
- **Reset**: `sp = 0`, all stack slots cleared to `5'd0`

### Stack Encoding

```
CALL addr:  [15:12] = 4'hC | [11:5] = 7'b0 | [4:0] = 5-bit target address
RET:        [15:12] = 4'hD | [11:0] = 12'b0 (ignored)
```

---

## Files Changed

### RTL
- **`rtl/ProtocolEmulator.v`**: Add `call_stack[0:3]`, `sp`, `CALL`/`RET` opcodes. Update ISA comment block. Reset stack on `!i_reset_n` and `i_prog_en`.

### Assembler
- **`python/omnibus_asm.py`**: Add `CALL <label>` and `RET` instruction handlers. `CALL` resolves label to 5-bit address; `RET` emits `0xD000`.

### Microcode Examples
- **`examples/subroutine_demo.asm`**: Demonstrates a shared `tx_byte` subroutine called to send `'O'`, `'K'`, then loop. Proves CALL/RET is functional.

### Verification
- **`test_rtl/simulation/cocotb/ProtocolEmulator/testbench.py`**: Two new tests:
  - `test_call_ret_basic`: CALL jumps to target; RET restores return address.
  - `test_call_ret_nested`: Two-deep nested CALL/RET sequence executes correctly.
- **`test_rtl/formal/ProtocolEmulator/properties.v`**: New invariants:
  - Stack pointer bounded: `sp <= 4`
  - CALL correctness: After CALL, `imem[past_pc][4:0]` was target, `call_stack[sp-1] == past_pc + 1`
  - RET correctness: After RET, `pc == call_stack[sp]`
  - Stack integrity: `sp` only changes by ±1 per cycle

---

## Verification Plan

1. **Cocotb/Icarus**: Full 9-test suite (7 existing + 2 new)
2. **SymbiYosys**: BMC depth-20, k-induction, 5+ cover targets
3. **Yosys synthesis**: Clean synthesis check
4. **Live HIL**: Upload `subroutine_demo.asm` via `omnibus_loader.py`, verify `OK` streaming
