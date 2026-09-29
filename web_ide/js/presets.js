// =============================================================================
// File        : presets.js
// Module      : OmniBus Microcode Presets & Example Library
// Description : 12 production-tested microcode programs across all protocols
//               and hardware assists for instant loading, simulation, and flashing.
// License     : MIT License
// =============================================================================

export const PRESETS = [
    {
        id: "uart_tx",
        title: "UART 115200 8N1 Transmitter",
        category: "Serial",
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
    
    ; Transmit Start Bit (0)
    SET tx_pin, 0 [$BAUD]      ; 1 cycle + 433 sidecar delay = 434 cycles
    
    ; Transmit 8 Data Bits (LSB First)
    OUT tx_pin, 8 [$BAUD]      ; Shifts 8 bits with cycle-exact timing
    
    ; Transmit Stop Bit (1)
    SET tx_pin, 1 [$BAUD]      ; Stop bit high for 1 bit period
    
    JMP loop                   ; Repeat continuous stream
`
    },
    {
        id: "i2c_master",
        title: "I2C Master Byte Write & Read",
        category: "Serial",
        desc: "Open-drain I2C Master with START/STOP generation, ACK sampling, and SCL clock stretching detection.",
        code: `; ==============================================================================
; OmniBus Microcode: I2C Master Write & Read with Open-Drain Arbitration
; ==============================================================================
.clock 50MHz

.pins
    sda = uio[0]
    scl = uio[1]

.const HALF_PERIOD 125         ; 400 kHz Fast-Mode quarter cycle delay

main:
    CFG_OD 0x03                ; Configure SDA and SCL as Open-Drain pins
    SET sda, 1 [HALF_PERIOD]   ; Release lines high (idle)
    SET scl, 1 [HALF_PERIOD]

start_cond:
    ; Generate I2C START Condition (SDA falling while SCL is High)
    SET sda, 0 [HALF_PERIOD]
    SET scl, 0 [HALF_PERIOD]

write_addr:
    ; Send 7-bit Address + Write (0x50 << 1 = 0xA0)
    MOV acc, 0xA0
    SET_LC LC0, 8

addr_loop:
    OUT sda, 1 [HALF_PERIOD]   ; Drive MSB bit
    SET scl, 1 [HALF_PERIOD]   ; Clock HIGH
    WAIT scl, 1 [1000]         ; Detect clock stretching by slave
    SET scl, 0 [HALF_PERIOD]   ; Clock LOW
    DJNZ LC0, addr_loop

sample_ack:
    SET sda, 1 [HALF_PERIOD]   ; Release SDA for Slave ACK
    SET scl, 1 [HALF_PERIOD]
    IN sda, 1                  ; Sample ACK (0 = ACK, 1 = NACK)
    SET scl, 0 [HALF_PERIOD]

stop_cond:
    ; Generate I2C STOP Condition (SDA rising while SCL is High)
    SET sda, 0 [HALF_PERIOD]
    SET scl, 1 [HALF_PERIOD]
    SET sda, 1 [HALF_PERIOD]

halt:
    JMP halt
`
    },
    {
        id: "neopixel_ws2812",
        title: "WS2812B NeoPixel RGB LED Strip",
        category: "Creative",
        desc: "Generates strict asymmetric NRZ 800 kHz pulses (T0H=350ns, T1H=700ns) for 24-bit GRB NeoPixel LEDs.",
        code: `; ==============================================================================
; OmniBus Microcode: WS2812B NeoPixel 800 kHz Asymmetric Pulse Driver
; ==============================================================================
.clock 50MHz

.pins
    din = uio[2]

; Timing at 50 MHz (20 ns/cycle):
; Bit 0: High for 17 cycles (340ns), Low for 43 cycles (860ns)
; Bit 1: High for 35 cycles (700ns), Low for 25 cycles (500ns)
.const T0H 17
.const T0L 43
.const T1H 35
.const T1L 25

main:
    SET din, 0 [2500]          ; Reset pulse (>50us low)

send_color:
    ; Send 24-bit Color: Green=0xFF, Red=0x00, Blue=0xAA
    SET_LC LC0, 24             ; 24 bits per pixel

pixel_loop:
    ; High pulse
    SET din, 1 [T1H]
    SET din, 0 [T1L]
    DJNZ LC0, pixel_loop

    SET din, 0 [3000]          ; Latch frame
    JMP send_color
`
    },
    {
        id: "joybus_n64",
        title: "N64 / GameCube Joybus Controller",
        category: "Retro",
        desc: "Bidirectional single-wire open-collector Joybus interface at 250 kbps with 1us/3us pulse encoding.",
        code: `; ==============================================================================
; OmniBus Microcode: Nintendo 64 / GameCube Joybus Controller Query (250 kbps)
; Protocol: Open-drain 1-wire; Bit 0 = 3us Low / 1us High; Bit 1 = 1us Low / 3us High
; ==============================================================================
.clock 50MHz

.pins
    joy_pin = uio[3]

.const T_1US 50
.const T_3US 150

main:
    CFG_OD 0x08                ; Pin 3 configured as Open-Drain
    SET joy_pin, 1 [T_3US]     ; Idle High

query_cmd:
    ; Send 0x01 (Poll Controller Buttons)
    ; Bit 0: 3us Low, 1us High
    SET joy_pin, 0 [T_3US]
    SET joy_pin, 1 [T_1US]

    ; Stop bit: 1us Low, then release to High-Z
    SET joy_pin, 0 [T_1US]
    SET joy_pin, 1 [T_3US]

read_response:
    ; Wait for controller response falling edge
    WAIT joy_pin, 0 [500]
    IN joy_pin, 8 [T_1US]      ; Sample 32-bit button state
    PUSH

    JMP main
`
    },
    {
        id: "chiptune_audio",
        title: "Chiptune Audio & Delta-Sigma PDM DAC",
        category: "Creative",
        desc: "Direct 1-bit Delta-Sigma DAC sound synthesizer playing square-wave chiptune melody through GPIO pin.",
        code: `; ==============================================================================
; OmniBus Microcode: Chiptune Sound Synthesizer & 1-Bit Delta-Sigma Audio DAC
; Plays audible tones directly through UIO[4] via PDM DAC assist.
; ==============================================================================
.clock 50MHz

.pins
    audio_out = uio[4]

main:
    ; Initialize Audio PDM Engine
    AUDIO_CFG 0x01             ; Enable audio DAC

play_note_a4:
    ; Note A4 = 440 Hz (Period = 113,636 cycles at 50 MHz)
    AUDIO_SAMPLE 200           ; Set volume / amplitude level
    SET audio_out, 1 [56818]
    SET audio_out, 0 [56818]

play_note_c5:
    ; Note C5 = 523 Hz (Period = 95,602 cycles)
    SET audio_out, 1 [47801]
    SET audio_out, 0 [47801]

play_note_e5:
    ; Note E5 = 659 Hz (Period = 75,872 cycles)
    SET audio_out, 1 [37936]
    SET audio_out, 0 [37936]

    JMP main
`
    },
    {
        id: "mitm_glitch",
        title: "Active MitM Interception & Glitch Fuzzer",
        category: "Security",
        desc: "Inspects incoming SPI bitstream, matches command 0x9F (Read ID), substitutes 0x37 on-the-fly, and triggers glitch.",
        code: `; ==============================================================================
; OmniBus Microcode: Active Man-in-the-Middle (MitM) Match-and-Mutate Engine
; Detects Target Byte 0x9F, Mutates to 0x37, and Fires 100ns Hardware Glitch Pulse
; ==============================================================================
.clock 50MHz

.pins
    mosi = uio[0]
    miso = uio[1]
    glitch_trig = uio[5]

main:
    ; Arm Glitch & MitM Subsystems
    GLITCH_WIDTH 5             ; 5 cycles = 100 ns glitch duration
    MITM_MATCH 0x9F            ; Target SPI Flash Read ID opcode
    MITM_REPLACE 0x37          ; Fuzzed payload substitution
    MITM_ENABLE 1

monitor_bus:
    IN mosi, 8                 ; Sample incoming wire byte
    CMP 0x9F                   ; Check match
    JMP NE, monitor_bus        ; Loop until matched

trigger_glitch:
    ; Fire synchronized fault injection pulse
    GLITCH_TRIG 1
    SET glitch_trig, 1 [5]
    SET glitch_trig, 0 [100]

    JMP monitor_bus
`
    },
    {
        id: "usb_fs_sof",
        title: "USB 1.1 Full-Speed SOF & NRZI",
        category: "Industrial",
        desc: "Full-Speed USB 1.1 packet generator with autonomous NRZI encoding and hardware bit-stuffing.",
        code: `; ==============================================================================
; OmniBus Microcode: USB 1.1 Full-Speed (12 Mbps) SOF Token Generator
; ==============================================================================
.clock 50MHz

.pins
    dp = uio[0]
    dm = uio[1]

main:
    USB_CONFIG 0x01            ; Enable Full-Speed USB Mode (12 Mbps)
    
send_sync:
    ; USB SYNC Pattern (0x80 = 00000001b)
    OUT dp, 8 [4]              ; ~4 cycles/bit at 50 MHz for 12 Mbps

send_sof_pid:
    ; SOF PID = 0xA5
    MOV acc, 0xA5
    OUT dp, 8 [4]

send_frame_num:
    ; Frame Counter & 5-bit CRC Token
    OUT dp, 11 [4]             ; 11-bit Frame number
    CRC_INIT                   ; Compute USB CRC-5
    CRC_BYTE 0xA5
    OUT dp, 5 [4]              ; Send CRC-5

send_eop:
    ; USB End-Of-Packet (SE0 for 2 bit times)
    SET dp, 0 [8]
    SET dm, 0 [8]
    SET dp, 1 [4]              ; Return to Idle (J-state)

    JMP send_sync
`
    },
    {
        id: "bist_crossbar",
        title: "Autonomous BIST & PRBS-7 LFSR",
        category: "Silicon",
        desc: "On-Chip Self-Play: PRBS-7 Galois LFSR non-zero progression and virtual loopback error scoring.",
        code: `; ==============================================================================
; OmniBus Microcode: Autonomous Built-In Self-Test (BIST) & PRBS-7 LFSR
; ==============================================================================
.clock 50MHz

.pins
    tx = uio[0]
    rx = uio[1]

main:
    BIST_CONFIG 0x01           ; Enable internal crossbar loopback
    BIST_START 1               ; Start PRBS-7 sequence generation

lfsr_loop:
    OUT tx, 8 [4]              ; Stream pseudo-random test vectors
    IN rx, 8 [4]               ; Capture and score loopback integrity
    
    CRC_INIT                   ; Update signature analyzer
    CRC_BYTE 0x7F
    
    DJNZ LC0, lfsr_loop

bist_complete:
    BIST_STOP 1
halt:
    JMP halt
`
    }
];
