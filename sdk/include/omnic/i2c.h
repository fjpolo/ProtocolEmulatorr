/**
 * =============================================================================
 * File        : i2c.h
 * Description : Omni-C I2C Master Driver Library with Clock Stretching.
 * License     : MIT License
 * =============================================================================
 */

#ifndef OMNIBUS_I2C_H
#define OMNIBUS_I2C_H

#include "omnibus.h"

#define I2C_DELAY 30  // ~400 kHz Fast-Mode quarter cycle delay @ 50 MHz

// Initialize I2C Open-Drain Bus on SDA (Pin 0) and SCL (Pin 1)
void i2c_init() {
    cfg_od(0x03);          // Enable open-drain on pins 0 & 1
    pin_high(PIN_SDA, 10); // Release SDA
    pin_high(PIN_SCL, 10); // Release SCL
}

// Generate I2C START condition (SDA falls while SCL is high)
void i2c_start() {
    pin_high(PIN_SDA, I2C_DELAY);
    pin_high(PIN_SCL, I2C_DELAY);
    pin_low(PIN_SDA, I2C_DELAY);
    pin_low(PIN_SCL, I2C_DELAY);
}

// Generate I2C STOP condition (SDA rises while SCL is high)
void i2c_stop() {
    pin_low(PIN_SDA, I2C_DELAY);
    pin_high(PIN_SCL, I2C_DELAY);
    pin_high(PIN_SDA, I2C_DELAY);
}

// Write 1 byte from OSR and sample ACK bit
void i2c_write_byte() {
    out_sck(8, I2C_DELAY);
    // Release SDA for ACK, pulse SCL
    pin_high(PIN_SDA, I2C_DELAY);
    pin_high(PIN_SCL, I2C_DELAY);
    pin_wait(PIN_SCL, HIGH, 1000); // Hardware clock stretching wait
    pin_low(PIN_SCL, I2C_DELAY);
}

// Read 1 byte into ISR and send ACK
void i2c_read_byte_ack() {
    pin_high(PIN_SDA, 0); // Release SDA (input)
    in_sck(8, I2C_DELAY);
    // Drive ACK (Low)
    pin_low(PIN_SDA, I2C_DELAY);
    pin_high(PIN_SCL, I2C_DELAY);
    pin_low(PIN_SCL, I2C_DELAY);
    pin_high(PIN_SDA, I2C_DELAY);
}

#endif // OMNIBUS_I2C_H
