# Task 19 — Autonomous Manchester / Biphase Mark Stream Accelerator (10BASE-T Ethernet, IEEE 802.3, BMC/FM0/FM1, S/PDIF, & DALI)

## 1. Overview & Motivation

Synchronous physical layers without a dedicated clock line encode clock and data transitions directly into the transmission stream:
1. **IEEE 802.3 / 10BASE-T Ethernet (Manchester Encoding)**:
   - Encodes logic `'0'` as a Low-to-High transition at the center of the bit cell.
   - Encodes logic `'1'` as a High-to-Low transition at the center of the bit cell.
   - A transition MUST occur at the center of every bit cell; absence of a center transition indicates a **Manchester code violation / collision / line fault**.
2. **Thomas Convention (Inverted Manchester)**:
   - Encodes logic `'0'` as a High-to-Low transition.
   - Encodes logic `'1'` as a Low-to-High transition.
   - Used in classic networking standards, RFID (ISO/IEC 14443 Type A), and avionics.
3. **Biphase Mark Code (BMC / FM1)**:
   - Guaranteed transition at every bit cell boundary.
   - Logic `'1'` adds a second transition at the mid-bit cell center.
   - Logic `'0'` maintains steady level across the entire bit cell.
   - Polarity-independent physical layer used in **S/PDIF digital audio (AES3/IEC 60958)**, **DALI digital lighting (IEC 62386)**, and **MIL-STD-1553 avionics data bus**.

Bit-banging Manchester or BMC in software requires two explicit output phase changes per bit and twice the cycle budget, making it impossible to sustain high bitrates (such as 10 Mbit/s Ethernet or 3.072 Mbit/s S/PDIF) with single-cycle microcode loops.

**Task 19 introduces a fully autonomous hardware Manchester and Biphase Mark Stream Accelerator inside the Protocol Emulator engine**, supporting autonomous two-phase serialization, autonomous center-sampling deserialization, continuous code violation detection, and zero-overhead hardware conditional branching.

---

## 2. Hardware Architecture & Register Specification

### A. Autonomous 2-Phase Serializer (`OUT`)
When `assist_manch_en` is set, executing `OUT` (opcode `0x1`) invokes an autonomous 2-phase hardware serializer:
- **Timing Resolution**: Each half-bit period is governed by `eff_hdelay = (eff_delay >> 1)`.
- **Phase 0 (First Half-Bit)**:
  - **IEEE 802.3**: Drives `osr[0]`.
  - **Thomas**: Drives `~osr[0]`.
  - **BMC (FM1)**: Inverts `manch_tx_state` on every bit cell boundary and drives `~manch_tx_state`.
  - Sets `delay_cnt <= eff_hdelay` and advances internal phase to `1`.
- **Phase 1 (Second Half-Bit)**:
  - **IEEE 802.3**: Drives `~osr[0]`.
  - **Thomas**: Drives `osr[0]`.
  - **BMC (FM1)**: If `osr[0] == 1'b1`, toggles `manch_tx_state`; if `osr[0] == 1'b0`, holds steady level.
  - Sets `delay_cnt <= eff_hdelay`, resets internal phase to `0`, shifts `osr <= {1'b0, osr[7:1]}`, and decrements `bit_cnt`.

### B. Autonomous 2-Phase Deserializer & Violation Detector (`IN`)
When `assist_manch_en` is set, executing `IN` (opcode `0x2`) invokes an autonomous 2-phase deserializer:
- **Phase 0**: Samples `gpio_in[rx_pin]` into `manch_rx_sample1`, starts `eff_hdelay` timer, and transitions to Phase 1.
- **Phase 1**: Samples `gpio_in[rx_pin]` (sample 2):
  - **Code Violation Check**: For IEEE and Thomas modes, checks `if (manch_rx_sample1 == gpio_in[rx_pin])`. If both half-cells are identical (flatline), latches `manch_error <= 1'b1`.
  - **Bit Recovery**:
    - **IEEE 802.3**: Recovers bit as `manch_rx_sample1` (`1` if high/low, `0` if low/high).
    - **Thomas**: Recovers bit as `~manch_rx_sample1` (`1` if low/high, `0` if high/low).
    - **BMC**: Recovers bit as `(manch_rx_sample1 != gpio_in[rx_pin])` (`1` if transition occurred, `0` if steady).
  - Shifts recovered bit into `isr[7:0]` and decrements `rx_bit_cnt`.

### C. Accelerator Registers

| Register | Width | Reset | Description |
| :--- | :--- | :--- | :--- |
| `assist_manch_en` | 1 bit | `1'b0` | `1`=Enable autonomous Manchester/BMC engine on `OUT`/`IN` |
| `assist_manch_mode` | 2 bits | `2'b00` | `00`=IEEE 802.3 (10BASE-T), `01`=Thomas, `10`=BMC (FM1/SPDIF/DALI), `11`=Reserved |
| `manch_tx_phase` | 1 bit | `1'b0` | Internal phase tracker for 2-phase transmitter (`0`=Phase 0, `1`=Phase 1) |
| `manch_tx_state` | 1 bit | `1'b0` | Running line state tracker for BMC / FM0 edge transitions |
| `manch_rx_phase` | 1 bit | `1'b0` | Internal phase tracker for 2-phase receiver (`0`=Phase 0, `1`=Phase 1) |
| `manch_rx_sample1` | 1 bit | `1'b0` | Latched sample of first half-bit cell |
| `manch_error` | 1 bit | `1'b0` | Sticky Manchester code violation latch (cleared by `ASSIST RESET`) |

---

## 3. Instruction Set Architecture Updates

### A. Opcode `0xF` (`ASSIST`) Extensions
```
15:12 = 4'hF (ASSIST Opcode)
11:10 = 2'b00 : ASSIST CFG
        instr[4]   : 1 = Configure Manchester engine
        instr[3]   : Manchester Enable (1=Enable, 0=Disable)
        instr[2:1] : Manchester Mode (00=IEEE, 01=Thomas, 10=BMC)
        instr[0]   : Initial BMC transmitter level
11:10 = 2'b01 : ASSIST RESET
        Clears manch_error <= 0, resets manch_tx_phase, manch_rx_phase, manch_tx_state
11:10 = 2'b10 : ASSIST READ
        Reads status into Accumulator:
        acc[7] = stuff_error
        acc[6] = manch_error
        acc[5:4] = assist_manch_mode
        acc[3] = assist_manch_en
        acc[2:1] = assist_stuff_mode
        acc[0] = assist_nrzi_en
```

### B. Opcode `0x8` (`JMP`) Conditional Branch Extension
Condition code `4'hF` is extended:
```verilog
4'hF: pc <= (stuff_error | manch_error) ? target : pc + 7'd1;
```
Assembly syntax: `JMP MANCH_ERR, <target>` or `JMP STREAM_ERR, <target>`.

---

## 4. Assembler Support (`omnibus_asm.py`)

New keywords and syntax supported:
```asm
; Enable IEEE 802.3 10BASE-T Manchester Accelerator
ASSIST MANCH, IEEE

; Enable Thomas convention (inverted Manchester)
ASSIST MANCH, THOMAS

; Enable Biphase Mark Code (BMC / S/PDIF / DALI)
ASSIST MANCH, BMC

; Fine-grained configuration via ASSIST CFG
ASSIST CFG, MANCH=1, MODE=BMC, INIT=0

; Zero-overhead branch on code violation
JMP MANCH_ERR, error_handler
```

---

## 5. Verification & Test Suite Summary

The emulator was validated with 4 new dedicated Cocotb unit tests in addition to the full regression test suite (52 tests total, 100% PASS):

| Test Name | Feature Verified | Result |
| :--- | :--- | :--- |
| `test_stream_manchester_tx_ieee` | 8-bit IEEE 802.3 Manchester serialization with center transitions and half-bit timing | **PASS** |
| `test_stream_manchester_tx_bmc` | 8-bit BMC serialization verifying boundary flips and mid-bit transitions on `'1'` | **PASS** |
| `test_stream_manchester_rx_ieee` | 8-bit IEEE 802.3 Manchester deserialization and bit recovery into ISR | **PASS** |
| `test_stream_manchester_violation_detect` | Code violation detection (flatline) asserting `manch_error` and `JMP MANCH_ERR` branch | **PASS** |
| Regression Suite (Tasks 01–18) | 48 legacy tests (UART, SPI, I2C, 1-Wire, CRC, ALU, Bank Switch, USB/CAN, Joybus, Gamepad) | **PASS (48/48)** |
| **Total Test Suite** | **All 52 Cocotb regression tests** | **PASS (52/52, 100%)** |

---

## 6. Demonstration Applications & Scripts

- **10BASE-T Ethernet Packet Generator**: `examples/ethernet_10baset_demo.asm`
  - Generates 10BASE-T preamble (7 bytes `0x55`), Start of Frame Delimiter (SFD `0xD5`), destination MAC, source MAC, EtherType (`0x0800` IPv4), and payload using autonomous Manchester serialization.
- **Batch Test & Demo Runner**: `run_manch_demo.bat` (and alias `run_manch.bat`).
