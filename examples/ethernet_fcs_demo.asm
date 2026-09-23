; ==============================================================================
; File        : ethernet_fcs_demo.asm
; Description : OmniBus 10BASE-T Ethernet Packet Transmitter with Hardware FCS (Task 20)
;               Features:
;                 - Autonomous Manchester Stream Accelerator (IEEE 802.3)
;                 - Hardware CRC-32 Engine (IEEE 802.3 Ethernet FCS, poly 0xEDB88320)
;                 - 7-byte Preamble (0x55) + 1-byte SFD (0xD5)
;                 - MAC Destination, Source, EtherType (IPv4: 0x0800)
;                 - 4-byte FCS Readout (B0, B1, B2, B3) serialized over Manchester
; ==============================================================================

; Step 1: Configure physical pin mapping and push-pull drive
PINMAP tx=0, rx=1, sck=2, cs=3
CFG_OD 0x00

; Step 2: Initialize Hardware CRC-32 Accelerator (IEEE 802.3 Ethernet FCS)
; Default seed is 0xFFFFFFFF, poly is 0xEDB88320 (reflected)
CRC_INIT ETHERNET

; Step 3: Enable Autonomous Manchester Accelerator (IEEE 802.3 standard)
ASSIST MANCH, IEEE

; Step 4: Transmit 7-byte 10BASE-T Preamble (0x55)
; (Note: Preamble and SFD are NOT included in the FCS calculation)
SET_LC 7
preamble_loop:
    ALU MOV, acc, 0x55
    ALU MOV, osr, acc
    OUT tx, 8, 4                ; Serialize 8 bits with Manchester center transitions
    DJNZ LC0, preamble_loop

; Step 5: Transmit Start Frame Delimiter (SFD: 0xD5)
ALU MOV, acc, 0xD5
ALU MOV, osr, acc
OUT tx, 8, 4

; Step 6: Transmit Destination MAC (Broadcast: FF:FF:FF:FF:FF:FF) & accumulate CRC-32
SET_LC 6
dst_mac_loop:
    ALU MOV, acc, 0xFF
    ALU MOV, osr, acc
    CRC_BYTE OSR                ; Feed OSR into hardware CRC-32 engine
    OUT tx, 8, 4
    DJNZ LC0, dst_mac_loop

; Step 7: Transmit Source MAC (02:00:00:12:34:56) & accumulate CRC-32
ALU MOV, acc, 0x02
ALU MOV, osr, acc
CRC_BYTE OSR
OUT tx, 8, 4

ALU MOV, acc, 0x12
ALU MOV, osr, acc
CRC_BYTE OSR
OUT tx, 8, 4

ALU MOV, acc, 0x34
ALU MOV, osr, acc
CRC_BYTE OSR
OUT tx, 8, 4

ALU MOV, acc, 0x56
ALU MOV, osr, acc
CRC_BYTE OSR
OUT tx, 8, 4

; Step 8: Transmit EtherType (0x0800 IPv4) & accumulate CRC-32
ALU MOV, acc, 0x08
ALU MOV, osr, acc
CRC_BYTE OSR
OUT tx, 8, 4

ALU MOV, acc, 0x00
ALU MOV, osr, acc
CRC_BYTE OSR
OUT tx, 8, 4

; Step 9: Transmit 4-byte Frame Check Sequence (FCS)
; In 802.3, the FCS remainder is transmitted inverted (1's complement) LSB-first.
; Byte 0:
CRC_READ_B0                     ; Copy crc_reg[7:0] to OSR and o_data
ALU MOV, acc, osr
ALU NOT                         ; 1's complement inversion
ALU MOV, osr, acc
OUT tx, 8, 4

; Byte 1:
CRC_READ_B1                     ; Copy crc_reg[15:8] to OSR and o_data
ALU MOV, acc, osr
ALU NOT
ALU MOV, osr, acc
OUT tx, 8, 4

; Byte 2:
CRC_READ_B2                     ; Copy crc_reg[23:16] to OSR and o_data
ALU MOV, acc, osr
ALU NOT
ALU MOV, osr, acc
OUT tx, 8, 4

; Byte 3:
CRC_READ_B3                     ; Copy crc_reg[31:24] to OSR and o_data
ALU MOV, acc, osr
ALU NOT
ALU MOV, osr, acc
OUT tx, 8, 4

; Step 10: Hold line idle
SET tx, 0, 50
NOP
