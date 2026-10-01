; ==============================================================================
; OmniBus Microcode — Compiled by Omni-C (omnibus-cc)
; Target Architecture: OmniBus 16-bit Deterministic Protocol Engine
; ==============================================================================
.clock 50000000
.entry main
.const PIN_TX 0
.const PIN_RX 1
.const PIN_SCK 2
.const PIN_CS 3
.const PIN_SDA 0
.const PIN_SCL 1
.const PIN_1WIRE 0
.const PIN_PULSE 0
.const PIN_AUDIO 0
.const PIN_GLITCH 5
.const HIGH 1
.const LOW 0
.const HIGH_Z 0
.const I2C_DELAY 30
; --- Function: i2c_init ---
i2c_init:
CFG_OD 3
SET 0, 1 [0x0A]
SET 1, 1 [0x0A]
RET
i2c_start:
SET 0, 1 [30]
SET 1, 1 [30]
SET 0, 0 [30]
SET 1, 0 [30]
RET
i2c_stop:
SET 0, 0 [30]
SET 1, 1 [30]
SET 0, 1 [30]
RET
i2c_write_byte:
OUT SCK, 8 [30]
SET 0, 1 [30]
SET 1, 1 [30]
WAIT 1, 1 [0x3E8]
SET 1, 0 [30]
RET
i2c_read_byte_ack:
SET 0, 1 [0]
IN SCK, 8 [30]
SET 0, 0 [30]
SET 1, 1 [30]
SET 1, 0 [30]
SET 0, 1 [30]
RET
main:
CALL i2c_init
CALL i2c_start
MOV acc, 0xA0
MOV osr, acc
CALL i2c_write_byte
MOV acc, 5
MOV osr, acc
CALL i2c_write_byte
PULL BLOCK
CALL i2c_write_byte
CALL i2c_stop
NOP [0x14]
CALL i2c_start
MOV acc, 0xA0
MOV osr, acc
CALL i2c_write_byte
MOV acc, 5
MOV osr, acc
CALL i2c_write_byte
CALL i2c_start
MOV acc, 0xA1
MOV osr, acc
CALL i2c_write_byte
CALL i2c_read_byte_ack
PUSH BLOCK
CALL i2c_stop
