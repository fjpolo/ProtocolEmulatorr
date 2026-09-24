# Task 18 — Asymmetric Single-Wire & Retro Physical Protocol Accelerators (WS2812B NeoPixel, N64/GC Joybus, & NES/SNES Gamepad)

## 1. Overview & Motivation

High-speed single-wire and retro synchronous bus protocols present unique physical-layer constraints:
1. **WS2812B / NeoPixel (800 kHz Single-Wire Asymmetric Pulse)**:
   - Encodes logic `'0'` as a short active-high pulse (~400 ns) followed by a long low rest period (~850 ns).
   - Encodes logic `'1'` as a long active-high pulse (~800 ns) followed by a short low rest period (~450 ns).
   - Microsecond reset latch (>50 µs low).
   - Requires strict sub-microsecond timing precision and MSB-first streaming for 24-bit GRB pixel frames.
2. **Nintendo N64 / GameCube Joybus (250 kHz Single-Wire Bi-directional Bus)**:
   - Single-wire open-drain bus with pull-up resistor.
   - Encodes logic `'0'` as 3 µs low + 1 µs high.
   - Encodes logic `'1'` as 1 µs low + 3 µs high.
   - Stop bit: 1 µs low + bus release high.
   - Transmitted LSB-first.
3. **Nintendo Entertainment System (NES) & Super Nintendo (SNES) Gamepad Controller Bus**:
   - Synchronous shift register interface using 3 pins: `LATCH` (CS), `CLOCK` (SCK), and `DATA` (RX, active-low serial stream).
   - NES: Host issues a ~12 µs LATCH pulse, followed by 8 clock cycles reading A, B, SELECT, START, UP, DOWN, LEFT, RIGHT.
   - SNES: Host issues a LATCH pulse followed by 16 clock cycles reading B, Y, SELECT, START, UP, DOWN, LEFT, RIGHT, A, X, L, R, plus 4 signature bits.

Attempting to bit-bang these timing-critical protocols using pure microcode instructions consumes high instruction overhead and jitter. **Task 18 extends the Protocol Emulator with autonomous physical-layer accelerators for asymmetric single-wire pulse serialization and retro gamepad host sampling.**

---

## 2. Hardware Architecture & Register Specification

### A. Asymmetric Single-Wire Pulse Serializer (`OUT`)
The serializer operates as a two-phase state machine triggered by opcode `0x1` (`OUT`):
- **Phase 0 (Active Duration)**: Drives `tx_pin` to the configured active level (`pulse_polarity ? 1'b0 : 1'b1`) for either `t_act_0` or `t_act_1` clock cycles depending on `cur_pulse_bit` (`pulse_msb_first ? osr[7] : osr[0]`).
- **Phase 1 (Rest Duration)**: Drives `tx_pin` to the rest level (`pulse_polarity ? 1'b1 : 1'b0`) for either `t_rest_0` or `t_rest_1` clock cycles, autonomously shifts the `osr` (left if MSB-first, right if LSB-first), decrements `bit_cnt`, and completes the instruction when all bits are sent.

### B. NES/SNES Gamepad Controller Host Engine (`IN`)
When `pulse_mode == 2'b10`, execution of opcode `0x2` (`IN`) triggers an autonomous hardware sequence:
- **Phase 0 (LATCH Pulse)**: Asserts `cs_pin` (LATCH) high for `t_latch` clock cycles.
- **Phase 1 (Setup Delay)**: Deasserts `cs_pin` low and pauses for `eff_delay` cycles.
- **Phase 2 (Clock High)**: Drives `sck_pin` high for `eff_delay` cycles.
- **Phase 3 (Clock Low & Sample)**: Drives `sck_pin` low, samples `rx_pin` (active-low gamepad buttons inverted to active-high) into `isr[0]` and `pad_shift_reg`, shifts data into `isr`, and loops across 8 (NES) or 16 (SNES) cycles before falling through to `pc + 1`.

### C. Accelerator Registers (`ProtocolEmulator.v`)

| Register | Width | Reset | Description |
| :--- | :--- | :--- | :--- |
| `pulse_mode` | 2 bits | `2'b00` | `00`=Disabled, `01`=Pulse TX (NeoPixel/Joybus), `10`=Gamepad Host (NES/SNES), `11`=Gamepad Device |
| `pulse_polarity` | 1 bit | `1'b0` | `0`=Active High (NeoPixel), `1`=Active Low Open-Drain (Joybus) |
| `pulse_msb_first` | 1 bit | `1'b1` | `1`=MSB-first (NeoPixel), `0`=LSB-first (Joybus) |
| `pulse_phase` | 2 bits | `2'd0` | Internal phase sequencer for 2-phase TX and 4-phase Host RX |
| `t_act_0` | 8 bits | `8'd19` | Active period for bit `'0'` (cycles) |
| `t_rest_0` | 8 bits | `8'd41` | Rest period for bit `'0'` (cycles) |
| `t_act_1` | 8 bits | `8'd39` | Active period for bit `'1'` (cycles) |
| `t_rest_1` | 8 bits | `8'd21` | Rest period for bit `'1'` (cycles) |
| `t_latch` | 8 bits | `8'd20` | Gamepad latch pulse duration (cycles) |
| `pulse_thresh` | 8 bits | `8'd29` | RX pulse width discriminator threshold |
| `pad_snes_16b` | 1 bit | `1'b0` | `0`=8-bit NES mode, `1`=16-bit SNES mode |
| `pad_shift_reg` | 16 bits | `16'h0000` | Full 16-bit shift register storing SNES controller button states |
| `pulse_rx_cnt` | 8 bits | `8'd0` | Pulse cycle width counter |

---

## 3. Instruction Set Architecture Updates

### Opcode `0xF` (`ASSIST`) Extensions

```
15:12 = 4'hF (ASSIST Opcode)
11:10 = Sub-operation:
        2'b00 : ASSIST CFG (Task 17 NRZI/Stuffing)
        2'b01 : ASSIST RESET
        2'b10 : ASSIST READ (instr[9]=0: status, instr[9]=1: pad_shift_reg[15:8])
        2'b11 : Task 18 Pulse & Gamepad Configurations:
                instr[9:8] = 2'b00 : PULSE_CFG
                instr[9:8] = 2'b01 : GAMEPAD_CFG
                instr[9:8] = 2'b10 : PULSE_TIME0
                instr[9:8] = 2'b11 : PULSE_TIME1
```

#### 1. `ASSIST PULSE_CFG [, NEOPIXEL | JOYBUS | MODE=<m>, POL=<p>, DIR=<msb|lsb>]`
- Preset `NEOPIXEL`: Mode=01, Polarity=0 (Active High), MSB-first, $t_{act0}=19, t_{rest0}=41, t_{act1}=39, t_{rest1}=21$.
- Preset `JOYBUS`: Mode=01, Polarity=1 (Active Low OD), LSB-first, $t_{act0}=149, t_{rest0}=49, t_{act1}=49, t_{rest1}=149$.

#### 2. `ASSIST GAMEPAD_CFG, <NES | SNES> [, LATCH=<cycles>]`
- Configures Gamepad Host mode. Sets `pulse_mode <= 2'b10`, `pad_snes_16b <= 1'b0` (NES) or `1'b1` (SNES), and optional latch duration.

#### 3. `ASSIST PULSE_TIME0, <t_act_0>` / `ASSIST PULSE_TIME1, <t_act_1>`
- Allows runtime customization of active timing periods for arbitrary 1-wire pulse protocols.

#### 4. `ASSIST READ, PAD_HIGH`
- Reads upper 8 bits (`pad_shift_reg[15:8]`) into Accumulator `acc` for 16-bit SNES controllers.

---

## 4. Assembler Support (`omnibus_asm.py`)

The assembler supports high-level syntax with hardware presets:
```asm
; NeoPixel Configuration
ASSIST PULSE_CFG, NEOPIXEL

; Joybus Configuration
ASSIST PULSE_CFG, JOYBUS

; NES Gamepad Configuration
ASSIST GAMEPAD_CFG, NES, LATCH=25

; SNES Gamepad Configuration
ASSIST GAMEPAD_CFG, SNES, LATCH=30

; Read high byte of SNES controller
ASSIST READ, PAD_HIGH
```

---

## 5. Verification & Test Suite

### A. Cocotb Simulation Test Suite (`testbench.py`)
5 dedicated test cases added to `testbench.py` bringing the total suite to **48 passed tests**:
1. `test_pulse_neopixel_tx`: Verifies exact bit 0 (20h/42l) and bit 1 (40h/22l) pulse cycle counts at 50 MHz.
2. `test_pulse_neopixel_rgb_frame`: Transmits a full 24-bit GRB frame (Green=0x55, Red=0xAA, Blue=0x33) with bit-accurate verification.
3. `test_pulse_joybus_tx`: Verifies N64/GC open-drain 250 kHz 3 µs / 1 µs pulses and LSB-first serialization.
4. `test_gamepad_nes_host_read`: Verifies autonomous LATCH pulse generation and 8-bit sampling of NES controller buttons (`0xA5`).
5. `test_gamepad_snes_host_read`: Verifies autonomous LATCH pulse, 16 clock bursts, lower byte in `ISR`, and upper byte in `pad_shift_reg` (`0xCAFE`).

### B. Formal Verification (`SymbiYosys`)
Formal safety invariants in `properties.v` verified via `test_alu.bat formal` covering BMC (`bound`), k-induction (`prf`), and reachability cover (`cvr`).
