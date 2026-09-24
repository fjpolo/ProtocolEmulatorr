; =============================================================================
; Example: RISC-V DTM IDCODE Scan via Hardware JTAG TAP Controller
; Target : ProtocolEmulator / OmniBus (Task 23)
; Pinout : Pin 0 = TDI (MOSI), Pin 1 = TCK (SCK), Pin 2 = TMS (CS), Pin 3 = TDO (MISO)
; =============================================================================
; IEEE 1149.1 Standard: On Test-Logic-Reset, standard TAP targets (including
; RISC-V Debug Module DTM) preload their 32-bit IDCODE into the Data Register.
; Navigating to SHIFT_DR scans out the 32-bit IDCODE (e.g. 0x0010E319).
; =============================================================================

.clock 50000000

    ; Configure Pin Routing: Pin 0=TDI, Pin 3=TDO, Pin 1=TCK, Pin 2=TMS
    PINMAP 0, 3, 1, 2

    ; Enable Hardware JTAG Host Controller
    JTAG_CFG 1

    ; Autonomous TMS Navigation: Drive 5 TMS=1 clocks to reach Test-Logic-Reset
    JTAG_NAV RESET

    ; Navigate to Run-Test/Idle
    JTAG_NAV IDLE

    ; Navigate to Shift-DR (Select-DR -> Capture-DR -> Shift-DR)
    JTAG_NAV SHIFT_DR

    ; Shift Byte 0 (bits 7:0) of IDCODE, stay in Shift-DR
    JTAG_SHIFT 8, EXIT=0
    PUSH

    ; Shift Byte 1 (bits 15:8) of IDCODE, stay in Shift-DR
    JTAG_SHIFT 8, EXIT=0
    PUSH

    ; Shift Byte 2 (bits 23:16) of IDCODE, stay in Shift-DR
    JTAG_SHIFT 8, EXIT=0
    PUSH

    ; Shift Byte 3 (bits 31:24) of IDCODE, assert TMS=1 on final bit to reach Exit1-DR
    JTAG_SHIFT 8, EXIT=1
    PUSH

    ; Return TAP to Run-Test/Idle (Exit1-DR -> Update-DR -> Idle)
    JTAG_NAV IDLE

halt:
    JMP halt
