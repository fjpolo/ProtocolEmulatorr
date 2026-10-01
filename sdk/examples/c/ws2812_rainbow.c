/**
 * =============================================================================
 * File        : ws2812_rainbow.c
 * Description : Omni-C WS2812B NeoPixel RGB LED Strip Pulse Streamer.
 * License     : MIT License
 * =============================================================================
 */

#include "ws2812.h"

void main() {
    ws2812_init();

    while (1) {
        // Latch reset pulse (>50us low)
        ws2812_reset();

        // Stream 8 RGB LEDs (24 bits per pixel: G, R, B)
        repeat (8) {
            // Pull Green byte from host FIFO and stream with hardware pulse assist
            pull_block();
            out_shift(8, 0);

            // Pull Red byte
            pull_block();
            out_shift(8, 0);

            // Pull Blue byte
            pull_block();
            out_shift(8, 0);
        }
    }
}
