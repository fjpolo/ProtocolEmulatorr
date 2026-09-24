# Task 23 — Dedicated Hardware JTAG TAP Controller & ARM SWD Hardware Sequencer (Supporting RISC-V DTM & ARM CoreSight)

## 1. Overview & Motivation

Embedded debug, in-circuit programming, and hardware boundary scan are critical capabilities for modern protocol emulators, silicon bringup tools, and automated test fixtures:
1. **IEEE 1149.1 Standard JTAG**: The industry-standard boundary scan and debug protocol used across microprocessors, FPGAs, CPLDs, DSPs, and specifically the **RISC-V Debug Specification (v0.13 and v1.0)** via its Debug Transport Module (DTM).
2. **ARM Serial Wire Debug (SWD / ADIv5)**: The low-pin-count 2-wire debug protocol used universally across ARM Cortex-M microcontrollers (Cortex-M0+/M3/M4/M7/M33), and modern hybrid RISC-V microcontrollers (such as the Raspberry Pi RP2350 featuring dual RISC-V Hazard3 cores connected to CoreSight via SWD).
3. **Hardware-Accelerated Sequences**: Debug protocols feature strict timing requirements, packet parity calculations, bus turnaround cycles, line resets (50+ clocks), and standard switching patterns (`0xE79E` JTAG-to-SWD select sequence) that are slow, complex, and prone to jitter when implemented purely in bit-banged software.

**Task 23 integrates a Dedicated Hardware IEEE 1149.1 JTAG TAP Controller and ARM SWD Host Hardware Sequencer** directly into the OmniBus Protocol Emulator:
- **IEEE 1149.1 16-State JTAG TAP Controller**: Fully autonomous state machine tracking standard states (`TEST_LOGIC_RESET`, `RUN_TEST_IDLE`, `SELECT_DR_SCAN`, `CAPTURE_DR`, `SHIFT_DR`, `EXIT1_DR`, `PAUSE_DR`, `EXIT2_DR`, `UPDATE_DR`, `SELECT_IR_SCAN`, `CAPTURE_IR`, `SHIFT_IR`, `EXIT1_IR`, `PAUSE_IR`, `EXIT2_IR`, `UPDATE_IR`).
- **Autonomous JTAG TMS Sequencer**: Hardware microcode navigation instruction (`JTAG_NAV`) generates multi-clock TMS sequences to autonomously navigate between key states (`RESET`, `IDLE`, `SHIFT_DR`, `SHIFT_IR`, `EXIT_TO_IDLE`).
- **High-Speed Autonomous JTAG Shifter**: `JTAG_SHIFT` executes 1-to-8 bit Data Register or Instruction Register shifts with automatic TMS assertion on the final bit (`EXIT=1`) to step out of Shift state in a single instruction.
- **ARM SWD (ADIv5) Packet Engine**:
  - Autonomous 8-bit Request Header generator with hardware Even Parity generation.
  - Automatic 1-cycle Bus Turnaround (`Trn`) cycle handling.
  - Hardware 3-bit Target ACK sampling (`001`=OK, `010`=WAIT, `100`=FAULT) and register latching.
  - 32-bit Data Phase (`SWD_RD32` / `SWD_WR32`) with automatic even parity bit check/generation.
  - Autonomous 54-clock Line Reset and 16-bit `0xE79E` JTAG-to-SWD Switching Sequence (`SWD_RESET`).
- **Extended Conditional Branches**: Added condition codes `SWD_OK`, `SWD_WAIT`, `SWD_FAULT`, and `JTAG_IDLE` to `JMP`.
- **Wishbone Peripheral Interface**: Dedicated `ADDR_DEBUG = 8'h1C` register for debug telemetry and host access.

---

## 2. Hardware Architecture

```
                               +-------------------------------------------------------------+
                               |           OmniBus Debug & Hardware Sequencer Subsystem      |
                               |                                                             |
   Microcode / Wishbone -------> [ JTAG Hardware Engine ]                                     |
                               |   ├── 16-State IEEE 1149.1 TAP FSM (fn_tap_next)            |
                               |   ├── Autonomous TMS Bit Shifter (jtag_tms_cnt)             |
                               |   └── DR/IR Data Shifter (jtag_shift_cnt + EXIT1 auto-step)  |
                               |                                                             |
                               | [ ARM SWD Packet Engine ]                                   |
                               |   ├── 8-bit Request Header Generator + Even Parity Calc     |
                               |   ├── Bus Turnaround (Trn) & Tri-State OE Control           |
                               |   ├── 3-bit ACK Sampler & Status Flag Latch                 |
                               |   ├── 32-bit Data Read/Write + Parity Verification          |
                               |   └── 54-Clock Line Reset + 0xE79E Switch Pattern Generator |
                               +-------------------------------------------------------------+
                                      |                 |                 |              |
                                      v                 v                 v              v
                                   Pin 0 (TDI/SWDIO) Pin 1 (TCK/SWCLK) Pin 2 (TMS)   Pin 3 (TDO)
```

### A. Dedicated Registers & Signals
| Register / Signal | Width | Reset | Description |
| :--- | :--- | :--- | :--- |
| `jtag_en` | 1 bit | `1'b0` | Master enable for JTAG hardware controller |
| `jtag_state` | 4 bits | `4'h0` | Current 16-state JTAG TAP FSM state (0=RESET, 1=IDLE, etc.) |
| `jtag_tms_cnt` | 4 bits | `4'h0` | Bit counter for autonomous TMS stepping |
| `jtag_shift_cnt` | 6 bits | `6'd0` | Bit counter for autonomous DR/IR shifts |
| `jtag_exit_on_last` | 1 bit | `1'b0` | Assert TMS=1 on final bit of shift to step into EXIT1 state |
| `swd_en` | 1 bit | `1'b0` | Master enable for ARM SWD hardware host engine |
| `swd_state` | 4 bits | `4'h0` | SWD FSM state (0=IDLE, 1=REQ, 2=TRN, 3=ACK, 4=RD32, etc.) |
| `swd_last_ack` | 3 bits | `3'b000` | Sampled 3-bit target ACK (`001`=OK, `010`=WAIT, `100`=FAULT) |
| `swd_parity_err` | 1 bit | `1'b0` | Sticky error flag set on SWD read data parity mismatch |
| `swd_data_reg` | 32 bits | `32'd0` | 32-bit SWD Data read/write storage register |
| `swd_oe` | 1 bit | `1'b0` | Output enable for bidirectional SWDIO pin (Pin 0) |

---

## 3. Microcode Instruction Set Extensions

### A. JTAG Controller Instructions
| Mnemonic | Opcode | Description |
| :--- | :--- | :--- |
| `JTAG_CFG <en>` | `0xF510` / `0xF511` | Enable/disable JTAG hardware engine |
| `JTAG_NAV RESET` | `0xF530` | Clocks 5 consecutive TMS=1 to force Test-Logic-Reset from any state |
| `JTAG_NAV IDLE` | `0xF531` | Smart navigation to Run-Test/Idle from current TAP state |
| `JTAG_NAV SHIFT_DR` | `0xF532` | Smart navigation to Shift-DR from Reset or Idle |
| `JTAG_NAV SHIFT_IR` | `0xF533` | Smart navigation to Shift-IR from Reset or Idle |
| `JTAG_NAV EXIT_TO_IDLE`| `0xF534` | Steps from Exit1 state to Run-Test/Idle (TMS=1, then TMS=0) |
| `JTAG_SHIFT <n> [, EXIT=0\|1]` | `0xF570`..`0xF57F` | Shifts $n$ bits (1..8) of data on TDI/TDO; sets TMS=1 on last bit if EXIT=1 |
| `ASSIST READ, JTAG` | `0xFA40` | Reads `{jtag_tdo, jtag_state[3:0], jtag_tms, jtag_tck, jtag_en}` into `acc` |

### B. ARM SWD Controller Instructions
| Mnemonic | Opcode | Description |
| :--- | :--- | :--- |
| `SWD_CFG <en>` | `0xF540` / `0xF541` | Enable/disable ARM SWD hardware host engine |
| `SWD_RESET [switch=0\|1]` | `0xF560` / `0xF561` | 54 clocks line reset; generates `0xE79E` switch sequence if `switch=1` |
| `SWD_REQ <AP\|DP>, <RD\|WR>, <addr>` | `0xF550`..`0xF55F` | Transmits 8-bit packet header, turnaround, and samples 3-bit ACK into `swd_last_ack` |
| `SWD_RD32` | `0xF580` | Reads 32 data bits + parity bit + turnaround into `swd_data_reg` |
| `SWD_WR32` | `0xF590` | Drives turnaround, 32 data bits + even parity bit from `swd_data_reg` |
| `SWD_LOAD <byte_idx>` | `0xF5A0`..`0xF5A3` | Loads `acc` into byte 0..3 of `swd_data_reg` |
| `ASSIST READ, SWD_STATUS` | `0xFA80` | Reads `{swd_last_ack[2:0], swd_parity_err, swd_en, 3'b0}` into `acc` |
| `ASSIST READ, SWD_DATA, <0..3>` | `0xFAC0`..`0xFAF0` | Reads byte 0..3 of `swd_data_reg` into `acc`, `isr`, and `o_data` |

### C. Extended Conditional Jumps
| Mnemonic | Condition Code | Opcode (`instr[11:8]`) | Description |
| :--- | :--- | :--- | :--- |
| `JMP SWD_OK, <addr>` | `SWD_OK` | `4'h8` (ext bit 7=1) | Jump if `swd_last_ack == 3'b001` (OK) |
| `JMP SWD_WAIT, <addr>` | `SWD_WAIT` | `4'h9` (ext bit 7=1) | Jump if `swd_last_ack == 3'b010` (WAIT) |
| `JMP SWD_FAULT, <addr>` | `SWD_FAULT` | `4'hA` (ext bit 7=1) | Jump if `swd_last_ack == 3'b100` (FAULT) |
| `JMP JTAG_IDLE, <addr>` | `JTAG_IDLE` | `4'hB` (ext bit 7=1) | Jump if `jtag_state == 4'h1` (RUN_TEST_IDLE) |

---

## 4. Verification & Regression Test Suite

All 4 dedicated Task 23 tests were implemented in `test_rtl/simulation/cocotb/ProtocolEmulator/testbench.py` and simulated with Icarus Verilog and Cocotb:

1. **`test_jtag_tap_reset_and_navigation`**:
   - Executes `JTAG_CFG 1`, `JTAG_NAV RESET`, `JTAG_NAV IDLE`, `JTAG_NAV SHIFT_DR`, `JTAG_NAV IDLE`, `JTAG_NAV SHIFT_IR`, `JTAG_NAV IDLE`.
   - Verified visiting of states 0 (`RESET`), 1 (`IDLE`), 4 (`SHIFT_DR`), and 11 (`SHIFT_IR`).
   - Verified conditional jump `JMP JTAG_IDLE` successfully branched and set `acc = 0xAA`.
   - **Result: PASS**.

2. **`test_jtag_riscv_idcode_scan`**:
   - Simulates RISC-V Debug Transport Module (DTM) target model with 32-bit IDCODE `0x0010E319`.
   - Microcode navigates to `SHIFT_DR`, performs 4 consecutive `JTAG_SHIFT 8` operations with `EXIT=1` on the final byte, and pushes each byte into the RX FIFO.
   - Verified exact reconstructed IDCODE `0x0010E319`.
   - **Result: PASS**.

3. **`test_swd_line_reset_and_switching`**:
   - Simulates `SWD_RESET 1`.
   - Sampled all clock pulses and SWDIO levels: captured 54 clocks high, 16 clocks containing the `0xE79E` JTAG-to-SWD switching sequence (LSB-first), 54 post-switch clocks high, and 4 idle clocks.
   - Verified 127 total SWCLK cycles and exact pattern `0xE79E`.
   - **Result: PASS**.

4. **`test_swd_request_and_ack_sampling`**:
   - Simulates ARM CoreSight target model with DP IDCODE `0x0BA01477`.
   - Microcode executes `SWD_REQ DP, READ, 0x00`, branches on `JMP SWD_OK`, performs `SWD_RD32`, and reads all 4 data bytes via `ASSIST READ, SWD_DATA, x`.
   - Verified request header `[1, 0, 1, 0, 0, 1, 0, 1]`, sampled `ACK = 001` (OK), 0 parity errors, and exact DP-IDCODE `0x0BA01477`.
   - **Result: PASS**.

### Full Regression Suite:
```
==================================================================================================================
** TESTS=68 PASS=68 FAIL=0 SKIP=0                                      6756790.07          13.58     497545.21  **
==================================================================================================================
```
100% regression pass rate across all 68 tests.
