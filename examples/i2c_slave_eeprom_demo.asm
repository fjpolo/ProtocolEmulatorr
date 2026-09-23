; =============================================================================
; OmniBus Microcode Program: Hardware I2C / SMBus Slave EEPROM Emulator
; Task 21: Autonomous hardware address recognition, auto-ACK, clock stretching,
;          and microcode data reception / transmission.
;
; Emulates a standard 24C02 I2C EEPROM at 7-bit slave address 0x50:
;   - Address 0x50 Write (0xA0): Receives word address & data, pushes to FIFO.
;   - Address 0x50 Read  (0xA1): Stretches SCL, loads data (0xBE), transmits byte,
;                                and evaluates Master ACK / NACK.
;
; Pin configuration (PMOD2 / GPIO):
;   SDA: GPIO 4 (open-drain, tx_pin / rx_pin)
;   SCL: GPIO 1 (open-drain, sck_pin)
;   LED: GPIO 2 (activity indicator, cs_pin)
; =============================================================================

.clock 50000000
.baud  115200

start:
    ; 1. Map physical protocol pins: SDA=4, SCL=1, Activity LED=2
    PINMAP 4, 4, 1, 2
    CFG_OD 0x12             ; Set Pins 4 and 1 to true open-drain mode
    SET 2, 0, 0             ; Turn off Activity LED initially

    ; 2. Configure Dedicated Hardware I2C Slave Engine: Address=0x50, Clock Stretching Enabled
    I2C_SLAVE_CFG 0x50, STRETCH=1

idle_loop:
    ; Wait for bus activity and matching 7-bit slave address
    JMP I2C_MATCH, on_address_matched
    JMP idle_loop

on_address_matched:
    SET 2, 1, 0             ; Turn ON Activity LED (Pin 2) on address match
    JMP I2C_READ, do_read_transfer

do_write_transfer:
    ; Master Write transaction (0xA0): Receive word address / payload byte
    IN SLAVE                ; Hardware autonomously receives 8 data bits, drives ACK on 9th SCL
    PUSH                    ; Latch received byte to FIFO / Host output
    JMP transaction_done

do_read_transfer:
    ; Master Read transaction (0xA1): Slave prepares data byte (0xBE), releases SCL, and sends
    MOV acc, 0xBE           ; Load EEPROM response constant (0xBE) into accumulator
    MOV OSR, acc            ; Transfer response byte into Serializer (OSR)
    I2C_RELEASE_SCL         ; Release hardware clock stretch hold, allowing Master to clock SCL
    OUT SLAVE               ; Hardware transmits 8 bits MSB-first and samples Master ACK/NACK
    JMP I2C_ACK, master_acked

master_nacked:
    ; Master sent NACK (SDA high on 9th clock) -> Read burst finished
    JMP transaction_done

master_acked:
    ; Master sent ACK (SDA low on 9th clock) -> Master requests next byte
    NOP

transaction_done:
    SET 2, 0, 0             ; Turn OFF Activity LED
    JMP idle_loop           ; Return to wait for next transaction
