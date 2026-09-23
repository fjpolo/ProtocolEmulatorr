# Task 22 — 1-Bit Delta-Sigma Audio DAC & Chiptune PDM Synthesizer Engine

## 1. Overview & Motivation

Embedded protocol emulation, industrial interface adapters, and retro computing test fixtures often require audio output capabilities:
1. **Audible diagnostic indicators**: Beeps, clicks, warning alarms, and protocol status indications without requiring bulky external DAC chips or complex I2S codec ICs.
2. **Autonomous retro gaming audio**: Emulating chiptune Sound Synthesizer hardware (such as NES APU, Game Boy, Commodore SID, or arcade sound generators) with multi-voice polyphony directly on general-purpose I/O pins.
3. **High-speed direct PCM audio streaming**: Streaming raw 8-bit PCM audio samples directly from the host FIFO or microcode to an external RC low-pass filter with high dynamic range.

Prior to Task 22, generating high-fidelity audio or polyphonic chiptune music would require 100% CPU/microcode involvement, burning cycles in cycle-counted timing loops and making simultaneous protocol emulation impossible.

**Task 22 integrates a Hardware 1-Bit Delta-Sigma (Σ-Δ) Audio DAC and 4-Voice Chiptune APU Synthesizer Engine** directly into the OmniBus Protocol Emulator:
- **50 MHz 1st-Order Delta-Sigma (Σ-Δ) PDM Modulator**: Runs autonomously at the full system clock rate ($f_{clk} = 50\text{ MHz}$), achieving an oversampling ratio ($OSR$) of $1250\times$ over standard 40 kHz audio bandwidth with first-order high-pass noise shaping.
- **Single-Ended or Differential BTL Output**: Supports driving a single GPIO pin or dual complementary GPIO pins (Bridge-Tied Load) directly into headphones or a speaker via simple passive RC filtering.
- **4-Voice Polyphonic Chiptune APU Synthesizer**:
  - **Voice 0 (Pulse 1)**: 16-bit period divider, 4 selectable duty cycles (12.5%, 25%, 50%, 75%), 4-bit volume control.
  - **Voice 1 (Pulse 2)**: 16-bit period divider, 4 selectable duty cycles (12.5%, 25%, 50%, 75%), 4-bit volume control.
  - **Voice 2 (Triangle)**: 16-step smooth triangle wave generator, 4-bit volume control.
  - **Voice 3 (Noise)**: 15-bit Galois LFSR with 15-bit (smooth white noise) or 7-bit (metallic arcade noise) modes and 4-bit volume control.
- **Digital Saturation-Clamped Mixer**: Sums all 4 voices without numeric overflow or wrap-around distortion ($V_0 + V_1 + V_2 + V_3 \le 255$).
- **Hardware Sound Effect Preset Sequencer**: Fully autonomous multi-step sound effects (`BEEP`, `BLIP`, `ERROR`, `COIN`, `LASER`, `SIREN`, `NOISE`) running in hardware with zero microcode overhead.
- **Serializer Integration**:
  - `OUT AUDIO`: Single-cycle sample load from `osr` into `audio_sample`.
  - `IN AUDIO`: Single-cycle sample capture from `audio_sample` into `isr` and `o_data`.
- **Wishbone Peripheral Interface**: Dedicated `ADDR_AUDIO = 8'h18` register for full host control and telemetry.

---

## 2. Hardware Architecture

```
                                  +-------------------------------------------------------------+
                                  |            OmniBus Delta-Sigma Audio & APU Subsystem        |
                                  |                                                             |
   Microcode / Wishbone ----------> [ Voice 0: Pulse 1 ] (16-bit Period, 4 Duty, Vol 0..15)     |
                                  | [ Voice 1: Pulse 2 ] (16-bit Period, 4 Duty, Vol 0..15)     |
                                  | [ Voice 2: Triangle] (16-Step Step Div, Vol 0..15)          |
                                  | [ Voice 3: LFSR    ] (15-bit Galois LFSR, Vol 0..15)        |
                                  |              |                                              |
                                  |              v                                              |
                                  |      [ 4-Voice Mixer ] (Clamped Sum: Max 255)               |
                                  |              |                                              |
                                  |              +--------------------------+                   |
                                  |                                         |                   |
   OUT AUDIO / Wishbone Sample ---> [ Sample Select Multiplexer ] <---------+                   |
                                  |              |                                              |
                                  |              v                                              |
                                  |  [ 1st-Order Delta-Sigma Modulator ] (50 MHz accumulator)   |
                                  |              |                                              |
                                  |              +------------+                                 |
                                  |                           v                                 |
   GPIO[audio_pin]   <------------+-------------------> [ PDM Out: Bitstream ]                  |
   GPIO[audio_pin^1] <--------------------------------- [ Complementary PDM (BTL) ]            |
                                  +-------------------------------------------------------------+
```

### A. Dedicated Registers & Wires
| Register / Signal | Width | Reset | Description |
| :--- | :--- | :--- | :--- |
| `audio_en` | 1 bit | `1'b0` | Master audio subsystem enable |
| `audio_mode` | 2 bits | `2'd0` | Mode: `00`=Off, `01`=Direct PCM, `10`=Chiptune APU Synth |
| `audio_pin` | 3 bits | `3'd0` | Target GPIO pin (0..7) for PDM output |
| `audio_diff` | 1 bit | `1'b0` | Differential BTL output enable (`audio_pin ^ 1`) |
| `audio_sample` | 8 bits | `8'h80` | Direct PCM 8-bit unsigned sample (128 = silence) |
| `pdm_acc` | 9 bits | `9'd0` | 1st-order Delta-Sigma error accumulator |
| `pdm_bit` | 1 bit | `1'b0` | Instantaneous 1-bit PDM output pulse |
| `v0_period`, `v1_period` | 16 bits | `16'd0` | Pulse wave oscillator period dividers |
| `v0_duty`, `v1_duty` | 2 bits | `2'd2` | Duty cycles: `00`=12.5%, `01`=25%, `10`=50%, `11`=75% |
| `v0_vol`, `v1_vol` | 4 bits | `4'd0` | Pulse voice amplitudes (0..15) |
| `v2_period` | 16 bits | `16'd0` | Triangle wave oscillator period divider |
| `v2_vol` | 4 bits | `4'd0` | Triangle voice amplitude (0..15) |
| `v3_period` | 16 bits | `16'd0` | Noise oscillator period divider |
| `v3_lfsr` | 15 bits | `15'h7FFF` | Galois LFSR state register ($x^{15} + x^{14} + 1$) |
| `v3_mode` | 1 bit | `1'b0` | Noise mode: `0`=15-bit LFSR, `1`=7-bit LFSR |
| `v3_vol` | 4 bits | `4'd0` | Noise voice amplitude (0..15) |
| `audio_preset` | 4 bits | `4'd0` | Active hardware sound effect preset ID |
| `preset_timer` | 20 bits | `20'd0` | Hardware preset envelope/duration timer |
| `preset_step` | 4 bits | `4'd0` | Preset sequencer step counter |

---

## 3. Instruction Set Architecture (ISA) Extensions

### A. Serializer Extensions (`OUT` / `IN`)
- **`OUT AUDIO` (`0x1F80`)**:
  Latches `osr` directly into `audio_sample`, asserts `audio_en = 1`, selects `audio_mode = 2'b01` (Direct PCM), and advances microcode PC in exactly 1 clock cycle without serial delay.
- **`IN AUDIO` (`0x2F80`)**:
  Captures current `audio_sample` into `isr` and `o_data` in exactly 1 clock cycle.

### B. Microcode `ASSIST` Audio Sub-Operations (Opcode `0xF`)
All audio operations use `instr[15:12] == 4'hF`, with sub-field classification under `instr[8:7] == 2'b11`:

| Assembly Mnemonic | Encoding | Description |
| :--- | :--- | :--- |
| `AUDIO_CFG <mode>, PIN=<pin>, DIFF=<0\|1>` | `0xF180 \| (pin<<2) \| mode` | Configure engine mode (`OFF`, `PCM`, `SYNTH`), target GPIO pin, and BTL differential output. |
| `AUDIO_VOL <vol>` | `0xF190 \| (vol & 0xF)` | Set global volume for all 4 APU voices. |
| `AUDIO_SAMPLE` | `0xF1A0` | Load 8-bit sample into `audio_sample` from accumulator (`acc`). |
| `AUDIO_DUTY <v0_duty>, <v1_duty>` | `0xF1B0 \| (v0<<2) \| v1` | Set Pulse 1 and Pulse 2 duty cycles (`0`=12.5%, `1`=25%, `2`=50%, `3`=75%). |
| `AUDIO_NOTE_LO <voice>` | `0xF1C0 \| (voice & 3)` | Load low 8 bits of frequency divider from accumulator (`acc`) into specified voice (`0`..`3`). |
| `AUDIO_NOTE_HI <voice>` | `0xF1D0 \| (voice & 3)` | Load high 8 bits of frequency divider from accumulator (`acc`) into specified voice (`0`..`3`). |
| `AUDIO_PLAY <preset>` | `0xF1E0 \| (preset & 0xF)` | Start autonomous hardware sound effect preset sequencer (`BEEP`, `BLIP`, `ERROR`, `COIN`, `LASER`, `SIREN`, `NOISE`). |
| `AUDIO_STOP` | `0xF1F0` | Halt active sound effect preset and silence voices. |

---

## 4. Wishbone Register Interface

### `ADDR_AUDIO` (`0x18`)
- **Read/Write Register**:
  - `[0]`: `audio_en` (1 = Audio subsystem enabled)
  - `[2:1]`: `audio_mode` (`00` = Disabled, `01` = Direct PCM, `10` = APU Synth)
  - `[5:3]`: `audio_pin` (GPIO output pin 0..7)
  - `[6]`: `audio_diff` (1 = Enable differential complementary output on `audio_pin ^ 1`)
  - `[14:7]`: `audio_sample` (8-bit PCM direct sample value)
  - `[18:15]`: `audio_preset` (Active preset ID)
  - `[31]`: `pdm_bit` (Real-time monitor of current 1-bit PDM output)

---

## 5. Verification & Testbench Results

All audio features were verified using Cocotb and Icarus Verilog:
1. **`test_audio_pdm_linear_dac`**: Verified Delta-Sigma 1-bit PDM pulse density linearity across 5 static DC levels (`0x00`, `0x40`, `0x80`, `0xC0`, `0xFF`) and complementary differential BTL phase inversion.
2. **`test_audio_out_pcm_streaming`**: Verified single-cycle `OUT AUDIO` streaming directly from host TX FIFO through microcode into the DAC.
3. **`test_audio_chiptune_square_tone`**: Verified APU Voice 0 frequency divider, 50% duty cycle, and 25% duty cycle pulse waveforms.
4. **`test_audio_sound_effect_presets`**: Verified autonomous hardware preset sequencing (`COIN`, `LASER`, `BEEP`) and clean execution of `AUDIO_STOP`.
5. **Full Regression Suite**: All 64 test cases in `testbench.py` passed with 0 failures and 0 regressions (`TESTS=64 PASS=64 FAIL=0 SKIP=0`).
