; ==============================================================================
; File        : omnibus.inc
; Description : OmniBus Core Assembly Standard Definitions & Helper Macros
; License     : MIT License
; ==============================================================================

; --- Master Clock & Baud Sentinels ---
.const BAUD_SENTINEL   0x1FF  ; $BAUD: Uses runtime hardware i_baud_div
.const HBAUD_SENTINEL  0x1FE  ; $HBAUD: Uses runtime hardware i_baud_div / 2

; --- Pin Mapping Identifiers ---
.const PIN_TX          0      ; UIO[0] / MOSI / SDA / D+
.const PIN_RX          1      ; UIO[1] / MISO / SCL / D-
.const PIN_SCK         2      ; UIO[2] / DIN
.const PIN_CS          3      ; UIO[3] / JOYBUS
.const PIN_AUDIO       4      ; UIO[4] / PDM_AUDIO
.const PIN_GLITCH      5      ; UIO[5] / GLITCH_OUT

; --- Micro-ALU Opcodes (Opcode 0xB) ---
.const ALU_ADD         0
.const ALU_SUB         1
.const ALU_CMP         2
.const ALU_AND         3
.const ALU_OR          4
.const ALU_XOR         5
.const ALU_MOV         6
.const ALU_NOT         7

; --- Jump Conditions (Opcode 0x8) ---
.const COND_ALWAYS     0
.const COND_ZERO       1
.const COND_NZ         2
.const COND_CARRY      3
.const COND_NC         4
.const COND_FIFO_EMPTY 5
.const COND_FIFO_FULL  6
.const COND_I2C_START  7
.const COND_I2C_STOP   8
.const COND_SWD_ACK    9
.const COND_MATCH      10
