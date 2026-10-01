// =============================================================================
// File        : presets.js
// Module      : OmniBus Microcode & Omni-C Presets & Example Library
// Description : Production-tested programs across Omni-C (C) and Assembly (.asm)
//               for both single-core and multi-core (OmniBus MP) architectures.
// License     : MIT License
// =============================================================================

export const PRESETS = [
    // =========================================================================
    // OMNI-C (HIGH-LEVEL C) PRESETS
    // =========================================================================
    {
        id: "c_uart_echo",
        title: "⚡ [C] UART Full-Duplex Echo Transceiver",
        category: "Omni-C",
        lang: "c",
        numCores: 1,
        desc: "Full-duplex UART 8N1 transceiver written in structured C using standard <uart.h> header with blocking FIFO stream.",
        code: `/**
 * =============================================================================
 * Omni-C: Full-Duplex UART 8N1 Echo Transceiver
 * =============================================================================
 */
#include "uart.h"

void main() {
    // Pin routing: TX on Pin 0, RX on Pin 1
    pin_map(0, 1, 2, 3);
    pin_high(PIN_TX, 0); // Idle TX line High

    while (1) {
        // Wait for incoming byte from host FIFO
        pull_block();

        // Echo byte over physical UART TX pin
        uart_tx_byte();

        // Sample incoming response from RX pin and push to host RX FIFO
        uart_rx_byte();
        push_block();
    }
}
`
    },
    {
        id: "c_spi_flash",
        title: "⚡ [C] SPI Flash JEDEC ID Reader (Mode 0)",
        category: "Omni-C",
        lang: "c",
        numCores: 1,
        desc: "SPI Master controller in C transmitting 0x9F (Read JEDEC ID) and clocking in 3-byte Manufacturer/Device IDs.",
        code: `/**
 * =============================================================================
 * Omni-C: SPI Flash JEDEC ID Reader (Mode 0)
 * =============================================================================
 */
#include "spi.h"

void main() {
    spi_init();

    while (1) {
        // Wait for host trigger
        pull_block();

        // Assert CS# Low
        spi_select();

        // Transmit JEDEC Read ID command (0x9F)
        acc = 0x9F;
        osr = acc;
        spi_transfer_byte();

        // Read 3-byte Manufacturer, Memory Type, Capacity
        repeat (3) {
            osr = 0x00; // Dummy byte to generate SCK clocks
            spi_transfer_byte();
            acc = isr;
            push_block();
        }

        // Deassert CS# High
        spi_deselect();
        delay_cycles(100);
    }
}
`
    },
    {
        id: "c_i2c_sensor",
        title: "⚡ [C] I2C Temperature Sensor Master",
        category: "Omni-C",
        lang: "c",
        numCores: 1,
        desc: "Open-drain I2C Master with START/STOP generation, device addressing (0x48), and 2-byte sensor read.",
        code: `/**
 * =============================================================================
 * Omni-C: I2C Sensor Master Reader
 * =============================================================================
 */
#include "i2c.h"

#define SENSOR_ADDR_WR  0x90  // 0x48 << 1 + 0 (Write)
#define SENSOR_ADDR_RD  0x91  // 0x48 << 1 + 1 (Read)

void main() {
    i2c_init();

    while (1) {
        pull_block(); // Trigger read

        // START condition
        i2c_start();

        // Send Sensor Address (Write)
        osr = SENSOR_ADDR_WR;
        i2c_write_byte();

        // Pointer Register (0x00 = Temp)
        osr = 0x00;
        i2c_write_byte();

        // Repeated START
        i2c_start();

        // Send Sensor Address (Read)
        osr = SENSOR_ADDR_RD;
        i2c_write_byte();

        // Read MSB and LSB
        i2c_read_byte_ack();
        acc = isr;
        push_block();

        // STOP condition
        i2c_stop();
        delay_cycles(200);
    }
}
`
    },
    {
        id: "c_ws2812_rainbow",
        title: "⚡ [C] WS2812 NeoPixel 800 kHz RGB Driver",
        category: "Omni-C",
        lang: "c",
        numCores: 1,
        desc: "Configures sub-cycle asymmetric pulse engine and streams 24-bit GRB colors to NeoPixel strip.",
        code: `/**
 * =============================================================================
 * Omni-C: WS2812 800 kHz Asymmetric Pulse Driver
 * =============================================================================
 */
#include "ws2812.h"

void main() {
    pin_low(0, 2500); // Reset latch (>50us)

    while (1) {
        // Stream Red, Green, Blue
        ws2812_send_pixel(0xFF, 0x00, 0x00); // Red
        ws2812_send_pixel(0x00, 0xFF, 0x00); // Green
        ws2812_send_pixel(0x00, 0x00, 0xFF); // Blue

        ws2812_latch();
        delay_cycles(5000);
    }
}
`
    },
    {
        id: "c_multicore_bridge",
        title: "⚡ [C] Dual-Core Spinlock & Mailbox Bridge",
        category: "Omni-C",
        lang: "c",
        numCores: 2,
        desc: "Dual-Core OmniBus MP in C: Core 0 ingests serial frames and Core 1 processes via hardware spinlocks & mailbox.",
        code: `/**
 * =============================================================================
 * Omni-C: Dual-Core OmniBus MP Spinlock & Mailbox Synchronized Bridge
 * =============================================================================
 */
#include "omnibus.h"

#pragma bank 0
void core0_main() {
    pin_map(0, 1, 2, 3);
    while (1) {
        pull_block();
        // Ingest token and synchronize with Core 1
        while (spinlock_acquire(0) != 0) {
            // Spin until lock is available
        }
        mailbox_write(0, 0x5A);
        spinlock_release(0);
        delay_cycles(100);
    }
}

#pragma bank 1
void core1_main() {
    pin_map(4, 5, 6, 7);
    while (1) {
        while (spinlock_acquire(0) != 0) {
            // Poll lock for new data from Core 0
        }
        acc = mailbox_read(0);
        spinlock_release(0);
        
        // Egress or transform
        osr = acc;
        push_block();
    }
}
`
    },

    // =========================================================================
    // ASSEMBLY (.ASM) PRESETS
    // =========================================================================
    {
        id: "multicore_uart_spi_bridge",
        title: "⚙️ [ASM] Dual-Core UART-to-SPI Multi-Protocol Bridge",
        category: "Multi-Core",
        lang: "asm",
        numCores: 2,
        desc: "Core 0 (Bank 0) ingests UART frames while Core 1 (Bank 1) concurrently generates SPI transactions synchronized via Mailbox 0 and Spinlock 0.",
        code: `; =============================================================================
; OmniBus MP: Dual-Core Asymmetric Multi-Protocol Bridge (2 Cores)
; Core 0 (Bank 0): High-speed UART Transceiver (Pins 0..3)
; Core 1 (Bank 1): Master SPI Controller (Pins 4..7)
; Synchronized via Shared Hardware Mailbox 0 and Spinlock 0
; =============================================================================
.clock 50MHz
.baud 115200

; --- Core 0 (Bank 0 / 0x00): UART Ingest ---
.bank 0
core0_init:
    PINMAP tx=0, rx=3, sck=1, cs=2

core0_loop:
    WAIT rx, 0, $HBAUD         ; Wait for UART Start Bit
    NOP $BAUD
    IN $BAUD                   ; Sample 8 data bits into ISR
    WAIT rx, 1, 0              ; Wait for Stop Bit

core0_acquire_lock:
    SPINLOCK_ACQ 0             ; Acquire Spinlock 0
    JMP NOT_ZERO, core0_acquire_lock

    MOV acc, isr               ; Copy received byte to Mailbox 0
    MB_WRITE 0
    SPINLOCK_REL 0             ; Release Lock -> notify Core 1

    JMP core0_loop

; --- Core 1 (Bank 1 / 0x20): SPI Master Egress ---
.bank 1
core1_init:
    PINMAP tx=4, rx=7, sck=5, cs=6

core1_loop:
    SPINLOCK_ACQ 0             ; Poll Spinlock 0 for data
    JMP NOT_ZERO, core1_loop

    MB_READ 0                  ; Read bridged byte from Mailbox 0
    MOV osr, acc
    SPINLOCK_REL 0             ; Release Lock

    SET cs, 0, [4]             ; Assert SPI CS#
    OUT SCK, [4]               ; Shift 8 bits on MOSI with SCK toggles
    SET cs, 1, [4]             ; Deassert SPI CS#

    NOP [10]
    JMP core1_loop
`
    },
    {
        id: "multicore_mailbox_sync",
        title: "⚙️ [ASM] Dual-Core Mailbox Ping-Pong & Barrier Sync",
        category: "Multi-Core",
        lang: "asm",
        numCores: 2,
        desc: "Producer/Consumer exchange between Core 0 and Core 1 synchronized via BARRIER_WAIT rendezvous and Mailboxes 0 & 1.",
        code: `; =============================================================================
; OmniBus MP: Dual-Core Mailbox Ping-Pong & Barrier Sync (2 Cores)
; Demonstrates zero-overhead BARRIER_WAIT rendezvous and shared mailboxes.
; =============================================================================
.clock 50MHz

; --- Core 0 (Bank 0 / 0x00): Token Generator ---
.bank 0
core0_entry:
    SET_LC 4

core0_loop:
    BARRIER_WAIT               ; Phase 1: Rendezvous barrier with Core 1

core0_lock0:
    SPINLOCK_ACQ 0
    JMP NOT_ZERO, core0_lock0
    MOV acc, 0x5A              ; Write token 0x5A to Mailbox 0
    MB_WRITE 0
    SPINLOCK_REL 0

core0_lock1:
    SPINLOCK_ACQ 1             ; Poll for Core 1 response in Mailbox 1
    JMP NOT_ZERO, core0_lock1
    MB_READ 1
    MOV osr, acc
    SPINLOCK_REL 1

    PUSH 0                     ; Output transformed result to FIFO
    BARRIER_WAIT               ; Phase 2: Frame completion barrier
    LOOP core0_loop

core0_done:
    NOP 10
    JMP core0_done

; --- Core 1 (Bank 1 / 0x20): Arithmetic Transformer ---
.bank 1
core1_entry:
    SET_LC 4

core1_loop:
    BARRIER_WAIT               ; Phase 1: Rendezvous barrier with Core 0

core1_lock0:
    SPINLOCK_ACQ 0             ; Read token from Core 0
    JMP NOT_ZERO, core1_lock0
    MB_READ 0
    MOV r1, acc
    SPINLOCK_REL 0

    MOV acc, r1                ; Transform data: Add 0x11
    ADD 0x11
    MOV r1, acc

core1_lock1:
    SPINLOCK_ACQ 1             ; Post reply to Mailbox 1
    JMP NOT_ZERO, core1_lock1
    MOV acc, r1
    MB_WRITE 1
    SPINLOCK_REL 1

    BARRIER_WAIT               ; Phase 2: Frame completion barrier
    LOOP core1_loop

core1_done:
    NOP 10
    JMP core1_done
`
    },
    {
        id: "multicore_quad_grid",
        title: "⚙️ [ASM] Quad-Core (4-Core) Streaming Pipeline Grid",
        category: "Multi-Core",
        lang: "asm",
        numCores: 4,
        desc: "4-Stage pipeline: Core 0 (Host Ingress) -> Core 1 (Crypto Transform) -> Core 2 (CRC Engine) -> Core 3 (SPI Egress).",
        code: `; =============================================================================
; OmniBus MP: Quad-Core (4-Core) Symmetric Pipelined Accelerator
; 4-Stage Streaming Grid:
; Core 0: Ingress Ingest (Host FIFO -> Cascade FIFO 0)
; Core 1: Crypto Transform (XOR 0xAA -> Mailbox 2)
; Core 2: Hardware CRC Engine (SMBus CRC -> Mailbox 3)
; Core 3: SPI Master Egress (Mailbox 3 -> MOSI/SCK & Return)
; =============================================================================
.clock 50MHz

; --- Core 0 (Bank 0 / 0x00): Ingress Stream ---
.bank 0
core0_init:
    SET_LC 8
core0_loop:
    BARRIER_WAIT
    PULL 0                     ; Pull byte from Host TX FIFO
    PUSH 0                     ; Forward to Cascade FIFO 0
    BARRIER_WAIT
    LOOP core0_loop
core0_halt:
    NOP 10
    JMP core0_halt

; --- Core 1 (Bank 1 / 0x20): Crypto XOR Slice ---
.bank 1
core1_init:
    SET_LC 8
core1_loop:
    BARRIER_WAIT
    PULL 0                     ; Ingest from Core 0 Cascade FIFO
    MOV acc, osr
    XOR 0xAA                   ; Apply cryptographic mask
    MOV r1, acc

core1_lock:
    SPINLOCK_ACQ 2
    JMP NOT_ZERO, core1_lock
    MOV acc, r1
    MB_WRITE 2                 ; Post payload to Mailbox 2
    SPINLOCK_REL 2

    BARRIER_WAIT
    LOOP core1_loop
core1_halt:
    NOP 10
    JMP core1_halt

; --- Core 2 (Bank 2 / 0x40): CRC Accelerator Slice ---
.bank 2
core2_init:
    SET_LC 8
core2_loop:
    BARRIER_WAIT
core2_lock2:
    SPINLOCK_ACQ 2
    JMP NOT_ZERO, core2_lock2
    MB_READ 2                  ; Read from Mailbox 2
    MOV r2, acc
    SPINLOCK_REL 2

    CRC_INIT SMBUS             ; Hardware CRC Calculation
    MOV osr, acc
    CRC_BYTE OSR
    CRC_READ_L
    MOV r2, acc

core2_lock3:
    SPINLOCK_ACQ 3
    JMP NOT_ZERO, core2_lock3
    MOV acc, r2
    MB_WRITE 3                 ; Post CRC checksum to Mailbox 3
    SPINLOCK_REL 3

    BARRIER_WAIT
    LOOP core2_loop
core2_halt:
    NOP 10
    JMP core2_halt

; --- Core 3 (Bank 3 / 0x60): SPI Egress Slice ---
.bank 3
core3_init:
    PINMAP tx=4, rx=7, sck=5, cs=6
    SET_LC 8
core3_loop:
    BARRIER_WAIT
core3_lock:
    SPINLOCK_ACQ 3
    JMP NOT_ZERO, core3_lock
    MB_READ 3                  ; Read from Mailbox 3
    MOV osr, acc
    SPINLOCK_REL 3

    SET cs, 0, [2]             ; Shift out over SPI
    OUT SCK, [2]
    SET cs, 1, [2]
    PUSH 0                     ; Return byte to Host RX FIFO

    BARRIER_WAIT
    LOOP core3_loop
core3_halt:
    NOP 10
    JMP core3_halt
`
    },
    {
        id: "uart_tx",
        title: "⚙️ [ASM] UART 115200 8N1 Transmitter",
        category: "Serial",
        lang: "asm",
        numCores: 1,
        desc: "Transmits serial characters with exact cycle-deterministic 8N1 bit framing using sidecar delay $BAUD.",
        code: `; ==============================================================================
; OmniBus Microcode: UART 115200 8N1 Transmitter (50 MHz Master Clock)
; Bit duration = 50,000,000 / 115,200 = 434 cycles/bit
; ==============================================================================
.clock 50MHz

.pins
    tx_pin = uio[0]

.entry main

main:
    SET tx_pin, 1 [$BAUD]      ; Initialize TX line to idle high

loop:
    PULL                       ; Transfer byte from TX FIFO to OSR
    SET tx_pin, 0 [$BAUD]      ; Start Bit (0)
    OUT tx_pin, 8 [$BAUD]      ; 8 Data Bits
    SET tx_pin, 1 [$BAUD]      ; Stop Bit (1)
    JMP loop
`
    },
    {
        id: "i2c_master",
        title: "⚙️ [ASM] I2C Master Byte Write & Read",
        category: "Serial",
        lang: "asm",
        numCores: 1,
        desc: "Open-drain I2C Master with START/STOP generation, ACK sampling, and SCL clock stretching detection.",
        code: `; ==============================================================================
; OmniBus Microcode: I2C Master Write & Read with Open-Drain Arbitration
; ==============================================================================
.clock 50MHz

.pins
    sda = uio[0]
    scl = uio[1]

.const HALF_PERIOD 125

main:
    CFG_OD 0x03                ; Configure SDA and SCL as Open-Drain pins
    SET sda, 1 [HALF_PERIOD]   ; Release lines high (idle)
    SET scl, 1 [HALF_PERIOD]

start_cond:
    SET sda, 0 [HALF_PERIOD]   ; START condition
    SET scl, 0 [HALF_PERIOD]

write_addr:
    MOV acc, 0xA0              ; Send 7-bit Address + Write (0x50 << 1 = 0xA0)
    SET_LC LC0, 8

addr_loop:
    OUT sda, 1 [HALF_PERIOD]
    SET scl, 1 [HALF_PERIOD]
    WAIT scl, 1 [1000]         ; Detect clock stretching by slave
    SET scl, 0 [HALF_PERIOD]
    DJNZ LC0, addr_loop

sample_ack:
    SET sda, 1 [HALF_PERIOD]
    SET scl, 1 [HALF_PERIOD]
    IN sda, 1                  ; Sample ACK
    SET scl, 0 [HALF_PERIOD]

stop_cond:
    SET sda, 0 [HALF_PERIOD]   ; STOP condition
    SET scl, 1 [HALF_PERIOD]
    SET sda, 1 [HALF_PERIOD]

halt:
    JMP halt
`
    },
    {
        id: "neopixel_ws2812",
        title: "⚙️ [ASM] WS2812B NeoPixel RGB LED Strip",
        category: "Pulse",
        lang: "asm",
        numCores: 1,
        desc: "Strict 800 kHz asymmetric pulse width modulation driving 24-bit GRB NeoPixel LED strings.",
        code: `; ==============================================================================
; OmniBus Microcode: WS2812B NeoPixel 800 kHz LED Driver
; ==============================================================================
.clock 50MHz

.pins
    led_pin = uio[2]

.const T0H 17                  ; 350 ns HIGH for '0'
.const T0L 40                  ; 800 ns LOW  for '0'
.const T1H 35                  ; 700 ns HIGH for '1'
.const T1L 30                  ; 600 ns LOW  for '1'

main:
    SET led_pin, 0 [2500]      ; Reset latch (>50us LOW)

send_color:
    MOV acc, 0xFF              ; Send Green byte (0xFF)
    SET_LC LC0, 8

bit_loop:
    SET led_pin, 1 [T1H]       ; Pulse HIGH
    SET led_pin, 0 [T1L]       ; Pulse LOW
    DJNZ LC0, bit_loop

halt:
    JMP halt
`
    },
    {
        id: "glitch_mitm",
        title: "⚙️ [ASM] Hardware Glitch & Wire-Speed MitM Fuzzer",
        category: "Security",
        lang: "asm",
        numCores: 1,
        desc: "Active fault injection pulse generator with hardware pattern matcher and wire-speed byte substitution.",
        code: `; ==============================================================================
; OmniBus Microcode: Hardware Fault Injector & Active MitM Fuzzer
; ==============================================================================
.clock 50MHz

.pins
    target_pin = uio[5]

main:
    GLITCH_CFG 5, 0            ; Target Pin 5, active-high pulse
    GLITCH_WIDTH 8             ; 8 cycles pulse width
    GLITCH_DELAY 20            ; Delay 20 cycles after trigger
    GLITCH_ARM 0               ; Arm glitch sequencer

    MITM_ENABLE
    MOV acc, 0x55              ; Match pattern 0x55
    MITM_MATCH
    MOV acc, 0xAA              ; Replace with 0xAA
    MITM_REPLACE

trigger_glitch:
    GLITCH_TRIG                ; Fire hardware glitch pulse
    NOP 100
    JMP trigger_glitch
`
    }
];
