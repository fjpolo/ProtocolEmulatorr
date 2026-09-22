; =============================================================================
; File        : imem_128_demo.asm
; Description : Multi-Bank Protocol Service Microcode Demo (128 words, 4 banks)
;               Demonstrates Task 16 IMEM expansion:
;                 - Bank 0 (0x00..0x1F): Command Dispatcher & UART Receiver
;                 - Bank 1 (0x20..0x3F): Arithmetic & Uppercase Converter Service
;                 - Bank 2 (0x40..0x5F): Dallas CRC-8 Verification Service
;                 - Bank 3 (0x60..0x7F): Telemetry & Status Output Service
; =============================================================================

.clock 50000000
.baud  115200

; =============================================================================
; BANK 0: Command Dispatcher & Master Loop (Addresses 0..31)
; =============================================================================
.bank 0
start:
    ; Receive UART command byte
    WAIT 0, HALF_DELAY
    NOP  BIT_DELAY
    IN   8, BIT_DELAY
    WAIT 1, 0

    MOV acc, ISR
    CMP acc, 0x31       ; '1' -> Invoke Bank 1 Service
    JMP ZERO, call_bank1

    CMP acc, 0x32       ; '2' -> Invoke Bank 2 Service
    JMP ZERO, call_bank2

    ; Default: invoke Bank 3 Status Output Service
    CALL svc_bank3
    JMP start

call_bank1:
    CALL svc_bank1
    JMP start

call_bank2:
    CALL svc_bank2
    JMP start


; =============================================================================
; BANK 1: Arithmetic & Case Converter Service (Addresses 32..63)
; =============================================================================
.bank 1
svc_bank1:
    ; Check if lowercase: acc >= 'a' (0x61) and <= 'z' (0x7A)
    CMP acc, 0x61
    JMP CARRY, b1_done
    CMP acc, 0x7B
    JMP NOT_CARRY, b1_done
    SUB acc, 0x20       ; Convert to uppercase

b1_done:
    ; Transmit result over UART
    MOV OSR, acc
    SET 0, BIT_DELAY
    OUT 8, BIT_DELAY
    SET 1, BIT_DELAY
    RET


; =============================================================================
; BANK 2: Dallas CRC-8 Checksum Service (Addresses 64..95)
; =============================================================================
.bank 2
svc_bank2:
    CRC_INIT DALLAS, ZERO
    CRC_BYTE ISR        ; Compute CRC of command byte
    CRC_READ_LOW        ; Read CRC into OSR and o_data

    ; Transmit calculated CRC byte
    SET 0, BIT_DELAY
    OUT 8, BIT_DELAY
    SET 1, BIT_DELAY
    RET


; =============================================================================
; BANK 3: Telemetry & Status Output Service (Addresses 96..127)
; =============================================================================
.bank 3
svc_bank3:
    ; Transmit 'O', 'K', '\n'
    MOV acc, 0x4F       ; 'O'
    MOV OSR, acc
    SET 0, BIT_DELAY
    OUT 8, BIT_DELAY
    SET 1, BIT_DELAY

    MOV acc, 0x4B       ; 'K'
    MOV OSR, acc
    SET 0, BIT_DELAY
    OUT 8, BIT_DELAY
    SET 1, BIT_DELAY

    MOV acc, 0x0A       ; '\n'
    MOV OSR, acc
    SET 0, BIT_DELAY
    OUT 8, BIT_DELAY
    SET 1, BIT_DELAY
    RET
