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
; --- Function: glitch_arm ---
glitch_arm:
GLITCH_ARM
RET
main:
GLITCH_CFG 5
GLITCH_ARM
MITM_MATCH 159
MITM_REPLACE 239
MITM_ENABLE
lbl_while_start_1:
IN 8 [0]
JMP I2C_ADDR_MATCH, lbl_then_4
lbl_then_4:
PUSH BLOCK
lbl_endif_3:
JMP lbl_while_start_1
lbl_while_end_2:
