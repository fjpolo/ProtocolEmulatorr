; =============================================================================
; File        : alu_interactive.asm
; Description : Interactive Hardware ALU Terminal Demo for FPGA
;               Receives UART characters @ 115200 baud, executes on-chip
;               Micro-ALU character classification and uppercase conversion:
;                 - 'a'..'z' (0x61..0x7A) -> converted to 'A'..'Z' via SUB acc, 0x20
;                 - other characters echoed as-is
; =============================================================================

.clock 50000000
.baud  115200

start:
    ; 1. Wait for incoming UART byte
    WAIT 0, HALF_DELAY  ; rx=0, sample mid-bit
    NOP  BIT_DELAY
    IN   8, BIT_DELAY   ; Sample 8 data bits into ISR
    WAIT 1, 0           ; Stop bit

    ; 2. Transfer received byte from ISR to Accumulator
    MOV acc, ISR

    ; 3. Check if lowercase: acc >= 0x61 ('a') and acc <= 0x7A ('z')
    CMP acc, 0x61       ; Compare with 'a'
    JMP CARRY, echo_out ; If acc < 0x61, not lowercase

    CMP acc, 0x7B       ; Compare with 'z' + 1
    JMP NOT_CARRY, echo_out ; If acc >= 0x7B, not lowercase

    ; 4. Lowercase detected! Convert to uppercase via ALU:
    SUB acc, 0x20       ; 'a' (0x61) -> 'A' (0x41)

echo_out:
    MOV OSR, acc        ; Load converted byte into OSR
    SET 0, BIT_DELAY    ; Start bit (0)
    OUT 8, BIT_DELAY    ; Transmit 8 data bits
    SET 1, BIT_DELAY    ; Stop bit (1)
    JMP start           ; Loop
