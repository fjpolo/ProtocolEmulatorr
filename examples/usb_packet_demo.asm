; =============================================================================
; File        : usb_packet_demo.asm
; Description : Autonomous USB 1.1 Stream Acceleration Demo
;               Demonstrates Task 17 Stream Accelerators:
;                 - Opcode 0xF: ASSIST CFG (NRZI=1, STUFF=USB, INIT=1)
;                 - Hardware NRZI Encoding/Decoding (toggle on 0, hold on 1)
;                 - Hardware Autonomous Bit-Stuffing (inserts '0' after six 1s)
;                 - Hardware Bit-Destuffing on RX
;                 - Hardware Bit-Stuff Violation Detection (JMP STUFF_ERR)
;                 - Real-time USB Packet Assembly (SYNC, PID, DATA, CRC)
;
; Frame Format (USB 1.1 Full/Low Speed Token/Data Packet):
;   [0] SYNC Field : 0x80 (Binary 10000000 -> NRZI K-J-K-J-K-J-K-K pattern)
;   [1] PID Field  : 0xC3 (DATA0 PID: Packet ID 0x3, complement 0xC)
;   [2] Data 0     : 0x7E (Contains 6 consecutive '1's -> triggers bit-stuffing!)
;   [3] Data 1     : 0x55 (Alternating 0/1 pattern)
;   [4] EOP / Status Handshake
; =============================================================================

.clock 50000000
.baud  12000000      ; 12 Mbps Full-Speed USB clock rate or scaled baud

start:
    ; -------------------------------------------------------------------------
    ; 1. Configure Autonomous Stream Accelerators
    ;    Enable NRZI encoding/decoding and USB 1.1 bit-stuffing (stuff 0 after 6x 1s)
    ;    Initialize line state to Idle High ('1')
    ; -------------------------------------------------------------------------
    ASSIST CFG, NRZI=1, STUFF=USB, INIT=1

    ; -------------------------------------------------------------------------
    ; 2. Transmit USB Packet Header
    ; -------------------------------------------------------------------------
    ; SYNC Field: 0x80 (LSB first: 0,0,0,0,0,0,0,1)
    MOV acc, 0x80
    MOV OSR, acc
    OUT 8, 4

    ; PID Field: 0xC3 (DATA0: 0011_1100 inverted check nibble)
    MOV acc, 0xC3
    MOV OSR, acc
    OUT 8, 4

    ; -------------------------------------------------------------------------
    ; 3. Transmit Payload with Run of Six '1's
    ;    0x7E = 0b0111_1110 (LSB first: 0, 1, 1, 1, 1, 1, 1, 0)
    ;    Hardware bit-stuffer autonomously inserts a '0' stuff bit after the 6th '1'
    ;    without any software delay or microcode intervention!
    ; -------------------------------------------------------------------------
    MOV acc, 0x7E
    MOV OSR, acc
    OUT 8, 4

    ; Transmit trailing byte: 0x55
    MOV acc, 0x55
    MOV OSR, acc
    OUT 8, 4

    ; -------------------------------------------------------------------------
    ; 4. Check for Stream Errors
    ; -------------------------------------------------------------------------
    JMP STUFF_ERR, err_stuff

    ; Success indicator: emit ACK response (0x4B / 0x06) to host FIFO
    MOV acc, 0x06
    MOV ISR, acc
    PUSH
    JMP halt

err_stuff:
    ; Stuff error flag asserted: emit NAK / error (0xFF) to host FIFO
    MOV acc, 0xFF
    MOV ISR, acc
    PUSH

halt:
    JMP halt
