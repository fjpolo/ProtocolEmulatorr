; =============================================================================
; File        : multicore_mailbox_sync.asm
; Description : OmniBus MP Dual-Core Synchronized Mailbox Exchange
;               Demonstrates hardware rendezvous barrier and shared mailbox
;               ping-pong between Core 0 and Core 1.
; Architecture: OmniBus MP Symmetric Multi-Core Micro-Engine
; License     : MIT License
; =============================================================================

.clock 50MHz

; =============================================================================
; Core 0 Execution Slice (Origin: 0x00 / Bank 0)
; =============================================================================
.bank 0
core0_entry:
    ; Initialize loop counter: 4 iterations
    SET_LC 4

core0_loop:
    ; Wait for Core 1 rendezvous before starting frame
    BARRIER_WAIT

    ; Acquire Spinlock 0
core0_lock0:
    SPINLOCK_ACQ 0
    JMP NOT_ZERO, core0_lock0

    ; Write token 0x5A to Mailbox 0
    MOV acc, 0x5A
    MB_WRITE 0

    ; Release Spinlock 0
    SPINLOCK_REL 0

    ; Wait for Core 1 to process and reply via Mailbox 1
core0_lock1:
    SPINLOCK_ACQ 1
    JMP NOT_ZERO, core0_lock1

    ; Read Core 1 response from Mailbox 1
    MB_READ 1
    MOV osr, acc

    ; Release Spinlock 1
    SPINLOCK_REL 1

    ; Push received result into Host FIFO
    PUSH 0

    ; Synchronize at end of frame
    BARRIER_WAIT

    ; Loop until all frames complete
    LOOP core0_loop

core0_done:
    NOP 10
    JMP core0_done


; =============================================================================
; Core 1 Execution Slice (Origin: 0x20 / Bank 1)
; =============================================================================
.bank 1
core1_entry:
    ; Initialize loop counter: 4 iterations
    SET_LC 4

core1_loop:
    ; Wait for Core 0 rendezvous
    BARRIER_WAIT

    ; Poll Spinlock 0 for Core 0 token in Mailbox 0
core1_lock0:
    SPINLOCK_ACQ 0
    JMP NOT_ZERO, core1_lock0

    ; Read token from Mailbox 0
    MB_READ 0
    MOV r1, acc

    ; Release Spinlock 0
    SPINLOCK_REL 0

    ; Transform data: Add 0x11
    MOV acc, r1
    ADD 0x11
    MOV r1, acc

    ; Acquire Spinlock 1 to write reply to Mailbox 1
core1_lock1:
    SPINLOCK_ACQ 1
    JMP NOT_ZERO, core1_lock1

    ; Write modified token to Mailbox 1
    MOV acc, r1
    MB_WRITE 1

    ; Release Spinlock 1
    SPINLOCK_REL 1

    ; Synchronize at end of frame
    BARRIER_WAIT

    ; Loop until all frames complete
    LOOP core1_loop

core1_done:
    NOP 10
    JMP core1_done
