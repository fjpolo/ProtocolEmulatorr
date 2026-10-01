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
; --- Function: onewire_init ---
onewire_init:
CFG_OD 1
SET 0, 1 [0x32]
RET
onewire_reset:
SET 0, 0 [0x5DC0]
SET 0, 1 [0xDAC]
WAIT 0, 0 [0x1388]
SET 0, 1 [0x4E20]
RET
onewire_write_1:
SET 0, 0 [0x12C]
SET 0, 1 [0xC80]
RET
onewire_write_0:
SET 0, 0 [0xBB8]
SET 0, 1 [0x1F4]
RET
main:
CALL onewire_init
lbl_while_start_1:
PULL BLOCK
SET 0, 0 [0x61A8]
SET 0, 1 [0x7D0]
WAIT 0, 0 [0x1388]
WAIT 0, 1 [0x1388]
WAIT 0, 0 [0x1388]
SET_LC LC0, 5
lbl_loop_lc0_3:
SET_LC LC1, 8
lbl_loop_lc1_5:
WAIT 0, 0 [0xFA0]
WAIT 0, 1 [0xFA0]
NOP [0x7D0]
IN 1 [0]
DJNZ LC1, lbl_loop_lc1_5
lbl_end_lc1_6:
PUSH BLOCK
DJNZ LC0, lbl_loop_lc0_3
lbl_end_lc0_4:
SET 0, 1 [0x1388]
JMP lbl_while_start_1
lbl_while_end_2:
