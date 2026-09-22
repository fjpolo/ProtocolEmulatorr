; =============================================================================
; OmniBus Microcode Program: Dynamic GPIO Pin Mapping Demo
; Demonstrates runtime pin configuration via PINMAP (Opcode 0x5).
;
; In this example, protocol roles are dynamically reassigned to alternate pins:
;   TX  (UART / Serial Out) -> GPIO 4
;   RX  (UART / Serial In)  -> GPIO 5
;   SCK (Clock)             -> GPIO 6
;   CS  (Chip Select)       -> GPIO 7
;
; Any incoming byte on GPIO 5 is sampled into ISR and echoed out on GPIO 4.
; =============================================================================

.clock 50000000
.baud  115200

start:
    ; Configure roles: TX=Pin 4, RX=Pin 5, SCK=Pin 6, CS=Pin 7
    PINMAP 4, 5, 6, 7

echo_loop:
    WAIT 5, 0, $HBAUD  ; Wait for start bit on GPIO 5, advance to mid-bit
    NOP  $BAUD         ; Advance to center of Data Bit 0
    IN   8, $BAUD      ; Sample 8 data bits from GPIO 5 (configured rx_pin)
    WAIT 5, 1, 0       ; Confirm stop bit (logic 1) on GPIO 5
    PUSH               ; Transfer ISR -> OSR for echo transmission
    SET  4, 0, $BAUD   ; Transmit start bit (0) on GPIO 4 (configured tx_pin)
    OUT  8, $BAUD      ; Transmit 8 data bits on GPIO 4
    SET  4, 1, $BAUD   ; Transmit stop bit (1) on GPIO 4
    JMP  echo_loop     ; Loop back for next byte
