; =============================================================================
; File        : crc_frame_demo.asm
; Description : OmniBus Microcode Demonstration: Hardware CRC-8 Frame
;               Verification and Transmission for Dallas 1-Wire Devices
;
; Demonstrates:
;   1. Initializing the hardware CRC accelerator (Dallas 1-Wire poly 0x8C)
;   2. Streaming 8 data bytes via IN 1W and single-cycle CRC_BYTE accumulation
;   3. Ingesting the 9th received CRC byte to verify residual checksum
;   4. Zero-overhead conditional branch via JMP CRC_OK
;   5. Generating an outgoing response frame, reading CRC_READ_LOW, and transmitting
; =============================================================================

.clock 50000000
.baud 115200

start:
    ; Configure Pin 0 for 1-Wire Bidirectional Open-Drain
    PINMAP  0, 0, 1, 2          ; Pin 0 = TX/RX, Pin 1 = SCK, Pin 2 = CS
    CFG_OD  0x01                ; Enable open-drain on Pin 0

    ; -------------------------------------------------------------------------
    ; Phase 1: Receive 8-Byte Payload + 1-Byte CRC from 1-Wire Slave (e.g. DS18B20)
    ; -------------------------------------------------------------------------
    CRC_INIT DALLAS, 0          ; Initialize CRC engine: Dallas poly (0x8C), seed=0
    SET_LC   LC0, 8             ; 8 data bytes in scratchpad payload

rx_data_loop:
    IN       1W, 8, 4           ; Read 1 byte from 1-Wire bus into ISR
    CRC_BYTE ISR                ; Single-cycle parallel CRC update from ISR
    PUSH                        ; Forward received byte to host RX FIFO
    DJNZ     LC0, rx_data_loop  ; Repeat for all 8 bytes

    ; Read the 9th byte (transmitted CRC) from the slave
    IN       1W, 8, 4           ; Read CRC byte into ISR
    CRC_BYTE ISR                ; Feed transmitted CRC into accelerator

    ; In standard Dallas 1-Wire, if data and CRC are intact, residual CRC == 0
    JMP      CRC_OK, frame_valid

crc_error:
    ; Frame corrupted: notify host or retry
    SET      0, 1, 10           ; Release bus high
    JMP      start              ; Restart packet reception

frame_valid:
    ; -------------------------------------------------------------------------
    ; Phase 2: Transmit Outgoing Frame with Hardware-Generated CRC
    ; -------------------------------------------------------------------------
    CRC_INIT DALLAS, 0          ; Reset CRC engine for outgoing packet
    SET_LC   LC0, 4             ; Transmit 4-byte command/data sequence

tx_data_loop:
    PULL     BLOCK              ; Fetch byte from TX FIFO into OSR
    CRC_BYTE OSR                ; Accumulate byte into CRC accelerator
    OUT      1W, 8, 4           ; Transmit byte LSB-first over 1-Wire bus
    DJNZ     LC0, tx_data_loop  ; Loop for 4 bytes

    ; Fetch calculated CRC and append to the packet
    CRC_READ_LOW                ; Copy crc_reg[7:0] to OSR & o_data
    OUT      1W, 8, 4           ; Transmit calculated CRC byte over 1-Wire bus

    ; Done: Return to idle listening
    SET      0, 1, 20
    JMP      start
