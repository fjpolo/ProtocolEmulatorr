; =============================================================================
; OmniBus Microcode Program: Multi-Byte SPI Burst Transmission
; Task 09: Uses hardware loop counter LC0 to stream N bytes under single CS_n
;
; Loop count:
;   Configured via SET_LC (e.g. 4 bytes), or dynamically via PULL_LC from host.
; =============================================================================

.clock 50000000
.baud  115200

start:
    ; Assert SPI CS_n (active low)
    SET     CS, 0, 0

    ; Number of bytes in the SPI burst (e.g. 4 bytes)
    SET_LC  LC0, 4

burst_loop:
    PULL                ; Load data byte from i_data (set via host 'D' command)
    OUT     SCK, $HBAUD ; Transmit 8 bits MSB-first with auto-SCK clocking
    DJNZ    LC0, burst_loop ; Repeat until all bytes sent

    ; Deassert SPI CS_n (idle high)
    SET     CS, 1, 0
    PUSH                ; Latch last received byte to o_data

idle_wait:
    JMP     idle_wait   ; Wait until next host trigger
