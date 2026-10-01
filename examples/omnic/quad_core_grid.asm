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
.const SPI_CLK_DELAY 2
; --- Function: spi_init ---
spi_init:
PINMAP tx=0, rx=1, sck=2, cs=3
SET 3, 1 [5]
SET 2, 0 [5]
RET
spi_select:
SET 3, 0 [5]
RET
spi_deselect:
SET 3, 1 [5]
RET
spi_transfer_byte:
OUT SCK, 8 [2]
RET
core0_ingress:
MOV acc, 0 ; local k
MOV r7, acc
lbl_while_start_1:
MOV acc, r7
CMP 8
JMP JNC lbl_while_end_2
BARRIER_WAIT
PULL BLOCK
PUSH BLOCK
BARRIER_WAIT
INC r7
JMP lbl_while_start_1
lbl_while_end_2:
lbl_while_start_3:
NOP [0x0A]
JMP lbl_while_start_3
lbl_while_end_4:
RET
core1_crypto:
MOV acc, 0 ; local k
MOV r7, acc
lbl_while_start_5:
MOV acc, r7
CMP 8
JMP JNC lbl_while_end_6
BARRIER_WAIT
PULL BLOCK
MOV acc, osr
XOR 0xAA
MOV r7, acc
lbl_while_start_7:
JMP JZ lbl_while_end_8
JMP lbl_while_start_7
lbl_while_end_8:
MOV acc, r7
MB_WRITE 2
SPINLOCK_REL 2
BARRIER_WAIT
INC r7
JMP lbl_while_start_5
lbl_while_end_6:
lbl_while_start_9:
NOP [0x0A]
JMP lbl_while_start_9
lbl_while_end_10:
RET
core2_forward:
MOV acc, 0 ; local k
MOV r7, acc
lbl_while_start_11:
MOV acc, r7
CMP 8
JMP JNC lbl_while_end_12
BARRIER_WAIT
lbl_while_start_13:
JMP JZ lbl_while_end_14
JMP lbl_while_start_13
lbl_while_end_14:
MB_READ 2
MOV r7, acc
SPINLOCK_REL 2
MOV acc, r7
NOT
MOV r7, acc
lbl_while_start_15:
JMP JZ lbl_while_end_16
JMP lbl_while_start_15
lbl_while_end_16:
MOV acc, r7
MB_WRITE 3
SPINLOCK_REL 3
BARRIER_WAIT
INC r7
JMP lbl_while_start_11
lbl_while_end_12:
lbl_while_start_17:
NOP [0x0A]
JMP lbl_while_start_17
lbl_while_end_18:
RET
core3_egress:
PINMAP tx=4, rx=7, sck=5, cs=6
MOV acc, 0 ; local k
MOV r7, acc
lbl_while_start_19:
MOV acc, r7
CMP 8
JMP JNC lbl_while_end_20
BARRIER_WAIT
lbl_while_start_21:
JMP JZ lbl_while_end_22
JMP lbl_while_start_21
lbl_while_end_22:
MB_READ 3
MOV r7, acc
SPINLOCK_REL 3
SET 3, 0 [2]
OUT SCK, 8 [2]
SET 3, 1 [2]
PUSH BLOCK
BARRIER_WAIT
INC r7
JMP lbl_while_start_19
lbl_while_end_20:
lbl_while_start_23:
NOP [0x0A]
JMP lbl_while_start_23
lbl_while_end_24:
RET
