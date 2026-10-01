// =============================================================================
// File        : c_headers.js
// Module      : OmniBus MP Virtual Standard C Library Headers & Configs
// Description : Virtual filesystem of Omni-C SDK headers for in-browser compilation.
// License     : MIT License
// =============================================================================

export const VIRTUAL_HEADERS = {
    "omnibus.h": `/**
 * =============================================================================
 * File        : omnibus.h
 * Description : Core Omni-C Standard Library for the OmniBus Protocol Engine.
 * License     : MIT License
 * =============================================================================
 */

#ifndef OMNIBUS_H
#define OMNIBUS_H

#pragma clock 50MHz
#pragma baud 115200

#include "OmniBus_Config.vh"

// Standard Pin Aliases
#define PIN_TX      0
#define PIN_RX      1
#define PIN_SCK     2
#define PIN_CS      3
#define PIN_SDA     0
#define PIN_SCL     1
#define PIN_1WIRE   0
#define PIN_PULSE   0
#define PIN_AUDIO   0
#define PIN_GLITCH  5

// Logic Levels
#define HIGH        1
#define LOW         0
#define HIGH_Z      0

// Dynamic Baud Sentinels
#define BAUD_DIV    $BAUD
#define HBAUD_DIV   $HBAUD

// Hardware Status Flags
#define FLAG_ZERO       zero
#define FLAG_CARRY      carry
#define FLAG_I2C_MATCH  i2c_match

// Multi-Core OmniBus MP Primitives
uint8_t core_id(void);
uint8_t spinlock_acquire(uint8_t lock_id);
void spinlock_release(uint8_t lock_id);
void barrier_wait(void);
uint8_t mailbox_read(uint8_t mb_id);
void mailbox_write(uint8_t mb_id, uint8_t data);

#endif // OMNIBUS_H
`,

    "OmniBus_Config.vh": `// Unified OmniBus Architecture & Symmetric Multi-Core Configuration
#ifndef OMNIBUS_CONFIG_VH
#define OMNIBUS_CONFIG_VH

#define NUM_CORES 2
#define DEFAULT_IMEM_SIZE 128
#define DEFAULT_FIFO_DEPTH 16
#define DEFAULT_BAUD_DIV 433

#endif // OMNIBUS_CONFIG_VH
`,

    "uart.h": `/**
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
`,

    "spi.h": `/**
 * =============================================================================
 * File        : spi.h
 * Description : Omni-C SPI Master Driver Library (Mode 0).
 * License     : MIT License
 * =============================================================================
 */

#ifndef OMNIBUS_SPI_H
#define OMNIBUS_SPI_H

#include "omnibus.h"

#define SPI_CLK_DELAY 2  // ~10 MHz SPI clock @ 50 MHz core

// Initialize SPI Pins (MOSI=0, MISO=1, SCK=2, CS_n=3)
void spi_init() {
    pin_map(0, 1, 2, 3);
    pin_high(PIN_CS, 5); // Idle CS# High
    pin_low(PIN_SCK, 5); // Mode 0: SCK Idle Low
}

// Assert Chip-Select (Active Low)
void spi_select() {
    pin_low(PIN_CS, 5);
}

// Deassert Chip-Select (Idle High)
void spi_deselect() {
    pin_high(PIN_CS, 5);
}

// Full-duplex transfer: transmit OSR, receive into ISR
void spi_transfer_byte() {
    out_sck(8, SPI_CLK_DELAY);
}

#endif // OMNIBUS_SPI_H
`,

    "i2c.h": `/**
 * =============================================================================
 * File        : i2c.h
 * Description : Omni-C I2C Master Driver Library with Clock Stretching.
 * License     : MIT License
 * =============================================================================
 */

#ifndef OMNIBUS_I2C_H
#define OMNIBUS_I2C_H

#include "omnibus.h"

#define I2C_DELAY 30  // ~400 kHz Fast-Mode quarter cycle delay @ 50 MHz

// Initialize I2C Open-Drain Bus on SDA (Pin 0) and SCL (Pin 1)
void i2c_init() {
    cfg_od(0x03);          // Enable open-drain on pins 0 & 1
    pin_high(PIN_SDA, 10); // Release SDA
    pin_high(PIN_SCL, 10); // Release SCL
}

// Generate I2C START condition (SDA falls while SCL is high)
void i2c_start() {
    pin_high(PIN_SDA, I2C_DELAY);
    pin_high(PIN_SCL, I2C_DELAY);
    pin_low(PIN_SDA, I2C_DELAY);
    pin_low(PIN_SCL, I2C_DELAY);
}

// Generate I2C STOP condition (SDA rises while SCL is high)
void i2c_stop() {
    pin_low(PIN_SDA, I2C_DELAY);
    pin_high(PIN_SCL, I2C_DELAY);
    pin_high(PIN_SDA, I2C_DELAY);
}

// Write 1 byte from OSR and sample ACK bit
void i2c_write_byte() {
    out_sck(8, I2C_DELAY);
    // Release SDA for ACK, pulse SCL
    pin_high(PIN_SDA, I2C_DELAY);
    pin_high(PIN_SCL, I2C_DELAY);
    pin_wait(PIN_SCL, HIGH, 1000); // Hardware clock stretching wait
    pin_low(PIN_SCL, I2C_DELAY);
}

// Read 1 byte into ISR and send ACK
void i2c_read_byte_ack() {
    pin_high(PIN_SDA, 0); // Release SDA (input)
    in_sck(8, I2C_DELAY);
    // Drive ACK (Low)
    pin_low(PIN_SDA, I2C_DELAY);
    pin_high(PIN_SCL, I2C_DELAY);
    pin_low(PIN_SCL, I2C_DELAY);
    pin_high(PIN_SDA, I2C_DELAY);
}

#endif // OMNIBUS_I2C_H
`,

    "ws2812.h": `/**
 * =============================================================================
 * File        : ws2812.h
 * Description : Omni-C 800 kHz Asymmetric NeoPixel RGB Driver Library.
 * License     : MIT License
 * =============================================================================
 */

#ifndef OMNIBUS_WS2812_H
#define OMNIBUS_WS2812_H

#include "omnibus.h"

// Transmit 24-bit GRB frame from OSR & ACC
void ws2812_send_pixel(uint8_t r, uint8_t g, uint8_t b) {
    // Assist pulse mode 800kHz: T0H=350ns, T0L=800ns, T1H=700ns, T1L=600ns
    assist_pulse_time0(17, 40);
    assist_pulse_time1(35, 30);
    assist_pulse_cfg(1);
    
    // Stream Green, Red, Blue
    out_shift(8, 0);
    out_shift(8, 0);
    out_shift(8, 0);
    
    assist_pulse_cfg(0);
}

// Reset latch (>50us low)
void ws2812_latch() {
    pin_low(0, 2500); // 50us low
}

#endif // OMNIBUS_WS2812_H
`,

    "onewire.h": `/**
 * =============================================================================
 * File        : onewire.h
 * Description : Omni-C Dallas 1-Wire Master Protocol Driver.
 * License     : MIT License
 * =============================================================================
 */

#ifndef OMNIBUS_ONEWIRE_H
#define OMNIBUS_ONEWIRE_H

#include "omnibus.h"

// Initialize 1-Wire Open-Drain Bus on Pin 0
void onewire_init() {
    cfg_od(0x01); // Pin 0 open-drain
    pin_high(PIN_1WIRE, 50);
}

// Reset pulse (480us Low, wait for presence pulse)
void onewire_reset() {
    pin_low(PIN_1WIRE, 24000);      // 480us Low @ 50 MHz
    pin_high(PIN_1WIRE, 3500);      // 70us High (wait for slave presence)
    pin_wait(PIN_1WIRE, LOW, 5000); // Sample presence pulse
    pin_high(PIN_1WIRE, 20000);     // Rest time
}

// Write 1 bit (1 = short 6us low, 0 = long 60us low)
void onewire_write_1() {
    pin_low(PIN_1WIRE, 300);    // 6us Low
    pin_high(PIN_1WIRE, 3200);  // 64us High
}

void onewire_write_0() {
    pin_low(PIN_1WIRE, 3000);   // 60us Low
    pin_high(PIN_1WIRE, 500);   // 10us High
}

#endif // OMNIBUS_ONEWIRE_H
`,

    "audio.h": `/**
 * =============================================================================
 * File        : audio.h
 * Description : Omni-C 1-Bit Delta-Sigma Audio DAC & Chiptune APU Driver.
 * License     : MIT License
 * =============================================================================
 */

#ifndef OMNIBUS_AUDIO_H
#define OMNIBUS_AUDIO_H

#include "omnibus.h"

// Set Chiptune Master Volume (0..15)
#define audio_set_volume(vol) assist_audio_vol(vol)

// Play Frequency Tone (note_hi, note_lo = 16-bit clock divisor)
#define audio_play_tone(note_hi, note_lo) assist_audio_play(note_hi, note_lo)

// Stop Audio Output
#define audio_silence() assist_audio_stop()

#endif // OMNIBUS_AUDIO_H
`,

    "mitm.h": `/**
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
`
};
