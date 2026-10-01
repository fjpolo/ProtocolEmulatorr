/**
 * =============================================================================
 * File        : i2c_eeprom.c
 * Description : Omni-C 24C02 I2C EEPROM Byte Write and Byte Read State Machine.
 * License     : MIT License
 * =============================================================================
 */

#include "i2c.h"

#define EEPROM_ADDR 0xA0  // 24C02 7-bit address 0x50 << 1 (Write)

void main() {
    i2c_init();

    // -------------------------------------------------------------------------
    // 1. Write Byte to Address 0x05
    // -------------------------------------------------------------------------
    i2c_start();

    // Send Slave Address (0xA0 = Write)
    acc = 0xA0;
    osr = acc;
    i2c_write_byte();

    // Send Memory Address (0x05)
    acc = 0x05;
    osr = acc;
    i2c_write_byte();

    // Send Data Byte from host TX FIFO
    pull_block();
    i2c_write_byte();

    i2c_stop();
    delay_cycles(20); // EEPROM write cycle delay

    // -------------------------------------------------------------------------
    // 2. Random Read Byte from Address 0x05
    // -------------------------------------------------------------------------
    i2c_start();

    // Dummy write to set address pointer
    acc = 0xA0;
    osr = acc;
    i2c_write_byte();

    acc = 0x05;
    osr = acc;
    i2c_write_byte();

    // Repeated START for Read
    i2c_start();
    acc = 0xA1; // Slave Address (0xA1 = Read)
    osr = acc;
    i2c_write_byte();

    // Read byte into ISR and push to host RX FIFO
    i2c_read_byte_ack();
    push_block();

    i2c_stop();
}
