; =============================================================================
; File        : packet_parser_demo.asm
; Description : Autonomous Variable-Length Packet Parser & Validator Demo
;               Demonstrates Task 15 Micro-ALU (Opcode 0xB), Inter-Register
;               Transfers, Arithmetic Loop Counter setup, and CRC Verification.
;
; Protocol Frame Format:
;   [0]      Sync / Magic Byte (Expected: 0x5A)
;   [1]      Payload Length N (1 to 255 bytes)
;   [2..N+1] Payload Data Bytes
;   [N+2]    Dallas 1-Wire CRC-8 Checksum
;
; Behavior:
;   - If magic != 0x5A -> emits NAK (0x15) and restarts
;   - If CRC corrupt   -> emits NAK (0x15) and restarts
;   - If packet valid  -> emits ACK (0x06) + inverted length byte
; =============================================================================

.clock 50000000
.baud  115200

start:
    ; 1. Wait for framing magic byte
    PULL BLOCK              ; OSR <= i_data (from host/FIFO)
    MOV acc, OSR            ; acc <= OSR
    CMP acc, 0x5A           ; Check magic header 0x5A
    JMP NOT_ZERO, bad_magic ; Magic mismatch -> emit error NAK

    ; 2. Read variable payload length byte N
    PULL BLOCK              ; OSR <= Length byte N
    MOV acc, OSR            ; acc <= N
    MOV LC0, acc            ; LC0 <= N (DJNZ iterates exactly N times)

    ; 3. Initialize CRC-8 Dallas engine
    CRC_INIT DALLAS, ZERO   ; crc_reg <= 0x0000

payload_loop:
    PULL BLOCK              ; Read next payload byte
    CRC_BYTE OSR            ; Accumulate CRC-8
    DJNZ LC0, payload_loop  ; Loop until all N bytes ingested

    ; 4. Read transmitted CRC-8 byte and verify residue
    PULL BLOCK              ; Read received CRC byte
    CRC_BYTE OSR            ; CRC state absorbs transmitted CRC
    JMP CRC_OK, packet_ok   ; Jump to ACK if crc_reg == 0x0000

bad_crc:
    MOV acc, 0x15           ; NAK (Corrupted checksum)
    MOV ISR, acc
    PUSH                    ; Emit NAK to RX FIFO / host
    JMP start

bad_magic:
    MOV acc, 0xFF           ; Error indicator (Bad magic sync)
    MOV ISR, acc
    PUSH                    ; Emit Error to RX FIFO / host
    JMP start

packet_ok:
    MOV acc, 0x06           ; ACK (Packet valid and verified)
    MOV ISR, acc
    PUSH                    ; Emit ACK
    JMP start
