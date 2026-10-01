/**
 * =============================================================================
 * File        : dual_core_mailbox_sync.c
 * Description : Omni-C Dual-Core Synchronized Mailbox & Barrier Ping-Pong
 *               Core 0 (Bank 0): Producer / Dispatcher
 *               Core 1 (Bank 1): Processing Engine (+0x11 transformer)
 * Architecture: OmniBus MP Symmetric Multi-Core Micro-Engine
 * License     : MIT License
 * =============================================================================
 */

#include "omnibus.h"

// -----------------------------------------------------------------------------
// Core 0 (Bank 0)
// -----------------------------------------------------------------------------
#pragma core 0

void core0_producer(void) {
    uint8_t i = 0;
    while (i < 4) {
        // Step 1: Wait for rendezvous with Core 1
        barrier_wait();

        // Step 2: Acquire Spinlock 0 to send request
        while (spinlock_acquire(0) != 0) {
            // Spin
        }
        mailbox_write(0, 0x5A);
        spinlock_release(0);

        // Step 3: Wait for Core 1 reply on Spinlock 1
        while (spinlock_acquire(1) != 0) {
            // Spin
        }
        uint8_t res = mailbox_read(1);
        spinlock_release(1);

        // Step 4: Push transformed result to host FIFO
        push_block();

        // Step 5: Rendezvous before next frame
        barrier_wait();
        i++;
    }

    while (1) {
        delay_cycles(10);
    }
}

// -----------------------------------------------------------------------------
// Core 1 (Bank 1)
// -----------------------------------------------------------------------------
#pragma core 1

void core1_worker(void) {
    uint8_t j = 0;
    while (j < 4) {
        // Step 1: Rendezvous with Core 0
        barrier_wait();

        // Step 2: Poll Spinlock 0 for token
        while (spinlock_acquire(0) != 0) {
            // Spin
        }
        uint8_t val = mailbox_read(0);
        spinlock_release(0);

        // Step 3: Transform token
        val = val + 0x11;

        // Step 4: Acquire Spinlock 1 and write reply
        while (spinlock_acquire(1) != 0) {
            // Spin
        }
        mailbox_write(1, val);
        spinlock_release(1);

        // Step 5: Rendezvous
        barrier_wait();
        j++;
    }

    while (1) {
        delay_cycles(10);
    }
}
