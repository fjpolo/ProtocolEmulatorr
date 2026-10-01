/**
 * =============================================================================
 * File        : uart_echo.c
 * Description : Omni-C UART Full-Duplex Echo Transceiver.
 * License     : MIT License
 * =============================================================================
 */

#include "uart.h"

void main() {
    // Configure default pin routing: TX on Pin 0, RX on Pin 1
    pin_map(0, 1, 2, 3);
    pin_high(PIN_TX, 0); // Idle TX line High

    while (1) {
        // Wait for incoming byte from host or external UART
        pull_block();

        // Echo byte over physical UART TX pin
        uart_tx_byte();

        // Receive any incoming reply and push to host RX FIFO
        uart_rx_byte();
        push_block();
    }
}
