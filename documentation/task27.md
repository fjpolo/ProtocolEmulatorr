# Task 27: The Protocol Detective (Autonomous Waveform Profiler & Auto-Baud Engine)

## 1. Executive Summary

**The Protocol Detective** equips the OmniBus with an autonomous, zero-knowledge hardware waveform profiling engine. Without prior knowledge of incoming signals or baud rates, OmniBus passively characterizes physical line dynamics in real time:
- **16-bit transition timer running at 50 MHz (20 ns resolution)** tracks $t_{\min\_high}$, $t_{\min\_low}$, and the fundamental bit period $t_{\min}$ (which directly maps to the runtime auto-baud divisor).
- **Bus Idle State Discriminator** distinguishes between Idle-High (e.g., UART, I2C, 1-Wire) and Idle-Low (e.g., Return-to-Zero, SPI, custom PWM) lines.
- **Clock vs. Data Duty-Cycle Symmetry Discriminator** detects whether an unknown waveform is a periodic clock or asynchronous data by comparing high/low pulse symmetry ($t_{\text{high}} \approx t_{\text{low}}$ within 25%) and continuity.
- **Framing Signature Detector** automatically identifies multi-line protocol signatures (I2C START/STOP transitions, UART start/stop frames, 1-Wire reset/presence pulses, and SPI SCK/CS coordination).
- **Configurable Glitch / Noise Filter** discards sub-threshold contact bounce and high-frequency noise spikes (1 to 15 clock cycles).

Both microcode execution (via dedicated `ASSIST` and extended `JMP` opcodes) and host software (via Wishbone B4 slave registers `0x50..0x5C`) have full wire-speed access to the profiler engine.

---

## 2. Hardware Architecture (`rtl/OmniBus_Profiler.v`)

```
               +-------------------------------------------------------+
               |                  OmniBus_Profiler                     |
               |                                                       |
i_gpio[7:0] -->|--+--> [ Pin Selector: i_pin_sel ]                     |
               |  |                   |                                |
               |  |           [ Double-Flop Sync ]                     |
               |  |                   |                                |
               |  |         [ Glitch Rejection Filter ]                |
               |  |          (1..15 cycles threshold)                  |
               |  |                   |                                |
               |  |     +-------------+-------------+                  |
               |  |     |                           |                  |
               |  |  [Pos/Neg Edge]        [16-bit Transition Timer]   |
               |  |     |                           |                  |
               |  |     +--------+------------------+                  |
               |  |              |                                     |
               |  |     [Pulse Width Latch & Min Tracker]              |
               |  |       * t_min_high / t_min_low                     |
               |  |       * t_min (Baud Divisor)                       |
               |  |       * t_max (Idle Timeout)                       |
               |  |              |                                     |
               |  |     +--------+------------------+                  |
               |  |     |                           |                  |
               |  |  [Duty-Cycle Symmetry]  [Signature Detector]       |
               |  |  (is_clock classifier)  * UART (Idle-H + Start)    |
               |  |                         * I2C (START/STOP + SCL)   |
               |  |                         * SPI (SCK + CS_n low)     |
               |  |                         * 1-Wire (Reset > 400 us)  |
               |  |                                                    |
               +--+----------------------------------------------------+
```

### 2.1 First-Edge Synchronization
To prevent partial pulse artifacts caused by arming the engine mid-transmission, the profiler synchronizes on the first observed transition without latching a pulse width. All subsequent pulse widths are strictly measured between valid consecutive physical transitions.

### 2.2 Duty-Cycle & Clock Symmetry Classifier
A signal is classified as a periodic clock (`o_is_clock = 1`) when:
1. At least 6 valid transitions have been observed.
2. Minimum high pulse and minimum low pulse widths match within tolerance:
   $$|t_{\min\_high} - t_{\min\_low}| \le \left(\frac{t_{\min}}{4} + 2\right)$$
3. Maximum observed pulse width does not exceed $1.5 \times t_{\min}$ (preventing asynchronous data with long steady-state runs or idle stretches from being classified as a clock).

---

## 3. Microcode ISA Extensions

The OmniBus deterministic execution engine integrates four control instructions, two conditional branch flags, and four telemetry read sources:

### 3.1 Control Instructions

| Mnemonic | Opcode (Hex) | Description |
|:---|:---:|:---|
| `PROFILER_CFG <pin> [, <filter>]` | `0xF490` | Assigns target GPIO pin (0..7) and optional glitch filter threshold |
| `PROFILER_FILTER <cycles>` | `0xF4A0` | Sets digital glitch filter threshold (1..15 clock cycles) |
| `PROFILER_ARM` | `0xF408` | Arms profiler capture engine and snapshots idle polarity |
| `PROFILER_STOP` | `0xF409` | Halts transition counters and freezes statistics |
| `PROFILER_RST` | `0xF40A` | Clears edge counters, min/max pulse latches, and resets states |

### 3.2 Conditional Jumps (`JMP`)

Under opcode `0x8` with extended selector bit `instr[7] = 1`:
- `JMP PROFILER_DONE, <target>` (`cond = 0xE`): Branches if profiler has converged on stable $t_{\min}$ measurement.
- `JMP PROFILER_CLOCK, <target>` (`cond = 0xF`): Branches if monitored line is classified as a symmetrical periodic clock.

### 3.3 Telemetry Read (`ASSIST READ`)

Under opcode `0xF` (`instr[11:10] = 2'b10`, `instr[9:8] = 2'b11`, `instr[7] = 1'b1`):
- `ASSIST READ, PROFILER_TMIN_L` (`instr[6:5] = 00`): Loads accumulator with low byte of minimum pulse width ($t_{\min}[7:0]$).
- `ASSIST READ, PROFILER_TMIN_H` (`instr[6:5] = 01`): Loads accumulator with high byte of minimum pulse width ($t_{\min}[15:8]$).
- `ASSIST READ, PROFILER_STATUS` (`instr[6:5] = 10`): Loads accumulator with `{busy, done, idle_pol, is_clock, proto_id[3:0]}`.
- `ASSIST READ, PROFILER_EDGES` (`instr[6:5] = 11`): Loads accumulator with total observed valid edge count ($0..255$).

---

## 4. Wishbone B4 Slave Memory Map (`rtl/OmniBus_Wishbone.v`)

Host CPUs and SoC bus masters can configure and read the profiler directly over the 32-bit Wishbone B4 interface:

| Address | Register Name | Access | Bit Field Definitions |
|:---:|:---|:---:|:---|
| `0x50` | `ADDR_PROFILER_CTRL` | RW | `[2:0]`: Target GPIO Pin Select (0..7)<br>`[6:3]`: Glitch Filter Rejection Threshold (1..15 cycles)<br>`[8]`: Arm strobe (self-clearing)<br>`[9]`: Stop strobe (self-clearing)<br>`[10]`: Reset strobe (self-clearing)<br>`[11]`: Interrupt Enable on Profiler Done |
| `0x54` | `ADDR_PROFILER_STATUS` | RO | `[0]`: Busy (engine capturing)<br>`[1]`: Done (converged)<br>`[2]`: Idle Polarity (0=Low, 1=High)<br>`[3]`: Is Clock (1=periodic clock)<br>`[7:4]`: Protocol ID (`0`=Unknown, `1`=UART, `2`=I2C, `3`=SPI, `4`=1-Wire)<br>`[15:8]`: Total Edge Count (0..255)<br>`[31:16]`: Reserved (0) |
| `0x58` | `ADDR_PROFILER_TMIN` | RO | `[15:0]`: Fundamental Bit Period / Baud Divisor ($t_{\min}$)<br>`[31:16]`: Maximum Observed Pulse Width ($t_{\max}$) |
| `0x5C` | `ADDR_PROFILER_PERIOD` | RO | `[15:0]`: Minimum High Pulse Width ($t_{\min\_high}$)<br>`[31:16]`: Minimum Low Pulse Width ($t_{\min\_low}$) |

Host interrupt `o_irq` asserts automatically when `reg_profiler_irq_en` is set and `profiler_done` transitions active.

---

## 5. Verification & Test Suite

The feature is validated across multiple layers with 100% pass rates:

1. **`test_profiler_autobaud_uart`**:
   - Stimulates UART frames at unknown baud rates on Pin 0.
   - Verifies idle polarity detection (High), bit period discovery ($t_{\min} = 100$ cycles $\pm 1$ cycle), non-clock classification, and `PROTO_UART` detection.
   - Verifies microcode branching via `JMP PROFILER_DONE` and telemetry retrieval.
2. **`test_profiler_clock_discrimination`**:
   - Stimulates symmetrical 50% square wave (16 cycles high, 16 cycles low).
   - Verifies clock classification (`o_is_clock = 1`), $t_{\min} = 16$ cycles, and branch execution via `JMP PROFILER_CLOCK`.
3. **`test_profiler_i2c_signature`**:
   - Stimulates I2C START and STOP conditions across SDA (Pin 4) and SCL (Pin 1).
   - Verifies detection of `PROTO_I2C` (ID 2) and coordination with SCL clock toggles.
4. **`test_wb_profiler_registers`**:
   - Performs Wishbone 32-bit register read/write tests at `0x50`, `0x54`, `0x58`, `0x5C`.
   - Validates live pulse characterization, edge counter accumulation, and stop/reset controls.

Run simulation via:
```cmd
.\scripts\run_profiler.bat sim
```

---

## 6. Interactive Hardware Demo

An interactive assembly program (`examples/profiler_autobaud_demo.asm`) demonstrates autonomous line characterization and live echo:
- Automatically loads into IMEM and launches an interactive serial console.
- Characterizes incoming signals and prints detected framing (`[DATA]` or `[CLOCK]`), baud timing, and edge count.
- Echoes incoming serial traffic in real time using the discovered baud rate divisor.

Launch via:
```cmd
.\scripts\run_profiler.bat
```
