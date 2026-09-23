; =============================================================================
; File        : chiptune_audio_demo.asm
; Description : 1-Bit Delta-Sigma Audio DAC & 4-Voice Chiptune APU Synthesizer Demo
;               Demonstrates Task 22:
;                 - Opcode 0xF: ASSIST AUDIO_CFG, SYNTH, PIN=2, DIFF=1
;                 - Hardware 50 MHz 1st-Order Delta-Sigma (Σ-Δ) PDM Modulator (OSR=1250x)
;                 - 4-Voice Chiptune APU Synthesizer:
;                   * Voice 0: Pulse Wave 1 (50% duty, Arpeggio Lead)
;                   * Voice 1: Pulse Wave 2 (25% duty, Harmony)
;                   * Voice 2: 16-Step Smooth Triangle Wave (Bassline)
;                   * Voice 3: 15-bit Galois LFSR Pseudo-Random Noise (Percussion)
;                 - Hardware Sound Effect Preset Triggering:
;                   * BEEP, BLIP, ERROR, COIN, LASER, SIREN, NOISE
;                 - Single-Cycle Direct PCM DAC Streaming (OUT AUDIO)
; =============================================================================

.clock 50000000
.baud  115200

start:
    ; -------------------------------------------------------------------------
    ; 1. Initialize Delta-Sigma Audio Subsystem
    ;    Mode = SYNTH (4-Voice Chiptune APU), PIN = GPIO 2, DIFF = 1 (BTL on Pin 3)
    ; -------------------------------------------------------------------------
    ASSIST AUDIO_CFG, SYNTH, PIN=2, DIFF=1

    ; Set initial APU voice volumes (0x0..0xF)
    ASSIST AUDIO_VOL, 0xC

    ; Configure Voice 0 (50% duty) and Voice 1 (25% duty)
    ASSIST AUDIO_DUTY, 2, 1

    ; -------------------------------------------------------------------------
    ; 2. Play Retro "COIN" Sound Effect Preset
    ;    (B5 987 Hz -> E6 1318 Hz dual-tone arpeggio)
    ; -------------------------------------------------------------------------
    ASSIST AUDIO_PLAY, COIN
    NOP 200

    ; -------------------------------------------------------------------------
    ; 3. Play Retro "LASER" Sound Effect Preset
    ;    (Fast downward pitch sweep with high resonance)
    ; -------------------------------------------------------------------------
    ASSIST AUDIO_PLAY, LASER
    NOP 250

    ; Stop preset sequencer
    ASSIST AUDIO_STOP

    ; -------------------------------------------------------------------------
    ; 4. Program 4-Voice Polyphonic Chiptune Chord (C-Major: C4 + E4 + G3)
    ;    Voice 0 (Pulse 1, C4 ~ 261.6 Hz): period = 50,000,000 / (16 * 261.6) = 11945 (0x2EA9)
    ;    Voice 1 (Pulse 2, E4 ~ 329.6 Hz): period = 50,000,000 / (16 * 329.6) = 9481 (0x2509)
    ;    Voice 2 (Triangle, C3 ~ 130.8 Hz): period = 50,000,000 / (16 * 130.8) = 23891 (0x5D53)
    ; -------------------------------------------------------------------------

    ; Voice 0: C4 (0x2EA9)
    MOV acc, 0xA9
    ASSIST AUDIO_NOTE_LO, 0
    MOV acc, 0x2E
    ASSIST AUDIO_NOTE_HI, 0

    ; Voice 1: E4 (0x2509)
    MOV acc, 0x09
    ASSIST AUDIO_NOTE_LO, 1
    MOV acc, 0x25
    ASSIST AUDIO_NOTE_HI, 1

    ; Voice 2: C3 Bass Triangle (0x5D53)
    MOV acc, 0x53
    ASSIST AUDIO_NOTE_LO, 2
    MOV acc, 0x5D
    ASSIST AUDIO_NOTE_HI, 2

    ; Voice 3: Periodic Hi-Hat Noise (0x0180)
    MOV acc, 0x80
    ASSIST AUDIO_NOTE_LO, 3
    MOV acc, 0x01
    ASSIST AUDIO_NOTE_HI, 3

    ; Hold chord for brief musical interval
    NOP 500

    ; -------------------------------------------------------------------------
    ; 5. Silence APU voices and Demonstrate Direct PCM Stream (OUT AUDIO)
    ; -------------------------------------------------------------------------
    ASSIST AUDIO_CFG, PCM, PIN=2, DIFF=1

    ; Stream ramp / sine PCM samples directly through Delta-Sigma PDM Modulator
    MOV acc, 0x20
    MOV OSR, acc
    OUT AUDIO

    MOV acc, 0x60
    MOV OSR, acc
    OUT AUDIO

    MOV acc, 0xA0
    MOV OSR, acc
    OUT AUDIO

    MOV acc, 0xE0
    MOV OSR, acc
    OUT AUDIO

    MOV acc, 0x80
    MOV OSR, acc
    OUT AUDIO

    ; Done: Stop audio modulation and loop
    ASSIST AUDIO_STOP
done_loop:
    JMP done_loop
