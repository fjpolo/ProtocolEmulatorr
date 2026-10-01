/**
 * =============================================================================
 * File        : omnibus.h
 * Description : Core Omni-C Standard Library for the OmniBus Protocol Engine.
 * License     : MIT License
 * =============================================================================
 */

#ifndef OMNIBUS_H
#define OMNIBUS_H

#pragma clock 50MHz
#pragma baud 115200

// Standard Pin Aliases
#define PIN_TX      0
#define PIN_RX      1
#define PIN_SCK     2
#define PIN_CS      3
#define PIN_SDA     0
#define PIN_SCL     1
#define PIN_1WIRE   0
#define PIN_PULSE   0
#define PIN_AUDIO   0
#define PIN_GLITCH  5

// Logic Levels
#define HIGH        1
#define LOW         0
#define HIGH_Z      0

// Dynamic Baud Sentinels
#define BAUD_DIV    $BAUD
#define HBAUD_DIV   $HBAUD

// Hardware Status Flags
#define FLAG_ZERO       zero
#define FLAG_CARRY      carry
#define FLAG_I2C_MATCH  i2c_match

#endif // OMNIBUS_H
