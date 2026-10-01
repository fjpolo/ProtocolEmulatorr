/**
 * =============================================================================
 * File        : onewire.h
 * Description : Omni-C Dallas 1-Wire Master Protocol Driver.
 * License     : MIT License
 * =============================================================================
 */

#ifndef OMNIBUS_ONEWIRE_H
#define OMNIBUS_ONEWIRE_H

#include "omnibus.h"

// Initialize 1-Wire Open-Drain Bus on Pin 0
void onewire_init() {
    cfg_od(0x01); // Pin 0 open-drain
    pin_high(PIN_1WIRE, 50);
}

// Reset pulse (480us Low, wait for presence pulse)
void onewire_reset() {
    pin_low(PIN_1WIRE, 24000);   // 480us Low @ 50 MHz
    pin_high(PIN_1WIRE, 3500);   // 70us High (wait for slave presence)
    pin_wait(PIN_1WIRE, LOW, 5000); // Sample presence pulse
    pin_high(PIN_1WIRE, 20000);  // Rest time
}

// Write 1 bit (1 = short 6us low, 0 = long 60us low)
void onewire_write_1() {
    pin_low(PIN_1WIRE, 300);    // 6us Low
    pin_high(PIN_1WIRE, 3200);  // 64us High
}

void onewire_write_0() {
    pin_low(PIN_1WIRE, 3000);   // 60us Low
    pin_high(PIN_1WIRE, 500);   // 10us High
}

#endif // OMNIBUS_ONEWIRE_H
