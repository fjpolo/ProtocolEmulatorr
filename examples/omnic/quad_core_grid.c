/**
 * =============================================================================
 * File        : quad_core_grid.c
 * Description : Omni-C Quad-Core (4-Core) Symmetric Pipelined Accelerator
 *               Core 0 (Bank 0 / 0x00): Ingress Stream Ingest (Host FIFO -> Core 1)
 *               Core 1 (Bank 1 / 0x20): Cryptographic Transform (XOR 0xAA -> Mailbox 2)
 *               Core 2 (Bank 2 / 0x40): Hardware Checksum / Forwarding -> Mailbox 3
 *               Core 3 (Bank 3 / 0x60): High-Speed SPI Egress & Host Return
 * Architecture: OmniBus MP Symmetric Multi-Core Micro-Engine (NUM_CORES=4)
 * License     : MIT License
 * =============================================================================
 */

#include "omnibus.h"
#include "spi.h"

// -----------------------------------------------------------------------------
// Core 0: Ingress Engine (Bank 0 / 0x00)
// -----------------------------------------------------------------------------
#pragma core 0

void core0_ingress(void) {
    uint8_t k = 0;
    while (k < 8) {
        barrier_wait();
        pull_block();
        push_block();
        barrier_wait();
        k++;
    }

    while (1) {
        delay_cycles(10);
    }
}

// -----------------------------------------------------------------------------
// Core 1: Crypto Transform Slice (Bank 1 / 0x20)
// -----------------------------------------------------------------------------
#pragma core 1

void core1_crypto(void) {
    uint8_t k = 0;
    while (k < 8) {
        barrier_wait();
        pull_block();
        uint8_t masked = osr ^ 0xAA;

        while (spinlock_acquire(2) != 0) {
            // Spin
        }
        mailbox_write(2, masked);
        spinlock_release(2);

        barrier_wait();
        k++;
    }

    while (1) {
        delay_cycles(10);
    }
}

// -----------------------------------------------------------------------------
// Core 2: Forwarding & Transformation Slice (Bank 2 / 0x40)
// -----------------------------------------------------------------------------
#pragma core 2

void core2_forward(void) {
    uint8_t k = 0;
    while (k < 8) {
        barrier_wait();

        while (spinlock_acquire(2) != 0) {
            // Spin
        }
        uint8_t val = mailbox_read(2);
        spinlock_release(2);

        // Invert bits
        val = ~val;

        while (spinlock_acquire(3) != 0) {
            // Spin
        }
        mailbox_write(3, val);
        spinlock_release(3);

        barrier_wait();
        k++;
    }

    while (1) {
        delay_cycles(10);
    }
}

// -----------------------------------------------------------------------------
// Core 3: SPI Egress Slice (Bank 3 / 0x60)
// -----------------------------------------------------------------------------
#pragma core 3

void core3_egress(void) {
    pin_map(4, 7, 5, 6);

    uint8_t k = 0;
    while (k < 8) {
        barrier_wait();

        while (spinlock_acquire(3) != 0) {
            // Spin
        }
        uint8_t out_val = mailbox_read(3);
        spinlock_release(3);

        // SPI Master transmit
        pin_low(PIN_CS, 2);
        out_sck(8, 2);
        pin_high(PIN_CS, 2);

        // Return status to host
        push_block();

        barrier_wait();
        k++;
    }

    while (1) {
        delay_cycles(10);
    }
}
