# Task 20 — Hardware CRC-32 (IEEE 802.3 Ethernet FCS) & CRC-5 (USB Token) Engine

## 1. Overview & Motivation

Synchronous and packetized protocols rely on hardware-accelerated Cyclic Redundancy Checks (CRC) to guarantee link integrity without consuming processor cycles:
1. **IEEE 802.3 10BASE-T Ethernet Frame Check Sequence (FCS)**:
   - 32-bit CRC with generator polynomial $G(x) = x^{32} + x^{26} + x^{23} + x^{22} + x^{16} + x^{12} + x^{11} + x^{10} + x^8 + x^7 + x^5 + x^4 + x^2 + x + 1$.
   - Reflected representation: `0xEDB88320`.
   - Default initialization seed: `0xFFFFFFFF`.
   - Appended to Ethernet MAC frames (over Destination MAC, Source MAC, EtherType, and Payload) transmitted LSB-first in 1's complement.
   - When received, appending the remainder yields a unique zero-residue `0x00000000` (or `0xDEBB20E3` if inverted).
2. **USB 1.1 Token Packets (CRC-5)**:
   - 5-bit CRC protecting 11-bit token packets (7-bit Address + 4-bit Endpoint).
   - Generator polynomial $G(x) = x^5 + x^2 + 1$.
   - Reflected representation: `0x14`.
   - Default initialization seed: `0x1F`.

Bit-banging a 32-bit CRC in software requires hundreds of ALU and shift instructions per byte, bottlenecking streaming protocols. **Task 20 upgrades the OmniBus Protocol Emulator hardware CRC engine (Opcode `0xE`) from 16 bits to 32 bits**, implementing single-cycle parallel 8-bit XOR tree matrix calculations for both IEEE 802.3 Ethernet CRC-32 and USB Token CRC-5 while maintaining 100% backward compatibility with all legacy CRC-8 and CRC-16 modes.

---

## 2. Hardware Architecture & Register Specification

### A. 32-Bit Register Datapath
- `crc_reg` widened from 16 bits to 32 bits: `reg [31:0] crc_reg`.
- `crc_seed` widened from 16 bits to 32 bits: `reg [31:0] crc_seed`.
- `crc_poly` widened from 2 bits to 3 bits: `reg [2:0] crc_poly`.

### B. Supported CRC Polynomial Matrix

| Poly ID (`crc_poly`) | Standard / Protocol | Bit Width | Reflected / Normal | Polynomial | Default Seed | Standard Verification Vector |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `3'b000` (`0`) | Dallas 1-Wire | 8 bits | Reflected | `0x8C` ($x^8+x^5+x^4+1$) | `0x00` | Vector `[0x02]` $\rightarrow$ `0x1C` |
| `3'b001` (`1`) | SMBus / I2C PEC | 8 bits | Normal | `0x07` ($x^8+x^2+x+1$) | `0x00` | Vector `[0x5A]` $\rightarrow$ `0x1F` |
| `3'b010` (`2`) | CCITT / XMODEM | 16 bits | Normal | `0x1021` ($x^{16}+x^{12}+x^5+1$) | `0x0000` | ASCII `"1234"` $\rightarrow$ `0xD789` |
| `3'b011` (`3`) | Modbus RTU / IBM | 16 bits | Reflected | `0xA001` ($x^{16}+x^{15}+x^2+1$) | `0xFFFF` | Vector `[0x01,0x03,0,0,0,0x0A]` $\rightarrow$ `0xCDC5` |
| `3'b100` (`4`) | **IEEE 802.3 Ethernet FCS** | **32 bits** | **Reflected** | **`0xEDB88320`** | **`0xFFFFFFFF`** | ASCII `"123456789"` $\rightarrow$ `0x340BC6D9` (FCS: `0xCBF43926`) |
| `3'b101` (`5`) | **USB 1.1 Token Packets** | **5 bits** | **Reflected** | **`0x14`** ($x^5+x^2+1$) | **`0x0000001F`** | Vector `[0x01, 0x00]` $\rightarrow$ `0x16` |

### C. Single-Cycle Parallel 8-Bit XOR Trees
Both extended functions evaluate an entire 8-bit byte per clock cycle using unrolled, combinational XOR reduction logic:
- `fn_crc32_eth`: Reflected IEEE 802.3 single-cycle parallel evaluation into `[31:0]`.
- `fn_crc5_usb`: Reflected USB 1.1 single-cycle parallel evaluation into `[31:0]` (lower 5 bits populated).

---

## 3. Instruction Set Architecture & Opcode Decoding

### A. Opcode `0xE` (`CRC`) Instruction Encoding

```
+---------------+---------------+---------------+---------------+
| 15 14 13 12   | 11 10 9       | 8 7 6 5 4 3 2 1 0             |
|   4'hE        |   sub_op[2:0] |   sub-operation operands      |
+---------------+---------------+---------------+---------------+
```

#### 1. `CRC_INIT` (`sub_op = 3'b000`)
- **Legacy Form (`instr[3] == 0`)**:
  - `instr[8:7]`: Polynomial `0` (Dallas), `1` (SMBus), `2` (CCITT), `3` (Modbus).
  - `instr[6:5]`: Seed mode (`00`=Default, `01`=Zero, `10`=0xFFFF).
  - Bits `[4:0]` are `0`, preserving 100% binary compatibility with legacy ROMs.
- **Extended Form (`instr[3] == 1`)**:
  - `instr[3]`: Extended polynomial selector (`1'b1`).
  - `instr[2:1]`: Extended polynomial ID:
    - `2'b00`: Ethernet CRC-32 (Poly 4).
    - `2'b01`: USB Token CRC-5 (Poly 5).
  - `instr[5:4]`: Seed mode:
    - `2'b00`: Default seed (`0xFFFFFFFF` for Ethernet, `0x0000001F` for USB).
    - `2'b01`: Force `0x00000000`.
    - `2'b10` / `2'b11`: Force `0xFFFFFFFF`.

#### 2. `CRC_BYTE` (`sub_op = 3'b001..3'b011`)
- `3'b001`: `CRC_BYTE OSR` — feeds `osr[7:0]` into CRC accelerator.
- `3'b010`: `CRC_BYTE ISR` — feeds `isr[7:0]` into CRC accelerator.
- `3'b011`: `CRC_BYTE DATA` — feeds `i_data[7:0]` from FIFO into CRC accelerator.

#### 3. 4-Byte Readout Instructions
- `3'b100`: `CRC_READ_LOW` / `CRC_READ_B0` — copies `crc_reg[7:0]` to `osr` and `o_data`.
- `3'b101`: `CRC_READ_HIGH` / `CRC_READ_B1` — copies `crc_reg[15:8]` to `osr` and `o_data`.
- `3'b110`: `CRC_RESET` — restores `crc_reg <= crc_seed`.
- `3'b111`: Extended Byte Readout:
  - `instr[0] == 0`: `CRC_READ_B2` — copies `crc_reg[23:16]` to `osr` and `o_data`.
  - `instr[0] == 1`: `CRC_READ_B3` — copies `crc_reg[31:24]` to `osr` and `o_data`.

#### 4. 32-Bit Zero-Residue Branching (`Opcode 0x8`)
- `JMP CRC_OK, <target>` (`cond = 4'h7`): Branches if `crc_reg == 32'h00000000`.
- `JMP CRC_ERR, <target>` (`cond = 4'hE`): Branches if `crc_reg != 32'h00000000`.
- Status bit in `OmniBus_Wishbone`: Bit 29 reflects `(core.crc_reg == 32'd0)`.

---

## 4. Assembler Support (`omnibus_asm.py`)

New mnemonics and aliases:
- Polynomials: `ETHERNET`, `ETH`, `CRC32`, `CRC-32`, `USB5`, `CRC5`, `CRC-5`.
- Readout instructions:
  - `CRC_READ_B0`, `CRC_READ_B1`, `CRC_READ_B2`, `CRC_READ_B3`.
  - `CRC READ B0`, `CRC READ B1`, `CRC READ B2`, `CRC READ B3`.
- Example assembly:
```assembly
CRC_INIT ETHERNET               ; Initialize 32-bit Ethernet CRC engine with 0xFFFFFFFF seed
PULL BLOCK                      ; Pull byte from TX FIFO
CRC_BYTE OSR                    ; Feed byte into 32-bit CRC accelerator
CRC_READ_B0                     ; Copy crc_reg[7:0] to OSR & o_data
CRC_READ_B1                     ; Copy crc_reg[15:8] to OSR & o_data
CRC_READ_B2                     ; Copy crc_reg[23:16] to OSR & o_data
CRC_READ_B3                     ; Copy crc_reg[31:24] to OSR & o_data
JMP CRC_OK, packet_valid        ; Zero-overhead branch if remainder == 0
```

---

## 5. Verification & Test Suite

The test suite runs via Cocotb with Icarus Verilog:

```bash
# Run Task 20 tests:
run_crc32.bat sim

# Run complete 56-test regression suite:
wsl bash -c "cd test_rtl/simulation/cocotb/ProtocolEmulator && python3 testrunner_icarus.py"
```

### Test Results Summary

| Testcase | Focus Area | Result |
| :--- | :--- | :--- |
| `test_crc32_ethernet_calculation` | Standard ASCII `"123456789"` vector, 4-byte readout (`B0=0xD9`, `B1=0xC6`, `B2=0x0B`, `B3=0x34`), raw `0x340BC6D9`, final FCS `0xCBF43926`, and `CRC_RESET` | **PASS** |
| `test_crc32_ethernet_residue_check` | 13-byte Ethernet packet with un-inverted FCS remainder, zero residue check (`crc_reg == 0`), `JMP CRC_OK` jump, and corrupted packet fallthrough | **PASS** |
| `test_crc5_usb_token_calculation` | USB 1.1 Token vector `[0x01, 0x00]` $\rightarrow$ `0x16`, and seed restore `0x1F` via `CRC_RESET` | **PASS** |
| `test_ethernet_packet_fcs_integration` | Complete 18-byte MAC frame transmission, dynamic 4-byte FCS capture, receiver reception, and self-verifying zero-residue check | **PASS** |
| **Complete Regression** | **All 56 Cocotb unit tests** across UART, SPI, I2C, 1-Wire, ALU, Stream Assist, and CRC | **56 / 56 PASS (100%)** |

---

## 6. Demonstration & Batch Runners

- `examples/ethernet_fcs_demo.asm`: Transmits complete 10BASE-T Ethernet packet (7-byte preamble, 1-byte SFD, MAC Destination, MAC Source, IPv4 EtherType) with real-time hardware CRC-32 calculation and 4-byte inverted FCS transmission over Manchester encoding.
- `run_crc32_demo.bat` & `run_crc32.bat`: Interactive terminal loader, simulation test runner (`run_crc32 sim`), IMEM dump, and hardware synthesis.
