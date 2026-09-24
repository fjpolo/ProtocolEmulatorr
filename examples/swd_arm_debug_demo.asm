; =============================================================================
; Example: ARM CoreSight & Hybrid RISC-V SWD Debug Port Probe (Task 23)
; Target : ProtocolEmulator / OmniBus
; Pinout : Pin 0 = SWDIO (Bidirectional data), Pin 1 = SWCLK (Clock output)
; Compatible: ARM Cortex-M0+/M3/M4/M7/M33 and Hybrid RISC-V (Raspberry Pi RP2350)
; =============================================================================

.clock 50000000

    ; Configure Pin Routing: Pin 0=SWDIO (TX), Pin 1=SWCLK (SCK)
    PINMAP 0, 0, 1, 2

    ; Enable Hardware ARM SWD Host Engine
    SWD_CFG 1

    ; Autonomous Line Reset + 16-bit JTAG-to-SWD Switching Sequence (0xE79E)
    ; Generates 54 clocks SWDIO=1, 0xE79E select pattern, 54 post-switch clocks, and 4 idle clocks
    SWD_RESET 1

    ; Request ARM Debug Port IDCODE (APnDP=0, RnW=1, Addr=0x00)
    ; Host transmits 8-bit header, performs turnaround (Trn), samples 3-bit ACK
    SWD_REQ DP, READ, 0x00

    ; Branch on sampled ACK response
    JMP SWD_OK, read_idcode

    ; If target returned WAIT or FAULT, report error (0xFF) and halt
    MOV acc, 0xFF
    MOV isr, acc
    PUSH
    JMP halt

read_idcode:
    ; Read 32-bit Data Register + Parity bit and turnaround from target
    SWD_RD32

    ; Check if target parity mismatch occurred
    JMP CARRY, parity_error

    ; Extract 4 DP-IDCODE bytes and push to RX FIFO (LSB first)
    ASSIST READ, SWD_DATA, 0
    PUSH
    ASSIST READ, SWD_DATA, 1
    PUSH
    ASSIST READ, SWD_DATA, 2
    PUSH
    ASSIST READ, SWD_DATA, 3
    PUSH
    JMP halt

parity_error:
    MOV acc, 0xEE
    MOV isr, acc
    PUSH

halt:
    JMP halt
