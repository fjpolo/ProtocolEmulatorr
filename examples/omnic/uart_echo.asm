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
main:
PINMAP tx=0, rx=1, sck=2, cs=3
SET 0, 1 [0]
lbl_while_start_1:
PULL BLOCK
CALL uart_tx_byte
CALL uart_rx_byte
PUSH BLOCK
JMP lbl_while_start_1
lbl_while_end_2:
