/**
 * =============================================================================
 * File        : ws2812.h
 * Description : Omni-C WS2812B NeoPixel Asymmetric Pulse Driver Library.
 * License     : MIT License
 * =============================================================================
 */

#ifndef OMNIBUS_WS2812_H
#define OMNIBUS_WS2812_H

#include "omnibus.h"

// Initialize WS2812B Hardware Pulse Accelerator (800 kHz NRZ)
// T0H = 350ns (~17 cycles), T0L = 800ns (~40 cycles)
// T1H = 700ns (~35 cycles), T1L = 600ns (~30 cycles)
void ws2812_init() {
    assist_pulse_cfg(0);       // Mode 0: WS2812 asymmetric timing
    assist_pulse_time0(17, 40);
    assist_pulse_time1(35, 30);
    pin_low(PIN_PULSE, 10);
}

// Reset latch (>50us low pulse)
void ws2812_reset() {
    pin_low(PIN_PULSE, 2500); // 50us @ 50 MHz
}

#endif // OMNIBUS_WS2812_H
