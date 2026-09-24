# Task 16 — Instruction Memory (IMEM) Expansion to 128 Words & Bank Switching

## 1. Overview & Motivation

OmniBus previously supported a 32-word Microcode Instruction Memory (`imem[0:31]`) addressed by a 5-bit Program Counter (`pc[4:0]`). While highly optimized for basic serial protocols (UART echo, SPI loopback), complex multi-packet parsers, 1-Wire ROM search routines, and multi-state protocol drivers with subroutine call trees frequently exhausted the 32-word limit.

**Task 16 quadruples the IMEM capacity from 32 to 128 words ($4\times$)** and introduces a **4-Bank Switching & Zero-Downtime Hot-Reload Architecture**:
- **Unified 7-bit Addressing (`pc[6:0]`)**: Linear flat execution across all 128 words without paging penalties.
- **4 Banks of 32 words**:
  - Bank 0: Words `0x00..0x1F` (0..31) — Default boot vector & core dispatcher.
  - Bank 1: Words `0x20..0x3F` (32..63) — Service protocol bank.
  - Bank 2: Words `0x40..0x5F` (64..95) — Accelerator & secondary driver bank.
  - Bank 3: Words `0x60..0x7F` (96..127) — Telemetry, diagnostics & error handling bank.
- **Zero-Downtime Hitless Hot-Reload**: Wishbone host CPU or serial bootloader can reprogram an inactive bank while the core actively executes live traffic in another bank, switching banks instantaneously without halting execution or resetting the core.

---

## 2. Architectural Specification

### A. Register & Memory Expansion

| Entity | Old Width / Range | New Width / Range | Description |
| :--- | :--- | :--- | :--- |
| **`imem`** | `16'h0000` $\times$ 32 words | **`16'h0000` $\times$ 128 words** | 2,048 bits / 256 bytes microcode RAM |
| **`pc`** | `[4:0]` ($0..31$) | **`[6:0]` ($0..127$)** | 7-bit Program Counter |
| **`call_stack`** | 4-deep $\times$ 5-bit | **4-deep $\times$ 7-bit** | Subroutine return address stack |
| **`i_prog_addr`** | `[4:0]` ($0..31$) | **`[6:0]` ($0..127$)** | Runtime programming address port |
| **`active_bank`**| N/A | **`[1:0]` ($0..3$)** | Core active execution bank |
| **`reg_imem_bank`**| N/A | **`[1:0]` ($0..3$)** | Wishbone window bank selector |

---

## 3. Instruction Set Updates

### A. Extended Branch Addressing (7-bit Targets)
Because bits `[6:0]` are available in all branching opcodes, branches can directly target any address $0..127$ across all banks without overhead:
- **`JMP [cond], target`** (Opcode `0x8`): `instr[6:0]` directly targets addresses $0..127$.
- **`CALL target`** (Opcode `0xC`): `instr[6:0]` pushes `pc+1` to 7-bit call stack and branches anywhere in $0..127$.
- **`RET`** (Opcode `0xD`): Pops 7-bit return address from stack.
- **`DJNZ LCx, target`** (Opcode `0x7`): `instr[6:0]` branches anywhere in $0..127$.

### B. Microcode Bank Switching Instructions (Opcode `0xB`)
| Mnemonic | Opcode / Sub-op | Bitfield Encoding | Action |
| :--- | :--- | :--- | :--- |
| **`BANK imm2`** / **`SET_BANK imm2`** | `0xB` (Immediate) | `16'b1011_0111_0100_00xx` | Sets `active_bank <= imm2[1:0]` |
| **`JMP_BANK imm2`** | `0xB` (Immediate) | `16'b1011_0111_1000_00xx` | Sets `active_bank <= imm2[1:0]` and jumps to `{imm2, 5'd0}` |
| **`MOV BANK, acc`** | `0xB` (Register) | `16'b1011_1001_0010_1000` | Transfers `acc[1:0]` to `active_bank` |
| **`MOV acc, BANK`** | `0xB` (Register) | `16'b1011_1000_0000_0101` | Reads `active_bank` into `acc[1:0]` (bits 7..2 zeroed) |

---

## 4. Wishbone SoC & Bootloader Banking

### A. Wishbone Register Map (`OmniBus_Wishbone.v`)
- **`ADDR_IMEM_BANK` (`0x14`)**:
  - `[1:0]` (RW): `reg_imem_bank` — Selects which bank is mapped into the `0x80..0xFC` 32-word window.
  - `[14:8]` (RO): `core.pc[6:0]` — Full 7-bit Program Counter telemetry.
  - `[17:16]` (RO): `core.active_bank[1:0]` — Active execution bank telemetry.
- **`ADDR_IMEM` (`0x80..0xFC`)**:
  - Mapped to `{reg_imem_bank, i_wb_addr[6:2]}`: grants full read/write access to all 128 words while maintaining standard 8-bit Wishbone byte addressing.

### B. Hitless Zero-Downtime Hot-Reload Workflow
1. Core actively processes traffic in Bank 0 (`active_bank = 0`).
2. Host CPU writes `1` to `ADDR_IMEM_BANK` (`0x14`).
3. Host CPU writes updated microcode into `0x80..0xFC` (writes directly to Bank 1, words 32..63).
4. Core in Bank 0 continues unaffected (no halting, no FIFO resets).
5. When ready, host writes bank switch trigger or core executes `JMP_BANK 1`: core switches to Bank 1 instantaneously with zero dropped frames.

---

## 5. Software & Tooling Updates

- **Assembler (`python/omnibus_asm.py`)**:
  - Added `.bank <0..3>` directive: sets current assembly address to `bank * 32`.
  - Added `.org <addr>` directive: sets arbitrary assembly address offset.
  - Added `BANK <imm2>`, `SET_BANK <imm2>`, `JMP_BANK <imm2>` mnemonics.
  - Added `BANK` / `ACTIVE_BANK` register aliases for `MOV`.
  - Raised maximum IMEM size limit to 128 words.
- **Loader (`python/omnibus_loader.py`)**:
  - Expanded address mask to `0x7F`.
  - Updated `--dump` to display all 128 words grouped by Bank (0..3).

---

## 6. Verification Results

### A. Cocotb Simulation Regression
- **DUT Test Suite (`test_rtl/simulation/cocotb/ProtocolEmulator/`)**:
  - **`TESTS=38 PASS=38 FAIL=0 SKIP=0`** (100% PASS)
  - `test_imem_128_words_linear`: Verified continuous 128-instruction execution across bank boundaries (31 $\rightarrow$ 32, 63 $\rightarrow$ 64, 95 $\rightarrow$ 96) ending at PC=127 with `acc=127`.
  - `test_bank_switching_and_hot_reload`: Verified `SET_BANK`, `MOV acc, BANK`, `JMP_BANK`, and register updates.
  - `test_call_ret_extended_range`: Verified cross-bank subroutine calls (Caller in Bank 0, Callee at address 100 in Bank 3, returning to Bank 0).

- **Wishbone SoC Test Suite (`test_rtl/simulation/cocotb/Wishbone/`)**:
  - **`TESTS=6 PASS=6 FAIL=0 SKIP=0`** (100% PASS)
  - `test_wb_imem_banking`: Verified Wishbone programming window mapping across all 4 banks and bank data isolation.

### B. Formal Verification Suite
- **`bound`**: **PASS** (BMC depth 10, zero assertion failures).
- **`prf`**: **PASS** ($k$-induction proof on 7-bit PC and stack safety).
