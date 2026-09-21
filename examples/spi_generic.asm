; =============================================================================
; OmniBus Microcode Program: SPI Mode 0 Generic Transceiver
; Task 07B: Demonstrates OUT SCK (MSB-first + auto SCK + MISO sampling).
;
; This is a 6-instruction SPI loop. Any byte sent via the OmniBootloader 'D'
; command is transmitted as SPI and received via MISO loopback into o_data.
;
; Usage (via omnibus_loader.py):
;   python omnibus_loader.py --file examples/spi_generic.asm  # load microcode
;   python omnibus_loader.py --spi-data 0xA5                  # send byte 0xA5
;   python omnibus_loader.py --spi-data 0x3C                  # send byte 0x3C
;   (LEDs update each time --spi-data is called)
;
; OUT SCK syntax (Task 07B extension):
;   OUT SCK, delay    ->  [15:12]=1, [11:10]=01 (pin_id=SCK), [8:0]=delay
;   Per-bit: MOSI=osr[7], SCK=1 (wait delay), MISO->ISR, SCK=0 (wait delay)
;   MSB-first, 8 bits. Full-duplex (MISO sampled on SCK rising edge).
;
; PULL loads i_data[7:0] into OSR. OmniBootloader 'D' command sets i_data.
;
; Timing: $HBAUD sentinel = i_baud_div[8:0]>>1 (half the bit period).
;   At default 115200 baud (div=433): SCK period = 2 * 216 * 20ns = 8.64us
;   For 1 MHz SPI: use --set-baud 1000000 (div=49, half=24, SCK=960ns period)
;   For 5 MHz SPI: use --set-baud 5000000 (div=9,  half=4,  SCK=200ns period)
;
; IMEM size: 6 words (0..5). Remaining 26 words are unused.
; =============================================================================

.clock 50000000
.baud  115200

@0
spi_loop:
    PULL                    ; [0] OSR = i_data[7:0]  (host byte via 'D' command)
    SET  CS, 0, 0           ; [1] Assert CS_n low  (begin SPI transaction)
    OUT  SCK, $HBAUD        ; [2] Serialize 8 bits: MOSI (MSB-first) + auto SCK + MISO -> ISR
    SET  CS, 1, 0           ; [3] Deassert CS_n high (end SPI transaction)
    PUSH                    ; [4] ISR -> OSR -> o_data  (LEDs show received byte)
    JMP  spi_loop           ; [5] Wait for next PULL (loops when new i_data loaded)
