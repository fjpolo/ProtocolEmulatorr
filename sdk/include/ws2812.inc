; ==============================================================================
; File        : ws2812.inc
; Description : OmniBus Assembly Standard Header for WS2812B / NeoPixel LEDs
; License     : MIT License
; ==============================================================================

; Timing at 50 MHz (20 ns/cycle):
; T0H (350 ns) = 17 cycles, T0L (850 ns) = 43 cycles
; T1H (700 ns) = 35 cycles, T1L (500 ns) = 25 cycles
.const NEO_T0H             17
.const NEO_T0L             43
.const NEO_T1H             35
.const NEO_T1L             25
.const NEO_RESET_CYCLES    2500 ; >50 us low

din = uio[2]
