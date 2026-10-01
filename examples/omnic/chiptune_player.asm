; ==============================================================================
; OmniBus Microcode — Compiled by Omni-C (omnibus-cc)
; Target Architecture: OmniBus 16-bit Deterministic Protocol Engine
; ==============================================================================
.clock 50000000
.entry main
.const PIN_TX 0
.const PIN_RX 1
.const PIN_SCK 2
.const PIN_CS 3
.const PIN_SDA 0
.const PIN_SCL 1
.const PIN_1WIRE 0
.const PIN_PULSE 0
.const PIN_AUDIO 0
.const PIN_GLITCH 5
.const HIGH 1
.const LOW 0
.const HIGH_Z 0
.const NOTE_C4_HI 29
.const NOTE_C4_LO 205
.const NOTE_E4_HI 23
.const NOTE_E4_LO 183
.const NOTE_G4_HI 19
.const NOTE_G4_LO 247
.const NOTE_C5_HI 14
.const NOTE_C5_LO 230
; --- Function: main ---
main:
AUDIO_VOL 0x0C
lbl_while_start_1:
AUDIO_PLAY 29, 205
NOP [0x61A8]
AUDIO_PLAY 23, 183
NOP [0x61A8]
AUDIO_PLAY 19, 247
NOP [0x61A8]
AUDIO_PLAY 14, 230
NOP [0xC350]
AUDIO_STOP
NOP [0x61A8]
JMP lbl_while_start_1
lbl_while_end_2:
