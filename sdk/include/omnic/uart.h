/**
 * =============================================================================
 * File        : uart.h
 * Description : Omni-C UART Protocol Driver Library (8N1 Transceiver).
 * License     : MIT License
 * =============================================================================
 */

#ifndef OMNIBUS_UART_H
#define OMNIBUS_UART_H

#include "omnibus.h"

// Transmit 1 byte from OSR over UART (8N1 @ dynamic baud rate)
void uart_tx_byte() {
    // Start bit (Low)
    pin_low(PIN_TX, BAUD_DIV);
    // 8 Data bits (LSB-first)
    out_shift(8, BAUD_DIV);
    // Stop bit (High)
    pin_high(PIN_TX, BAUD_DIV);
}

// Receive 1 byte into ISR over UART (8N1 @ dynamic baud rate)
void uart_rx_byte() {
    // Wait for Falling Edge (Start Bit)
    pin_wait(PIN_RX, LOW, 0);
    // Mid-bit delay
    delay_hbaud();
    // Sample 8 data bits at mid-bit intervals
    in_shift(8, BAUD_DIV);
}

#endif // OMNIBUS_UART_H
