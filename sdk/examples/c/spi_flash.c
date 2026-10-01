/**
 * =============================================================================
 * File        : spi_flash.c
 * Description : Omni-C Winbond W25Q128 SPI Flash JEDEC ID Read and Fast Read.
 * License     : MIT License
 * =============================================================================
 */

#include "spi.h"

#define CMD_READ_JEDEC_ID 0x9F
#define CMD_READ_DATA     0x03

void main() {
    spi_init();

    // -------------------------------------------------------------------------
    // 1. Read JEDEC ID (0x9F -> returns 3 bytes: Manufacturer, Memory Type, Capacity)
    // -------------------------------------------------------------------------
    spi_select();

    // Transmit Command 0x9F
    acc = CMD_READ_JEDEC_ID;
    osr = acc;
    spi_transfer_byte();

    // Read 3 ID bytes into host RX FIFO
    repeat (3) {
        spi_transfer_byte();
        push_block();
    }

    spi_deselect();
    delay_cycles(10);

    // -------------------------------------------------------------------------
    // 2. Continuous Fast Read from Address 0x000000
    // -------------------------------------------------------------------------
    spi_select();

    // Command 0x03
    acc = CMD_READ_DATA;
    osr = acc;
    spi_transfer_byte();

    // 24-bit Address: 0x00, 0x00, 0x00
    acc = 0x00;
    osr = acc;
    spi_transfer_byte();
    spi_transfer_byte();
    spi_transfer_byte();

    // Stream 16 bytes to Host RX FIFO
    repeat (16) {
        spi_transfer_byte();
        push_block();
    }

    spi_deselect();
}
