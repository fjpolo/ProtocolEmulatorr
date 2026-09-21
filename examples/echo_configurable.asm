; =============================================================================
; OmniBus Microcode Program: Configurable-Baud UART Echo Transceiver
; Task 06: Uses $BAUD / $HBAUD tokens that resolve to runtime i_baud_div.
;
; Unlike echo.asm (which uses hardcoded BIT_DELAY = 433 for 115200 @ 50 MHz),
; this program's timing tracks the baud_div register in OmniBootloader.
; Change the baud rate at runtime via:
;   python omnibus_loader.py --set-baud 57600 --file examples/echo_configurable.asm
;
; Encoding:
;   $BAUD  assembles to delay=9'h1FF → execution uses i_baud_div[8:0]
;   $HBAUD assembles to delay=9'h1FE → execution uses i_baud_div[8:0] >> 1
;
; Supported baud rates @ 50 MHz:
;   115200 (div=433), 57600 (div=867), 38400 (div=1301), 19200 (div=2603)
;   9600 (div=5207), 230400 (div=216), 460800 (div=107), 921600 (div=53)
; =============================================================================

.clock 50000000
.baud  115200

start:
    WAIT 0, $HBAUD  ; Wait for Start bit (RX=0), delay to mid-start (half bit)
    NOP  $BAUD      ; Advance 1.0 bit to center of Data Bit 0
    IN   8, $BAUD   ; Sample 8 data bits LSB-first (8 x full-bit delay)
    WAIT 1, 0       ; Confirm Stop bit logic-1 (no delay — immediate check)
    PUSH            ; Transfer ISR -> OSR for echo transmission
    SET  0, $BAUD   ; Transmit Start bit (0) for full bit period
    OUT  8, $BAUD   ; Transmit 8 data bits from OSR (8 x full-bit delay)
    SET  1, $BAUD   ; Transmit Stop bit (1) for full bit period
    JMP  start      ; Loop back to WAIT for next byte
