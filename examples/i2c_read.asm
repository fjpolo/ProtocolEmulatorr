; =============================================================================
; OmniBus Microcode Program: I2C Master Byte Read with ACK Generation
; Task 10: Receives 1 byte from an I2C slave using IN SDA auto-clocking
;
; Pin configuration (PMOD2 / GPIO):
;   SDA: GPIO 4 (open-drain, tx_pin / rx_pin)
;   SCL: GPIO 1 (open-drain, sck_pin)
; =============================================================================

.clock 50000000
.baud  115200

@0
start:
    PINMAP 4, 4, 1, 2       ; [0] SDA=Pin 4, SCL=Pin 1, CS=Pin 2
    CFG_OD 0x12             ; [1] Pins 4 and 1 open-drain

i2c_read_loop:
    SET  SDA, 1, 0          ; [2] SDA idle high
    SET  SCL, 1, $HBAUD     ; [3] SCL idle high
    SET  SDA, 0, $HBAUD     ; [4] START condition: SDA falling while SCL high
    SET  SCL, 0, 0          ; [5] SCL low -> enter receive phase

    IN   SDA, $HBAUD        ; [6] Releases SDA, pulses SCL 8 times, reads byte into ISR!

    ; Master ACK phase (drive SDA low):
    SET  SDA, 0, 0          ; [7] Drive ACK bit (0 = ACK)
    SET  SCL, 1, $HBAUD     ; [8] SCL high: ACK pulse
    SET  SCL, 0, 0          ; [9] SCL low: end of ACK pulse

    ; STOP condition:
    SET  SDA, 0, 0          ; [10] SDA low
    SET  SCL, 1, $HBAUD     ; [11] SCL high
    SET  SDA, 1, $HBAUD     ; [12] STOP: SDA rising while SCL high

    PUSH                    ; [13] Output received byte to LEDs / RX FIFO
    JMP  i2c_read_loop      ; [14] Repeat
