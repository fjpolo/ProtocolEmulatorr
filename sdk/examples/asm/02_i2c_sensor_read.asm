; ==============================================================================
; OmniBus Example 02: I2C Sensor Master Read with Open-Drain Arbitration
; ==============================================================================
.clock 50MHz

.const HALF_PERIOD 125         ; 400 kHz Fast-Mode quarter cycle delay

sda = uio[0]
scl = uio[1]

main:
    CFG_OD 0x03                ; Configure SDA and SCL as Open-Drain
    SET sda, 1 [HALF_PERIOD]   ; Release lines high (idle)
    SET scl, 1 [HALF_PERIOD]

start_cond:
    ; Generate I2C START (SDA falls while SCL is High)
    SET sda, 0 [HALF_PERIOD]
    SET scl, 0 [HALF_PERIOD]

write_addr:
    ; Send 7-bit Device Address (0x48 Temperature Sensor + Write = 0x90)
    MOV acc, 0x90
    SET_LC LC0, 8

addr_loop:
    OUT sda, 1 [HALF_PERIOD]   ; Shift out bit
    SET scl, 1 [HALF_PERIOD]   ; Clock High
    WAIT scl, 1 [1000]         ; Handle Clock Stretching by slave
    SET scl, 0 [HALF_PERIOD]   ; Clock Low
    DJNZ LC0, addr_loop

sample_ack:
    SET sda, 1 [HALF_PERIOD]   ; Release SDA for Slave ACK
    SET scl, 1 [HALF_PERIOD]
    IN sda, 1                  ; Sample ACK (0 = ACK, 1 = NACK)
    SET scl, 0 [HALF_PERIOD]

stop_cond:
    ; Generate I2C STOP (SDA rises while SCL is High)
    SET sda, 0 [HALF_PERIOD]
    SET scl, 1 [HALF_PERIOD]
    SET sda, 1 [HALF_PERIOD]

halt:
    JMP halt
