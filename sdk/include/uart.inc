; ==============================================================================
; File        : uart.inc
; Description : OmniBus Assembly Standard Header for UART Communications
; License     : MIT License
; ==============================================================================

; Default UART bit timing macros (at 50 MHz):
; 115200 baud -> 434 cycles/bit (1 instruction + 433 delay cycles)
.const UART_115200_DELAY   433
.const UART_57600_DELAY    867
.const UART_9600_DELAY     5207

; Pin assignments
tx_pin = uio[0]
rx_pin = uio[1]
