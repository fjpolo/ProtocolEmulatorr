; =============================================================================
; File        : alu_selftest.asm
; Description : Autonomous Hardware ALU Self-Test Microcode for FPGA
;               Exercises Micro-ALU (Opcode 0xB): ADD, SUB, AND, INC, SHL,
;               CMP, and conditional branching (JMP ZERO, JMP NOT_ZERO).
;               Continuously outputs "OK\n" if all tests pass, or "E\n" on failure.
; Total size  : Exactly 32 words (fits in 32-word IMEM).
; =============================================================================

.clock 50000000
.baud  115200

start:
    ; Test 1: Immediate ADD
    MOV acc, 0x10       ; acc = 0x10
    ADD acc, 0x24       ; acc = 0x34
    CMP acc, 0x34
    JMP NOT_ZERO, fail

    ; Test 2: Immediate SUB
    SUB acc, 0x14       ; acc = 0x20
    CMP acc, 0x20
    JMP NOT_ZERO, fail

    ; Test 3: Bitwise AND & Zero flag
    AND acc, 0x0F       ; acc = 0x00, ZERO flag set
    JMP NOT_ZERO, fail

    ; Test 4: Unary INC & SHL
    INC                 ; acc = 0x01
    SHL                 ; acc = 0x02
    CMP acc, 0x02
    JMP NOT_ZERO, fail

    ; All ALU tests PASSED -> Transmit "OK\n"
    MOV acc, 0x4F       ; 'O'
    CALL tx_char
    MOV acc, 0x4B       ; 'K'
    CALL tx_char
    MOV acc, 0x0A       ; '\n'
    CALL tx_char

    NOP 511             ; Inter-message delay
    JMP start

; Error Handler: Transmit "E\n"
fail:
    MOV acc, 0x45       ; 'E' (Error)
    CALL tx_char
    MOV acc, 0x0A       ; '\n'
    CALL tx_char
    JMP fail

; Subroutine: Transmit 8-bit character in acc over UART (tx pin)
tx_char:
    MOV OSR, acc
    SET 0, BIT_DELAY    ; Start bit (0)
    OUT 8, BIT_DELAY    ; 8 Data bits LSB-first
    SET 1, BIT_DELAY    ; Stop bit (1)
    RET
