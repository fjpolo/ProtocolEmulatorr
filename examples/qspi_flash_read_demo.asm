; =============================================================================
; Example   : qspi_flash_read_demo.asm
; Module    : OmniBus Protocol Emulator
; Task      : Task 24 - Quad-SPI (QSPI) Multi-Lane NOR Flash Host Controller
; Target    : Winbond W25Q128 / Macronix MX25 / ISSI IS25LP Quad SPI Flash
; Command   : 0xEB (Fast Read Quad I/O: 1-4-4 mode)
; Address   : 24-bit physical address 0x102030
; Clocks    : 6 dummy wait cycles
; Transfer  : 4 data bytes read across Quad lanes (IO0..IO3) into RX FIFO
; =============================================================================

    ; 1. Configure QSPI Host Engine: Quad mode (4 lanes), CPOL=0 (idle Low)
    QSPI_CFG MODE=QUAD, CPOL=0

    ; 2. Assert Chip Select (CS# active Low)
    QSPI_CS 0

    ; 3. Instruction Phase: Send 0xEB (Fast Read Quad I/O) on Lane 0 (MOSI)
    MOV acc, 0xEB
    QSPI_CMD

    ; 4. Address Phase: Load 24-bit address 0x102030 and transmit across 4 lanes
    MOV acc, 0x10
    QSPI_LOAD_ADDR 0
    MOV acc, 0x20
    QSPI_LOAD_ADDR 1
    MOV acc, 0x30
    QSPI_LOAD_ADDR 2
    QSPI_ADDR 24

    ; 5. Dummy Clock Phase: 6 wait cycles with pins in Hi-Z
    QSPI_DUMMY 6

    ; 6. Data Phase: Autonomous multi-byte reception across 4 lanes
    ; Read Byte 0 -> Push to RX FIFO for host CPU
    IN QSPI
    PUSH

    ; Read Byte 1 -> Push to RX FIFO
    IN QSPI
    PUSH

    ; Read Byte 2 -> Push to RX FIFO
    IN QSPI
    PUSH

    ; Read Byte 3 -> Push to RX FIFO
    IN QSPI
    PUSH

    ; 7. Deassert Chip Select (CS# idle High)
    QSPI_CS 1

    ; 8. Terminate / loop
halt:
    JMP halt
