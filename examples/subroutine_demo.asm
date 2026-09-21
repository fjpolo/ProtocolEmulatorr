; =============================================================================
; OmniBus Microcode Program: Subroutine Demo — "OK" Streamer
; Task 05: Demonstrates CALL/RET hardware subroutine stack.
;
; Architecture:
;   Main loop calls two subroutines (tx_O, tx_K) then loops.
;   Each subroutine bit-bangs one UART character and returns.
;   This proves CALL/RET pushes/pops the return address correctly.
;
; Total: 7 (main) + 11 (tx_O) + 11 (tx_K) = 29 words — fits in 32-word IMEM.
; =============================================================================

.clock 50000000
.baud  115200

; ---- Main program (addresses 0..6) ----
start:
    CALL tx_O           ; Send 'O' — pushes return addr 0x01 to stack
    CALL tx_K           ; Send 'K' — pushes return addr 0x02 to stack
    NOP  511            ; Inter-message delay #1
    NOP  511            ; Inter-message delay #2
    JMP  start          ; Loop forever

; ---- Subroutine: Transmit 'O' (0x4F, LSB-first: 1,1,1,1,0,0,1,0) ----
; Occupies addresses 5..15
tx_O:
    SET 0, BIT_DELAY    ; Start bit (0)
    SET 1, BIT_DELAY    ; Bit 0 = 1
    SET 1, BIT_DELAY    ; Bit 1 = 1
    SET 1, BIT_DELAY    ; Bit 2 = 1
    SET 1, BIT_DELAY    ; Bit 3 = 1
    SET 0, BIT_DELAY    ; Bit 4 = 0
    SET 0, BIT_DELAY    ; Bit 5 = 0
    SET 1, BIT_DELAY    ; Bit 6 = 1
    SET 0, BIT_DELAY    ; Bit 7 = 0
    SET 1, BIT_DELAY    ; Stop bit (1)
    RET                 ; Return to caller

; ---- Subroutine: Transmit 'K' (0x4B, LSB-first: 1,1,0,1,0,0,1,0) ----
; Occupies addresses 16..26
tx_K:
    SET 0, BIT_DELAY    ; Start bit (0)
    SET 1, BIT_DELAY    ; Bit 0 = 1
    SET 1, BIT_DELAY    ; Bit 1 = 1
    SET 0, BIT_DELAY    ; Bit 2 = 0
    SET 1, BIT_DELAY    ; Bit 3 = 1
    SET 0, BIT_DELAY    ; Bit 4 = 0
    SET 0, BIT_DELAY    ; Bit 5 = 0
    SET 1, BIT_DELAY    ; Bit 6 = 1
    SET 0, BIT_DELAY    ; Bit 7 = 0
    SET 1, BIT_DELAY    ; Stop bit (1)
    RET                 ; Return to caller
