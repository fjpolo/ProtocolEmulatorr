; =============================================================================
; File        : multicore_quad_grid.asm
; Description : OmniBus MP Quad-Core (4-Core) Symmetric Pipelined Accelerator
;               Core 0 (Bank 0 / 0x00): Ingress Stream Ingest (Host FIFO -> Core 1)
;               Core 1 (Bank 1 / 0x20): Cryptographic Transform (XOR 0xAA -> Mailbox 2)
;               Core 2 (Bank 2 / 0x40): Hardware CRC8 Calculation (CRC Engine -> Mailbox 3)
;               Core 3 (Bank 3 / 0x60): High-Speed SPI Egress & Host Return
; Architecture: OmniBus MP Symmetric Multi-Core Micro-Engine (NUM_CORES=4)
; License     : MIT License
; =============================================================================

.clock 50MHz

; =============================================================================
; Core 0: Ingress Engine (Bank 0 / 0x00)
; =============================================================================
.bank 0
core0_init:
    SET_LC 8

core0_loop:
    ; Rendezvous all 4 cores before each frame
    BARRIER_WAIT

    ; Pull input byte from Host TX FIFO into OSR
    PULL 0

    ; Push byte into Core 1 Cascade Streaming FIFO
    PUSH 0

    ; Wait for pipeline completion
    BARRIER_WAIT
    LOOP core0_loop

core0_halt:
    NOP 10
    JMP core0_halt


; =============================================================================
; Core 1: Crypto Transform Slice (Bank 1 / 0x20)
; =============================================================================
.bank 1
core1_init:
    SET_LC 8

core1_loop:
    BARRIER_WAIT

    ; Pull streamed byte from Core 0 Cascade FIFO
    PULL 0
    MOV acc, osr

    ; Apply payload masking (XOR 0xAA)
    XOR 0xAA
    MOV r1, acc

    ; Acquire Spinlock 2 to write to Shared Mailbox 2
core1_lock:
    SPINLOCK_ACQ 2
    JMP NOT_ZERO, core1_lock

    MOV acc, r1
    MB_WRITE 2
    SPINLOCK_REL 2

    BARRIER_WAIT
    LOOP core1_loop

core1_halt:
    NOP 10
    JMP core1_halt


; =============================================================================
; Core 2: CRC Engine Slice (Bank 2 / 0x40)
; =============================================================================
.bank 2
core2_init:
    SET_LC 8

core2_loop:
    BARRIER_WAIT

    ; Poll Spinlock 2 for Core 1 payload in Mailbox 2
core2_lock2:
    SPINLOCK_ACQ 2
    JMP NOT_ZERO, core2_lock2

    MB_READ 2
    MOV r2, acc
    SPINLOCK_REL 2

    ; Initialize and calculate hardware CRC8
    CRC_INIT SMBUS
    MOV osr, acc
    CRC_BYTE OSR
    CRC_READ_L
    MOV r2, acc

    ; Acquire Spinlock 3 to post CRC result to Mailbox 3
core2_lock3:
    SPINLOCK_ACQ 3
    JMP NOT_ZERO, core2_lock3

    MOV acc, r2
    MB_WRITE 3
    SPINLOCK_REL 3

    BARRIER_WAIT
    LOOP core2_loop

core2_halt:
    NOP 10
    JMP core2_halt


; =============================================================================
; Core 3: SPI Egress Slice (Bank 3 / 0x60)
; =============================================================================
.bank 3
core3_init:
    PINMAP tx=4, rx=7, sck=5, cs=6
    SET_LC 8

core3_loop:
    BARRIER_WAIT

    ; Poll Spinlock 3 for processed frame from Core 2
core3_lock:
    SPINLOCK_ACQ 3
    JMP NOT_ZERO, core3_lock

    MB_READ 3
    MOV osr, acc
    SPINLOCK_REL 3

    ; Transmit 8 bits over SPI bus
    SET cs, 0, [2]
    OUT SCK, [2]
    SET cs, 1, [2]

    ; Push completion CRC into Host RX FIFO
    PUSH 0

    BARRIER_WAIT
    LOOP core3_loop

core3_halt:
    NOP 10
    JMP core3_halt
