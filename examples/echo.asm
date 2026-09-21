; =============================================================================
; OmniBus Microcode Program: UART Echo Transceiver
; Description: Receives 8N1 byte over UART and immediately echoes it back.
; Baud Rate: 115,200 baud @ 50 MHz (434 cycles/bit)
; =============================================================================

.clock 50000000
.baud 115200

start:
    WAIT 0, HALF_DELAY  ; Wait for start bit (rx=0), delay to mid-start (216)
    NOP  BIT_DELAY      ; Advance 1.0 bit to center of Data Bit 0 (433)
    IN   8, BIT_DELAY   ; Sample 8 data bits LSB-first into ISR (433)
    WAIT 1, 0           ; Confirm stop bit logic 1 (rx=1)
    PUSH                ; Transfer ISR -> OSR for echo transmission
    SET  0, BIT_DELAY   ; Transmit start bit (tx=0, 433)
    OUT  8, BIT_DELAY   ; Transmit 8 data bits from OSR (433)
    SET  1, BIT_DELAY   ; Transmit stop bit (tx=1, 433)
    JMP  start          ; Loop back to wait for next incoming byte
