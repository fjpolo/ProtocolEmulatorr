; ==============================================================================
; File        : chiptune.inc
; Description : OmniBus Assembly Standard Header for Chiptune Audio & PDM DAC
; License     : MIT License
; ==============================================================================

; Note half-periods in clock cycles at 50 MHz:
; A4 (440 Hz) -> Half-Period = 50,000,000 / (2 * 440) = 56,818 cycles
; C5 (523 Hz) -> Half-Period = 47,801 cycles
; E5 (659 Hz) -> Half-Period = 37,936 cycles
; G5 (784 Hz) -> Half-Period = 31,888 cycles

.const NOTE_A4_HALF        56818
.const NOTE_C5_HALF        47801
.const NOTE_E5_HALF        37936
.const NOTE_G5_HALF        31888

audio_out = uio[4]
