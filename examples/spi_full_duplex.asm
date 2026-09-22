; =============================================================================
; OmniBus Microcode Program: Full-Duplex SPI Master Transceiver
; Task 10: Demonstrates simultaneous transmit & receive and master read.
;
; Pin configuration (Task 07C PINMAP):
;   Pin 0: MOSI (TX)
;   Pin 1: SCK  (Clock)
;   Pin 2: CS_n (Chip Select)
;   Pin 3: MISO (RX)
; =============================================================================

.clock 50000000
.baud  115200

@0
start:
    PINMAP  0, 3, 1, 2      ; Map: TX=Pin0 (MOSI), RX=Pin3 (MISO), SCK=Pin1, CS=Pin2
    SET     CS, 1, 0        ; CS_n idle high

transfer:
    SET     CS, 0, 0        ; Assert CS_n low (begin transaction)
    PULL                    ; Load TX byte from host into OSR
    OUT     SCK, $HBAUD     ; Send OSR to MOSI while receiving MISO into ISR!
    SET     CS, 1, 0        ; Deassert CS_n high
    PUSH                    ; Transfer received byte from ISR to RX FIFO / LEDs
    JMP     transfer        ; Loop for next transfer
