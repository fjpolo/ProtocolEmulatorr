; ==============================================================================
; File        : mitm.inc
; Description : OmniBus Assembly Standard Header for Glitch Injection & MitM
; License     : MIT License
; ==============================================================================

; Default Glitch Trigger Pin: UIO[5]
.const GLITCH_DEFAULT_PIN  5
.const GLITCH_100NS_WIDTH  5  ; 5 cycles at 50 MHz = 100 ns

glitch_out = uio[5]
