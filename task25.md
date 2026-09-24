# Task 25 — Hardware Glitch / Fault Injection & Active Wire-Speed MitM Fuzzing Engine

## 1. Overview & Motivation

Hardware security evaluation, vulnerability research, and robustness verification require real-time, deterministic control over signal levels, timing, and protocol payload streams:
1. **Clock & Voltage Fault Injection (Glitching)**:
   - Modern secure microcontrollers, smart cards, cryptographic accelerators, and secure elements are evaluated using targeted clock glitches and power-rail crowbar pulses.
   - Fault injection requires **sub-cycle precision**: generating nanosecond-scale pulses (1 to 255 clock cycles, 20 ns resolution @ 50 MHz) with configurable countdown delay (0 to 65,535 clock cycles).
   - Crowbar circuitry or MOSFET pulldowns require selectable polarity (active-High trigger pulse or active-Low crowbar pulldown).
2. **Autonomous Wire-Speed Pattern Matching & Trigger-on-Match**:
   - Software-initiated triggers over USB or UART introduce milliseconds of jitter, making precise fault synchronization impossible.
   - The hardware engine monitors inbound and outbound data streams autonomously at wire speed. When a specific target byte (e.g. authentication command, opcode, or magic handshake) is observed, the glitch countdown starts *immediately* (0 jitter, single-cycle determinism).
   - Wildcard bitmasking (`mitm_mask[7:0]`) enables matching command opcodes while ignoring variable payload or sequence fields.
3. **Active Wire-Speed Man-in-the-Middle (MitM) Fuzzing**:
   - Protocol security fuzzing often requires injecting invalid CRC, corrupting frame headers, or modifying security flags in-flight.
   - The MitM engine automatically substitutes (`mitm_replace_byte`) or bitwise inverts (`~payload`) matching bytes on-the-fly during serialization (`PULL` / `OUT`) and deserialization (`IN` / `PUSH`) without stalling the bus or requiring external interposers.
4. **Hardware Telemetry & Wishbone Register**:
   - Real-time hardware status and telemetry are exposed via Wishbone B4 at address `ADDR_GLITCH = 8'h24`, enabling host CPUs and automated test benches to monitor glitch firing, match counts, and configuration state.

**Task 25 integrates a dedicated Hardware Glitch Generator and Wire-Speed MitM Fuzzing Engine directly into the OmniBus Protocol Emulator ASIC core**, transforming OmniBus into a versatile hardware security evaluation and protocol fuzzing platform.

---

## 2. Hardware Architecture

```
                       +-------------------------------------------------------------+
                       |       OmniBus Hardware Security & Fuzzing Engine (Task 25)  |
                       |                                                             |
   RX / TX Stream ---->|  [ Wire-Speed Pattern Matcher ]                             |
  (gpio_in / i_data)   |    ├── Pattern Register: mitm_match_byte[7:0]               |
                       |    ├── Wildcard Mask   : mitm_mask[7:0]                     |
                       |    └── Match Pulse     : in_mitm_match / pull_mitm_match    |
                       |                  |                                          |
                       |                  v (Trigger on Match)                       |
                       |  [ Glitch Generator FSM ]                                   |
                       |    ├── Countdown Timer : glitch_timer[15:0] (0..65535 clk)  |
                       |    ├── Pulse Width     : glitch_width[7:0]  (1..255 clk)    |
                       |    ├── Polarity Select : glitch_pol (0=Active-Hi, 1=Crowbar)|
                       |    └── Target Pin Mux  : glitch_pin[2:0] (GPIO 0..7)        |
                       |                  |                                          |
                       |                  v (Glitch Pulse Override)                  |
                       |  [ GPIO Output Multiplexer ]                                |
                       |    └── Glitch Pin Driven Active for Exact Pulse Duration    |
                       |                                                             |
                       |  [ Wire-Speed Mutator ]                                     |
                       |    ├── Mode 00: Trigger Glitch Only                         |
                       |    ├── Mode 01: Substitute matching byte with Replace Byte  |
                       |    └── Mode 10: Invert matching byte (~payload)             |
                       +-------------------------------------------------------------+
                                       |                           |
                                       v                           v
                                Glitch Pin Pulse            Mutated Payload
                              (Target GPIO 0..7)           (o_data / o_tx)
```

### Dedicated Glitch & MitM Control Registers
| Register / Signal | Width | Reset | Description |
| :--- | :--- | :--- | :--- |
| `glitch_pin` | 3 bits | `3'd0` | Target GPIO pin (0..7) driven during glitch pulse |
| `glitch_pol` | 1 bit | `1'b0` | Glitch pulse polarity: `0` = Active High, `1` = Active Low (crowbar) |
| `glitch_armed` | 1 bit | `1'b0` | Arm status: `1` = Glitch engine ready to trigger |
| `glitch_on_match` | 1 bit | `1'b0` | Trigger source: `1` = Auto-trigger on MitM match, `0` = Software trigger |
| `glitch_active` | 1 bit | `1'b0` | Glitch state: `1` when pulse countdown or pulse generation is in progress |
| `glitch_fired` | 1 bit | `1'b0` | Sticky status flag: `1` after glitch pulse completes |
| `glitch_width` | 8 bits | `8'd1` | Duration of glitch pulse in clock cycles (1 to 255) |
| `glitch_delay` | 16 bits | `16'd0` | Countdown delay before pulse asserts (0 to 65,535 clock cycles) |
| `mitm_en` | 1 bit | `1'b0` | Master enable for wire-speed MitM pattern match & mutation |
| `mitm_mode` | 2 bits | `2'b01` | Mutation mode: `00` = Trigger only, `01` = Substitute, `10` = Invert |
| `mitm_match_byte` | 8 bits | `8'h00` | Target pattern byte to match in data stream |
| `mitm_mask` | 8 bits | `8'hFF` | Pattern match bitmask (`1` = compare bit, `0` = wildcard / don't care) |
| `mitm_replace_byte`| 8 bits | `8'h00` | Injected replacement byte when pattern match occurs |
| `mitm_match_found` | 1 bit | `1'b0` | Sticky status flag: `1` when pattern match has occurred |
| `mitm_match_count` | 8 bits | `8'd0` | Total match events detected |

---

## 3. Microcode Instruction Set Architecture (ISA) Extensions

Task 25 adds dedicated instructions and conditional jump flags to microcode under opcode `4'hF` (`ASSIST`) and `4'h8` (`JMP`).

### A. Glitch & MitM Instruction Encodings
| Mnemonic | Encoding | Opcode / Subtype | Description |
| :--- | :--- | :--- | :--- |
| `GLITCH_CFG pin, pol` | `16'b1111_0100_0001_P_POL` | `4'hF` ASSIST `[7:0]=0x10..0x1F` | Configure glitch target pin (0..7) and polarity (0=High, 1=Low) |
| `GLITCH_WIDTH width` | `16'b1111_0100_0010_XXXX` | `4'hF` ASSIST `[7:0]=0x20..0x2F` | Set glitch pulse width (1..15 direct immediate, or `acc`) |
| `GLITCH_ARM mode` | `16'b1111_0100_0000_001M` | `4'hF` ASSIST `[7:0]=0x02..0x03` | Arm glitch generator (`0` = manual/software, `1` = auto-on-match) |
| `GLITCH_DISARM` | `16'b1111_0100_0000_0000` | `4'hF` ASSIST `[7:0]=0x00` | Disarm glitch generator |
| `GLITCH_TRIG` | `16'b1111_0100_0000_0001` | `4'hF` ASSIST `[7:0]=0x01` | Trigger glitch countdown immediately via microcode |
| `GLITCH_DELAY d` | `16'b1111_0100_0101_XXXX` | `4'hF` ASSIST `[7:0]=0x50..0x5F` | Set countdown delay (1..15 direct immediate, or `acc`) |
| `MITM_ENABLE` | `16'b1111_0100_0000_0101` | `4'hF` ASSIST `[7:0]=0x05` | Enable wire-speed MitM pattern match & mutation |
| `MITM_DISABLE` | `16'b1111_0100_0000_0100` | `4'hF` ASSIST `[7:0]=0x04` | Disable MitM engine |
| `MITM_MATCH` | `16'b1111_0100_0110_0000` | `4'hF` ASSIST `[7:0]=0x60` | Load `mitm_match_byte <= acc` |
| `MITM_REPLACE` | `16'b1111_0100_0111_0000` | `4'hF` ASSIST `[7:0]=0x70` | Load `mitm_replace_byte <= acc` |
| `MITM_MASK` | `16'b1111_0100_1000_0000` | `4'hF` ASSIST `[7:0]=0x80` | Load `mitm_mask <= acc` |
| `MITM_CLR` | `16'b1111_0100_0000_0110` | `4'hF` ASSIST `[7:0]=0x06` | Clear `mitm_match_found` and reset match counter |

### B. Conditional Branches (`JMP`)
| Mnemonic | Condition Code | Branch Condition | Description |
| :--- | :--- | :--- | :--- |
| `JMP GLITCH_DONE, target`| `4'hC` | `glitch_fired == 1` | Branch when glitch pulse has completed |
| `JMP MATCH_FOUND, target`| `4'hD` | `mitm_match_found == 1` | Branch when MitM pattern match has been detected |

---

## 4. Wishbone B4 Host Integration

Host software accesses the Glitch & MitM engine via Wishbone 32-bit register `ADDR_GLITCH`:

| Offset | Name | Type | Reset | Description |
| :--- | :--- | :--- | :--- | :--- |
| `0x24` | `ADDR_GLITCH` | RO / Telemetry | `32'h00000000` | Hardware glitch status and telemetry word |

### Bitfield Definitions
- `[31:24]`: `mitm_match_count[7:0]` — Total pattern match events detected.
- `[23:16]`: `glitch_timer[7:0]` — Current countdown timer lower byte (0 when idle).
- `[15:8]` : `mitm_replace_byte[7:0]` — Configured replacement byte.
- `[7]`    : `glitch_fired` — Sticky flag indicating glitch pulse completed.
- `[6]`    : `mitm_match_found` — Sticky flag indicating pattern match detected.
- `[5]`    : `glitch_armed` — Glitch generator armed state.
- `[4]`    : `glitch_active` — Glitch countdown or pulse active.
- `[3]`    : `glitch_pol` — Active polarity (`0` = High, `1` = Low crowbar).
- `[2:0]`  : `glitch_pin[2:0]` — Target GPIO pin index (0..7).

---

## 5. Verification & Simulation Results

Comprehensive verification was performed using Icarus Verilog and Cocotb in WSL:

```
==================================================================================================================
** TEST                                              STATUS  SIM TIME (ns)  REAL TIME (s)  RATIO (ns/s) **
==================================================================================================================
** testbench.test_glitch_pattern_match_trigger        PASS        1980.00           0.01     148129.32  **
** testbench.test_mitm_wire_speed_byte_substitution   PASS       15360.00           0.04     378522.38  **
** testbench.test_glitch_manual_software_trigger      PASS        1160.00           0.01     206274.33  **
==================================================================================================================
** TESTS=75 PASS=75 FAIL=0 SKIP=0                              6793490.07          13.45     505059.51  **
==================================================================================================================
```

Wishbone wrapper verification (`OmniBus_Wishbone`):
```
============================================================================================
** TEST                                STATUS  SIM TIME (ns)  REAL TIME (s)  RATIO (ns/s) **
============================================================================================
** testbench.test_wb_reg_access         PASS         520.00           0.02      20940.71  **
** testbench.test_wb_imem_programming   PASS         640.00           0.00     215195.97  **
** testbench.test_wb_tx_streaming       PASS        2500.00           0.01     246735.38  **
** testbench.test_wb_rx_streaming       PASS        9060.00           0.02     542498.53  **
** testbench.test_wb_irq_watermarks     PASS         480.00           0.00     204579.40  **
** testbench.test_wb_imem_banking       PASS        1460.00           0.00     310925.81  **
** testbench.test_wb_glitch_telemetry   PASS        1040.00           0.00     246835.45  **
============================================================================================
** TESTS=7 PASS=7 FAIL=0 SKIP=0                    15700.01           0.10     158665.82  **
============================================================================================
```

**Total Regression Suite: 82 / 82 tests passing (100% pass rate, 0 regressions)**.

---

## 6. Example Usage & Demo

Assembly example: [`examples/glitch_fault_demo.asm`](examples/glitch_fault_demo.asm)
- Sets up Glitch Generator on Pin 4 with active-Low crowbar polarity, width = 5 cycles, delay = 10 cycles.
- Sets up MitM pattern match for `0xA5`, mask `0xFF`, replacement byte `0x55`.
- Arms Glitch Generator to fire automatically on pattern match.
- Runs full-duplex UART echo loop; upon receiving `0xA5`, the byte is substituted with `0x55` on-the-fly and the glitch pulse fires with exact single-cycle determinism.

Run the demo via batch script:
```cmd
run_glitch_demo.bat sim      # Run simulation test suite
run_glitch_demo.bat glitch   # Assemble and load demo into OmniBus IMEM
```
