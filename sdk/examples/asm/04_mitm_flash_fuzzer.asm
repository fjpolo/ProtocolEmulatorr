; ==============================================================================
; OmniBus Example 04: Active MitM SPI Command Match-and-Mutate & Glitch Trigger
; ==============================================================================
.clock 50MHz

mosi = uio[0]
miso = uio[1]
glitch_trig = uio[5]

main:
    ; Arm Glitch & MitM Subsystems
    GLITCH_WIDTH 5             ; 5 cycles = 100 ns glitch pulse
    MITM_MATCH 0x9F            ; Match SPI Flash Read ID Command (0x9F)
    MITM_REPLACE 0x37          ; Fuzzed replacement payload
    MITM_ENABLE 1

monitor_bus:
    IN mosi, 8                 ; Sample incoming wire byte
    CMP 0x9F
    JMP NE, monitor_bus        ; Loop until matched

trigger_glitch:
    ; Fire hardware synchronized glitch pulse
    GLITCH_TRIG 1
    SET glitch_trig, 1 [5]
    SET glitch_trig, 0 [100]

    JMP monitor_bus
