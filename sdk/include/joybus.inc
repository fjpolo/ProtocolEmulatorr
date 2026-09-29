; ==============================================================================
; File        : joybus.inc
; Description : OmniBus Assembly Standard Header for N64/GC Joybus (250 kbps)
; License     : MIT License
; ==============================================================================

; Timing at 50 MHz:
; 1 us pulse = 50 cycles
; 3 us pulse = 150 cycles
.const JOYBUS_1US          50
.const JOYBUS_3US          150
.const JOYBUS_OD_MASK      0x08  ; Pin 3 Open-Drain

joy_pin = uio[3]
