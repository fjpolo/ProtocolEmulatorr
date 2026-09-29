; ==============================================================================
; File        : spi.inc
; Description : OmniBus Assembly Standard Header for SPI Master / Flash Protocols
; License     : MIT License
; ==============================================================================

; Timing constants at 50 MHz:
; 25 MHz SPI Clock -> 2 cycles per period (1 cycle high, 1 cycle low)
; 10 MHz SPI Clock -> 5 cycles per period
.const SPI_25M_HALF        0
.const SPI_10M_HALF        2
.const SPI_1M_HALF         24

mosi = uio[0]
miso = uio[1]
sck  = uio[2]
cs_n = uio[3]
