; =============================================================================
; Example   : usb_sie_demo.asm
; Module    : OmniBus Protocol Emulator
; Task      : Task 28 - USB 1.1 Autonomous Serial Interface Engine (SIE)
; Target    : Tang Console 60K FPGA (GW5AT-LV60PG484AC1)
; Operation : Autonomous USB Token Filtering, Handshake Responder & Data Loop
; Pins      : Pin 0 = USB D+ (Full Speed Pull-Up / Data +)
;             Pin 1 = USB D- (Data -)
; =============================================================================

    ; 1. Configure USB SIE for Device Address 5
    USB_CFG 5
    USB_SIE_EN

    ; 2. Initialize accumulator to idle indicator
    MOV acc, 0x00

usb_poll_loop:
    ; Check USB Status & Token Reception
    ASSIST READ, USB_TOKEN
    JMP ZERO, check_bus_reset

    ; Token received for Device Address 5!
    ; Bits [7:4] = Token PID (SETUP=0xD, OUT=0x1, IN=0x9)
    ; Bits [3:0] = Endpoint
    PUSH
    MOV acc, 0xAA          ; Telemetry indicator: Token latched
    OUT 0, 8, 4

wait_packet_data:
    ; Wait for associated DATA packet or Handshake
    ASSIST READ, USB_STATUS
    PUSH

    ; Check if CRC Error occurred (carry flag is set on CRC error)
    JMP CARRY, usb_crc_fail

    ; Read received Data Byte if valid
    ASSIST READ, USB_DATA
    PUSH

    ; Autonomously acknowledge valid reception
    USB_SEND_ACK
    JMP usb_poll_loop

check_bus_reset:
    ; If carry is set on USB_TOKEN read, bus reset condition detected
    JMP CARRY, usb_reset_handler
    JMP usb_poll_loop

usb_reset_handler:
    ; Reset address to 0
    USB_CFG 0
    MOV acc, 0xFF          ; Reset indicator
    OUT 0, 8, 4
    JMP usb_poll_loop

usb_crc_fail:
    ; Send STALL on CRC or framing failure
    USB_SEND_STALL
    MOV acc, 0xEE          ; Error indicator
    OUT 0, 8, 4
    JMP usb_poll_loop
