; ==============================================================================
; File        : i2c.inc
; Description : OmniBus Assembly Standard Header for I2C / SMBus Protocols
; License     : MIT License
; ==============================================================================

; Timing constants at 50 MHz:
; Standard Mode (100 kHz): Period = 500 cycles (Quarter period = 125 cycles)
; Fast Mode (400 kHz): Period = 125 cycles (Quarter period = 31 cycles)
.const I2C_100K_QUARTER    125
.const I2C_400K_QUARTER    31

; Open-drain mask: Pin 0 (SDA) + Pin 1 (SCL) = 0x03
.const I2C_OD_MASK         0x03

sda = uio[0]
scl = uio[1]
