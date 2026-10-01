; ==============================================================================
; OmniBus Example 03: WS2812B NeoPixel 800 kHz Asymmetric Pulse Driver
; ==============================================================================
.clock 50MHz

.const T0H 17
.const T0L 43
.const T1H 35
.const T1L 25

din = uio[2]

main:
    SET din, 0 [2500]          ; Reset pulse (>50us low)

send_pixel:
    ; Send 24-bit GRB Pixel Data
    SET_LC LC0, 24

pixel_loop:
    SET din, 1 [T1H]
    SET din, 0 [T1L]
    DJNZ LC0, pixel_loop

    SET din, 0 [3000]          ; Latch Frame
    JMP send_pixel
