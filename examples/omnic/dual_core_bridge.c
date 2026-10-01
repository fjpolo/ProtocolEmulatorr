/**
 * =============================================================================
 * File        : dual_core_bridge.c
 * Description : OmniBus MP Dual-Core Asymmetric UART-to-SPI Multi-Protocol Bridge
 *               Core 0 (Bank 0): High-speed UART Transceiver (Pins 0..3)
 *               Core 1 (Bank 1): Master SPI Controller (Pins 4..7)
 *               Synchronized via Shared Hardware Mailbox 0 and Spinlock 0.
 * Architecture: OmniBus MP Symmetric Multi-Core Micro-Engine
 * License     : MIT License
 * =============================================================================
 */

#include "omnibus.h"
#include "uart.h"
#include "spi.h"

// -----------------------------------------------------------------------------
// Core 0 Execution Slice (Origin: 0x00 / Bank 0)
// -----------------------------------------------------------------------------
#pragma core 0

void core0_uart_rx(void) {
    // Map UART transceiver pins (TX=0, RX=3)
    pin_map(0, 3, 1, 2);

    while (1) {
        // Wait for incoming UART Start Bit and sample 8 data bits
        pin_wait(PIN_RX, 0, HBAUD_DIV);
        delay_cycles(BAUD_DIV);
        uart_rx_byte();
        pin_wait(PIN_RX, 1, 0);

        // Synchronize and write byte to Shared Mailbox 0
        while (spinlock_acquire(0) != 0) {
            // Spin until lock acquired
        }

        mailbox_write(0, isr);
        spinlock_release(0);
    }
}

// -----------------------------------------------------------------------------
// Core 1 Execution Slice (Origin: 0x20 / Bank 1)
// -----------------------------------------------------------------------------
#pragma core 1

void core1_spi_tx(void) {
    // Map SPI Master pins (MOSI=4, MISO=7, SCK=5, CS=6)
    pin_map(4, 7, 5, 6);

    while (1) {
        // Poll Spinlock 0 for bridged UART payload
        while (spinlock_acquire(0) != 0) {
            // Spin until lock acquired
        }

        // Fetch received byte from Mailbox 0
        uint8_t data = mailbox_read(0);
        spinlock_release(0);

        // Transmit over SPI bus with active-low CS toggle
        pin_low(PIN_CS, 4);
        out_sck(8, 4);
        pin_high(PIN_CS, 4);

        delay_cycles(10);
    }
}
