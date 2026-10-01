; ==============================================================================
; OmniBus Example 01: UART 115200 8N1 "Hello OmniBus!" Streamer
; ==============================================================================
.clock 50MHz

tx_pin = uio[0]

.entry main

main:
    SET tx_pin, 1 [$BAUD]      ; Initialize TX idle High

stream_loop:
    PULL                       ; Block until host writes a byte to TX FIFO
    
    ; Transmit Start Bit (0)
    SET tx_pin, 0 [$BAUD]
    
    ; Transmit 8 Data Bits (LSB First)
    OUT tx_pin, 8 [$BAUD]
    
    ; Transmit Stop Bit (1)
    SET tx_pin, 1 [$BAUD]
    
    JMP stream_loop
