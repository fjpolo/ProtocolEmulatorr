/**
 * =============================================================================
 * File        : spi.h
 * Description : Omni-C SPI Master Driver Library (Mode 0).
 * License     : MIT License
 * =============================================================================
 */

#ifndef OMNIBUS_SPI_H
#define OMNIBUS_SPI_H

#include "omnibus.h"

#define SPI_CLK_DELAY 2  // ~10 MHz SPI clock @ 50 MHz core

// Initialize SPI Pins (MOSI=0, MISO=1, SCK=2, CS_n=3)
void spi_init() {
    pin_map(0, 1, 2, 3);
    pin_high(PIN_CS, 5); // Idle CS# High
    pin_low(PIN_SCK, 5); // Mode 0: SCK Idle Low
}

// Assert Chip-Select (Active Low)
void spi_select() {
    pin_low(PIN_CS, 5);
}

// Deassert Chip-Select (Idle High)
void spi_deselect() {
    pin_high(PIN_CS, 5);
}

// Full-duplex transfer: transmit OSR, receive into ISR
void spi_transfer_byte() {
    out_sck(8, SPI_CLK_DELAY);
}

#endif // OMNIBUS_SPI_H
