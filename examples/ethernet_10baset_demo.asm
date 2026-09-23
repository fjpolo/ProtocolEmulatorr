; ==============================================================================
; File        : ethernet_10baset_demo.asm
; Description : OmniBus 10BASE-T Ethernet Packet Transmitter (Task 19)
;               Features Autonomous Manchester Stream Acceleration (IEEE 802.3):
;                 - 7-byte Preamble (0x55 alternating bit pattern)
;                 - 1-byte Start Frame Delimiter (SFD: 0xD5)
;                 - Broadcast MAC Header & IPv4 EtherType
;                 - Cycle-accurate half-bit transitions (Center Rising/Falling)
; ==============================================================================

; Step 1: Configure physical pin mapping and push-pull drive
PINMAP tx=0, rx=1, sck=2, cs=3
CFG_OD 0x00

; Step 2: Enable Autonomous Manchester Accelerator (IEEE 802.3 standard)
ASSIST MANCH, IEEE

; Step 3: Transmit 7-byte 10BASE-T Preamble (0x55)
; In IEEE 802.3 Manchester, byte 0x55 produces continuous 10 MHz clock toggles
SET_LC 7
preamble_loop:
    ALU MOV, acc, 0x55
    ALU MOV, osr, acc
    OUT tx, 8, 4                ; Serialize 8 bits with Manchester center transitions
    DJNZ LC0, preamble_loop

; Step 4: Transmit Start Frame Delimiter (SFD: 0xD5 = 11010101b -> wire 10101011b)
ALU MOV, acc, 0xD5
ALU MOV, osr, acc
OUT tx, 8, 4

; Step 5: Transmit Destination MAC (Broadcast: FF:FF:FF:FF:FF:FF)
SET_LC 6
dst_mac_loop:
    ALU MOV, acc, 0xFF
    ALU MOV, osr, acc
    OUT tx, 8, 4
    DJNZ LC0, dst_mac_loop

; Step 6: Transmit Source MAC (02:00:00:12:34:56)
ALU MOV, acc, 0x02
ALU MOV, osr, acc
OUT tx, 8, 4

ALU MOV, acc, 0x12
ALU MOV, osr, acc
OUT tx, 8, 4

ALU MOV, acc, 0x34
ALU MOV, osr, acc
OUT tx, 8, 4

ALU MOV, acc, 0x56
ALU MOV, osr, acc
OUT tx, 8, 4

; Step 7: Transmit EtherType (0x0800 IPv4)
ALU MOV, acc, 0x08
ALU MOV, osr, acc
OUT tx, 8, 4

ALU MOV, acc, 0x00
ALU MOV, osr, acc
OUT tx, 8, 4

; Step 8: End of transmission: hold idle level
SET tx, 0, 50
NOP
