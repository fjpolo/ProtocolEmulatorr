; =============================================================================
; OmniBus Microcode Program: Continuous "OK\r\n" Streamer
; Description: Transmits ASCII "OK\r\n" continuously over UART @ 115200 baud.
; Demonstrates runtime reprogramming of pure transmitter microcode.
; =============================================================================

.clock 50000000
.baud 115200

start:
    ; --- Character 'O' (0x4F = 0100_1111b, LSB-first: 1, 1, 1, 1, 0, 0, 1, 0) ---
    SET 0, BIT_DELAY    ; Start bit (0)
    SET 1, BIT_DELAY    ; Bit 0 (1)
    SET 1, BIT_DELAY    ; Bit 1 (1)
    SET 1, BIT_DELAY    ; Bit 2 (1)
    SET 1, BIT_DELAY    ; Bit 3 (1)
    SET 0, BIT_DELAY    ; Bit 4 (0)
    SET 0, BIT_DELAY    ; Bit 5 (0)
    SET 1, BIT_DELAY    ; Bit 6 (1)
    SET 0, BIT_DELAY    ; Bit 7 (0)
    SET 1, BIT_DELAY    ; Stop bit (1)

    ; --- Character 'K' (0x4B = 0100_1011b, LSB-first: 1, 1, 0, 1, 0, 0, 1, 0) ---
    SET 0, BIT_DELAY    ; Start bit (0)
    SET 1, BIT_DELAY    ; Bit 0 (1)
    SET 1, BIT_DELAY    ; Bit 1 (1)
    SET 0, BIT_DELAY    ; Bit 2 (0)
    SET 1, BIT_DELAY    ; Bit 3 (1)
    SET 0, BIT_DELAY    ; Bit 4 (0)
    SET 0, BIT_DELAY    ; Bit 5 (0)
    SET 1, BIT_DELAY    ; Bit 6 (1)
    SET 0, BIT_DELAY    ; Bit 7 (0)
    SET 1, BIT_DELAY    ; Stop bit (1)

    ; --- Inter-message delay ---
    NOP 511             ; Pause
    NOP 511             ; Pause
    JMP start           ; Repeat
