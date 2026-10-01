/**
 * =============================================================================
 * File        : mitm_fuzzer.c
 * Description : Omni-C Active Wire-Speed MitM Packet Mutator & Glitch Fuzzer.
 * License     : MIT License
 * =============================================================================
 */

#include "mitm.h"

#define MATCH_CMD_FLASH_ID 0x9F
#define REPLACE_BYTE       0xEF  // Mutate flash manufacturer ID to Winbond

void main() {
    // -------------------------------------------------------------------------
    // 1. Arm Hardware Glitch Pulse Generator (fires 5-cycle glitch on Pin 5)
    // -------------------------------------------------------------------------
    assist_glitch_cfg(5);  // Width = 5 clock cycles (100ns @ 50 MHz)
    assist_glitch_arm();

    // -------------------------------------------------------------------------
    // 2. Configure Wire-Speed MitM Match-and-Mutate Engine
    // -------------------------------------------------------------------------
    assist_mitm_match(MATCH_CMD_FLASH_ID);
    assist_mitm_replace(REPLACE_BYTE);
    assist_mitm_enable();

    // -------------------------------------------------------------------------
    // 3. Real-Time Wire-Speed Pass-Through & Mutation Loop
    // -------------------------------------------------------------------------
    while (1) {
        // Read byte from in-line bus
        in_shift(8, 0);

        // Check if MitM pattern matched (hardware status condition)
        if (FLAG_I2C_MATCH) {
            // Log mutation event by pushing modified byte to telemetry FIFO
            push_block();
        }
    }
}
