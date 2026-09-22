; =============================================================================
; OmniBus Microcode Program: Open-Drain Mode Demo
; Demonstrates CFG_OD (Opcode 0x6) for I2C/1-Wire style open-drain pin control.
;
; In this example:
;   Pin 4 is configured as open-drain via CFG_OD (mask 0x10 = 8'b00010000).
;   SET 4, 0 actively drives the pin LOW (o_gpio[4]=0, o_gpio_oe[4]=1).
;   SET 4, 1 releases the pin to float HIGH (o_gpio[4]=1, o_gpio_oe[4]=0).
; =============================================================================

.clock 50000000
.baud  115200

start:
    ; Set Pin 4 as open-drain (bit 4 of mask = 1)
    CFG_OD 0x10

od_loop:
    ; Drive Pin 4 low for 1 bit period
    SET 4, 0, $BAUD

    ; Release Pin 4 high (Hi-Z, external pull-up) for 1 bit period
    SET 4, 1, $BAUD

    ; Repeat
    JMP od_loop
