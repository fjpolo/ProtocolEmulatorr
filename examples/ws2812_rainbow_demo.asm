; =============================================================================
; File        : ws2812_rainbow_demo.asm
; Description : Autonomous WS2812B NeoPixel Single-Wire LED Driver Demo
;               Demonstrates Task 18 Asymmetric Pulse Accelerator:
;                 - Opcode 0xF: ASSIST PULSE_CFG, NEOPIXEL
;                 - Autonomous 800 kHz single-wire NRZ pulse timing:
;                   * Bit 0: 400ns HIGH, 850ns LOW (20 cyc / 42 cyc @ 50MHz)
;                   * Bit 1: 800ns HIGH, 450ns LOW (40 cyc / 22 cyc @ 50MHz)
;                 - Hardware MSB-first bit order for 24-bit GRB color packets
;                 - Zero-overhead streaming directly from OSR via OUT 8
;                 - Latch / Reset pulse (> 50us low) to commit colors
; =============================================================================

.clock 50000000
.baud  800000

start:
    ; 1. Configure Asymmetric Pulse Accelerator for WS2812B NeoPixel profile
    ASSIST PULSE_CFG, NEOPIXEL

    ; -------------------------------------------------------------------------
    ; LED 0: Pure Green (G=0xFF, R=0x00, B=0x00)
    ; -------------------------------------------------------------------------
    MOV acc, 0xFF           ; Green = 255
    MOV OSR, acc
    OUT 8, 0

    MOV acc, 0x00           ; Red = 0
    MOV OSR, acc
    OUT 8, 0

    MOV acc, 0x00           ; Blue = 0
    MOV OSR, acc
    OUT 8, 0

    ; -------------------------------------------------------------------------
    ; LED 1: Pure Red (G=0x00, R=0xFF, B=0x00)
    ; -------------------------------------------------------------------------
    MOV acc, 0x00           ; Green = 0
    MOV OSR, acc
    OUT 8, 0

    MOV acc, 0xFF           ; Red = 255
    MOV OSR, acc
    OUT 8, 0

    MOV acc, 0x00           ; Blue = 0
    MOV OSR, acc
    OUT 8, 0

    ; -------------------------------------------------------------------------
    ; LED 2: Pure Blue (G=0x00, R=0x00, B=0xFF)
    ; -------------------------------------------------------------------------
    MOV acc, 0x00           ; Green = 0
    MOV OSR, acc
    OUT 8, 0

    MOV acc, 0x00           ; Red = 0
    MOV OSR, acc
    OUT 8, 0

    MOV acc, 0xFF           ; Blue = 255
    MOV OSR, acc
    OUT 8, 0

    ; -------------------------------------------------------------------------
    ; Latch / Reset Code: Hold line low for > 50us (2500 cycles @ 50MHz)
    ; -------------------------------------------------------------------------
    SET tx, 0, 250
    SET tx, 0, 250

    ; Emit completion ACK (0x06) to host FIFO
    MOV acc, 0x06
    MOV ISR, acc
    PUSH

halt:
    JMP halt
