; =============================================================================
; OmniBus Microcode Program: Hardware Loop Countdown Demonstration
; Task 09: Demonstrates zero-overhead nested hardware loop counters (LC0, LC1)
;
; LC0: Inner loop counter (counts down 15 -> 0, pushing value to o_data / LEDs)
; LC1: Outer loop counter (repeats the countdown cycle)
; =============================================================================

.clock 50000000
.baud  115200

start:
    ; Outer loop: repeat 4 complete countdown cycles
    SET_LC LC1, 4

outer_loop:
    ; Inner loop: initialize LC0 to 15 (0x0F)
    SET_LC LC0, 15

inner_loop:
    PUSH_LC LC0         ; Output current loop count to o_data / LEDs
    NOP     $BAUD       ; Visible bit delay
    NOP     $BAUD
    DJNZ    LC0, inner_loop ; Decrement LC0; if != 0, jump back to inner_loop

    ; End of inner loop: push 0
    PUSH_LC LC0         ; LC0 is now 0x00
    NOP     $BAUD
    NOP     $BAUD

    ; Decrement outer loop counter LC1
    DJNZ    LC1, outer_loop ; Repeat countdown cycle until LC1 reaches 0

done:
    ; Loop forever displaying final count (0x00)
    JMP     done
