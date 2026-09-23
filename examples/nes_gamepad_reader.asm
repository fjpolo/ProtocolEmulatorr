; =============================================================================
; File        : nes_gamepad_reader.asm
; Description : Autonomous NES/SNES Gamepad Controller Reader Demo
;               Demonstrates Task 18 Retro Gamepad Controller Accelerator:
;                 - Opcode 0xF: ASSIST GAMEPAD_CFG, ROLE=HOST, TYPE=NES
;                 - Autonomous LATCH strobe on cs_pin (Pin 2)
;                 - Autonomous 8-clock burst on sck_pin (Pin 1)
;                 - Synchronous sampling of button bits from rx_pin (Pin 0) into ISR
;                 - Inverted button bit decoding (Active-LOW: 0=Pressed, 1=Released)
;                 - Stream telemetry directly to host FIFO via PUSH
; =============================================================================

.clock 50000000
.baud  100000

start:
    ; 1. Configure Gamepad Accelerator in Console Host Mode for 8-bit NES controller
    ASSIST GAMEPAD_CFG, ROLE=HOST, TYPE=NES

poll_loop:
    ; 2. Poll gamepad: automatically pulses LATCH high, then clocks 8 times
    IN 8, 4

    ; 3. Invert sampled bits so 1 = Pressed, 0 = Released
    MOV acc, ISR
    NOT acc
    MOV ISR, acc

    ; 4. Push decoded 8-bit button mask to host FIFO:
    ;    Bit 0: A
    ;    Bit 1: B
    ;    Bit 2: Select
    ;    Bit 3: Start
    ;    Bit 4: Up
    ;    Bit 5: Down
    ;    Bit 6: Left
    ;    Bit 7: Right
    PUSH

    ; Inter-frame delay (~16.6ms for 60Hz polling, here short delay for demo)
    NOP 100
    JMP poll_loop
