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
main:
CALL spi_init
CALL spi_select
MOV acc, 0x9F
MOV osr, acc
CALL spi_transfer_byte
SET_LC LC0, 3
lbl_loop_lc0_1:
CALL spi_transfer_byte
PUSH BLOCK
DJNZ LC0, lbl_loop_lc0_1
lbl_end_lc0_2:
CALL spi_deselect
NOP [0x0A]
CALL spi_select
MOV acc, 3
MOV osr, acc
CALL spi_transfer_byte
MOV acc, 0
MOV osr, acc
CALL spi_transfer_byte
CALL spi_transfer_byte
CALL spi_transfer_byte
SET_LC LC0, 0x10
lbl_loop_lc0_3:
CALL spi_transfer_byte
PUSH BLOCK
DJNZ LC0, lbl_loop_lc0_3
lbl_end_lc0_4:
CALL spi_deselect
