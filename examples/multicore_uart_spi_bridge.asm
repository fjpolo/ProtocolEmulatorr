; =============================================================================
; File        : multicore_uart_spi_bridge.asm
; Description : OmniBus MP Dual-Core Asymmetric Multi-Protocol Bridge
;               Core 0 (Bank 0): High-speed UART Transceiver (Pins 0..3)
;               Core 1 (Bank 1): Master SPI Controller (Pins 4..7)
;               Synchronized via Shared Hardware Mailbox 0 and Spinlock 0.
; Architecture: OmniBus MP Symmetric Multi-Core Micro-Engine
; =============================================================================

.clock 50MHz
.baud 115200

; =============================================================================
; Core 0 Execution Slice (Origin: 0x00 / Bank 0)
; =============================================================================
.bank 0
core0_init:
    PINMAP tx=0, rx=3, sck=1, cs=2

core0_loop:
    ; Wait for UART Start Bit (RX falling edge)
    WAIT rx, 0, $HBAUD
    NOP $BAUD

    ; Sample 8 data bits into ISR
    IN $BAUD

    ; Wait for stop bit
    WAIT rx, 1, 0

    ; Acquire Spinlock 0 before writing to Mailbox 0
core0_acquire_lock:
    SPINLOCK_ACQ 0
    JMP NOT_ZERO, core0_acquire_lock

    ; Write received UART byte into Shared Mailbox 0
    MOV acc, isr
    MB_WRITE 0

    ; Release Spinlock 0 to notify Core 1
    SPINLOCK_REL 0

    ; Loopback to next UART frame
    JMP core0_loop


; =============================================================================
; Core 1 Execution Slice (Origin: 0x20 / Bank 1)
; =============================================================================
.bank 1
core1_init:
    PINMAP tx=4, rx=7, sck=5, cs=6

core1_loop:
    ; Poll Spinlock 0 to check if Core 0 has new bridge data
    SPINLOCK_ACQ 0
    JMP NOT_ZERO, core1_loop

    ; Read bridged byte from Shared Mailbox 0
    MB_READ 0
    MOV osr, acc

    ; Release Spinlock 0
    SPINLOCK_REL 0

    ; Assert SPI Chip Select (Active-Low on CS / Pin 6)
    SET cs, 0, [4]

    ; Transmit 8 bits on MOSI (Pin 4) with SCK (Pin 5) toggle
    OUT SCK, [4]

    ; Deassert SPI Chip Select
    SET cs, 1, [4]

    ; Small inter-frame delay then continue
    NOP [10]
    JMP core1_loop
