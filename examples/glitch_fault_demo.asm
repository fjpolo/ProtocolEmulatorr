; =============================================================================
; Example   : glitch_fault_demo.asm
; Module    : OmniBus Protocol Emulator
; Task      : Task 25 - Hardware Glitch / Fault Injection & Wire-Speed MitM Engine
; Target    : Hardware Security Evaluation, Fault Injection & Active Wire Fuzzing
; Operation : Interactive Serial Terminal with Real-Time Mutation & Glitch Pulse
; =============================================================================

    ; 1. Configure Hardware Glitch Generator:
    ; Target Pin: GPIO 4, Polarity: Active-Low Crowbar (pol=1)
    GLITCH_CFG 4, 1

    ; Configure glitch pulse width: 5 clock cycles (100 ns @ 50 MHz)
    GLITCH_WIDTH 5

    ; Configure countdown delay: 10 clock cycles (200 ns @ 50 MHz)
    GLITCH_DELAY 10

    ; 2. Configure Wire-Speed MitM Fuzzing Engine:
    ; Match pattern: ASCII '!' (0x21)
    MOV acc, 0x21
    MITM_MATCH

    ; Replacement byte: ASCII '*' (0x2A) (fuzzed payload)
    MOV acc, 0x2A
    MITM_REPLACE

    ; Bitmask: 0xFF (exact 8-bit match)
    MOV acc, 0xFF
    MITM_MASK

    ; Enable MitM substitution engine
    MITM_ENABLE

    ; 3. Arm Glitch Generator to trigger automatically on MitM pattern match
    GLITCH_ARM 1

    ; 4. Protocol Transceiver Echo Loop with Wire-Speed MitM Mutation
rx_loop:
    WAIT 0, 0, $HBAUD
    NOP $BAUD
    IN 8, $BAUD
    WAIT 0, 1, 0

    ; Push received (potentially mutated) byte to FIFO
    PUSH

    ; Transmit byte back out on TX (Pin 0)
    SET 0, 0, $BAUD
    OUT 8, $BAUD
    SET 0, 1, $BAUD

    ; Check if glitch completed
    JMP GLITCH_DONE, glitch_success
    JMP rx_loop

glitch_success:
    ; Print notification tag: ' ' (0x20), '[' (0x5B), 'G' (0x47), ']' (0x5D)
    MOV acc, 0x20
    MOV OSR, acc
    CALL tx_char
    MOV acc, 0x5B
    MOV OSR, acc
    CALL tx_char
    MOV acc, 0x47
    MOV OSR, acc
    CALL tx_char
    MOV acc, 0x5D
    MOV OSR, acc
    CALL tx_char

    ; Rearm glitch generator & clear sticky flags for continuous testing
    MITM_CLR
    GLITCH_ARM 1
    JMP rx_loop

tx_char:
    SET 0, 0, $BAUD
    OUT 8, $BAUD
    SET 0, 1, $BAUD
    RET
