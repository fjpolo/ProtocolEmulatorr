; =============================================================================
; Example   : profiler_autobaud_demo.asm
; Module    : OmniBus Protocol Emulator
; Task      : Task 27 - The Protocol Detective (Autonomous Waveform Profiler)
; Target    : Tang Console 60K FPGA (GW5AT-LV60PG484AC1)
; Operation : Autonomous Bus Characterization, Auto-Baud Discovery & Live Echo
; =============================================================================

    ; 1. Configure Waveform Profiler on Pin 0 (UART RX) with 2-cycle filter
    PROFILER_CFG 0, 2
    PROFILER_RST

    ; 2. Print Welcome Banner over UART TX (Pin 0) at default 115,200 baud
    MOV acc, 0x0D ; '\r'
    CALL print_char
    MOV acc, 0x0A ; '\n'
    CALL print_char
    MOV acc, 0x5B ; '['
    CALL print_char
    MOV acc, 0x4F ; 'O'
    CALL print_char
    MOV acc, 0x4D ; 'M'
    CALL print_char
    MOV acc, 0x4E ; 'N'
    CALL print_char
    MOV acc, 0x49 ; 'I'
    CALL print_char
    MOV acc, 0x5D ; ']'
    CALL print_char
    MOV acc, 0x20 ; ' '
    CALL print_char
    MOV acc, 0x50 ; 'P'
    CALL print_char
    MOV acc, 0x52 ; 'R'
    CALL print_char
    MOV acc, 0x4F ; 'O'
    CALL print_char
    MOV acc, 0x46 ; 'F'
    CALL print_char
    MOV acc, 0x49 ; 'I'
    CALL print_char
    MOV acc, 0x4C ; 'L'
    CALL print_char
    MOV acc, 0x45 ; 'E'
    CALL print_char
    MOV acc, 0x52 ; 'R'
    CALL print_char
    MOV acc, 0x20 ; ' '
    CALL print_char
    MOV acc, 0x41 ; 'A'
    CALL print_char
    MOV acc, 0x52 ; 'R'
    CALL print_char
    MOV acc, 0x4D ; 'M'
    CALL print_char
    MOV acc, 0x45 ; 'E'
    CALL print_char
    MOV acc, 0x44 ; 'D'
    CALL print_char
    MOV acc, 0x0D ; '\r'
    CALL print_char
    MOV acc, 0x0A ; '\n'
    CALL print_char

    ; 3. Arm the autonomous profiler engine
    PROFILER_ARM

wait_capture:
    ; Check if measurement converged or classified as periodic clock
    JMP PROFILER_CLOCK, detected_clock
    JMP PROFILER_DONE, detected_converged
    JMP wait_capture

detected_clock:
    MOV acc, 0x5B ; '['
    CALL print_char
    MOV acc, 0x43 ; 'C'
    CALL print_char
    MOV acc, 0x4C ; 'L'
    CALL print_char
    MOV acc, 0x4F ; 'O'
    CALL print_char
    MOV acc, 0x43 ; 'C'
    CALL print_char
    MOV acc, 0x4B ; 'K'
    CALL print_char
    MOV acc, 0x5D ; ']'
    CALL print_char
    JMP show_telemetry

detected_converged:
    MOV acc, 0x5B ; '['
    CALL print_char
    MOV acc, 0x44 ; 'D'
    CALL print_char
    MOV acc, 0x41 ; 'A'
    CALL print_char
    MOV acc, 0x54 ; 'T'
    CALL print_char
    MOV acc, 0x41 ; 'A'
    CALL print_char
    MOV acc, 0x5D ; ']'
    CALL print_char

show_telemetry:
    MOV acc, 0x20 ; ' '
    CALL print_char

    ; Read Profiler Status: [busy, done, idle_pol, is_clock, proto_id[3:0]]
    ASSIST READ, PROFILER_STATUS
    PUSH

    ; Read t_min low byte (fundamental bit period / baud divisor)
    ASSIST READ, PROFILER_TMIN_L
    PUSH

    ; Read total edge count
    ASSIST READ, PROFILER_EDGES
    PUSH

    ; Print Done Tag
    MOV acc, 0x4F ; 'O'
    CALL print_char
    MOV acc, 0x4B ; 'K'
    CALL print_char
    MOV acc, 0x0D ; '\r'
    CALL print_char
    MOV acc, 0x0A ; '\n'
    CALL print_char

    PROFILER_STOP

    ; 4. Live Echo Loop using auto-detected baud timing
echo_loop:
    WAIT 0, 0, $HBAUD
    NOP $BAUD
    IN 8, $BAUD
    WAIT 0, 1, 0
    PUSH
    SET 0, 0, $BAUD
    OUT 8, $BAUD
    SET 0, 1, $BAUD
    JMP echo_loop

; Subroutine: print_char in acc on TX (Pin 0) at standard $BAUD
print_char:
    MOV OSR, acc
    SET 0, 0, $BAUD
    OUT 8, $BAUD
    SET 0, 1, $BAUD
    RET
