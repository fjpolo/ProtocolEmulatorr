# Task 29: On-Chip Self-Play & Virtual Crossbar (BIST Engine)

## 1. Architectural Context & Motivation

In strict adherence to **Feature 5 of [`documentation/CONCEPT.md`](file:///c:/Workspace/ASIC/ProtocolEmulator/documentation/CONCEPT.md#L77)**:
> *"To verify the chip on real silicon after fabrication, OmniBus includes an **Internal Virtual Crossbar**:*
> *- Channel A (Master) communicates directly with Channel B (Slave) inside the silicon.*
> *- OmniBus runs autonomous regression suites on itself: Channel A transmits corner-case packets (with jitter, noise, and corrupted parity) while Channel B attempts recovery, outputting real-time verification scores on the onboard status LEDs."*

Rather than introducing bulky, rigid, hardwired protocol controllers (which would inflate the ASIC area beyond the Tiny Tapeout 6×4 tile budget of ~20k–25k gates), Task 29 completes the core promise of the OmniBus architecture by adding an ultralight **On-Chip Self-Play Built-In Self-Test (BIST) Engine** with an **Internal Virtual Crossbar**.

With this engine, silicon can be fully tested and diagnosed on a breadboard without external logic analyzers, oscilloscopes, or host PCs.

---

## 2. Hardware Architecture

```
                      +-------------------------------------------------------+
                      |               OmniBus Virtual Crossbar                |
                      |                                                       |
i_gpio[7:0] --------->|---\                                                   |
                      |    |--> [ MUX: bist_en ] ------> eff_gpio_src[7:0]    |
o_gpio[7:0] --------->|---/         |                            |            |
                      |             +---> [ Crossbar Modes ]     v            |
                      |                     0: Direct Loopback   Core Inputs  |
                      |                     1: Split Ch A <-> B  (gpio_raw)   |
                      |                     2: Jitter / Glitch                |
                      |                                                       |
                      |  +-------------------------------------------------+  |
                      |  |            BIST Hardware Scoring Engine         |  |
                      |  |  * Vector Counter (16-bit)                      |  |
                      |  |  * Pass Counter   (16-bit)                      |  |
                      |  |  * Error Counter  (16-bit, Sticky Fail)         |  |
                      |  |  * Real-Time LED Score Output                   |  |
                      |  +-------------------------------------------------+  |
                      +-------------------------------------------------------+
```

### 2.1 Virtual Crossbar Routing Modes
The virtual crossbar multiplexer redirects internal input lines before the 2-stage synchronizer (`gpio_raw`):

1. **Pass-Through Mode (`bist_mode = 00` / `bist_en = 0`)**:
   Core inputs connect to external physical package pins `i_gpio`.
2. **Direct Self-Loopback (`bist_mode = 01`)**:
   Output pin $P$ loops back directly to input pin $P$ (`eff_gpio_src[P] = o_gpio[P]`). Allows the microcode engine to verify its own pin drivers and serializers without external wiring.
3. **Split Dual-Channel Crossbar (`bist_mode = 10`)**:
   Partitions the 8 GPIO pins into two isolated virtual channels:
   - **Channel A (Master)**: Pins 0..3 (TX/MOSI=0, RX/MISO=1, SCK=2, CS_n=3).
   - **Channel B (Slave)**: Pins 4..7 (RX/MOSI=4, TX/MISO=5, SCK=6, CS_n=7).
   - Cross-connection matrix:
     - `eff_gpio_src[4] = o_gpio[0]` (Ch A Master TX $\to$ Ch B Slave RX)
     - `eff_gpio_src[1] = o_gpio[5]` (Ch B Slave TX $\to$ Ch A Master RX)
     - `eff_gpio_src[6] = o_gpio[2]` (Ch A Master SCK $\to$ Ch B Slave SCK)
     - `eff_gpio_src[7] = o_gpio[3]` (Ch A Master CS_n $\to$ Ch B Slave CS_n)
4. **Jitter / Stress Injection Mode (`bist_mode = 11` or `bist_jitter_en = 1`)**:
   Uses an internal 8-bit pseudo-random LFSR ($x^8 + x^6 + x^5 + x^4 + 1$) to randomly invert bit levels during loopback on selected clock cycles, deliberately introducing bit-stuffing violations, Manchester phase errors, and CRC corruptions to stress autonomous error-recovery routines.

### 2.2 Hardware BIST Scoring Engine
- **Vector Counter (`bist_vec_cnt`)**: Incremented on each `BIST_PASS` or `BIST_FAIL` assertion.
- **Pass Counter (`bist_pass_cnt`)**: Incremented on each `BIST_PASS` instruction.
- **Fail Counter (`bist_fail_cnt`)**: Incremented on each `BIST_FAIL` instruction.
- **Sticky Fail Flag (`bist_fail_flag`)**: Set to `1` upon the first failure; persists until `BIST_RST`.
- **Stage Register (`bist_stage`)**: 4-bit test stage index (0..15) configured by `BIST_STAGE <n>`.

### 2.3 Real-Time Visual LED Telemetry (Tang Console 60K)
When `bist_active` is asserted, the onboard 8 status LEDs dynamically switch from normal peripheral display to the BIST telemetry visualizer:
- **LED 7**: Sticky Error Flag (Red / Fail indicator; stays `1` if any test fails)
- **LED 6..4**: Current Test Stage Index (`bist_stage[2:0]`, values 1..7)
- **LED 3**: BIST Engine Active Heartbeat
- **LED 2..0**: Internal Virtual Crossbar activity (live pin toggle states)

---

## 3. Microcode Instruction Set Architecture (ISA)

### 3.1 BIST Opcodes (`instr[15:12] = 0xF`, `instr[11:10] = 01b`, `instr[9:8] = 00b`, `instr[7:4] = 0xEh / 0xFh`)

| Instruction | Hex Encoding | Operands | Description |
|:---|:---:|:---:|:---|
| `BIST_DIS` | `0xF4E0` | None | Disable BIST, return crossbar to external pass-through mode |
| `BIST_LOOP` | `0xF4E1` | None | Enable direct pin loopback mode (`o_gpio[p] -> core_in[p]`) |
| `BIST_SPLIT` | `0xF4E2` | None | Enable Split Dual-Channel crossbar (Ch A 0..3 $\leftrightarrow$ Ch B 4..7) |
| `BIST_JITTER` | `0xF4E3` | None | Enable pseudo-random jitter / stress injection mode |
| `BIST_START` | `0xF4E4` | None | Start BIST engine and latch active telemetry |
| `BIST_STOP` | `0xF4E5` | None | Halt BIST engine |
| `BIST_RST` | `0xF4E6` | None | Clear vector, pass, fail counters and reset sticky fail flag |
| `BIST_PASS` | `0xF4E7` | None | Hardware assertion pass (increments pass & vector counters) |
| `BIST_FAIL` | `0xF4E8` | None | Hardware assertion fail (increments fail & vector counters, sets fail flag) |
| `BIST_STAGE <n>` | `0xF4F0 + n` | `0..15` | Load 4-bit test stage index into `bist_stage` |
| `BIST_CFG <mode>` | `0xF4E0 + mode` | `0..3` | Set crossbar mode (0=dis, 1=loop, 2=split, 3=jitter) |

### 3.2 Microcode `ASSIST READ` Telemetry

Reading BIST telemetry into `acc`, `isr`, and `o_data`:

| Instruction | Hex Encoding | Data Returned | Description |
|:---|:---:|:---|:---|
| `ASSIST READ, BIST_STATUS` | `0xFB08` | `{bist_active, bist_fail_flag, bist_mode[1:0], bist_stage[3:0]}` | BIST status, error flag, mode, and current stage |
| `ASSIST READ, BIST_PASS` | `0xFB09` | `bist_pass_cnt[7:0]` | Lower 8 bits of hardware pass counter |
| `ASSIST READ, BIST_FAIL` | `0xFB0A` | `bist_fail_cnt[7:0]` | Lower 8 bits of hardware fail counter |
| `ASSIST READ, BIST_VEC` | `0xFB0B` | `bist_vec_cnt[7:0]` | Lower 8 bits of total vector / assertion counter |

---

## 4. Wishbone B4 Slave Memory Map

The BIST subsystem is memory-mapped into the Wishbone B4 address space at offsets `0x70`..`0x78`:

| Address | Name | Access | Bit Fields |
|:---:|:---|:---:|:---|
| `0x70` | `ADDR_BIST_CTRL` | RW | `[1:0]`: mode (0=dis, 1=loop, 2=split, 3=jitter)<br>`[2]`: jitter_en<br>`[3]`: bist_en<br>`[4]`: start strobe<br>`[5]`: stop strobe<br>`[6]`: rst strobe<br>`[11:8]`: stage index |
| `0x74` | `ADDR_BIST_STATUS` | RO | `[0]`: bist_active<br>`[1]`: bist_fail_flag (sticky)<br>`[3:2]`: bist_mode<br>`[7:4]`: bist_stage<br>`[23:8]`: bist_fail_cnt (16-bit) |
| `0x78` | `ADDR_BIST_SCORES` | RO | `[15:0]`: bist_vec_cnt (16-bit total vectors)<br>`[31:16]`: bist_pass_cnt (16-bit total passes) |

---

## 5. Verification & Test Coverage

Full automated test suite executed via WSL (Icarus Verilog + Cocotb):

- `test_bist_virtual_crossbar_direct`: Tests internal direct pin loopback without any external pin toggling.
- `test_bist_channel_split_crossbar`: Tests Channel A transmitting to Channel B across the internal crossbar.
- `test_bist_error_scoring_and_reset`: Tests hardware assertion failure scoring, sticky flag, and zeroing on reset.
- `test_wb_bist_registers`: Tests Wishbone slave register configuration, mode switching, and telemetry readback.

### Full Regression Suite:
```
====================================================================================================
TESTS=84 PASS=84 FAIL=0 SKIP=0  (ProtocolEmulator Core & Hardware Assists)
TESTS=14 PASS=14 FAIL=0 SKIP=0  (OmniBus Wishbone SoC Subsystem)
TOTAL: 98 PASS / 0 FAIL (100% Passing Rate)
====================================================================================================
```

---

## 6. Execution on Physical Hardware

To run the autonomous self-play BIST on the Sipeed Tang Console 60K:

```cmd
scripts\run_bist.bat run
```

This compiles [`examples/bist_self_play.asm`](file:///c:/Workspace/ASIC/ProtocolEmulator/examples/bist_self_play.asm) and flashes it directly into the FPGA instruction memory. The chip immediately starts self-testing, sequencing through Stage 1 (ALU), Stage 2 (Direct Loopback), Stage 3 (Split Crossbar), and Stage 4 (Heartbeat), displaying real-time pass/fail status on the onboard LEDs.
