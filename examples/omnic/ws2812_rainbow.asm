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
; --- Function: ws2812_init ---
ws2812_init:
PULSE_CFG 0
PULSE_TIME0 0x11, 0x28
PULSE_TIME1 0x23, 0x1E
SET 0, 0 [0x0A]
RET
ws2812_reset:
SET 0, 0 [0x9C4]
RET
main:
CALL ws2812_init
lbl_while_start_1:
CALL ws2812_reset
SET_LC LC0, 8
lbl_loop_lc0_3:
PULL BLOCK
OUT 8 [0]
PULL BLOCK
OUT 8 [0]
PULL BLOCK
OUT 8 [0]
DJNZ LC0, lbl_loop_lc0_3
lbl_end_lc0_4:
JMP lbl_while_start_1
lbl_while_end_2:
