; ==============================================================================
; OmniBus Microcode — Compiled by Omni-C (omnibus-cc)
; Target Architecture: OmniBus 16-bit Deterministic Protocol Engine
; ==============================================================================
.clock 50000000
.const NUM_CORES 2
.const DEFAULT_IMEM_SIZE 128
.const DEFAULT_FIFO_DEPTH 16
.const DEFAULT_BAUD_DIV 433
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
; --- Function: uart_tx_byte ---
uart_tx_byte:
SET 0, 0 [$BAUD]
OUT 8 [$BAUD]
SET 0, 1 [$BAUD]
RET
uart_rx_byte:
WAIT 1, 0 [0]
NOP [$HBAUD]
IN 8 [$BAUD]
RET
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
core0_uart_rx:
PINMAP tx=0, rx=3, sck=1, cs=2
lbl_while_start_1:
WAIT 1, 0 [$HBAUD]
NOP [$BAUD]
CALL uart_rx_byte
WAIT 1, 1 [0]
lbl_while_start_3:
JMP JZ lbl_while_end_4
JMP lbl_while_start_3
lbl_while_end_4:
MOV acc, isr
MB_WRITE 0
SPINLOCK_REL 0
JMP lbl_while_start_1
lbl_while_end_2:
RET
core1_spi_tx:
PINMAP tx=4, rx=7, sck=5, cs=6
lbl_while_start_5:
lbl_while_start_7:
JMP JZ lbl_while_end_8
JMP lbl_while_start_7
lbl_while_end_8:
MB_READ 0
MOV r7, acc
SPINLOCK_REL 0
SET 3, 0 [4]
OUT SCK, 8 [4]
SET 3, 1 [4]
NOP [0x0A]
JMP lbl_while_start_5
lbl_while_end_6:
RET
