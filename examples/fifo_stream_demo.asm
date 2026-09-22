; =============================================================================
; OmniBus Microcode Program: FIFO Streaming with Flow Control
; Task 11: Demonstrates conditional JMP on FIFO flags and blocking PULL/PUSH.
; =============================================================================

.clock 50000000
.baud  115200

@0
start:
    ; Non-blocking poll: loop until byte arrives in TX FIFO
wait_data:
    JMP     TX_EMPTY, wait_data

    ; Pop incoming byte from TX FIFO into OSR
    PULL

    ; Forward to RX FIFO with blocking flow control (wait if RX FIFO full)
    PUSH    BLOCK

    ; Stream next byte
    JMP     start
