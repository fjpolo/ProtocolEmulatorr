; =============================================================================
; Example   : dma_stream_demo.asm
; Module    : OmniBus Protocol Emulator
; Task      : Task 26 - OmniBus DMA & Stream Flow Engine
; Target    : High-Throughput Memory Streamer & FIFO Flow Control Demo
; Target HW : Sipeed Tang Console 60K (GW5AT-LV60PG484AC1)
; Operation : Interactive Serial Terminal with FIFO Buffering & Stream Telemetry
; =============================================================================

.clock 50000000
.baud  115200

    ; Configure PINMAP: Pin 0 = TX, Pin 0 = RX
    PINMAP 0, 0, 1, 2

rx_loop:
    ; Wait for UART Start bit on Pin 0 (falling edge)
    WAIT 0, 0, $HBAUD
    NOP $BAUD
    IN 8, $BAUD
    WAIT 0, 1, 0

    ; Save received byte to acc and push into FIFO
    MOV acc, isr
    PUSH

    ; Echo character back to host over UART TX (Pin 0)
    SET 0, 0, $BAUD
    OUT 8, $BAUD
    SET 0, 1, $BAUD

    ; Check if user pressed Enter (0x0D '\r' or 0x0A '\n')
    CMP acc, 0x0D
    JMP ZERO, send_ack
    CMP acc, 0x0A
    JMP ZERO, send_ack

    ; Check if user pressed '!' (0x21) -> trigger burst streaming
    CMP acc, 0x21
    JMP ZERO, send_burst

    JMP rx_loop

send_ack:
    ; Stream tag: " [DMA OK]\r\n"
    MOV acc, 0x20
    MOV osr, acc
    CALL tx_char
    MOV acc, 0x5B
    MOV osr, acc
    CALL tx_char
    MOV acc, 0x44
    MOV osr, acc
    CALL tx_char
    MOV acc, 0x4D
    MOV osr, acc
    CALL tx_char
    MOV acc, 0x41
    MOV osr, acc
    CALL tx_char
    MOV acc, 0x20
    MOV osr, acc
    CALL tx_char
    MOV acc, 0x4F
    MOV osr, acc
    CALL tx_char
    MOV acc, 0x4B
    MOV osr, acc
    CALL tx_char
    MOV acc, 0x5D
    MOV osr, acc
    CALL tx_char
    MOV acc, 0x0D
    MOV osr, acc
    CALL tx_char
    MOV acc, 0x0A
    MOV osr, acc
    CALL tx_char
    JMP rx_loop

send_burst:
    ; Stream test burst pattern: " >>01234567\r\n"
    MOV acc, 0x20
    MOV osr, acc
    CALL tx_char
    MOV acc, 0x3E
    MOV osr, acc
    CALL tx_char
    MOV acc, 0x3E
    MOV osr, acc
    CALL tx_char

    SET_LC LC0, 8
    MOV acc, 0x30
burst_loop:
    MOV osr, acc
    CALL tx_char
    ADD acc, 1
    DJNZ lc0, burst_loop

    MOV acc, 0x0D
    MOV osr, acc
    CALL tx_char
    MOV acc, 0x0A
    MOV osr, acc
    CALL tx_char
    JMP rx_loop

tx_char:
    SET 0, 0, $BAUD
    OUT 8, $BAUD
    SET 0, 1, $BAUD
    RET
