/**
 * =============================================================================
 * File        : mitm.h
 * Description : Omni-C Wire-Speed Man-in-the-Middle (MitM) & Glitch Fuzzer Driver.
 * License     : MIT License
 * =============================================================================
 */

#ifndef OMNIBUS_MITM_H
#define OMNIBUS_MITM_H

#include "omnibus.h"

// Arm Sub-Cycle Hardware Glitch Generator
void glitch_arm() {
    assist_glitch_arm();
}

#endif // OMNIBUS_MITM_H
