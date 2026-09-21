; =============================================================================
; OmniBus Microcode Program: SPI Mode 0 Master - Loopback Test
; Task 07: Demonstrates SPI bit-banging using pin selector extension.
;
; Protocol: SPI Mode 0 (CPOL=0 CPHA=0)
;   - CS_n asserted low before first bit, deasserted high after last bit
;   - MOSI driven BEFORE SCK rising edge (setup time)
;   - MISO sampled ON SCK rising edge
;   - SCK idles low
;
; This program continuously transmits byte 0xA5 (10100101b) and receives
; the echo via internal MOSI->MISO loopback. After each 8-bit transfer,
; o_data = 0xA5 (visible on Console 60K LEDs, LED[4:0] = 0b00101 = 5).
;
; Pin mapping (Task 07 ISA extension, instr[11:10]):
;   SET MOSI, val, delay  -> pin_id=0, drives o_tx  (TX/MOSI)
;   SET SCK,  val, delay  -> pin_id=1, drives o_spi_sck
;   SET CS,   val, delay  -> pin_id=2, drives o_spi_cs_n
;   IN  1,    delay       -> 1-bit sample from i_rx (MISO)
;
; Instruction count: 24 words (fits in 32-word IMEM with headroom)
;
; Timing: Uses $HBAUD sentinels for SCK half-period.
;   At i_baud_div=433 (115200 baud equivalent): SCK period = 2 * 216 * 20ns = 8.64us
;   For faster SPI: set i_baud_div via loader --set-baud or --set-div
;     e.g. --set-div 9  -> ~5 MHz SCK @ 50 MHz clock (div=9 -> period=10*20ns=200ns)
; =============================================================================

.clock 50000000
.baud  115200

; --- Main loop ----------------------------------------------------------
@0
start:
    SET  CS, 0, 0           ; [0]  Assert CS_n low (begin transaction)

    SET  MOSI, 1, 0         ; [1]  B7 = 1  (MSB first)
    CALL do_bit             ; [2]  SCK toggle + MISO sample

    SET  MOSI, 0, 0         ; [3]  B6 = 0
    CALL do_bit             ; [4]

    SET  MOSI, 1, 0         ; [5]  B5 = 1
    CALL do_bit             ; [6]

    SET  MOSI, 0, 0         ; [7]  B4 = 0
    CALL do_bit             ; [8]

    SET  MOSI, 0, 0         ; [9]  B3 = 0
    CALL do_bit             ; [10]

    SET  MOSI, 1, 0         ; [11] B2 = 1
    CALL do_bit             ; [12]

    SET  MOSI, 0, 0         ; [13] B1 = 0
    CALL do_bit             ; [14]

    SET  MOSI, 1, 0         ; [15] B0 = 1  (LSB)
    CALL do_bit             ; [16]

    SET  CS, 1, 0           ; [17] Deassert CS_n high (end transaction)
    PUSH                    ; [18] ISR -> OSR -> o_data (LEDs = received byte)
    JMP  start              ; [19] Loop back for next transfer

; --- Subroutine: do_bit -------------------------------------------------
; SCK rising edge: slave (loopback) samples MOSI here.
; MISO is sampled 1 bit into ISR during the high phase.
; SCK falling edge: prepare for next bit.
@20
do_bit:
    SET  SCK, 1, $HBAUD     ; [20] SCK high  (rising edge, half-bit wait)
    IN   1,   $HBAUD        ; [21] Sample MISO (1-bit, half-bit delay)
    SET  SCK, 0, $HBAUD     ; [22] SCK low   (falling edge, half-bit wait)
    RET                     ; [23] Return to caller
