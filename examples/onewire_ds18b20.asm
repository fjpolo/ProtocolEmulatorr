; =============================================================================
; File        : onewire_ds18b20.asm
; Description : Dallas / Maxim 1-Wire (OneWire) DS18B20 Temperature Sensor Driver
; Architecture: OmniBus Deterministic Protocol Engine (Task 12)
; Hardware    : Pin 0 = DQ (Bidirectional Open-Drain 1-Wire data bus)
; =============================================================================

    ; 1. Configure Pin 0 as Bidirectional Open-Drain Data Line (DQ)
    ;    PINMAP: tx=0, rx=0, sck=1, cs=2
    PINMAP 0, 0, 1, 2
    CFG_OD 0x01                 ; Pin 0 in Open-Drain mode (drive low / release Hi-Z)

reset_bus:
    ; 2. Issue 1-Wire Master Reset Pulse (pull low for $BAUD = 480 us)
    SET 0, 0, $BAUD

    ; 3. Release line and wait 70 us for Slave Presence Pulse
    SET 0, 1, 70

    ; 4. Check for Slave Presence Pulse (slave drives DQ low)
    JMP PIN_LO, slave_present
    JMP reset_bus               ; Retry if no device responded

slave_present:
    ; 5. Wait for Presence Pulse to finish (line returns high)
    WAIT 0, 1, 100

    ; 6. Send SKIP ROM Command (0xCC = 1100_1100b)
    PULL BLOCK                  ; Pull 0xCC from TX FIFO
    OUT 1W, 5                   ; Transmit byte LSB-first over 1-Wire

    ; 7. Send CONVERT T Command (0x44 = 0100_0100b)
    PULL BLOCK                  ; Pull 0x44 from TX FIFO
    OUT 1W, 5                   ; Transmit byte LSB-first over 1-Wire

    ; 8. Wait for conversion, then Issue Second Reset Pulse
    SET 0, 0, $BAUD
    SET 0, 1, 70
    WAIT 0, 0, 150              ; Wait for presence pulse
    WAIT 0, 1, 100              ; Wait for presence pulse end

    ; 9. Send SKIP ROM Command (0xCC)
    PULL BLOCK
    OUT 1W, 5

    ; 10. Send READ SCRATCHPAD Command (0xBE = 1011_1110b)
    PULL BLOCK
    OUT 1W, 5

    ; 11. Read Temperature LSB (Byte 0 of scratchpad)
    IN 1W, 5                    ; Read 8 bits LSB-first into ISR
    PUSH BLOCK                  ; Push Temperature LSB to RX FIFO

    ; 12. Read Temperature MSB (Byte 1 of scratchpad)
    IN 1W, 5                    ; Read 8 bits LSB-first into ISR
    PUSH BLOCK                  ; Push Temperature MSB to RX FIFO

    ; 13. Loop back to idle/next measurement
    JMP reset_bus
