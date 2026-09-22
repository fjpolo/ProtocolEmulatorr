; =============================================================================
; OmniBus Microcode Program: I2C Master Byte Write with Auto-ACK Loopback
; Task 08: Transmits 1 byte over I2C to a slave device and samples ACK bit.
;
; Pin configuration (PMOD2 / GPIO):
;   SDA: GPIO 4 (open-drain, tx_pin / rx_pin)
;   SCL: GPIO 1 (open-drain, sck_pin)
;
; Timing:
;   $HBAUD sets SCL half-period. Default ~216 kHz (div=433 @ 50 MHz).
;   For 400 kHz Fast-Mode: use --set-baud 800000
;   For 100 kHz Standard-Mode: use --set-baud 200000
; =============================================================================

.clock 50000000
.baud  115200

start:
    ; Set roles: SDA on Pin 4 (TX/data & RX/sample), SCL on Pin 1, CS on Pin 2
    PINMAP 4, 4, 1, 2
    ; Set open-drain mode on Pin 4 (SDA) and Pin 1 (SCL): mask = 0x12 (bits 4 and 1)
    CFG_OD 0x12

i2c_loop:
    PULL                    ; [0] OSR = i_data (host byte set via bootloader 'D' command)
    SET  SDA, 1, 0          ; [1] SDA idle high (float)
    SET  SCL, 1, $HBAUD     ; [2] SCL idle high (float)
    SET  SDA, 0, $HBAUD     ; [3] START condition: SDA falling while SCL high
    SET  SCL, 0, 0          ; [4] SCL low -> data phase begins
    OUT  SDA, $HBAUD        ; [5] Send 8 bits MSB-first + auto SCL clocking
    SET  SDA, 1, 0          ; [6] Release SDA for slave ACK
    SET  SCL, 1, $HBAUD     ; [7] SCL high: slave holds SDA low = ACK
    SET  SCL, 0, 0          ; [8] SCL low: end of ACK pulse
    SET  SDA, 0, 0          ; [9] SDA low: prepare for STOP
    SET  SCL, 1, $HBAUD     ; [10] SCL high
    SET  SDA, 1, $HBAUD     ; [11] STOP condition: SDA rising while SCL high
    PUSH                    ; [12] Update o_data / LEDs with received ACK
    JMP  i2c_loop           ; [13] Next transaction
