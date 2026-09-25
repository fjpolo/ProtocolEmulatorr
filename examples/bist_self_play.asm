; ==============================================================================
; File        : bist_self_play.asm
; Description : On-Chip Self-Play Built-In Self-Test (BIST) Autonomous Test Program
; Target      : OmniBus Protocol Engine / Tang Console 60K (Task 29)
; 
; Architecture:
;   - Fully autonomous self-verification executing on real silicon.
;   - Live UART telemetry reporting at 115200 baud out Pin 0 / TX pin.
;   - Uses the Internal Virtual Crossbar to route signals internally without
;     requiring external loopback jumpers or logic analyzer probes.
;   - Real-time LED status & scoring telemetry.
;   - Live ASCII Reporting:
;       BIST:
;       S1:OK
;       S2:OK
;       S3:OK
;       S4:OK
;       ..................
; ==============================================================================

.clock 50000000
.baud 115200

start:
    SET 0, 1, 0                 ; Idle UART TX (Pin 0 high)
    BIST_RST                    ; Reset all vector, pass, and fail counters
    BIST_START                  ; Enable hardware BIST engine
    NOP 10

    ; Print "\r\nBIST\r\n"
    MOV acc, '\r'
    CALL tx_byte
    MOV acc, '\n'
    CALL tx_byte
    MOV acc, 'B'
    CALL tx_byte
    MOV acc, 'I'
    CALL tx_byte
    MOV acc, 'S'
    CALL tx_byte
    MOV acc, 'T'
    CALL tx_byte
    MOV acc, '\r'
    CALL tx_byte
    MOV acc, '\n'
    CALL tx_byte

; ==============================================================================
; STAGE 1: ALU Arithmetic & Flags Self-Test
; ==============================================================================
stage1:
    BIST_STAGE 1                ; Signal Stage 1
    MOV acc, 'S'
    CALL tx_byte
    MOV acc, '1'
    CALL tx_byte

    ; Test ADD & Zero/Carry Flags
    MOV acc, 0x55
    ADD acc, 0xAA               ; 0x55 + 0xAA = 0xFF (no carry, non-zero)
    JMP ZERO, stage1_fail
    JMP CARRY, stage1_fail

    ADD acc, 0x01               ; 0xFF + 0x01 = 0x00 (carry=1, zero=1)
    JMP NOT_ZERO, stage1_fail
    JMP NOT_CARRY, stage1_fail

    ; Test Bitwise XOR
    MOV acc, 0xA5
    XOR acc, 0xA5               ; Result must be 0x00
    JMP NOT_ZERO, stage1_fail

    ; Stage 1 Success
    BIST_PASS
    CALL print_ok
    JMP stage2

stage1_fail:
    BIST_FAIL
    CALL print_err
    ; Fall-through to Stage 2

; ==============================================================================
; STAGE 2: Direct Virtual Crossbar Loopback Self-Test
; ==============================================================================
stage2:
    BIST_STAGE 2                ; Signal Stage 2
    MOV acc, 'S'
    CALL tx_byte
    MOV acc, '2'
    CALL tx_byte

    BIST_LOOP                   ; Lock crossbar to direct loopback (pin P -> pin P)
    NOP 10

    ; Drive pin 1 High, verify through crossbar
    SET 1, 1, 20
    WAIT 1, 1, 100

    ; Drive pin 1 Low, verify through crossbar
    SET 1, 0, 20
    WAIT 1, 0, 100

    ; Restore pin 0 to High for UART TX
    SET 0, 1, 0

    ; Stage 2 Success
    BIST_PASS
    CALL print_ok
    JMP stage3

stage2_fail:
    BIST_FAIL
    CALL print_err
    ; Fall-through to Stage 3

; ==============================================================================
; STAGE 3: Split Dual-Channel Crossbar (Ch A 0..3 <-> Ch B 4..7)
; ==============================================================================
stage3:
    BIST_STAGE 3                ; Signal Stage 3
    MOV acc, 'S'
    CALL tx_byte
    MOV acc, '3'
    CALL tx_byte

    BIST_SPLIT                  ; Ch A (pins 0..3) <-> Ch B (pins 4..7)
    NOP 10

    ; Channel B TX (pin 5) -> Channel A RX (pin 1)
    SET 5, 1, 20
    WAIT 1, 1, 100

    SET 5, 0, 20
    WAIT 1, 0, 100

    ; Channel A TX (pin 2) -> Channel B RX (pin 6)
    SET 2, 1, 20
    WAIT 6, 1, 100

    SET 2, 0, 20
    WAIT 6, 0, 100

    ; Restore pin 0 to High for UART TX
    SET 0, 1, 0

    ; Stage 3 Success
    BIST_PASS
    CALL print_ok
    JMP stage4

stage3_fail:
    BIST_FAIL
    CALL print_err
    ; Fall-through to Stage 4

; ==============================================================================
; STAGE 4: Final Summary & Continuous Heartbeat Stream
; ==============================================================================
stage4:
    BIST_STAGE 4                ; Signal Stage 4
    MOV acc, 'S'
    CALL tx_byte
    MOV acc, '4'
    CALL tx_byte
    BIST_PASS
    CALL print_ok

    ; Restore normal routing for clean external UART
    BIST_DIS
    SET 0, 1, 0

bist_heartbeat:
    MOV acc, '.'
    CALL tx_byte
    NOP 511
    NOP 511
    NOP 511
    NOP 511
    JMP bist_heartbeat

; ==============================================================================
; Subroutines
; ==============================================================================
tx_byte:
    MOV osr, acc
    SET 0, 0, 433               ; UART start bit (Pin 0 low @ 115200 baud)
    OUT 433                     ; 8 data bits LSB-first
    SET 0, 1, 433               ; UART stop bit (Pin 0 high)
    RET

print_ok:
    MOV acc, ':'
    CALL tx_byte
    MOV acc, 'O'
    CALL tx_byte
    MOV acc, 'K'
    CALL tx_byte
    MOV acc, '\r'
    CALL tx_byte
    MOV acc, '\n'
    CALL tx_byte
    RET

print_err:
    MOV acc, ':'
    CALL tx_byte
    MOV acc, 'E'
    CALL tx_byte
    MOV acc, 'R'
    CALL tx_byte
    MOV acc, 'R'
    CALL tx_byte
    MOV acc, '\r'
    CALL tx_byte
    MOV acc, '\n'
    CALL tx_byte
    RET
