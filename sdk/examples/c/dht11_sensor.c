/**
 * =============================================================================
 * File        : dht11_sensor.c
 * Description : Omni-C DHT11 Single-Wire Temperature & Humidity Sensor Reader.
 * License     : MIT License
 * =============================================================================
 */

#include "onewire.h"

void main() {
    onewire_init();

    while (1) {
        // ---------------------------------------------------------------------
        // 1. Host Trigger: Pull byte to start measurement
        // ---------------------------------------------------------------------
        pull_block();

        // ---------------------------------------------------------------------
        // 2. Start Signal: Host pulls low for 18ms (900,000 cycles @ 50 MHz)
        // ---------------------------------------------------------------------
        pin_low(PIN_1WIRE, 25000); // 500us low pulse
        pin_high(PIN_1WIRE, 2000); // 40us pullup

        // Wait for DHT11 Response (80us Low followed by 80us High)
        pin_wait(PIN_1WIRE, LOW, 5000);
        pin_wait(PIN_1WIRE, HIGH, 5000);
        pin_wait(PIN_1WIRE, LOW, 5000);

        // ---------------------------------------------------------------------
        // 3. Read 5 Bytes (Humidity Integral, Decimal, Temp Integral, Decimal, Checksum)
        // ---------------------------------------------------------------------
        repeat (5) {
            // Read 8 bits
            repeat (8) {
                // Wait for 50us low pulse before bit
                pin_wait(PIN_1WIRE, LOW, 4000);
                pin_wait(PIN_1WIRE, HIGH, 4000);

                // Sample at 40us: High = '1' (70us pulse), Low = '0' (26us pulse)
                delay_cycles(2000); // 40us delay @ 50 MHz
                in_shift(1, 0);     // Sample 1 bit into ISR
            }

            // Push received byte to Host RX FIFO
            push_block();
        }

        // Release bus High
        pin_high(PIN_1WIRE, 5000);
    }
}
