; ==============================================================================
; OmniBus Microcode — Compiled by Omni-C (omnibus-cc)
; Target Architecture: OmniBus 16-bit Deterministic Protocol Engine
; ==============================================================================
.clock 50000000
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
.core 0
; --- Function: core0_producer ---
core0_producer:
MOV acc, 0 ; local i
MOV r7, acc
lbl_while_start_1:
MOV acc, r7
CMP 4
JMP JNC lbl_while_end_2
BARRIER_WAIT
lbl_while_start_3:
JMP JZ lbl_while_end_4
JMP lbl_while_start_3
lbl_while_end_4:
MOV acc, 0x5A
MB_WRITE 0
SPINLOCK_REL 0
lbl_while_start_5:
JMP JZ lbl_while_end_6
JMP lbl_while_start_5
lbl_while_end_6:
MB_READ 1
MOV r7, acc
SPINLOCK_REL 1
PUSH BLOCK
BARRIER_WAIT
INC r7
JMP lbl_while_start_1
lbl_while_end_2:
lbl_while_start_7:
NOP [0x0A]
JMP lbl_while_start_7
lbl_while_end_8:
RET
core1_worker:
MOV acc, 0 ; local j
MOV r7, acc
lbl_while_start_9:
MOV acc, r7
CMP 4
JMP JNC lbl_while_end_10
BARRIER_WAIT
lbl_while_start_11:
JMP JZ lbl_while_end_12
JMP lbl_while_start_11
lbl_while_end_12:
MB_READ 0
MOV r7, acc
SPINLOCK_REL 0
MOV acc, r7
ADD 0x11
MOV r7, acc
lbl_while_start_13:
JMP JZ lbl_while_end_14
JMP lbl_while_start_13
lbl_while_end_14:
MOV acc, r7
MB_WRITE 1
SPINLOCK_REL 1
BARRIER_WAIT
INC r7
JMP lbl_while_start_9
lbl_while_end_10:
lbl_while_start_15:
NOP [0x0A]
JMP lbl_while_start_15
lbl_while_end_16:
RET
