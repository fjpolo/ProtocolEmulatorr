// =============================================================================
// File        : ProtocolEmulator.v
// Module      : ProtocolEmulator (OmniBus Deterministic Protocol Engine)
// Description : Cycle-deterministic micro-engine with OSR/ISR, 4-deep CALL/RET
//               stack, runtime i_baud_div ($BAUD/$HBAUD sentinels), and:
//               Task 07: SET/WAIT pin selector, IN variable bit count (1-8 bits)
//               Task 07B: OUT SCK (pin_id=01): MSB-first with auto SCK toggle.
//               Task 07C (GPIO Bus):
//                 - Unified 8-bit bidirectional GPIO bus (i_gpio, o_gpio, o_gpio_oe)
//                 - PINMAP (opcode 0x5): dynamic role-to-pin mapping (tx, rx, sck, cs)
//                 - CFG_OD (opcode 0x6): open-drain mask configuration
//                 - SET (opcode 0x3) & WAIT (opcode 0x4) across all 8 pins (0..7)
//                 - Backward-compatible convenience aliases (o_tx, o_spi_sck, o_spi_cs_n, i_rx)
// License     : MIT License
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module ProtocolEmulator(
    input   wire            i_clk,
    input   wire            i_reset_n,
    input   wire    [7:0]   i_data,
    output  reg     [7:0]   o_data,

    // Hardware FIFO Control & Handshaking Interface
    input   wire            i_tx_valid,     // 1 when byte is available in TX FIFO
    output  reg             o_tx_pop,       // 1-cycle active-high pop strobe on PULL
    input   wire            i_rx_full,      // 1 when RX FIFO cannot accept data
    output  reg             o_rx_push,      // 1-cycle active-high push strobe on PUSH

    // Runtime Baud Rate Divisor (cycles_per_bit - 1). Default 433 = 115200@50MHz.
    // $BAUD sentinels: 9'h1FF (NOP/OUT/IN) or 8'hFF (SET/WAIT) -> i_baud_div[8:0]
    // $HBAUD sentinels: 9'h1FE (NOP/OUT/IN) or 8'hFE (SET/WAIT) -> i_baud_div[8:0]>>1
    input   wire    [15:0]  i_baud_div,

    // Unified 8-bit Bidirectional GPIO Bus
    input   wire    [7:0]   i_gpio,         // 8 GPIO input pins
    output  wire    [7:0]   o_gpio,         // 8 GPIO output drive levels
    output  wire    [7:0]   o_gpio_oe,      // 8 GPIO output enables (1=drive, 0=Hi-Z/input)

    // Backward-compatibility convenience ports (aliased to active role pins)
    input   wire            i_rx,           // Legacy UART RX / SPI MISO
    output  wire            o_tx,           // Mapped to o_gpio[tx_pin]
    output  wire            o_spi_sck,      // Mapped to o_gpio[sck_pin]
    output  wire            o_spi_cs_n,     // Mapped to o_gpio[cs_pin]

    // Runtime Microcode Programming Interface
    input   wire            i_prog_en,
    input   wire            i_prog_we,
    input   wire    [6:0]   i_prog_addr,
    input   wire    [15:0]  i_prog_data,
    output  wire    [15:0]  o_prog_rdata
);

    // -------------------------------------------------------------------------
    // Execution State Registers
    // -------------------------------------------------------------------------
    reg [6:0]  pc;              // 7-bit Program Counter (0 to 127 instructions)
    reg [15:0] delay_cnt;       // 16-bit hardware sidecar delay counter (0 to 65535 cycles)
    reg        out_sck_phase;   // OUT SCK/1W phase: 0=drive phase, 1=release phase
    reg [1:0]  in_sck_phase;    // IN phase: SPI/I2C: 0=high/active, 1=low/idle; 1W: 0=drive, 1=wait/sample, 2=recovery
    reg [7:0]  osr;             // Output Shift Register (Serializer)
    reg [3:0]  bit_cnt;         // Serialization bit counter
    reg [7:0]  isr;             // Input Shift Register (Deserializer)
    reg [3:0]  rx_bit_cnt;      // Deserialization bit counter

    // 4-deep x 7-bit hardware call stack for CALL/RET subroutines
    reg [6:0]  call_stack [0:3]; // Return address stack (7 bits: 0..127)
    reg [1:0]  sp;               // Stack pointer (0..3, wraps-safe)

    // Active execution bank (4 banks of 32 words: 0..3)
    reg [1:0]  active_bank;

    // 2x 8-bit Hardware Loop Counters for zero-overhead loops (LC0, LC1)
    reg [7:0]  lc0;              // Loop counter 0
    reg [7:0]  lc1;              // Loop counter 1

    // Hardware CRC Generator & Checksum Accelerator State (Supports 5b, 8b, 16b, 32b)
    reg [31:0] crc_reg;          // 32-bit CRC accumulator
    reg [31:0] crc_seed;         // 32-bit initial/reload seed value
    reg [2:0]  crc_poly;         // Active polynomial: 0=Dallas, 1=SMBus, 2=CCITT, 3=Modbus, 4=Ethernet CRC-32, 5=USB CRC-5

    // 8-bit Micro-ALU State & Condition Flags
    reg [7:0]  acc;              // 8-bit Accumulator register
    reg        zero_flag;        // Zero flag: set if last ALU result == 8'h00
    reg        carry_flag;       // Carry/Borrow flag: set on arithmetic overflow/borrow or bit shift

    // Autonomous Stream Accelerators State: NRZI & Hardware Bit-Stuffing / De-stuffing
    reg        assist_nrzi_en;      // Enable NRZI encoding on TX and decoding on RX
    reg [1:0]  assist_stuff_mode;   // 00=Off, 01=USB (6 ones -> stuff 0), 10=CAN (5 identical -> stuff complement)
    reg        nrzi_tx_state;       // NRZI current physical line output level (default 1'b1, idle J-state for USB)
    reg        nrzi_rx_prev;        // NRZI previous physical line input level for transition detection
    reg [2:0]  tx_stuff_cnt;        // TX consecutive bit run counter
    reg [2:0]  rx_stuff_cnt;        // RX consecutive bit run counter
    reg        tx_last_bit;         // TX previous bit transmitted (for CAN 5 identical bits)
    reg        rx_last_bit;         // RX previous decoded bit (for CAN 5 identical bits)
    reg        stuff_error;         // Sticky bit-stuff error flag on RX

    // Asymmetric Single-Wire & Retro Physical Protocol Accelerators State (Task 18)
    reg [1:0]  pulse_mode;          // 00=Off, 01=Single-Wire Asymmetric (WS2812B/Joybus), 10=NES/SNES Host, 11=NES/SNES Device
    reg        pulse_polarity;      // 0=Active-High (WS2812B), 1=Active-Low Open-Drain (N64 Joybus / NES/SNES)
    reg        pulse_msb_first;     // 0=LSB-first, 1=MSB-first (for WS2812B 24-bit GRB)
    reg [1:0]  pulse_phase;         // Phase sequencing for 2-phase asymmetric pulse or gamepad LATCH/CLOCK
    reg [7:0]  t_act_0;             // Active pulse duration for bit '0' (cycles - 1, default 19 for 400ns @ 50MHz)
    reg [7:0]  t_rest_0;            // Rest duration for bit '0' (cycles - 1, default 41 for 850ns @ 50MHz)
    reg [7:0]  t_act_1;             // Active pulse duration for bit '1' (cycles - 1, default 39 for 800ns @ 50MHz)
    reg [7:0]  t_rest_1;            // Rest duration for bit '1' (cycles - 1, default 21 for 450ns @ 50MHz)
    reg [7:0]  t_latch;             // Gamepad LATCH pulse width (cycles - 1, default 60 @ 50MHz)
    reg [7:0]  pulse_thresh;        // RX pulse discrimination threshold (default 29 for 600ns @ 50MHz)
    reg        pad_snes_16b;        // 0=8-bit NES mode, 1=16-bit SNES mode
    reg [15:0] pad_shift_reg;       // 16-bit shift register for NES/SNES multi-byte reads/emulation
    reg [7:0]  pulse_rx_cnt;        // Measured duration of active pulse during RX

    // Autonomous Manchester & Biphase Mark Stream Accelerators State (Task 19)
    reg        assist_manch_en;     // 1=Enable Manchester / BMC acceleration
    reg [1:0]  assist_manch_mode;   // 00=IEEE 802.3 (10BASE-T), 01=Thomas (Inverted), 10=BMC (Biphase Mark)
    reg        manch_tx_phase;      // 0=First half-bit, 1=Second half-bit
    reg        manch_tx_state;      // Line level state tracker for BMC mode
    reg        manch_rx_phase;      // 0=First half-bit sample, 1=Second half-bit sample & decode
    reg        manch_rx_sample1;    // First half-bit sampled value
    reg        manch_error;         // Latched error flag for Manchester code violation

    // Dedicated Hardware I2C / SMBus Slave Engine State (Task 21)
    reg        i2c_slave_en;        // 1=Enable hardware I2C slave monitor
    reg [6:0]  i2c_slave_addr;      // 7-bit programmable slave address
    reg        i2c_stretch_en;      // 1=Enable automatic clock stretching (holding SCL low)
    reg        i2c_addr_match;      // 1=Slave address matched
    reg        i2c_rw_bit;          // 0=Master Write, 1=Master Read
    reg        i2c_start_flag;      // Sticky flag: set on START / repeated START
    reg        i2c_stop_flag;       // Sticky flag: set on STOP
    reg        i2c_bus_active;      // 1=Bus active between START and STOP
    reg        i2c_master_ack;      // Sampled Master ACK (1=ACK, 0=NACK)
    reg        i2c_drive_ack;       // 1=Autonomous hardware pulling SDA low for ACK
    reg        i2c_stretch_hold;    // 1=Autonomous hardware holding SCL low for clock stretch
    reg [7:0]  i2c_rx_addr;         // Latched 8-bit address word from master
    reg [3:0]  i2c_bit_idx;         // Bit counter for address reception
    reg [3:0]  i2c_slave_state;     // State machine: 0=IDLE, 1=ADDR_RX, 2=ADDR_ACK, 3=DATA_WAIT
    reg [1:0]  in_slave_phase;      // Phase sequencing for IN SLAVE
    reg [1:0]  out_slave_phase;     // Phase sequencing for OUT SLAVE
    reg        scl_prev;            // Previous SCL level for edge detection
    reg        sda_prev;            // Previous SDA level for edge detection

    // 1-Bit Delta-Sigma Audio DAC & 4-Voice Chiptune PDM Synthesizer State (Task 22)
    reg        audio_en;        // 1=Enable audio engine and PDM output on audio_pin
    reg [1:0]  audio_mode;      // 00=Off, 01=Direct PCM, 10=Chiptune APU, 11=Hybrid
    reg [2:0]  audio_pin;       // GPIO pin index for PDM output (0..7, default cs_pin/2)
    reg        audio_diff;      // 1=Enable differential inverted PDM output on (audio_pin ^ 1)
    reg [7:0]  audio_sample;    // Current 8-bit DAC sample (0..255)
    reg [8:0]  pdm_acc;         // 9-bit Delta-Sigma first-order accumulator
    reg        pdm_bit;         // 1-bit PDM output stream bit

    // 4-Voice Chiptune APU Synthesizer Registers
    reg [15:0] v0_period;       // Voice 0 (Pulse 1) 16-bit period divider
    reg [15:0] v0_cnt;          // Voice 0 period counter
    reg [2:0]  v0_step;         // Voice 0 8-step duty cycle sequencer
    reg [1:0]  v0_duty;         // Voice 0 duty cycle: 00=12.5%, 01=25%, 10=50%, 11=75%
    reg [3:0]  v0_vol;          // Voice 0 volume (0..15)

    reg [15:0] v1_period;       // Voice 1 (Pulse 2) 16-bit period divider
    reg [15:0] v1_cnt;          // Voice 1 period counter
    reg [2:0]  v1_step;         // Voice 1 8-step duty cycle sequencer
    reg [1:0]  v1_duty;         // Voice 1 duty cycle: 00=12.5%, 01=25%, 10=50%, 11=75%
    reg [3:0]  v1_vol;          // Voice 1 volume (0..15)

    reg [15:0] v2_period;       // Voice 2 (Triangle) 16-bit period divider
    reg [15:0] v2_cnt;          // Voice 2 period counter
    reg [4:0]  v2_step;         // Voice 2 32-step triangle sequencer
    reg [3:0]  v2_vol;          // Voice 2 volume (0..15)

    reg [15:0] v3_period;       // Voice 3 (Noise) 16-bit period divider
    reg [15:0] v3_cnt;          // Voice 3 period counter
    reg [14:0] v3_lfsr;         // Voice 3 15-bit Galois LFSR noise generator
    reg        v3_mode;         // Voice 3 noise mode: 0=15-bit, 1=7-bit metallic
    reg [3:0]  v3_vol;          // Voice 3 volume (0..15)

    reg [3:0]  audio_preset;    // Active sound effect preset ID (1=BEEP, 2=BLIP, 3=ERROR, 4=COIN, 5=LASER, 6=SIREN, 7=NOISE)
    reg [19:0] preset_timer;    // Preset duration timer
    reg [3:0]  preset_step;     // Preset progression step counter

    // =========================================================================
    // Dedicated Hardware JTAG TAP Controller & ARM SWD Sequencer State (Task 23)
    // =========================================================================
    // JTAG TAP Controller State
    reg        jtag_en;           // 1=Enable JTAG hardware master mode
    reg [3:0]  jtag_state;        // Current 16-state JTAG TAP FSM state (0=RESET, 1=IDLE, etc.)
    reg [7:0]  jtag_tms_shifter;  // TMS bit shift register
    reg [3:0]  jtag_tms_cnt;      // Number of TMS bits remaining to clock
    reg        jtag_tms;          // Current TMS bit level driven to cs_pin
    reg        jtag_tck;          // Current TCK clock level driven to sck_pin
    reg        jtag_tdi;          // Current TDI bit level driven to tx_pin
    reg        jtag_tdo_sampled;  // Last sampled TDO bit from rx_pin
    reg [31:0] jtag_dr_reg;       // 32-bit Data Register shift storage (IDCODE / DTMCS / DMI)
    reg [7:0]  jtag_ir_reg;       // 8-bit Instruction Register shift storage
    reg [5:0]  jtag_shift_cnt;    // Bit counter for JTAG IR/DR shifts
    reg        jtag_exit_on_last; // 1=Assert TMS high on final shifted bit to exit Shift state
    reg        jtag_phase;        // 0=Setup TDI/TMS, TCK low; 1=TCK high, sample TDO, step TAP state

    // ARM SWD Sequencer State
    reg        swd_en;            // 1=Enable ARM SWD hardware host mode
    reg [3:0]  swd_state;         // 0=IDLE, 1=REQ, 2=TRN_IN, 3=ACK, 4=TRN_OUT, 5=DATA_TX, 6=DATA_RX, 7=RESET_SYNC, 8=RESET_SWITCH, 9=RESET_POST
    reg [7:0]  swd_req_byte;      // 8-bit Request Header: [1, APnDP, RnW, A2, A3, Parity, 0, 1]
    reg [2:0]  swd_last_ack;      // Sampled 3-bit ACK from target (001=OK, 010=WAIT, 100=FAULT)
    reg        swd_parity_err;    // Sticky flag: set on SWD data parity mismatch
    reg        swd_swdio_out;     // Current SWDIO drive level
    reg        swd_sclk;          // Current SWCLK clock level driven to sck_pin
    reg        swd_oe;            // 1=Drive SWDIO, 0=Tri-state (Hi-Z during target ACK / Read)
    reg [5:0]  swd_bit_cnt;       // Bit counter for SWD phases
    reg [31:0] swd_data_reg;      // 32-bit SWD Data read/write storage
    reg        swd_parity_bit;    // Calculated parity bit
    reg [7:0]  swd_reset_cnt;     // Counter for 50+ line reset clocks
    reg [15:0] swd_switch_seq;    // 16-bit JTAG-to-SWD select sequence (0xE79E)
    reg        swd_phase;         // Clock phase: 0=Falling (drive), 1=Rising (sample)

    // =========================================================================
    // Dedicated Hardware Quad-SPI (QSPI) & Multi-Lane Host State (Task 24)
    // =========================================================================
    reg        qspi_en;           // 1=Enable hardware QSPI host engine
    reg [1:0]  qspi_width;        // 0=Single (1-bit), 1=Dual (2-bit), 2=Quad (4-bit), 3=Octal (8-bit)
    reg        qspi_ddr;          // 1=Double Data Rate (both edges), 0=Single Data Rate
    reg        qspi_cpol;         // 0=SCK idle low, 1=SCK idle high
    reg [3:0]  qspi_state;        // 0=IDLE, 1=CMD, 2=ADDR, 3=DUMMY, 4=DATA_RX, 5=DATA_TX
    reg [7:0]  qspi_cmd_byte;     // 8-bit instruction opcode
    reg [31:0] qspi_addr_reg;     // 24-bit or 32-bit address storage
    reg [5:0]  qspi_addr_bits;    // Remaining address bits to clock (e.g. 24 or 32)
    reg [3:0]  qspi_dummy_cnt;    // Remaining dummy clock cycles
    reg [5:0]  qspi_bit_cnt;      // Bit/nibble transfer counter within byte
    reg [31:0] qspi_data_reg;     // 32-bit multi-lane shift storage
    reg        qspi_sclk;         // Generated SCK clock level
    reg        qspi_cs;           // Generated CS# level (active low)
    reg        qspi_oe;           // Output enable for data lanes
    reg [7:0]  qspi_data_out;     // Data bits driven to lanes
    reg        qspi_phase;        // Clock phase: 0=drive/setup, 1=sample/hold
    reg [7:0]  qspi_rx_byte;      // Assembled received byte

    // Pin Role Mapping & GPIO Control Registers
    reg [2:0]  tx_pin;          // Pin index for OUT serializer (default 0)
    reg [2:0]  rx_pin;          // Pin index for IN deserializer / default WAIT (default 0)
    reg [2:0]  sck_pin;         // Pin index for OUT SCK clock (default 1)
    reg [2:0]  cs_pin;          // Pin index for CS_n (default 2)
    reg [7:0]  gpio_od;         // Open-drain mask: 1=open-drain, 0=push-pull
    reg [7:0]  gpio_out_reg;    // 8-bit GPIO output levels
    reg [7:0]  gpio_oe_reg;     // 8-bit GPIO output enables (1=drive, 0=Hi-Z)



    // =========================================================================
    // OMNIBUS 16-BIT INSTRUCTION SET ARCHITECTURE (ISA) SPECIFICATION
    // =========================================================================
    //
    // All instructions are 16 bits wide and execute in a single clock cycle
    // plus an optional sidecar hardware delay counter (Zero-Jitter timing).
    //
    // -------------------------------------------------------------------------
    // General Instruction Encoding:
    // -------------------------------------------------------------------------
    //
    // [15:12] (4b) : Opcode (0x0 .. 0xF)
    // [11:0]  (12b): Instruction-specific operands, mode, and sidecar delay
    //
    // -------------------------------------------------------------------------
    // Timing & Delay Sentinels:
    // -------------------------------------------------------------------------
    // Most instructions support sidecar delay counters in clock cycles:
    //   - Standard 9-bit delay (instr[8:0]):
    //       0x000 .. 0x1FD : Fixed delay in clock cycles (0 to 509 cycles)
    //       0x1FE ($HBAUD) : Dynamic half-bit baud delay = (i_baud_div >> 1)
    //       0x1FF ($BAUD)  : Dynamic full-bit baud delay = i_baud_div
    //   - Standard 8-bit delay (instr[7:0]):
    //       0x00 .. 0xFD   : Fixed delay in clock cycles (0 to 253 cycles)
    //       0xFE ($HBAUD)  : Dynamic half-bit baud delay = (i_baud_div >> 1)
    //       0xFF ($BAUD)   : Dynamic full-bit baud delay = i_baud_div
    //
    // =========================================================================
    // COMPLETE INSTRUCTION SET REFERENCE:
    // =========================================================================
    //
    // 0x0 | NOP [delay]
    //       [15:12] = 0x0
    //       [8:0]   = delay (9b: cycles / $HBAUD / $BAUD)
    //       Exact cycle-accurate delay without modifying registers or I/O.
    //
    // 0x1 | OUT mode, [bit_cnt,] delay
    //       [15:12] = 0x1
    //       [11:10] = mode:
    //                 2'b00: UART LSB-first serializer (drives tx_pin from OSR[0])
    //                 2'b01: SPI MSB-first serializer (drives tx_pin, auto-toggles
    //                        sck_pin, simultaneously samples rx_pin into ISR)
    //                 2'b10: 1-Wire LSB-first serializer (OUT 1W): drives tx_pin open-drain
    //                        with precise 1W bit slots (short low for 1, long low for 0).
    //                        [9] = 0: 8-bit byte transfer, 1: 1-bit slot (Search ROM)
    //                 2'b11: I2C MSB-first serializer (drives tx_pin/SDA open-drain,
    //                        auto-toggles sck_pin/SCL, samples rx_pin into ISR)
    //       [8:0]   = delay (9b: half-period, bit-period, or 1W short pulse delay)
    //
    // 0x2 | IN mode, [bit_cnt,] delay
    //       [15:12] = 0x2
    //       [11:10] = mode:
    //                 2'b00: UART LSB-first deserializer (samples rx_pin into ISR[7],
    //                        supports variable bit count via instr[11:9])
    //                 2'b01: SPI Master Read (IN SCK): auto-toggles sck_pin 8 times,
    //                        deserializes rx_pin (MISO) MSB-first into ISR
    //                 2'b10: 1-Wire Master Read (IN 1W): generates master read pulse on tx_pin,
    //                        releases line, samples rx_pin into ISR LSB-first at ~12us window.
    //                        [9] = 0: 8-bit byte transfer, 1: 1-bit slot (Search ROM)
    //                 2'b11: I2C Master Read (IN SDA): releases tx_pin (SDA Hi-Z OD),
    //                        auto-toggles sck_pin (SCL) 8 times, deserializes rx_pin
    //       [8:0]   = delay (9b: half-period, bit-period, or 1W short pulse delay)
    //
    // 0x3 | SET pin_sel, pin_val, delay
    //       [15:12] = 0x3
    //       [11:9]  = pin_sel (3b: physical GPIO pin 0..7)
    //       [8]     = pin_val (1b: 0 or 1)
    //       [7:0]   = delay   (8b: cycles / $HBAUD / $BAUD)
    //       Push-pull mode: actively drives pin_val (0 or 1).
    //       Open-drain mode (gpio_od[pin_sel]=1):
    //         pin_val=0 -> drives LOW (out=0, oe=1)
    //         pin_val=1 -> releases to Hi-Z (out=1, oe=0, external pull-up)
    //
    // 0x4 | WAIT pin_sel, pin_val, delay
    //       [15:12] = 4'h4
    //       [11:9]  = pin_sel (3b: physical GPIO pin 0..7)
    //       [8]     = pin_val (1b: 0 or 1)
    //       [7:0]   = delay   (8b: post-match settling delay / $HBAUD / $BAUD)
    //       Blocks PC execution until gpio_in[pin_sel] == pin_val, then executes
    //       the specified sidecar delay before advancing to next instruction.
    //
    // 0x5 | PINMAP tx, rx, sck, cs
    //       [15:12] = 4'h5
    //       [11:9]  = tx_pin  (3b: GPIO pin for UART TX / SPI MOSI / I2C SDA)
    //       [8:6]   = rx_pin  (3b: GPIO pin for UART RX / SPI MISO / I2C SDA)
    //       [5:3]   = sck_pin (3b: GPIO pin for SPI SCK / I2C SCL)
    //       [2:0]   = cs_pin  (3b: GPIO pin for SPI CS_n)
    //       Dynamically remaps protocol engine signals across physical GPIO 0..7.
    //       Automatically configures default pin directions (TX, SCK, CS -> OUT; RX -> IN).
    //
    // 0x6 | CFG_OD mask
    //       [15:12] = 4'h6
    //       [7:0]   = od_mask (8b: bitmask for GPIO pins 7..0)
    //       Configures individual GPIO pin drive behavior:
    //         0 = Push-pull (active high / active low drive)
    //         1 = Open-drain (active low drive / Hi-Z release for I2C, 1-Wire, etc.)
    //
    // 0x7 | HARDWARE LOOP COUNTERS (Zero-overhead branching & packet counting)
    //       [15:12] = 4'h7
    //       [11]    = lc_sel (1b: 0 = LC0, 1 = LC1)
    //       [10]    = op_mode:
    //                 0 : DJNZ LCx, target (Decrement and Jump if Not Zero)
    //                     [4:0] = target destination address (0..31)
    //                     Decrements LCx. If LCx != 1, jumps to target in 1 cycle.
    //                     When LCx == 1, decrements to 0 and falls through (pc+1).
    //                     If LCx == 0 on entry, wraps to 255 (256 loop iterations).
    //                 1 : Load / Store operations:
    //                     [9:8] = 2'b00 : SET_LC LCx, count (count = instr[7:0])
    //                     [9:8] = 2'b01 : PULL_LC LCx       (loads LCx from i_data)
    //                     [9:8] = 2'b10 : PUSH_LC LCx       (outputs LCx to o_data & OSR)
    //                     [9:8] = 2'b11 : MOV_LC  LCx, OSR  (loads LCx from OSR)
    //
    // 0x8 | JMP [cond], target
    //       [15:12] = 4'h8
    //       [11:8]  = condition:
    //                 4'h0: Unconditional JMP target (default)
    //                 4'h1: JMP TX_VALID, target (jump if i_tx_valid == 1)
    //                 4'h2: JMP TX_EMPTY, target (jump if i_tx_valid == 0)
    //                 4'h3: JMP RX_FULL,  target (jump if i_rx_full  == 1)
    //                 4'h4: JMP RX_READY, target (jump if i_rx_full  == 0)
    //                 4'h5: JMP PIN_HI,   target (jump if gpio_in[rx_pin] == 1)
    //                 4'h6: JMP PIN_LO,   target (jump if gpio_in[rx_pin] == 0)
    //                 4'h7: JMP CRC_OK,   target (jump if crc_reg == 16'h0000)
    //                 4'h8: JMP ZERO / EQ,target (jump if zero_flag == 1)
    //                 4'h9: JMP NOT_ZERO, target (jump if zero_flag == 0)
    //                 4'hA: JMP CARRY,    target (jump if carry_flag == 1)
    //                 4'hB: JMP NOT_CARRY,target (jump if carry_flag == 0)
    //                 4'hC: JMP NEG,      target (jump if acc[7] == 1)
    //                 4'hD: JMP POS,      target (jump if acc[7] == 0)
    //                 4'hE: JMP CRC_ERR,  target (jump if crc_reg != 16'h0000)
    //       [4:0]   = target address (0..31)
    //       Single-cycle branch. If condition met, branches to target; else pc+1.
    //
    // 0x9 | PULL [BLOCK]
    //       [15:12] = 4'h9
    //       [0]     = block_mode (0 = non-blocking, 1 = blocking wait for i_tx_valid)
    //       Refills Output Shift Register (OSR <= i_data) from host/TX FIFO.
    //       Pulses o_tx_pop for 1 cycle when data is consumed.
    //
    // 0xA | PUSH [BLOCK]
    //       [15:12] = 4'hA
    //       [0]     = block_mode (0 = non-blocking, 1 = blocking wait for !i_rx_full)
    //       Flushes Input Shift Register to output port and OSR (OSR <= ISR, o_data <= ISR).
    //       Pulses o_rx_push for 1 cycle.
    //
    // 0xB | ALU sub_op, [operands]
    //       [15:12] = 4'hB
    //       [11]    = mode: 0 = Immediate mode, 1 = Register mode
    //       Immediate mode ([11] == 0):
    //         [10:8] = sub_op:
    //                  3'b000: ADD acc, imm8   ({carry, acc} <= acc + imm8)
    //                  3'b001: SUB acc, imm8   ({carry, acc} <= acc - imm8)
    //                  3'b010: CMP acc, imm8   (computes acc - imm8, sets zero/carry)
    //                  3'b011: AND acc, imm8   (acc <= acc & imm8)
    //                  3'b100: OR  acc, imm8   (acc <= acc | imm8)
    //                  3'b101: XOR acc, imm8   (acc <= acc ^ imm8)
    //                  3'b110: MOV acc, imm8   (acc <= imm8)
    //                  3'b111: NOT acc         (acc <= ~acc)
    //         [7:0]  = imm8 (8-bit immediate value)
    //       Register mode ([11] == 1):
    //         [10:8] = sub_op:
    //                  3'b000: MOV acc, reg    (acc <= reg[src])
    //                  3'b001: MOV reg, acc    (reg[dst] <= acc)
    //                  3'b010: ADD acc, reg    ({carry, acc} <= acc + reg[src])
    //                  3'b011: SUB acc, reg    ({carry, acc} <= acc - reg[src])
    //                  3'b100: CMP acc, reg    (computes acc - reg[src], sets flags)
    //                  3'b101: LOGIC acc, reg  (AND/OR/XOR via [5:3])
    //                  3'b110: UNARY acc       (INC/DEC/CLR via [5:3])
    //                  3'b111: SHIFT acc       (SHL/SHR/ROL/ROR via [5:3])
    //         [5:3]  = dst_reg / sub-operation selector
    //         [2:0]  = src_reg (000:OSR, 001:ISR, 010:LC0, 011:LC1, 100:i_data, 101:acc, 110:CRC_L, 111:CRC_H)
    //
    // 0xC | CALL target
    //       [15:12] = 4'hC
    //       [4:0]   = target address (0..31)
    //       Pushes (pc + 1) to 4-deep hardware return address call stack (LIFO)
    //       and jumps to target address.
    //
    // 0xD | RET
    //       [15:12] = 4'hD
    //       Pops return address from hardware call stack and jumps to it.
    //
    // 0xE | CRC sub_op, [operands]
    //       [15:12] = 4'hE
    //       [11:9]  = sub_op:
    //                 3'b000: CRC_INIT poly, seed
    //                         [8:7] poly: 00=Dallas CRC-8 (0x8C), 01=SMBus CRC-8 (0x07),
    //                                     10=CCITT CRC-16 (0x1021), 11=Modbus CRC-16 (0xA001)
    //                         [6:5] seed: 00=Default for poly (Modbus=0xFFFF, others=0x0000),
    //                                     01=0x0000, 10/11=0xFFFF
    //                 3'b001: CRC_BYTE OSR  (updates crc_reg with OSR byte in 1 cycle)
    //                 3'b010: CRC_BYTE ISR  (updates crc_reg with ISR byte in 1 cycle)
    //                 3'b011: CRC_BYTE DATA (updates crc_reg with i_data in 1 cycle)
    //                 3'b100: CRC_READ_LOW  (latches crc_reg[7:0] to OSR & o_data)
    //                 3'b101: CRC_READ_HIGH (latches crc_reg[15:8] to OSR & o_data)
    //                 3'b110: CRC_RESET     (reloads configured seed into crc_reg)
    //
    // 0xF | ASSIST sub_op, [operands]
    //       [15:12] = 4'hF
    //       [11:10] = sub_op:
    //                 2'b00: ASSIST CFG, nrzi_en, stuff_mode, [init_val]
    //                        [9]   = nrzi_en    (1=enable NRZI toggle-on-0)
    //                        [8:7] = stuff_mode (00=off, 01=USB 6-ones, 10=CAN 5-identical)
    //                        [6]   = init_en    (1=re-init NRZI line state from [5])
    //                        [5]   = init_val   (0 or 1, default 1'b1 for USB idle J-state)
    //                 2'b01: ASSIST RESET
    //                        Clears run counters, stuff_error flag, and resets NRZI states.
    //                 2'b10: ASSIST READ
    //                        Reads {stuff_error, assist_nrzi_en, assist_stuff_mode, 1'b0, tx_stuff_cnt} into acc.
    //                        Sets zero_flag <= !stuff_error, carry_flag <= stuff_error.
    //
    // =========================================================================
    // Microcode RAM (128 words x 16 bits = 4 banks of 32 words)
    // =========================================================================
    reg [15:0] imem [0:127];

    assign o_prog_rdata = imem[i_prog_addr];

    integer i;
    initial begin
        for (i = 0; i < 128; i = i + 1) begin
            imem[i] = 16'h0000;
        end
        // UART Echo Transceiver with runtime baud sentinels ($HBAUD=0xFE, $BAUD=0xFF)
        imem[0] = 16'h40FE; // WAIT rx=0, $HBAUD
        imem[1] = 16'h01FF; // NOP       $BAUD
        imem[2] = 16'h21FF; // IN  rx, 8 $BAUD
        imem[3] = 16'h4100; // WAIT rx=1, 0
        imem[4] = 16'hA000; // PUSH
        imem[5] = 16'h30FF; // SET tx=0, $BAUD
        imem[6] = 16'h11FF; // OUT tx, 8 $BAUD
        imem[7] = 16'h31FF; // SET tx=1, $BAUD
        imem[8] = 16'h8000; // JMP 0x0
    end

    // Synchronous write port for runtime programming with power-on reset defaults
    always @(posedge i_clk) begin
        if (!i_reset_n) begin
            imem[0]  <= 16'h40FE;
            imem[1]  <= 16'h01FF;
            imem[2]  <= 16'h21FF;
            imem[3]  <= 16'h4100;
            imem[4]  <= 16'hA000;
            imem[5]  <= 16'h30FF;
            imem[6]  <= 16'h11FF;
            imem[7]  <= 16'h31FF;
            imem[8]  <= 16'h8000;
            for (i = 9; i < 128; i = i + 1) begin
                imem[i] <= 16'h0000;
            end
        end else if (i_prog_en && i_prog_we) begin
            imem[i_prog_addr] <= i_prog_data;
        end
    end

    wire [15:0] instr   = imem[pc];
    wire [3:0]  opcode  = instr[15:12];

    // -------------------------------------------------------------------------
    // 4-Voice Chiptune APU Combinational Waveforms & Digital Mixer Logic
    // -------------------------------------------------------------------------
    wire v0_wave = (v0_duty == 2'b00) ? (v0_step == 3'd0) :
                   (v0_duty == 2'b01) ? (v0_step < 3'd2) :
                   (v0_duty == 2'b10) ? (v0_step < 3'd4) : (v0_step < 3'd6);
    wire [5:0] v0_out = (v0_wave && v0_vol != 4'd0) ? {v0_vol, 2'b00} : 6'd0;

    wire v1_wave = (v1_duty == 2'b00) ? (v1_step == 3'd0) :
                   (v1_duty == 2'b01) ? (v1_step < 3'd2) :
                   (v1_duty == 2'b10) ? (v1_step < 3'd4) : (v1_step < 3'd6);
    wire [5:0] v1_out = (v1_wave && v1_vol != 4'd0) ? {v1_vol, 2'b00} : 6'd0;

    wire [3:0] v2_tri = (v2_step < 5'd16) ? v2_step[3:0] : (4'd15 - v2_step[3:0]);
    wire [5:0] v2_out = (v2_vol != 4'd0) ? {v2_tri, 2'b00} : 6'd0;

    wire [5:0] v3_out = (v3_lfsr[0] && v3_vol != 4'd0) ? {v3_vol, 2'b00} : 6'd0;

    wire [7:0] raw_synth_sum = (v0_out + v1_out + v2_out + v3_out);
    wire [7:0] synth_sample  = (v0_vol == 4'd0 && v1_vol == 4'd0 && v2_vol == 4'd0 && v3_vol == 4'd0) ? 8'h80 :
                               (raw_synth_sum > 8'd255) ? 8'hFF : raw_synth_sum;

    wire [7:0] active_audio_sample = (audio_mode == 2'b10) ? synth_sample : audio_sample;
    wire [8:0] pdm_sum             = {1'b0, pdm_acc[7:0]} + {1'b0, active_audio_sample};

    wire slave_sda_drive = i2c_drive_ack || (opcode == 4'h1 && instr[11:9] == 3'b111 && out_slave_phase == 2'd0 && osr[7] == 1'b0);
    wire slave_scl_drive = i2c_stretch_hold;

    wire [7:0] i2c_gpio_out;
    wire [7:0] i2c_gpio_oe;

    genvar p;
    generate
        for (p = 0; p < 8; p = p + 1) begin : gen_i2c_gpio
            wire is_tx  = (p == tx_pin);
            wire is_sck = (p == sck_pin);
            wire is_cs  = (p == cs_pin);
            wire is_rx  = (p == rx_pin);
            wire is_audio_main = audio_en && (p == audio_pin);
            wire is_audio_diff = audio_en && audio_diff && (p == (audio_pin ^ 3'd1));

            wire is_jtag_tck = jtag_en && is_sck;
            wire is_jtag_tms = jtag_en && is_cs;
            wire is_jtag_tdi = jtag_en && is_tx;

            wire is_swd_sclk  = swd_en && is_sck;
            wire is_swd_swdio = swd_en && is_tx;

            wire [2:0] qspi_rx_p = (rx_pin == tx_pin) ? 3'd3 : rx_pin;
            wire is_qspi_sck   = qspi_en && is_sck && (qspi_width != 2'b11);
            wire is_qspi_cs    = qspi_en && is_cs && (qspi_width != 2'b11);
            wire is_qspi_lane0 = qspi_en && (p == tx_pin);
            wire is_qspi_lane1 = qspi_en && (p == qspi_rx_p) && (qspi_width != 2'b00);
            wire is_qspi_lane2 = qspi_en && (p == 3'd4) && (qspi_width[1] == 1'b1);
            wire is_qspi_lane3 = qspi_en && (p == 3'd5) && (qspi_width[1] == 1'b1);
            wire is_qspi_octal = qspi_en && (qspi_width == 2'b11);
            wire is_qspi_lane  = is_qspi_lane0 || is_qspi_lane1 || is_qspi_lane2 || is_qspi_lane3 || is_qspi_octal;
            wire qspi_bit_val  = is_qspi_octal ? qspi_data_out[p] :
                                 is_qspi_lane0 ? qspi_data_out[0] :
                                 is_qspi_lane1 ? qspi_data_out[1] :
                                 is_qspi_lane2 ? qspi_data_out[2] :
                                 is_qspi_lane3 ? qspi_data_out[3] : 1'b0;

            assign i2c_gpio_out[p] = is_audio_main ? pdm_bit :
                                     is_audio_diff ? ~pdm_bit :
                                     is_jtag_tck   ? jtag_tck :
                                     is_jtag_tms   ? jtag_tms :
                                     is_jtag_tdi   ? jtag_tdi :
                                     is_swd_sclk   ? swd_sclk :
                                     is_swd_swdio  ? swd_swdio_out :
                                     is_qspi_sck   ? qspi_sclk :
                                     is_qspi_cs    ? qspi_cs :
                                     is_qspi_lane  ? qspi_bit_val :
                                     (is_tx && slave_sda_drive) ? 1'b0 :
                                     (is_sck && slave_scl_drive) ? 1'b0 :
                                     (i2c_slave_en && (is_tx || is_sck)) ? 1'b1 :
                                     gpio_out_reg[p];

            assign i2c_gpio_oe[p]  = is_audio_main ? 1'b1 :
                                     is_audio_diff ? 1'b1 :
                                     is_jtag_tck   ? 1'b1 :
                                     is_jtag_tms   ? 1'b1 :
                                     is_jtag_tdi   ? 1'b1 :
                                     (jtag_en && is_rx) ? 1'b0 :
                                     is_swd_sclk   ? 1'b1 :
                                     is_swd_swdio  ? swd_oe :
                                     is_qspi_sck   ? 1'b1 :
                                     is_qspi_cs    ? 1'b1 :
                                     is_qspi_lane  ? qspi_oe :
                                     (qspi_en && (qspi_width == 2'b00) && (p == qspi_rx_p)) ? 1'b0 :
                                     (is_tx && slave_sda_drive) ? 1'b1 :
                                     (is_sck && slave_scl_drive) ? 1'b1 :
                                     (i2c_slave_en && (is_tx || is_sck)) ? 1'b0 :
                                     gpio_oe_reg[p];
        end
    endgenerate

    assign o_gpio     = i2c_gpio_out;
    assign o_gpio_oe  = i2c_gpio_oe;
    assign o_tx       = i2c_gpio_out[tx_pin];
    assign o_spi_sck  = qspi_en ? qspi_sclk : i2c_gpio_out[sck_pin];
    assign o_spi_cs_n = qspi_en ? qspi_cs   : i2c_gpio_out[cs_pin];

    // Operands for SET / WAIT:
    // [11:9] pin_sel (3 bits: GPIO 0..7)
    // [8]    pin_val (1 bit: 0 or 1)
    // [7:0]  sw_delay (8 bits: 0..253, 0xFE=$HBAUD, 0xFF=$BAUD)
    wire [2:0]  pin_sel  = instr[11:9];
    wire        pin_val  = instr[8];
    wire [7:0]  sw_delay = instr[7:0];

    // IN bit count: instr[11:9]=0 means 8 bits (backward compat), 1..7 means N bits.
    wire [3:0] in_count_init = (instr[11:9] == 3'd0) ? 4'd7 : ({1'b0, instr[11:9]} - 4'd1);

    // Standard 9-bit delay for NOP, OUT, IN:
    wire [8:0]  delay   = instr[8:0];
    wire [6:0]  target  = instr[6:0];

    // Resolved delays:
    // Full 16-bit eff_delay (NOP, OUT, IN):
    wire [15:0] eff_delay = (delay == 9'h1FF) ? i_baud_div :
                            (delay == 9'h1FE) ? (i_baud_div >> 1) :
                            {7'd0, delay};

    // 16-bit eff_sw_delay (SET, WAIT):
    wire [15:0] eff_sw_delay = (sw_delay == 8'hFF) ? i_baud_div :
                               (sw_delay == 8'hFE) ? (i_baud_div >> 1) :
                               {8'd0, sw_delay};

    // 1-Wire multi-pulse derived delays (10x and 9x short pulse duration)
    wire [15:0] eff_delay_10x = (eff_delay << 3) + (eff_delay << 1);
    wire [15:0] eff_delay_9x  = (eff_delay << 3) + eff_delay;
    wire [15:0] eff_hdelay    = (eff_delay >> 1);
    wire [15:0] debug_hdelay  = (i_baud_div <= 16'd24) ? 16'd3 : (i_baud_div >> 3);

    // -------------------------------------------------------------------------
    // 2-stage input synchronizer for all 8 GPIO pins
    // Supports backward compatibility: merges i_rx with i_gpio[rx_pin] and i_gpio[0]
    // -------------------------------------------------------------------------
    wire [7:0] gpio_raw;
    genvar g;
    generate
        for (g = 0; g < 8; g = g + 1) begin : gen_gpio_raw
            assign gpio_raw[g] = (swd_en && g == tx_pin) ? i_gpio[g] :
                                 (qspi_en) ? i_gpio[g] :
                                 (g == rx_pin || g == 3'd0) ? (i_gpio[g] & i_rx) : i_gpio[g];
        end
    endgenerate

    reg [7:0] gpio_sync_0, gpio_sync_1;
    always @(posedge i_clk) begin
        if (!i_reset_n) begin
            gpio_sync_0 <= 8'hFF;
            gpio_sync_1 <= 8'hFF;
        end else begin
            gpio_sync_0 <= gpio_raw;
            gpio_sync_1 <= gpio_sync_0;
        end
    end
    wire [7:0] gpio_in = gpio_sync_1;

    // Dedicated Multi-Lane QSPI / Octal Input Bus Sampling Wires (Task 24)
    wire [2:0] qspi_rx_in_pin = (rx_pin == tx_pin) ? 3'd3 : rx_pin;
    wire [3:0] qspi_in_nibble = {gpio_in[5], gpio_in[4], gpio_in[qspi_rx_in_pin], gpio_in[tx_pin]};
    wire [1:0] qspi_in_pair   = {gpio_in[qspi_rx_in_pin], gpio_in[tx_pin]};
    wire       qspi_in_single = gpio_in[qspi_rx_in_pin];
    wire [7:0] qspi_in_octal  = gpio_in;

    // Dedicated Hardware I2C / SMBus Slave Line Edge & Framing Detectors
    wire i2c_scl_in = gpio_in[sck_pin];
    wire i2c_sda_in = gpio_in[tx_pin] & gpio_in[rx_pin];

    wire scl_rise = (!scl_prev && i2c_scl_in);
    wire scl_fall = (scl_prev && !i2c_scl_in);
    wire sda_fall = (sda_prev && !i2c_sda_in);
    wire sda_rise = (!sda_prev && i2c_sda_in);

    wire i2c_start_cond = (sda_fall && i2c_scl_in);
    wire i2c_stop_cond  = (sda_rise && i2c_scl_in);

    // Stream Accelerator RX Decoding: NRZI transition detector
    wire nrzi_rx_bit = (gpio_in[rx_pin] == nrzi_rx_prev) ? 1'b1 : 1'b0;
    wire dec_rx_bit  = assist_nrzi_en ? nrzi_rx_bit : gpio_in[rx_pin];

    // Asymmetric Single-Wire Serializer bit selector
    wire cur_pulse_bit = pulse_msb_first ? osr[7] : osr[0];

    // -------------------------------------------------------------------------
    // Hardware CRC Generator Combinational Functions (Parallel 8-bit XOR Tree)
    // -------------------------------------------------------------------------
    function [31:0] fn_crc8_dallas;
        input [7:0]  data;
        input [31:0] current_crc;
        reg   [7:0]  c;
        reg          fb;
        integer      i;
        begin
            c = current_crc[7:0];
            for (i = 0; i < 8; i = i + 1) begin
                fb = c[0] ^ data[i];
                c  = (c >> 1) ^ (fb ? 8'h8C : 8'h00);
            end
            fn_crc8_dallas = {24'h000000, c};
        end
    endfunction

    function [31:0] fn_crc8_smbus;
        input [7:0]  data;
        input [31:0] current_crc;
        reg   [7:0]  c;
        integer      i;
        begin
            c = current_crc[7:0] ^ data;
            for (i = 0; i < 8; i = i + 1) begin
                if (c[7])
                    c = (c << 1) ^ 8'h07;
                else
                    c = (c << 1);
            end
            fn_crc8_smbus = {24'h000000, c};
        end
    endfunction

    function [31:0] fn_crc16_ccitt;
        input [7:0]  data;
        input [31:0] current_crc;
        reg   [15:0] c;
        integer      i;
        begin
            c = current_crc[15:0] ^ {data, 8'h00};
            for (i = 0; i < 8; i = i + 1) begin
                if (c[15])
                    c = (c << 1) ^ 16'h1021;
                else
                    c = (c << 1);
            end
            fn_crc16_ccitt = {16'h0000, c};
        end
    endfunction

    function [31:0] fn_crc16_modbus;
        input [7:0]  data;
        input [31:0] current_crc;
        reg   [15:0] c;
        integer      i;
        begin
            c = current_crc[15:0] ^ {8'h00, data};
            for (i = 0; i < 8; i = i + 1) begin
                if (c[0])
                    c = (c >> 1) ^ 16'hA001;
                else
                    c = (c >> 1);
            end
            fn_crc16_modbus = {16'h0000, c};
        end
    endfunction

    function [31:0] fn_crc32_eth;
        input [7:0]  data;
        input [31:0] current_crc;
        reg   [31:0] c;
        integer      i;
        begin
            c = current_crc ^ {24'd0, data};
            for (i = 0; i < 8; i = i + 1) begin
                if (c[0])
                    c = (c >> 1) ^ 32'hEDB88320;
                else
                    c = (c >> 1);
            end
            fn_crc32_eth = c;
        end
    endfunction

    function [31:0] fn_crc5_usb;
        input [7:0]  data;
        input [31:0] current_crc;
        reg   [4:0]  c;
        reg          fb;
        integer      i;
        begin
            c = current_crc[4:0];
            for (i = 0; i < 8; i = i + 1) begin
                fb = c[0] ^ data[i];
                c  = (c >> 1) ^ (fb ? 5'h14 : 5'h00);
            end
            fn_crc5_usb = {27'd0, c};
        end
    endfunction

    // -------------------------------------------------------------------------
    // IEEE 1149.1 Standard 16-State JTAG TAP Transition Function
    // -------------------------------------------------------------------------
    function [3:0] fn_tap_next;
        input [3:0] cur;
        input       tms;
        begin
            case (cur)
                4'h0: fn_tap_next = tms ? 4'h0 : 4'h1; // TEST_LOGIC_RESET
                4'h1: fn_tap_next = tms ? 4'h2 : 4'h1; // RUN_TEST_IDLE
                4'h2: fn_tap_next = tms ? 4'h9 : 4'h3; // SELECT_DR_SCAN
                4'h3: fn_tap_next = tms ? 4'h5 : 4'h4; // CAPTURE_DR
                4'h4: fn_tap_next = tms ? 4'h5 : 4'h4; // SHIFT_DR
                4'h5: fn_tap_next = tms ? 4'h8 : 4'h6; // EXIT1_DR
                4'h6: fn_tap_next = tms ? 4'h6 : 4'h7; // PAUSE_DR
                4'h7: fn_tap_next = tms ? 4'h8 : 4'h4; // EXIT2_DR
                4'h8: fn_tap_next = tms ? 4'h2 : 4'h1; // UPDATE_DR
                4'h9: fn_tap_next = tms ? 4'h0 : 4'hA; // SELECT_IR_SCAN
                4'hA: fn_tap_next = tms ? 4'hC : 4'hB; // CAPTURE_IR
                4'hB: fn_tap_next = tms ? 4'hC : 4'hB; // SHIFT_IR
                4'hC: fn_tap_next = tms ? 4'hF : 4'hD; // EXIT1_IR
                4'hD: fn_tap_next = tms ? 4'hD : 4'hE; // PAUSE_IR
                4'hE: fn_tap_next = tms ? 4'hF : 4'hB; // EXIT2_IR
                4'hF: fn_tap_next = tms ? 4'h2 : 4'h1; // UPDATE_IR
            endcase
        end
    endfunction

    wire [7:0] crc_in_byte = (instr[10:9] == 2'b01) ? osr :
                             (instr[10:9] == 2'b10) ? isr : i_data;

    wire [31:0] next_crc_dallas = fn_crc8_dallas(crc_in_byte, crc_reg);
    wire [31:0] next_crc_smbus  = fn_crc8_smbus(crc_in_byte, crc_reg);
    wire [31:0] next_crc_ccitt  = fn_crc16_ccitt(crc_in_byte, crc_reg);
    wire [31:0] next_crc_modbus = fn_crc16_modbus(crc_in_byte, crc_reg);
    wire [31:0] next_crc_eth    = fn_crc32_eth(crc_in_byte, crc_reg);
    wire [31:0] next_crc_usb5   = fn_crc5_usb(crc_in_byte, crc_reg);

    wire [31:0] next_crc = (crc_poly == 3'b000) ? next_crc_dallas :
                           (crc_poly == 3'b001) ? next_crc_smbus  :
                           (crc_poly == 3'b010) ? next_crc_ccitt  :
                           (crc_poly == 3'b011) ? next_crc_modbus :
                           (crc_poly == 3'b100) ? next_crc_eth    :
                           (crc_poly == 3'b101) ? next_crc_usb5   :
                                                  next_crc_dallas;

    // -------------------------------------------------------------------------
    // 8-bit Micro-ALU Combinatorial Logic
    // -------------------------------------------------------------------------
    wire [7:0] alu_reg_val = (instr[2:0] == 3'b000) ? osr :
                             (instr[2:0] == 3'b001) ? isr :
                             (instr[2:0] == 3'b010) ? lc0 :
                             (instr[2:0] == 3'b011) ? lc1 :
                             (instr[2:0] == 3'b100) ? i_data :
                             (instr[2:0] == 3'b101) ? {6'b0, active_bank} :
                             (instr[2:0] == 3'b110) ? crc_reg[7:0] :
                                                      crc_reg[15:8];

    wire [8:0] alu_imm_add = {1'b0, acc} + {1'b0, instr[7:0]};
    wire [8:0] alu_imm_sub = {1'b0, acc} - {1'b0, instr[7:0]};

    wire [8:0] alu_reg_add = {1'b0, acc} + {1'b0, alu_reg_val};
    wire [8:0] alu_reg_sub = {1'b0, acc} - {1'b0, alu_reg_val};

    // -------------------------------------------------------------------------
    // Execution Engine
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (!i_reset_n || i_prog_en) begin
            pc            <= 7'd0;
            delay_cnt     <= 16'd0;
            tx_pin        <= 3'd0; // Default: Pin 0 = TX / MOSI
            rx_pin        <= 3'd0; // Default: Pin 0 = RX (legacy compat)
            sck_pin       <= 3'd1; // Default: Pin 1 = SCK
            cs_pin        <= 3'd2; // Default: Pin 2 = CS_n
            gpio_od       <= 8'h00; // Default: all push-pull
            gpio_out_reg  <= 8'b1111_1101; // Pin 0=1 (TX idle), Pin 1=0 (SCK idle low), Pin 2=1 (CS idle high)
            gpio_oe_reg   <= 8'b0000_0111; // Pins 0, 1, 2 driven outputs, others high-Z
            out_sck_phase <= 1'b0;
            in_sck_phase  <= 2'd0;
            osr           <= 8'h00;
            bit_cnt       <= 4'd0;
            isr           <= 8'h00;
            rx_bit_cnt    <= 4'd0;
            o_data        <= 8'h00;
            sp            <= 2'd0;
            call_stack[0] <= 7'd0;
            call_stack[1] <= 7'd0;
            call_stack[2] <= 7'd0;
            call_stack[3] <= 7'd0;
            active_bank   <= 2'b00;
            lc0           <= 8'd0;
            lc1           <= 8'd0;
            crc_reg       <= 32'd0;
            crc_seed      <= 32'd0;
            crc_poly      <= 3'd0;
            acc           <= 8'h00;
            zero_flag     <= 1'b0;
            carry_flag    <= 1'b0;
            o_tx_pop      <= 1'b0;
            o_rx_push     <= 1'b0;
            assist_nrzi_en    <= 1'b0;
            assist_stuff_mode <= 2'b00;
            nrzi_tx_state     <= 1'b1;
            nrzi_rx_prev      <= 1'b1;
            tx_stuff_cnt      <= 3'd0;
            rx_stuff_cnt      <= 3'd0;
            tx_last_bit       <= 1'b1;
            rx_last_bit       <= 1'b1;
            stuff_error       <= 1'b0;
            pulse_mode        <= 2'b00;
            pulse_polarity    <= 1'b0;
            pulse_msb_first   <= 1'b0;
            pulse_phase       <= 2'd0;
            t_act_0           <= 8'd19;
            t_rest_0          <= 8'd41;
            t_act_1           <= 8'd39;
            t_rest_1          <= 8'd21;
            t_latch           <= 8'd60;
            pulse_thresh      <= 8'd29;
            pad_snes_16b      <= 1'b0;
            pad_shift_reg     <= 16'd0;
            pulse_rx_cnt      <= 8'd0;
            assist_manch_en   <= 1'b0;
            assist_manch_mode <= 2'b00;
            manch_tx_phase    <= 1'b0;
            manch_tx_state    <= 1'b0;
            manch_rx_phase    <= 1'b0;
            manch_rx_sample1  <= 1'b0;
            manch_error       <= 1'b0;
            i2c_slave_en      <= 1'b0;
            i2c_slave_addr    <= 7'd0;
            i2c_stretch_en    <= 1'b0;
            i2c_addr_match    <= 1'b0;
            i2c_rw_bit        <= 1'b0;
            i2c_start_flag    <= 1'b0;
            i2c_stop_flag     <= 1'b0;
            i2c_bus_active    <= 1'b0;
            i2c_master_ack    <= 1'b0;
            i2c_drive_ack     <= 1'b0;
            i2c_stretch_hold  <= 1'b0;
            i2c_rx_addr       <= 8'd0;
            i2c_bit_idx       <= 4'd0;
            i2c_slave_state   <= 4'd0;
            in_slave_phase    <= 2'd0;
            out_slave_phase   <= 2'd0;
            scl_prev          <= 1'b1;
            sda_prev          <= 1'b1;
            audio_en          <= 1'b0;
            audio_mode        <= 2'b00;
            audio_pin         <= 3'd2; // Default Pin 2 (cs_pin)
            audio_diff        <= 1'b0;
            audio_sample      <= 8'h80;
            pdm_acc           <= 9'd0;
            pdm_bit           <= 1'b0;
            v0_period         <= 16'd0;
            v0_cnt            <= 16'd0;
            v0_step           <= 3'd0;
            v0_duty           <= 2'b10; // 50% duty
            v0_vol            <= 4'd0;
            v1_period         <= 16'd0;
            v1_cnt            <= 16'd0;
            v1_step           <= 3'd0;
            v1_duty           <= 2'b10; // 50% duty
            v1_vol            <= 4'd0;
            v2_period         <= 16'd0;
            v2_cnt            <= 16'd0;
            v2_step           <= 5'd0;
            v2_vol            <= 4'd0;
            v3_period         <= 16'd0;
            v3_cnt            <= 16'd0;
            v3_lfsr           <= 15'h7FFF;
            v3_mode           <= 1'b0;
            v3_vol            <= 4'd0;
            audio_preset      <= 4'd0;
            preset_timer      <= 20'd0;
            preset_step       <= 4'd0;
            jtag_en           <= 1'b0;
            jtag_state        <= 4'h0; // RESET
            jtag_tms_shifter  <= 8'h00;
            jtag_tms_cnt      <= 4'd0;
            jtag_tms          <= 1'b1;
            jtag_tck          <= 1'b0;
            jtag_tdi          <= 1'b1;
            jtag_tdo_sampled  <= 1'b0;
            jtag_dr_reg       <= 32'd0;
            jtag_ir_reg       <= 8'd0;
            jtag_shift_cnt    <= 6'd0;
            jtag_exit_on_last <= 1'b0;
            jtag_phase        <= 1'b0;
            swd_en            <= 1'b0;
            swd_state         <= 4'd0;
            swd_req_byte      <= 8'd0;
            swd_last_ack      <= 3'd0;
            swd_parity_err    <= 1'b0;
            swd_swdio_out     <= 1'b1;
            swd_sclk          <= 1'b0;
            swd_oe            <= 1'b1;
            swd_bit_cnt       <= 6'd0;
            swd_data_reg      <= 32'd0;
            swd_parity_bit    <= 1'b0;
            swd_reset_cnt     <= 8'd0;
            swd_switch_seq    <= 16'hE79E;
            swd_phase         <= 1'b0;
            qspi_en           <= 1'b0;
            qspi_width        <= 2'b00;
            qspi_ddr          <= 1'b0;
            qspi_cpol         <= 1'b0;
            qspi_state        <= 4'd0;
            qspi_cmd_byte     <= 8'h00;
            qspi_addr_reg     <= 32'd0;
            qspi_addr_bits    <= 6'd0;
            qspi_dummy_cnt    <= 4'd0;
            qspi_bit_cnt      <= 6'd0;
            qspi_data_reg     <= 32'd0;
            qspi_sclk         <= 1'b0;
            qspi_cs           <= 1'b1;
            qspi_oe           <= 1'b0;
            qspi_data_out     <= 8'h00;
            qspi_phase        <= 1'b0;
            qspi_rx_byte      <= 8'h00;
        end else begin
            // Default: clear single-cycle pop/push strobes
            o_tx_pop  <= 1'b0;
            o_rx_push <= 1'b0;

            // Track edge transitions on SCL & SDA
            scl_prev <= i2c_scl_in;
            sda_prev <= i2c_sda_in;

            // -------------------------------------------------------------
            // 1-Bit Delta-Sigma Modulator Engine (Task 22)
            // -------------------------------------------------------------
            if (audio_en) begin
                pdm_acc <= pdm_sum;
                pdm_bit <= pdm_sum[8];
            end else begin
                pdm_acc <= 9'd0;
                pdm_bit <= 1'b0;
            end

            // -------------------------------------------------------------
            // 4-Voice Chiptune APU Oscillators & Sequencers (Task 22)
            // -------------------------------------------------------------
            if (audio_en && (audio_mode == 2'b10 || audio_mode == 2'b11)) begin
                // Voice 0 (Pulse 1)
                if (v0_period != 16'd0) begin
                    if (v0_cnt == 16'd0) begin
                        v0_cnt  <= v0_period;
                        v0_step <= v0_step + 3'd1;
                    end else begin
                        v0_cnt  <= v0_cnt - 16'd1;
                    end
                end

                // Voice 1 (Pulse 2)
                if (v1_period != 16'd0) begin
                    if (v1_cnt == 16'd0) begin
                        v1_cnt  <= v1_period;
                        v1_step <= v1_step + 3'd1;
                    end else begin
                        v1_cnt  <= v1_cnt - 16'd1;
                    end
                end

                // Voice 2 (Triangle)
                if (v2_period != 16'd0) begin
                    if (v2_cnt == 16'd0) begin
                        v2_cnt  <= v2_period;
                        v2_step <= v2_step + 5'd1;
                    end else begin
                        v2_cnt  <= v2_cnt - 16'd1;
                    end
                end

                // Voice 3 (Noise)
                if (v3_period != 16'd0) begin
                    if (v3_cnt == 16'd0) begin
                        v3_cnt  <= v3_period;
                        v3_lfsr <= {v3_lfsr[0] ^ v3_lfsr[1], v3_lfsr[14:1]};
                        if (v3_mode) v3_lfsr[6] <= v3_lfsr[0] ^ v3_lfsr[1];
                    end else begin
                        v3_cnt  <= v3_cnt - 16'd1;
                    end
                end

                // Sound Effect Preset Sequencer
                if (audio_preset != 4'd0) begin
                    preset_timer <= preset_timer + 20'd1;
                    case (audio_preset)
                        4'd1: begin // BEEP (440 Hz)
                            v0_period <= 16'd14204;
                            v0_vol    <= 4'd12;
                            v0_duty   <= 2'b10;
                            if (preset_timer >= 20'd250000) begin
                                audio_preset <= 4'd0;
                                v0_vol       <= 4'd0;
                            end
                        end
                        4'd2: begin // BLIP (880 Hz)
                            v0_period <= 16'd7102;
                            v0_vol    <= 4'd14;
                            v0_duty   <= 2'b10;
                            if (preset_timer >= 20'd100000) begin
                                audio_preset <= 4'd0;
                                v0_vol       <= 4'd0;
                            end
                        end
                        4'd3: begin // ERROR (Low buzzing two-tone)
                            v0_duty <= 2'b01;
                            if (preset_timer < 20'd150000) begin
                                v0_period <= 16'd41666; // 150 Hz
                                v0_vol    <= 4'd14;
                            end else if (preset_timer < 20'd300000) begin
                                v0_period <= 16'd56818; // 110 Hz
                                v0_vol    <= 4'd14;
                            end else begin
                                audio_preset <= 4'd0;
                                v0_vol       <= 4'd0;
                            end
                        end
                        4'd4: begin // COIN (B5 987 Hz -> E6 1318 Hz)
                            v0_duty <= 2'b10;
                            if (preset_timer < 20'd100000) begin
                                v0_period <= 16'd6331; // B5
                                v0_vol    <= 4'd12;
                            end else if (preset_timer < 20'd300000) begin
                                v0_period <= 16'd4741; // E6
                                v0_vol    <= 4'd14;
                            end else begin
                                audio_preset <= 4'd0;
                                v0_vol       <= 4'd0;
                            end
                        end
                        4'd5: begin // LASER (Downward frequency sweep)
                            v0_duty <= 2'b00; // 12.5% narrow pulse
                            v0_vol  <= 4'd15;
                            if (preset_timer[9:0] == 10'd0) begin
                                v0_period <= v0_period + 16'd400;
                            end
                            if (preset_timer >= 20'd200000) begin
                                audio_preset <= 4'd0;
                                v0_vol       <= 4'd0;
                            end
                        end
                        4'd6: begin // SIREN (Alternating high/low alert)
                            v0_duty <= 2'b10;
                            v0_vol  <= 4'd14;
                            if (preset_timer < 20'd150000)
                                v0_period <= 16'd8000;
                            else if (preset_timer < 20'd300000)
                                v0_period <= 16'd12000;
                            else
                                preset_timer <= 20'd0; // Repeat until AUDIO_STOP
                        end
                        4'd7: begin // NOISE (Percussive crash/snare)
                            v3_period <= 16'd300;
                            v3_mode   <= 1'b0;
                            if (preset_timer[13:0] == 14'd0 && v3_vol > 4'd0) begin
                                v3_vol <= v3_vol - 4'd1;
                            end
                            if (preset_timer >= 20'd250000) begin
                                audio_preset <= 4'd0;
                                v3_vol       <= 4'd0;
                            end
                        end
                        default: begin
                            audio_preset <= 4'd0;
                        end
                    endcase
                end
            end

            // -------------------------------------------------------------
            // Autonomous Hardware I2C / SMBus Slave Tracker (Task 21)
            // -------------------------------------------------------------
            if (i2c_stop_cond) begin
                i2c_bus_active   <= 1'b0;
                i2c_stop_flag    <= 1'b1;
                i2c_drive_ack    <= 1'b0;
                i2c_stretch_hold <= 1'b0;
                i2c_slave_state  <= 4'd0; // IDLE
            end else if (i2c_start_cond) begin
                i2c_bus_active   <= 1'b1;
                i2c_start_flag   <= 1'b1;
                i2c_stop_flag    <= 1'b0;
                i2c_addr_match   <= 1'b0;
                i2c_drive_ack    <= 1'b0;
                i2c_stretch_hold <= 1'b0;
                i2c_bit_idx      <= 4'd0;
                i2c_slave_state  <= i2c_slave_en ? 4'd1 : 4'd0; // ADDR_RX or IDLE
            end else if (i2c_slave_en) begin
                case (i2c_slave_state)
                    4'd1: begin // ADDR_RX: 8 bits (7-bit address + R/W)
                        if (scl_rise) begin
                            i2c_rx_addr <= {i2c_rx_addr[6:0], i2c_sda_in};
                            i2c_bit_idx <= i2c_bit_idx + 4'd1;
                        end else if (scl_fall) begin
                            if (i2c_bit_idx == 4'd8) begin
                                if (i2c_rx_addr[7:1] == i2c_slave_addr) begin
                                    i2c_rw_bit      <= i2c_rx_addr[0];
                                    i2c_drive_ack   <= 1'b1; // Drive ACK for 9th SCL
                                    i2c_slave_state <= 4'd2; // ADDR_ACK
                                end else begin
                                    i2c_addr_match  <= 1'b0;
                                    i2c_drive_ack   <= 1'b0;
                                    i2c_slave_state <= 4'd0; // IDLE (NACK)
                                end
                            end
                        end
                    end

                    4'd2: begin // ADDR_ACK: 9th SCL pulse
                        if (scl_fall) begin
                            i2c_drive_ack   <= 1'b0; // Release SDA after 9th pulse
                            i2c_addr_match  <= 1'b1; // Confirm address match to microcode
                            if (i2c_stretch_en) begin
                                i2c_stretch_hold <= 1'b1; // Hold SCL low
                            end
                            i2c_slave_state <= 4'd3; // DATA_WAIT
                        end
                    end

                    4'd3: begin // DATA_WAIT
                        // Waiting for microcode IN SLAVE / OUT SLAVE
                    end

                    default: i2c_slave_state <= 4'd0;
                endcase
            end

            if (delay_cnt > 16'd0) begin
                delay_cnt <= delay_cnt - 16'd1;
            end else if (jtag_tms_cnt != 4'd0) begin
                // -------------------------------------------------------------
                // JTAG Hardware TMS Bit Clocking Sequencer
                // -------------------------------------------------------------
                if (jtag_phase == 1'b0) begin
                    // Phase 0: Setup TMS on cs_pin, TCK low
                    jtag_tms   <= jtag_tms_shifter[0];
                    jtag_tck   <= 1'b0;
                    jtag_phase <= 1'b1;
                    delay_cnt  <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                end else begin
                    // Phase 1: TCK high, step TAP FSM, sample TDO
                    jtag_tck         <= 1'b1;
                    jtag_state       <= fn_tap_next(jtag_state, jtag_tms_shifter[0]);
                    jtag_tdo_sampled <= gpio_in[rx_pin];
                    jtag_tms_shifter <= {1'b0, jtag_tms_shifter[7:1]};
                    jtag_tms_cnt     <= jtag_tms_cnt - 4'd1;
                    jtag_phase       <= 1'b0;
                    delay_cnt        <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                    if (jtag_tms_cnt == 4'd1) begin
                        pc <= pc + 7'd1;
                    end
                end
            end else if (jtag_shift_cnt != 4'd0) begin
                // -------------------------------------------------------------
                // JTAG Hardware Data Shift Sequencer (DR / IR) (Task 23)
                // -------------------------------------------------------------
                if (jtag_phase == 1'b0) begin
                    jtag_tdi   <= osr[0];
                    jtag_tms   <= (jtag_shift_cnt == 4'd1 && jtag_exit_on_last) ? 1'b1 : 1'b0;
                    jtag_tck   <= 1'b0;
                    jtag_phase <= 1'b1;
                    delay_cnt  <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                end else begin
                    jtag_tck         <= 1'b1;
                    jtag_state       <= fn_tap_next(jtag_state, (jtag_shift_cnt == 4'd1 && jtag_exit_on_last) ? 1'b1 : 1'b0);
                    jtag_tdo_sampled <= gpio_in[rx_pin];
                    isr              <= {gpio_in[rx_pin], isr[7:1]};
                    osr              <= {1'b0, osr[7:1]};
                    jtag_shift_cnt   <= jtag_shift_cnt - 4'd1;
                    jtag_phase       <= 1'b0;
                    delay_cnt        <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                    if (jtag_shift_cnt == 4'd1) begin
                        acc    <= {gpio_in[rx_pin], isr[7:1]};
                        o_data <= {gpio_in[rx_pin], isr[7:1]};
                        pc     <= pc + 7'd1;
                    end
                end
            end else if (swd_state != 4'd0) begin
                // -------------------------------------------------------------
                // ARM SWD Hardware Sequencer (Request / Turnaround / ACK / Reset)
                // -------------------------------------------------------------
                case (swd_state)
                    4'd1: begin // REQ: Send 8-bit request header [1, APnDP, RnW, A2, A3, Parity, 0, 1]
                        if (swd_phase == 1'b0) begin
                            swd_sclk      <= 1'b0;
                            swd_oe        <= 1'b1;
                            swd_swdio_out <= swd_req_byte[0];
                            swd_phase     <= 1'b1;
                            delay_cnt     <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                        end else begin
                            swd_sclk     <= 1'b1;
                            swd_req_byte <= {1'b0, swd_req_byte[7:1]};
                            swd_bit_cnt  <= swd_bit_cnt + 6'd1;
                            swd_phase    <= 1'b0;
                            delay_cnt    <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                            if (swd_bit_cnt == 6'd7) begin
                                swd_state   <= 4'd2; // Move to Turnaround (Trn)
                                swd_bit_cnt <= 6'd0;
                            end
                        end
                    end

                    4'd2: begin // TRN_IN: 1 turnaround cycle (Host drives low/releases to Hi-Z)
                        if (swd_phase == 1'b0) begin
                            swd_sclk  <= 1'b0;
                            swd_oe    <= 1'b0; // Float SWDIO to Hi-Z
                            swd_phase <= 1'b1;
                            delay_cnt <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                        end else begin
                            swd_sclk    <= 1'b1;
                            swd_state   <= 4'd3; // Move to ACK sampling
                            swd_bit_cnt <= 6'd0;
                            swd_phase   <= 1'b0;
                            delay_cnt   <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                        end
                    end

                    4'd3: begin // ACK: Sample 3-bit ACK from target on SWCLK rising edges
                        if (swd_phase == 1'b0) begin
                            swd_sclk  <= 1'b0;
                            swd_oe    <= 1'b0;
                            swd_phase <= 1'b1;
                            delay_cnt <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                        end else begin
                            swd_sclk     <= 1'b1;
                            swd_last_ack <= {gpio_in[tx_pin], swd_last_ack[2:1]};
                            swd_bit_cnt  <= swd_bit_cnt + 6'd1;
                            swd_phase    <= 1'b0;
                            delay_cnt    <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                            if (swd_bit_cnt == 6'd2) begin
                                // 3 ACK bits sampled
                                acc          <= {5'b00000, gpio_in[tx_pin], swd_last_ack[2:1]};
                                zero_flag    <= ({gpio_in[tx_pin], swd_last_ack[2:1]} == 3'b001); // OK
                                carry_flag   <= ({gpio_in[tx_pin], swd_last_ack[2:1]} != 3'b001); // Error
                                swd_state    <= 4'd0; // Done
                                swd_oe       <= 1'b0; // Keep SWDIO floating for target data phase
                                pc           <= pc + 7'd1;
                            end
                        end
                    end

                    4'd4: begin // SWD_RD32: 32 data bits from target LSB-first
                        if (swd_phase == 1'b0) begin
                            swd_sclk  <= 1'b0;
                            swd_oe    <= 1'b0; // Target drives
                            swd_phase <= 1'b1;
                            delay_cnt <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                        end else begin
                            swd_sclk     <= 1'b1;
                            swd_data_reg <= {gpio_in[tx_pin], swd_data_reg[31:1]};
                            swd_bit_cnt  <= swd_bit_cnt + 6'd1;
                            swd_phase    <= 1'b0;
                            delay_cnt    <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                            if (swd_bit_cnt == 6'd31) begin
                                swd_state   <= 4'd5; // Move to Parity read
                                swd_bit_cnt <= 6'd0;
                            end
                        end
                    end

                    4'd5: begin // SWD_RD_PARITY: 1 parity bit from target
                        if (swd_phase == 1'b0) begin
                            swd_sclk  <= 1'b0;
                            swd_oe    <= 1'b0;
                            swd_phase <= 1'b1;
                            delay_cnt <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                        end else begin
                            swd_sclk       <= 1'b1;
                            swd_parity_bit <= gpio_in[tx_pin];
                            swd_parity_err <= (gpio_in[tx_pin] != ^swd_data_reg);
                            swd_state      <= 4'd6; // Move to turnaround
                            swd_phase      <= 1'b0;
                            delay_cnt      <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                        end
                    end

                    4'd6: begin // SWD_RD_TRN: Host reclaims bus
                        if (swd_phase == 1'b0) begin
                            swd_sclk      <= 1'b0;
                            swd_oe        <= 1'b1;
                            swd_swdio_out <= 1'b0;
                            swd_phase     <= 1'b1;
                            delay_cnt     <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                        end else begin
                            swd_sclk  <= 1'b1;
                            swd_state <= 4'd0; // Done
                            swd_phase <= 1'b0;
                            acc       <= swd_data_reg[7:0];
                            pc        <= pc + 7'd1;
                        end
                    end

                    4'd7: begin // RESET_SYNC: 54 clocks with SWDIO=1
                        if (swd_phase == 1'b0) begin
                            swd_sclk      <= 1'b0;
                            swd_oe        <= 1'b1;
                            swd_swdio_out <= 1'b1;
                            swd_phase     <= 1'b1;
                            delay_cnt     <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                        end else begin
                            swd_sclk      <= 1'b1;
                            swd_reset_cnt <= swd_reset_cnt + 8'd1;
                            swd_phase     <= 1'b0;
                            delay_cnt     <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                            if (swd_reset_cnt == 8'd53) begin
                                if (swd_switch_seq != 16'h0000) begin
                                    swd_state      <= 4'd8; // Move to switch sequence
                                    swd_bit_cnt    <= 6'd0;
                                end else begin
                                    swd_state      <= 4'd9; // Move to post-reset line sync
                                    swd_reset_cnt  <= 8'd0;
                                end
                            end
                        end
                    end

                    4'd8: begin // RESET_SWITCH: 16-bit JTAG-to-SWD select sequence (0xE79E LSB-first)
                        if (swd_phase == 1'b0) begin
                            swd_sclk      <= 1'b0;
                            swd_oe        <= 1'b1;
                            swd_swdio_out <= swd_switch_seq[0];
                            swd_phase     <= 1'b1;
                            delay_cnt     <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                        end else begin
                            swd_sclk       <= 1'b1;
                            swd_switch_seq <= {1'b0, swd_switch_seq[15:1]};
                            swd_bit_cnt    <= swd_bit_cnt + 6'd1;
                            swd_phase      <= 1'b0;
                            delay_cnt      <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                            if (swd_bit_cnt == 6'd15) begin
                                swd_state     <= 4'd9; // Move to post-reset line sync
                                swd_reset_cnt <= 8'd0;
                            end
                        end
                    end

                    4'd9: begin // RESET_POST: 54 clocks SWDIO=1, then 4 clocks SWDIO=0
                        if (swd_phase == 1'b0) begin
                            swd_sclk      <= 1'b0;
                            swd_oe        <= 1'b1;
                            swd_swdio_out <= (swd_reset_cnt < 8'd54) ? 1'b1 : 1'b0;
                            swd_phase     <= 1'b1;
                            delay_cnt     <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                        end else begin
                            swd_sclk      <= 1'b1;
                            swd_reset_cnt <= swd_reset_cnt + 8'd1;
                            swd_phase     <= 1'b0;
                            delay_cnt     <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                            if (swd_reset_cnt >= 8'd57) begin
                                swd_state     <= 4'd0; // Done
                                swd_swdio_out <= 1'b1;
                                pc            <= pc + 7'd1;
                            end
                        end
                    end

                    4'd10: begin // SWD_WR_TRN: Host drives bus after ACK
                        if (swd_phase == 1'b0) begin
                            swd_sclk      <= 1'b0;
                            swd_oe        <= 1'b1;
                            swd_swdio_out <= 1'b0;
                            swd_phase     <= 1'b1;
                            delay_cnt     <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                        end else begin
                            swd_sclk    <= 1'b1;
                            swd_state   <= 4'd11; // Move to data write
                            swd_bit_cnt <= 6'd0;
                            swd_phase   <= 1'b0;
                            delay_cnt   <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                        end
                    end

                    4'd11: begin // SWD_WR32: Send 32 data bits LSB-first
                        if (swd_phase == 1'b0) begin
                            swd_sclk      <= 1'b0;
                            swd_oe        <= 1'b1;
                            swd_swdio_out <= swd_data_reg[0];
                            swd_phase     <= 1'b1;
                            delay_cnt     <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                        end else begin
                            swd_sclk     <= 1'b1;
                            swd_data_reg <= {1'b0, swd_data_reg[31:1]};
                            swd_bit_cnt  <= swd_bit_cnt + 6'd1;
                            swd_phase    <= 1'b0;
                            delay_cnt    <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                            if (swd_bit_cnt == 6'd31) begin
                                swd_state   <= 4'd12; // Move to parity bit
                                swd_bit_cnt <= 6'd0;
                            end
                        end
                    end

                    4'd12: begin // SWD_WR_PARITY: Send parity bit
                        if (swd_phase == 1'b0) begin
                            swd_sclk      <= 1'b0;
                            swd_oe        <= 1'b1;
                            swd_swdio_out <= swd_parity_bit;
                            swd_phase     <= 1'b1;
                            delay_cnt     <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                        end else begin
                            swd_sclk      <= 1'b1;
                            swd_state     <= 4'd0; // Done
                            swd_swdio_out <= 1'b0;
                            swd_phase     <= 1'b0;
                            pc            <= pc + 7'd1;
                        end
                    end

                    default: swd_state <= 4'd0;
                endcase
            end else if (qspi_state != 4'd0) begin
                // -------------------------------------------------------------
                // Quad-SPI (QSPI) & Multi-Lane Hardware Sequencer (Task 24)
                // -------------------------------------------------------------
                case (qspi_state)
                    4'd1: begin // CMD: Transmit 8-bit command on IO0 (tx_pin)
                        if (qspi_phase == 1'b0) begin
                            qspi_sclk        <= qspi_cpol;
                            qspi_cs          <= 1'b0; // assert CS# low
                            qspi_oe          <= 1'b1;
                            qspi_data_out[0] <= qspi_cmd_byte[7];
                            qspi_phase       <= 1'b1;
                            delay_cnt        <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                        end else begin
                            qspi_sclk     <= ~qspi_cpol;
                            qspi_cmd_byte <= {qspi_cmd_byte[6:0], 1'b0};
                            qspi_bit_cnt  <= qspi_bit_cnt + 6'd1;
                            qspi_phase    <= 1'b0;
                            delay_cnt     <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                            if (qspi_bit_cnt == 6'd7) begin
                                qspi_state   <= 4'd0; // Done CMD
                                qspi_bit_cnt <= 6'd0;
                                pc           <= pc + 7'd1;
                            end
                        end
                    end

                    4'd2: begin // ADDR: Transmit 24-bit or 32-bit address across qspi_width lanes
                        if (qspi_phase == 1'b0) begin
                            qspi_sclk  <= qspi_cpol;
                            qspi_oe    <= 1'b1;
                            case (qspi_width)
                                2'b10:   qspi_data_out[3:0] <= qspi_addr_reg[31:28]; // Quad: 4 bits/clk
                                2'b01:   qspi_data_out[1:0] <= qspi_addr_reg[31:30]; // Dual: 2 bits/clk
                                2'b11:   qspi_data_out[7:0] <= qspi_addr_reg[31:24]; // Octal: 8 bits/clk
                                default: qspi_data_out[0]   <= qspi_addr_reg[31];    // Single: 1 bit/clk
                            endcase
                            qspi_phase <= 1'b1;
                            delay_cnt  <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                        end else begin
                            qspi_sclk <= ~qspi_cpol;
                            case (qspi_width)
                                2'b10: begin // Quad
                                    qspi_addr_reg  <= {qspi_addr_reg[27:0], 4'b0000};
                                    qspi_addr_bits <= (qspi_addr_bits <= 6'd4) ? 6'd0 : qspi_addr_bits - 6'd4;
                                    if (qspi_addr_bits <= 6'd4) begin
                                        qspi_state <= 4'd0;
                                        pc         <= pc + 7'd1;
                                    end
                                end
                                2'b01: begin // Dual
                                    qspi_addr_reg  <= {qspi_addr_reg[29:0], 2'b00};
                                    qspi_addr_bits <= (qspi_addr_bits <= 6'd2) ? 6'd0 : qspi_addr_bits - 6'd2;
                                    if (qspi_addr_bits <= 6'd2) begin
                                        qspi_state <= 4'd0;
                                        pc         <= pc + 7'd1;
                                    end
                                end
                                2'b11: begin // Octal
                                    qspi_addr_reg  <= {qspi_addr_reg[23:0], 8'b0000_0000};
                                    qspi_addr_bits <= (qspi_addr_bits <= 6'd8) ? 6'd0 : qspi_addr_bits - 6'd8;
                                    if (qspi_addr_bits <= 6'd8) begin
                                        qspi_state <= 4'd0;
                                        pc         <= pc + 7'd1;
                                    end
                                end
                                default: begin // Single
                                    qspi_addr_reg  <= {qspi_addr_reg[30:0], 1'b0};
                                    qspi_addr_bits <= qspi_addr_bits - 6'd1;
                                    if (qspi_addr_bits <= 6'd1) begin
                                        qspi_state <= 4'd0;
                                        pc         <= pc + 7'd1;
                                    end
                                end
                            endcase
                            qspi_phase <= 1'b0;
                            delay_cnt  <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                        end
                    end

                    4'd3: begin // DUMMY: Clock N dummy wait cycles with pins in Hi-Z
                        if (qspi_phase == 1'b0) begin
                            qspi_sclk  <= qspi_cpol;
                            qspi_oe    <= 1'b0; // Hi-Z
                            qspi_phase <= 1'b1;
                            delay_cnt  <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                        end else begin
                            qspi_sclk      <= ~qspi_cpol;
                            qspi_dummy_cnt <= qspi_dummy_cnt - 4'd1;
                            qspi_phase     <= 1'b0;
                            delay_cnt      <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                            if (qspi_dummy_cnt == 4'd1) begin
                                qspi_state <= 4'd0; // Done dummy
                                pc         <= pc + 7'd1;
                            end
                        end
                    end

                    4'd4: begin // DATA_RX: Receive 1 byte across multi-lanes into isr/acc/o_data
                        if (qspi_phase == 1'b0) begin
                            qspi_sclk  <= qspi_cpol;
                            qspi_oe    <= 1'b0; // Target drives
                            qspi_phase <= 1'b1;
                            delay_cnt  <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                        end else begin
                            qspi_sclk  <= ~qspi_cpol;
                            qspi_phase <= 1'b0;
                            delay_cnt  <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                            case (qspi_width)
                                2'b10: begin // Quad: 2 nibbles = 1 byte
                                    if (qspi_bit_cnt == 6'd0) begin
                                        qspi_rx_byte[7:4] <= qspi_in_nibble;
                                        qspi_bit_cnt      <= 6'd1;
                                    end else begin
                                        qspi_rx_byte[3:0] <= qspi_in_nibble;
                                        isr               <= {qspi_rx_byte[7:4], qspi_in_nibble};
                                        o_data            <= {qspi_rx_byte[7:4], qspi_in_nibble};
                                        acc               <= {qspi_rx_byte[7:4], qspi_in_nibble};
                                        qspi_state        <= 4'd0;
                                        qspi_bit_cnt      <= 6'd0;
                                        pc                <= pc + 7'd1;
                                    end
                                end
                                2'b01: begin // Dual: 4 pairs = 1 byte
                                    qspi_rx_byte <= {qspi_rx_byte[5:0], qspi_in_pair};
                                    qspi_bit_cnt <= qspi_bit_cnt + 6'd1;
                                    if (qspi_bit_cnt == 6'd3) begin
                                        isr          <= {qspi_rx_byte[5:0], qspi_in_pair};
                                        o_data       <= {qspi_rx_byte[5:0], qspi_in_pair};
                                        acc          <= {qspi_rx_byte[5:0], qspi_in_pair};
                                        qspi_state   <= 4'd0;
                                        qspi_bit_cnt <= 6'd0;
                                        pc           <= pc + 7'd1;
                                    end
                                end
                                2'b11: begin // Octal: 1 byte in 1 clock
                                    isr          <= qspi_in_octal;
                                    o_data       <= qspi_in_octal;
                                    acc          <= qspi_in_octal;
                                    qspi_rx_byte <= qspi_in_octal;
                                    qspi_state   <= 4'd0;
                                    pc           <= pc + 7'd1;
                                end
                                default: begin // Single: 8 bits
                                    qspi_rx_byte <= {qspi_rx_byte[6:0], qspi_in_single};
                                    qspi_bit_cnt <= qspi_bit_cnt + 6'd1;
                                    if (qspi_bit_cnt == 6'd7) begin
                                        isr          <= {qspi_rx_byte[6:0], qspi_in_single};
                                        o_data       <= {qspi_rx_byte[6:0], qspi_in_single};
                                        acc          <= {qspi_rx_byte[6:0], qspi_in_single};
                                        qspi_state   <= 4'd0;
                                        qspi_bit_cnt <= 6'd0;
                                        pc           <= pc + 7'd1;
                                    end
                                end
                            endcase
                        end
                    end

                    4'd5: begin // DATA_TX: Transmit 1 byte from osr across multi-lanes
                        if (qspi_phase == 1'b0) begin
                            qspi_sclk <= qspi_cpol;
                            qspi_oe   <= 1'b1;
                            case (qspi_width)
                                2'b10:   qspi_data_out[3:0] <= (qspi_bit_cnt == 6'd0) ? osr[7:4] : osr[3:0];
                                2'b01:   qspi_data_out[1:0] <= osr[7:6];
                                2'b11:   qspi_data_out[7:0] <= osr;
                                default: qspi_data_out[0]   <= osr[7];
                            endcase
                            qspi_phase <= 1'b1;
                            delay_cnt  <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                        end else begin
                            qspi_sclk  <= ~qspi_cpol;
                            qspi_phase <= 1'b0;
                            delay_cnt  <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                            case (qspi_width)
                                2'b10: begin // Quad
                                    if (qspi_bit_cnt == 6'd0) begin
                                        qspi_bit_cnt <= 6'd1;
                                    end else begin
                                        qspi_state   <= 4'd0;
                                        qspi_bit_cnt <= 6'd0;
                                        pc           <= pc + 7'd1;
                                    end
                                end
                                2'b01: begin // Dual
                                    osr          <= {osr[5:0], 2'b00};
                                    qspi_bit_cnt <= qspi_bit_cnt + 6'd1;
                                    if (qspi_bit_cnt == 6'd3) begin
                                        qspi_state   <= 4'd0;
                                        qspi_bit_cnt <= 6'd0;
                                        pc           <= pc + 7'd1;
                                    end
                                end
                                2'b11: begin // Octal
                                    qspi_state <= 4'd0;
                                    pc         <= pc + 7'd1;
                                end
                                default: begin // Single
                                    osr          <= {osr[6:0], 1'b0};
                                    qspi_bit_cnt <= qspi_bit_cnt + 6'd1;
                                    if (qspi_bit_cnt == 6'd7) begin
                                        qspi_state   <= 4'd0;
                                        qspi_bit_cnt <= 6'd0;
                                        pc           <= pc + 7'd1;
                                    end
                                end
                            endcase
                        end
                    end

                    default: qspi_state <= 4'd0;
                endcase
            end else begin
                case (opcode)
                    4'h4: begin // WAIT: Wait until gpio_in[pin_sel] == pin_val, then delay
                        if (gpio_in[pin_sel] == pin_val) begin
                            delay_cnt <= eff_sw_delay;
                            pc        <= pc + 7'd1;
                        end else begin
                            delay_cnt <= 16'd0;
                            pc        <= pc;
                        end
                    end

                    4'h2: begin // IN: Multi-cycle deserialization into ISR
                        if (instr[11:7] == 5'b11110) begin
                            // -------------------------------------------------------
                            // QSPI Multi-Lane Stream Read (IN QSPI):
                            // Receives 1 byte across configured lanes into isr, o_data, acc
                            // -------------------------------------------------------
                            qspi_state   <= 4'd4; // DATA_RX
                            qspi_bit_cnt <= 6'd0;
                            qspi_phase   <= 1'b0;
                            pc           <= pc;
                        end else if (instr[11:7] == 5'b11111) begin
                            // -------------------------------------------------------
                            // Audio DAC Sample Read Mode (IN AUDIO):
                            // Captures current audio_sample into ISR and o_data in 1 cycle.
                            // -------------------------------------------------------
                            isr       <= audio_sample;
                            o_data    <= audio_sample;
                            delay_cnt <= 16'd0;
                            pc        <= pc + 7'd1;
                        end else if (instr[11:9] == 3'b111) begin
                            // -------------------------------------------------------
                            // I2C Slave Receive Mode (IN SLAVE / IN I2C_SLAVE):
                            // Deserializes 8 data bits from master MSB-first into ISR
                            // on SCL rising edges, drives ACK low on 9th SCL pulse,
                            // releases SDA on SCL fall, and latches o_data <= isr.
                            // -------------------------------------------------------
                            delay_cnt        <= 16'd0;
                            i2c_stretch_hold <= 1'b0; // release clock stretch if active
                            if (in_slave_phase == 2'd0) begin
                                if (i2c_stop_cond) begin
                                    in_slave_phase <= 2'd0;
                                    rx_bit_cnt     <= 4'd0;
                                    pc             <= pc + 7'd1;
                                end else if (scl_rise) begin
                                    isr <= {isr[6:0], i2c_sda_in};
                                    if (rx_bit_cnt == 4'd7) begin
                                        in_slave_phase <= 2'd1;
                                    end else begin
                                        rx_bit_cnt <= rx_bit_cnt + 4'd1;
                                    end
                                end
                            end else if (in_slave_phase == 2'd1) begin
                                if (i2c_stop_cond) begin
                                    in_slave_phase <= 2'd0;
                                    rx_bit_cnt     <= 4'd0;
                                    pc             <= pc + 7'd1;
                                end else if (scl_fall) begin
                                    i2c_drive_ack  <= 1'b1; // Drive ACK low for 9th SCL pulse
                                    in_slave_phase <= 2'd2;
                                end
                            end else if (in_slave_phase == 2'd2) begin
                                if (scl_fall || i2c_stop_cond) begin
                                    i2c_drive_ack  <= 1'b0; // Release SDA
                                    if (i2c_stretch_en && !i2c_stop_cond)
                                        i2c_stretch_hold <= 1'b1; // Clock stretch
                                    o_data         <= isr;
                                    rx_bit_cnt     <= 4'd0;
                                    in_slave_phase <= 2'd0;
                                    pc             <= pc + 7'd1;
                                end
                            end
                        end else if (pulse_mode == 2'b10) begin
                            // -------------------------------------------------------
                            // NES / SNES Gamepad Host Read Mode (Task 18)
                            // Phase 0: Assert LATCH high on cs_pin for t_latch cycles
                            // Phase 1: Lower LATCH low on cs_pin, inter-pulse setup
                            // Phase 2: Drive CLOCK high on sck_pin
                            // Phase 3: Drive CLOCK low on sck_pin, sample rx_pin into ISR
                            // -------------------------------------------------------
                            if (pulse_phase == 2'd0) begin
                                gpio_out_reg[cs_pin]  <= 1'b1; // LATCH high
                                gpio_oe_reg[cs_pin]   <= 1'b1;
                                gpio_out_reg[sck_pin] <= 1'b0; // CLOCK idle low
                                gpio_oe_reg[sck_pin]  <= 1'b1;
                                delay_cnt             <= {8'd0, t_latch};
                                pulse_phase           <= 2'd1;
                                pc                    <= pc;
                            end else if (pulse_phase == 2'd1) begin
                                gpio_out_reg[cs_pin] <= 1'b0; // LATCH low
                                delay_cnt            <= eff_delay;
                                pulse_phase          <= 2'd2;
                                pc                   <= pc;
                            end else if (pulse_phase == 2'd2) begin
                                gpio_out_reg[sck_pin] <= 1'b1; // CLOCK high
                                delay_cnt             <= eff_delay;
                                pulse_phase           <= 2'd3;
                                pc                    <= pc;
                            end else begin
                                // Phase 3: Falling clock edge, sample DATA
                                gpio_out_reg[sck_pin] <= 1'b0; // CLOCK low
                                delay_cnt             <= eff_delay;
                                isr                   <= {isr[6:0], gpio_in[rx_pin]};
                                pad_shift_reg         <= {pad_shift_reg[14:0], gpio_in[rx_pin]};
                                if (rx_bit_cnt == 4'd1) begin
                                    rx_bit_cnt  <= 4'd0;
                                    pulse_phase <= 2'd0;
                                    pc          <= pc + 7'd1;
                                end else if (rx_bit_cnt == 4'd0) begin
                                    rx_bit_cnt  <= pad_snes_16b ? 4'd15 : in_count_init;
                                    pulse_phase <= 2'd2; // next clock
                                    pc          <= pc;
                                end else begin
                                    rx_bit_cnt  <= rx_bit_cnt - 4'd1;
                                    pulse_phase <= 2'd2; // next clock
                                    pc          <= pc;
                                end
                            end
                        end else if (instr[11:10] == 2'b01) begin
                            // -------------------------------------------------------
                            // Synchronous SPI Master Read (IN SCK):
                            // Generates 8 clock pulses on sck_pin (auto-toggles) and
                            // samples rx_pin (MISO) MSB-first into ISR.
                            // -------------------------------------------------------
                            delay_cnt <= eff_delay;
                            if (in_sck_phase == 2'd0) begin
                                // Rising clock phase: drive SCK high
                                if (gpio_od[sck_pin]) begin
                                    gpio_out_reg[sck_pin] <= 1'b1;
                                    gpio_oe_reg[sck_pin]  <= 1'b0; // release high
                                end else begin
                                    gpio_out_reg[sck_pin] <= 1'b1;
                                    gpio_oe_reg[sck_pin]  <= 1'b1; // drive high
                                end
                                in_sck_phase <= 2'd1;
                                pc           <= pc;
                            end else begin
                                // Falling clock phase: sample rx_pin into ISR, drive SCK low
                                isr <= {isr[6:0], gpio_in[rx_pin]};
                                if (gpio_od[sck_pin]) begin
                                    gpio_out_reg[sck_pin] <= 1'b0;
                                    gpio_oe_reg[sck_pin]  <= 1'b1; // drive low
                                end else begin
                                    gpio_out_reg[sck_pin] <= 1'b0;
                                    gpio_oe_reg[sck_pin]  <= 1'b1; // drive low
                                end
                                in_sck_phase <= 2'd0;
                                if (rx_bit_cnt == 4'd0) begin
                                    rx_bit_cnt <= 4'd7;
                                    pc         <= pc;
                                end else if (rx_bit_cnt == 4'd1) begin
                                    rx_bit_cnt <= 4'd0;
                                    pc         <= pc + 7'd1;
                                end else begin
                                    rx_bit_cnt <= rx_bit_cnt - 4'd1;
                                    pc         <= pc;
                                end
                            end
                        end else if (instr[11:10] == 2'b11) begin
                            // -------------------------------------------------------
                            // Synchronous I2C Master Read (IN SDA):
                            // Releases tx_pin (SDA) to Hi-Z open drain, generates 8
                            // clock pulses on sck_pin (SCL), and samples rx_pin (SDA)
                            // MSB-first into ISR while SCL is high.
                            // -------------------------------------------------------
                            delay_cnt <= eff_delay;
                            // Ensure SDA is released in open-drain mode
                            gpio_out_reg[tx_pin] <= 1'b1;
                            gpio_oe_reg[tx_pin]  <= 1'b0;

                            if (in_sck_phase == 2'd0) begin
                                // High clock phase: release SCL high and sample SDA
                                if (gpio_od[sck_pin]) begin
                                    gpio_out_reg[sck_pin] <= 1'b1;
                                    gpio_oe_reg[sck_pin]  <= 1'b0; // release high
                                end else begin
                                    gpio_out_reg[sck_pin] <= 1'b1;
                                    gpio_oe_reg[sck_pin]  <= 1'b1; // drive high
                                end
                                isr          <= {isr[6:0], gpio_in[rx_pin]};
                                in_sck_phase <= 2'd1;
                                pc           <= pc;
                            end else begin
                                // Low clock phase: drive SCL low
                                if (gpio_od[sck_pin]) begin
                                    gpio_out_reg[sck_pin] <= 1'b0;
                                    gpio_oe_reg[sck_pin]  <= 1'b1; // drive low
                                end else begin
                                    gpio_out_reg[sck_pin] <= 1'b0;
                                    gpio_oe_reg[sck_pin]  <= 1'b1; // drive low
                                end
                                in_sck_phase <= 2'd0;
                                if (rx_bit_cnt == 4'd0) begin
                                    rx_bit_cnt <= 4'd7;
                                    pc         <= pc;
                                end else if (rx_bit_cnt == 4'd1) begin
                                    rx_bit_cnt <= 4'd0;
                                    pc         <= pc + 7'd1;
                                end else begin
                                    rx_bit_cnt <= rx_bit_cnt - 4'd1;
                                    pc         <= pc;
                                end
                            end
                        end else if (instr[11:10] == 2'b10) begin
                            // -------------------------------------------------------
                            // 1-Wire Master Read (IN 1W):
                            //   instr[9] = 0: 8-bit byte read, 1: 1-bit single-slot read
                            // Phase 0: Master pulls tx_pin low for 1x eff_delay (~6us)
                            // Phase 1: Master releases tx_pin high for 1x eff_delay (~6us)
                            // Phase 2: Master samples rx_pin at ~12us window, then waits
                            //          9x eff_delay recovery time to complete 60us slot.
                            // Deserializes LSB-first into ISR.
                            // -------------------------------------------------------
                            if (in_sck_phase == 2'd0) begin
                                // Phase 0: Master pull-down pulse
                                gpio_out_reg[tx_pin] <= 1'b0;
                                gpio_oe_reg[tx_pin]  <= 1'b1; // drive low
                                delay_cnt            <= eff_delay;
                                in_sck_phase         <= 2'd1;
                                pc                   <= pc;
                            end else if (in_sck_phase == 2'd1) begin
                                // Phase 1: Release line, wait 1x delay for slave pull-down/line rise
                                gpio_out_reg[tx_pin] <= 1'b1;
                                gpio_oe_reg[tx_pin]  <= 1'b0; // release Hi-Z
                                delay_cnt            <= eff_delay;
                                in_sck_phase         <= 2'd2;
                                pc                   <= pc;
                            end else begin
                                // Phase 2: Sample rx_pin into ISR, wait 9x delay recovery
                                gpio_out_reg[tx_pin] <= 1'b1;
                                gpio_oe_reg[tx_pin]  <= 1'b0; // stay released
                                isr                  <= instr[9] ? {7'd0, gpio_in[rx_pin]} : {gpio_in[rx_pin], isr[7:1]};
                                delay_cnt            <= eff_delay_9x;
                                in_sck_phase         <= 2'd0;
                                if (instr[9] || rx_bit_cnt == 4'd1) begin
                                    rx_bit_cnt <= 4'd0;
                                    pc         <= pc + 7'd1;
                                end else if (rx_bit_cnt == 4'd0) begin
                                    rx_bit_cnt <= 4'd7;
                                    pc         <= pc;
                                end else begin
                                    rx_bit_cnt <= rx_bit_cnt - 4'd1;
                                    pc         <= pc;
                                end
                            end
                        end else begin
                            // -------------------------------------------------------
                            // Normal IN mode (instr[11:10]=00): LSB-first Deserializer
                            // Features Autonomous Stream Accelerators:
                            //   - Hardware NRZI Decoding (transition=0, no-transition=1)
                            //   - Hardware Bit-Destuffing (strips USB 6-ones '0', CAN 5-bits)
                            // -------------------------------------------------------
                            if (assist_nrzi_en) begin
                                nrzi_rx_prev <= gpio_in[rx_pin];
                            end

                            if (assist_manch_en) begin
                                // ---------------------------------------------------
                                // Autonomous Manchester / BMC Deserializer (Task 19)
                                // Phase 0: Sample first half-bit (eff_hdelay)
                                // Phase 1: Sample second half-bit & decode bit
                                // ---------------------------------------------------
                                if (manch_rx_phase == 1'b0) begin
                                    manch_rx_sample1 <= gpio_in[rx_pin];
                                    delay_cnt        <= eff_hdelay;
                                    manch_rx_phase   <= 1'b1;
                                    pc               <= pc;
                                end else begin
                                    // Phase 1: Second half sample & decode
                                    delay_cnt      <= eff_hdelay;
                                    manch_rx_phase <= 1'b0;

                                    // Manchester code violation check:
                                    // In IEEE or Thomas, level MUST transition at center (sample1 != sample2)
                                    if (assist_manch_mode != 2'b10 && (manch_rx_sample1 == gpio_in[rx_pin])) begin
                                        manch_error <= 1'b1;
                                    end

                                    // Bit recovery
                                    if (assist_manch_mode == 2'b10) begin
                                        // BMC: mid-bit transition indicates bit 1, steady indicates bit 0
                                        isr <= {(manch_rx_sample1 != gpio_in[rx_pin]), isr[7:1]};
                                    end else if (assist_manch_mode == 2'b01) begin
                                        // Thomas: 1=Low/High, 0=High/Low
                                        isr <= {~manch_rx_sample1, isr[7:1]};
                                    end else begin
                                        // IEEE 802.3: 0=Low/High, 1=High/Low
                                        isr <= {manch_rx_sample1, isr[7:1]};
                                    end

                                    if (rx_bit_cnt == 4'd0) begin
                                        rx_bit_cnt <= in_count_init;
                                        pc         <= (in_count_init == 4'd0) ? pc + 7'd1 : pc;
                                    end else if (rx_bit_cnt == 4'd1) begin
                                        rx_bit_cnt <= 4'd0;
                                        pc         <= pc + 7'd1;
                                    end else begin
                                        rx_bit_cnt <= rx_bit_cnt - 4'd1;
                                        pc         <= pc;
                                    end
                                end
                            end else if (assist_stuff_mode == 2'b01 && rx_stuff_cnt == 3'd6) begin
                                // USB Bit-Destuffing: next bit must be '0' (stuff bit) and is discarded
                                if (dec_rx_bit == 1'b0) begin
                                    rx_stuff_cnt <= 3'd0;
                                end else begin
                                    stuff_error  <= 1'b1; // Illegal 7th consecutive '1'
                                    rx_stuff_cnt <= 3'd0;
                                end
                                delay_cnt <= eff_delay;
                                pc        <= pc; // Do not shift ISR, do not decrement rx_bit_cnt
                            end else if (assist_stuff_mode == 2'b10 && rx_stuff_cnt == 3'd5) begin
                                // CAN Bit-Destuffing: next bit must be inverted bit and is discarded
                                if (dec_rx_bit == ~rx_last_bit) begin
                                    rx_last_bit  <= dec_rx_bit;
                                    rx_stuff_cnt <= 3'd1;
                                end else begin
                                    stuff_error  <= 1'b1; // Illegal 6th identical bit
                                    rx_stuff_cnt <= 3'd0;
                                end
                                delay_cnt <= eff_delay;
                                pc        <= pc;
                            end else begin
                                // Valid payload data bit: shift into ISR
                                isr <= {dec_rx_bit, isr[7:1]};

                                if (assist_stuff_mode == 2'b01) begin
                                    rx_stuff_cnt <= dec_rx_bit ? (rx_stuff_cnt + 3'd1) : 3'd0;
                                end else if (assist_stuff_mode == 2'b10) begin
                                    if (rx_bit_cnt == 4'd0 && rx_stuff_cnt == 3'd0) begin
                                        rx_last_bit  <= dec_rx_bit;
                                        rx_stuff_cnt <= 3'd1;
                                    end else if (dec_rx_bit == rx_last_bit) begin
                                        rx_stuff_cnt <= rx_stuff_cnt + 3'd1;
                                    end else begin
                                        rx_last_bit  <= dec_rx_bit;
                                        rx_stuff_cnt <= 3'd1;
                                    end
                                end

                                delay_cnt <= eff_delay;
                                if (rx_bit_cnt == 4'd0) begin
                                    rx_bit_cnt <= in_count_init;
                                    pc         <= (in_count_init == 4'd0) ? pc + 7'd1 : pc;
                                end else if (rx_bit_cnt == 4'd1) begin
                                    rx_bit_cnt <= 4'd0;
                                    pc         <= pc + 7'd1;
                                end else begin
                                    rx_bit_cnt <= rx_bit_cnt - 4'd1;
                                    pc         <= pc;
                                end
                            end
                        end
                    end

                    4'hA: begin // PUSH [BLOCK]: Transfer ISR to OSR and latch to o_data
                        delay_cnt <= 16'd0;
                        if (instr[0] && i_rx_full) begin
                            // Blocking PUSH: stall until space is available in RX FIFO
                            pc        <= pc;
                            o_rx_push <= 1'b0;
                        end else begin
                            osr       <= isr;
                            o_data    <= isr;
                            o_rx_push <= 1'b1; // 1-cycle push strobe
                            pc        <= pc + 7'd1;
                        end
                    end

                    4'h9: begin // PULL [BLOCK]: Latch input data into OSR
                        delay_cnt <= 16'd0;
                        if (instr[0] && !i_tx_valid) begin
                            // Blocking PULL: stall until valid data is available in TX FIFO
                            pc       <= pc;
                            o_tx_pop <= 1'b0;
                        end else begin
                            osr      <= i_data;
                            o_tx_pop <= i_tx_valid; // 1-cycle pop strobe when data is consumed
                            pc       <= pc + 7'd1;
                        end
                    end

                    4'h1: begin // OUT: Multi-cycle serialization from OSR
                        if (instr[11:7] == 5'b11110) begin
                            // -------------------------------------------------------
                            // QSPI Multi-Lane Stream Write (OUT QSPI):
                            // Transmits 1 byte from osr across configured lanes
                            // -------------------------------------------------------
                            qspi_state   <= 4'd5; // DATA_TX
                            qspi_bit_cnt <= 6'd0;
                            qspi_phase   <= 1'b0;
                            pc           <= pc;
                        end else if (instr[11:7] == 5'b11111) begin
                            // -------------------------------------------------------
                            // Audio DAC Sample Load Mode (OUT AUDIO):
                            // Immediately latches OSR into audio_sample, activates
                            // direct PCM mode, and advances PC in 1 clock cycle.
                            // -------------------------------------------------------
                            audio_sample <= osr;
                            audio_en     <= 1'b1;
                            audio_mode   <= 2'b01; // Direct PCM mode
                            delay_cnt    <= 16'd0;
                            pc           <= pc + 7'd1;
                        end else if (instr[11:9] == 3'b111) begin
                            // -------------------------------------------------------
                            // I2C Slave Transmit Mode (OUT SLAVE / OUT I2C_SLAVE):
                            // Transmits 8 data bits from OSR MSB-first to master on SCL
                            // falling edges, releases SDA on 9th pulse, and samples
                            // master ACK on 9th SCL rising edge into i2c_master_ack.
                            // -------------------------------------------------------
                            delay_cnt        <= 16'd0;
                            i2c_stretch_hold <= 1'b0; // release clock stretch if active
                            if (out_slave_phase == 2'd0) begin
                                if (i2c_stop_cond) begin
                                    out_slave_phase <= 2'd0;
                                    bit_cnt         <= 4'd0;
                                    pc              <= pc + 7'd1;
                                end else if (scl_fall) begin
                                    if (bit_cnt == 4'd7) begin
                                        out_slave_phase <= 2'd1;
                                    end else begin
                                        osr     <= {osr[6:0], 1'b0};
                                        bit_cnt <= bit_cnt + 4'd1;
                                    end
                                end
                            end else if (out_slave_phase == 2'd1) begin
                                if (i2c_stop_cond) begin
                                    out_slave_phase <= 2'd0;
                                    bit_cnt         <= 4'd0;
                                    pc              <= pc + 7'd1;
                                end else if (scl_rise) begin
                                    i2c_master_ack  <= !i2c_sda_in; // 1 = ACK (low), 0 = NACK (high)
                                    out_slave_phase <= 2'd2;
                                end
                            end else if (out_slave_phase == 2'd2) begin
                                if (scl_fall || i2c_stop_cond) begin
                                    if (i2c_stretch_en && i2c_master_ack && !i2c_stop_cond)
                                        i2c_stretch_hold <= 1'b1;
                                    bit_cnt         <= 4'd0;
                                    out_slave_phase <= 2'd0;
                                    pc              <= pc + 7'd1;
                                end
                            end
                        end else if (instr[11:10] == 2'b01 || instr[11:10] == 2'b11) begin
                            // -------------------------------------------------------
                            // MSB-first Serializer with Auto-Clock Toggle:
                            //   instr[11:10] = 01: SPI Mode (OUT SCK)
                            //   instr[11:10] = 11: I2C Mode (OUT SDA)
                            // Full-duplex: drives tx_pin + auto-toggles sck_pin +
                            // samples rx_pin into ISR. Honors gpio_od open-drain mask.
                            // -------------------------------------------------------
                            delay_cnt <= eff_delay;
                            if (out_sck_phase == 1'b0) begin
                                // Rising clock phase: set data, raise clock
                                if (gpio_od[tx_pin]) begin
                                    gpio_out_reg[tx_pin] <= osr[7];
                                    gpio_oe_reg[tx_pin]  <= ~osr[7]; // 0: drive low, 1: release
                                end else begin
                                    gpio_out_reg[tx_pin] <= osr[7];
                                    gpio_oe_reg[tx_pin]  <= 1'b1;
                                end

                                if (gpio_od[sck_pin]) begin
                                    gpio_out_reg[sck_pin] <= 1'b1;
                                    gpio_oe_reg[sck_pin]  <= 1'b0;   // release high
                                end else begin
                                    gpio_out_reg[sck_pin] <= 1'b1;
                                    gpio_oe_reg[sck_pin]  <= 1'b1;   // drive high
                                end
                                out_sck_phase <= 1'b1;
                                pc            <= pc;
                            end else begin
                                // Falling clock phase: sample rx_pin, lower clock, shift OSR
                                isr <= {isr[6:0], gpio_in[rx_pin]};

                                if (gpio_od[sck_pin]) begin
                                    gpio_out_reg[sck_pin] <= 1'b0;
                                    gpio_oe_reg[sck_pin]  <= 1'b1;   // drive low
                                end else begin
                                    gpio_out_reg[sck_pin] <= 1'b0;
                                    gpio_oe_reg[sck_pin]  <= 1'b1;   // drive low
                                end

                                osr           <= {osr[6:0], 1'b0};
                                out_sck_phase <= 1'b0;
                                if (bit_cnt == 4'd0) begin
                                    bit_cnt <= 4'd7;
                                    pc      <= pc;
                                end else if (bit_cnt == 4'd1) begin
                                    bit_cnt <= 4'd0;
                                    pc      <= pc + 7'd1;
                                end else begin
                                    bit_cnt <= bit_cnt - 4'd1;
                                    pc      <= pc;
                                end
                            end
                        end else if (instr[11:10] == 2'b10) begin
                            // -------------------------------------------------------
                            // 1-Wire Serializer (OUT 1W):
                            //   instr[9] = 0: 8-bit byte transfer, 1: 1-bit slot (Search ROM)
                            // Phase 0: Pull tx_pin low (short for '1', long for '0')
                            // Phase 1: Release tx_pin high (long for '1', short for '0')
                            // Both Write 1 and Write 0 total 11x delay per bit slot.
                            // -------------------------------------------------------
                            if (out_sck_phase == 1'b0) begin
                                // Phase 0: Drive low
                                gpio_out_reg[tx_pin] <= 1'b0;
                                gpio_oe_reg[tx_pin]  <= 1'b1; // drive low
                                delay_cnt            <= osr[0] ? eff_delay : eff_delay_10x;
                                out_sck_phase        <= 1'b1;
                                pc                   <= pc;
                            end else begin
                                // Phase 1: Release high & shift OSR LSB-first
                                gpio_out_reg[tx_pin] <= 1'b1;
                                gpio_oe_reg[tx_pin]  <= 1'b0; // release Hi-Z
                                delay_cnt            <= osr[0] ? eff_delay_10x : eff_delay;
                                osr                  <= {1'b0, osr[7:1]};
                                out_sck_phase        <= 1'b0;
                                if (instr[9] || bit_cnt == 4'd1) begin
                                    bit_cnt <= 4'd0;
                                    pc      <= pc + 7'd1;
                                end else if (bit_cnt == 4'd0) begin
                                    bit_cnt <= 4'd7;
                                    pc      <= pc;
                                end else begin
                                    bit_cnt <= bit_cnt - 4'd1;
                                    pc      <= pc;
                                end
                            end
                        end else begin
                            // -------------------------------------------------------
                            // Normal OUT mode (instr[11:10]=00): Serializer
                            // Features Autonomous Stream Accelerators:
                            //   - Asymmetric Single-Wire Pulse Accelerator (WS2812B / Joybus)
                            //   - Hardware Bit-Stuffing (USB 6 ones, CAN 5 identical)
                            //   - Hardware NRZI Encoding (Toggle on 0, Hold on 1)
                            // -------------------------------------------------------
                            if (pulse_mode == 2'b01) begin
                                // ---------------------------------------------------
                                // Asymmetric Single-Wire Pulse Serializer (Task 18)
                                // Phase 0: Drive Active level for t_act
                                // Phase 1: Drive Rest level for t_rest & shift OSR
                                // ---------------------------------------------------
                                if (pulse_phase == 2'd0) begin
                                    // Phase 0: Active duration
                                    gpio_out_reg[tx_pin] <= pulse_polarity ? 1'b0 : 1'b1;
                                    gpio_oe_reg[tx_pin]  <= 1'b1;
                                    delay_cnt            <= cur_pulse_bit ? {8'd0, t_act_1} : {8'd0, t_act_0};
                                    pulse_phase          <= 2'd1;
                                    pc                   <= pc;
                                end else begin
                                    // Phase 1: Rest duration
                                    gpio_out_reg[tx_pin] <= pulse_polarity ? 1'b1 : 1'b0;
                                    gpio_oe_reg[tx_pin]  <= (pulse_polarity && gpio_od[tx_pin]) ? 1'b0 : 1'b1;
                                    delay_cnt            <= cur_pulse_bit ? {8'd0, t_rest_1} : {8'd0, t_rest_0};
                                    pulse_phase          <= 2'd0;
                                    if (pulse_msb_first)
                                        osr <= {osr[6:0], 1'b0};
                                    else
                                        osr <= {1'b0, osr[7:1]};

                                    if (bit_cnt == 4'd0) begin
                                        bit_cnt <= 4'd7;
                                        pc      <= pc;
                                    end else if (bit_cnt == 4'd1) begin
                                        bit_cnt <= 4'd0;
                                        pc      <= pc + 7'd1;
                                    end else begin
                                        bit_cnt <= bit_cnt - 4'd1;
                                        pc      <= pc;
                                    end
                                end
                            end else if (assist_manch_en) begin
                                // ---------------------------------------------------
                                // Autonomous Manchester / BMC Serializer (Task 19)
                                // Phase 0: First half-bit duration (eff_hdelay)
                                // Phase 1: Second half-bit duration (eff_hdelay)
                                // ---------------------------------------------------
                                if (manch_tx_phase == 1'b0) begin
                                    // Phase 0: First half-bit
                                    if (assist_manch_mode == 2'b10) begin
                                        // BMC mode: toggle boundary state
                                        gpio_out_reg[tx_pin] <= ~manch_tx_state;
                                        manch_tx_state       <= ~manch_tx_state;
                                    end else if (assist_manch_mode == 2'b01) begin
                                        // Thomas convention: 0=High/Low, 1=Low/High
                                        gpio_out_reg[tx_pin] <= ~osr[0];
                                    end else begin
                                        // IEEE 802.3 10BASE-T: 0=Low/High, 1=High/Low
                                        gpio_out_reg[tx_pin] <= osr[0];
                                    end
                                    gpio_oe_reg[tx_pin] <= 1'b1;
                                    delay_cnt           <= eff_hdelay;
                                    manch_tx_phase      <= 1'b1;
                                    pc                  <= pc;
                                end else begin
                                    // Phase 1: Second half-bit
                                    if (assist_manch_mode == 2'b10) begin
                                        // BMC mode: toggle at mid-bit if data bit is '1'
                                        if (osr[0]) begin
                                            gpio_out_reg[tx_pin] <= ~manch_tx_state;
                                            manch_tx_state       <= ~manch_tx_state;
                                        end else begin
                                            gpio_out_reg[tx_pin] <= manch_tx_state;
                                        end
                                    end else if (assist_manch_mode == 2'b01) begin
                                        gpio_out_reg[tx_pin] <= osr[0];
                                    end else begin
                                        gpio_out_reg[tx_pin] <= ~osr[0];
                                    end
                                    gpio_oe_reg[tx_pin] <= 1'b1;
                                    delay_cnt           <= eff_hdelay;
                                    manch_tx_phase      <= 1'b0;
                                    osr                 <= {1'b0, osr[7:1]};

                                    if (bit_cnt == 4'd0) begin
                                        bit_cnt <= 4'd7;
                                        pc      <= pc;
                                    end else if (bit_cnt == 4'd1) begin
                                        bit_cnt <= 4'd0;
                                        pc      <= pc + 7'd1;
                                    end else begin
                                        bit_cnt <= bit_cnt - 4'd1;
                                        pc      <= pc;
                                    end
                                end
                            end else if (assist_stuff_mode == 2'b01 && tx_stuff_cnt == 3'd6) begin
                                // USB Bit-Stuffing: Insert '0' after 6 consecutive 1s
                                if (assist_nrzi_en) begin
                                    nrzi_tx_state        <= ~nrzi_tx_state;
                                    gpio_out_reg[tx_pin] <= ~nrzi_tx_state;
                                end else begin
                                    gpio_out_reg[tx_pin] <= 1'b0;
                                end
                                gpio_oe_reg[tx_pin]  <= 1'b1;
                                delay_cnt            <= eff_delay;
                                tx_stuff_cnt         <= 3'd0;
                                // Hold OSR, bit_cnt, and PC
                                osr                  <= osr;
                                bit_cnt              <= bit_cnt;
                                pc                   <= pc;
                            end else if (assist_stuff_mode == 2'b10 && tx_stuff_cnt == 3'd5) begin
                                // CAN Bit-Stuffing: Insert inverted bit after 5 identical bits
                                if (assist_nrzi_en) begin
                                    if (~tx_last_bit == 1'b0) begin
                                        nrzi_tx_state        <= ~nrzi_tx_state;
                                        gpio_out_reg[tx_pin] <= ~nrzi_tx_state;
                                    end else begin
                                        gpio_out_reg[tx_pin] <= nrzi_tx_state;
                                    end
                                end else begin
                                    gpio_out_reg[tx_pin] <= ~tx_last_bit;
                                end
                                gpio_oe_reg[tx_pin]  <= 1'b1;
                                delay_cnt            <= eff_delay;
                                tx_last_bit          <= ~tx_last_bit;
                                tx_stuff_cnt         <= 3'd1;
                                osr                  <= osr;
                                bit_cnt              <= bit_cnt;
                                pc                   <= pc;
                            end else begin
                                // Normal payload bit transmission from osr[0]
                                if (assist_nrzi_en) begin
                                    if (osr[0] == 1'b0) begin
                                        nrzi_tx_state        <= ~nrzi_tx_state;
                                        gpio_out_reg[tx_pin] <= ~nrzi_tx_state;
                                    end else begin
                                        gpio_out_reg[tx_pin] <= nrzi_tx_state;
                                    end
                                end else begin
                                    gpio_out_reg[tx_pin] <= osr[0];
                                end
                                gpio_oe_reg[tx_pin]  <= 1'b1;

                                // Update consecutive run counter
                                if (assist_stuff_mode == 2'b01) begin
                                    tx_stuff_cnt <= osr[0] ? (tx_stuff_cnt + 3'd1) : 3'd0;
                                end else if (assist_stuff_mode == 2'b10) begin
                                    if (bit_cnt == 4'd0 && tx_stuff_cnt == 3'd0) begin
                                        tx_last_bit  <= osr[0];
                                        tx_stuff_cnt <= 3'd1;
                                    end else if (osr[0] == tx_last_bit) begin
                                        tx_stuff_cnt <= tx_stuff_cnt + 3'd1;
                                    end else begin
                                        tx_last_bit  <= osr[0];
                                        tx_stuff_cnt <= 3'd1;
                                    end
                                end

                                osr       <= {1'b0, osr[7:1]};
                                delay_cnt <= eff_delay;
                                if (bit_cnt == 4'd0) begin
                                    bit_cnt <= 4'd7;
                                    pc      <= pc;
                                end else if (bit_cnt == 4'd1) begin
                                    bit_cnt <= 4'd0;
                                    pc      <= pc + 7'd1;
                                end else begin
                                    bit_cnt <= bit_cnt - 4'd1;
                                    pc      <= pc;
                                end
                            end
                        end
                    end

                    4'h3: begin // SET: Drive selected GPIO pin to pin_val
                        if (gpio_od[pin_sel]) begin
                            // Open-drain mode:
                            // pin_val=0 -> drive LOW (out=0, oe=1)
                            // pin_val=1 -> release Hi-Z (out=1, oe=0, external pull-up)
                            if (pin_val == 1'b0) begin
                                gpio_out_reg[pin_sel] <= 1'b0;
                                gpio_oe_reg[pin_sel]  <= 1'b1;
                            end else begin
                                gpio_out_reg[pin_sel] <= 1'b1;
                                gpio_oe_reg[pin_sel]  <= 1'b0;
                            end
                        end else begin
                            // Push-pull mode: drive output actively
                            gpio_out_reg[pin_sel] <= pin_val;
                            gpio_oe_reg[pin_sel]  <= 1'b1;
                        end
                        delay_cnt <= eff_sw_delay;
                        pc        <= pc + 7'd1;
                    end

                    4'h5: begin // PINMAP: Configure protocol roles to physical GPIO pins
                        tx_pin  <= instr[11:9];
                        rx_pin  <= instr[8:6];
                        sck_pin <= instr[5:3];
                        cs_pin  <= instr[2:0];
                        // Automatically set initial direction: TX, SCK, CS outputs; RX input
                        gpio_oe_reg[instr[11:9]] <= 1'b1;
                        gpio_oe_reg[instr[5:3]]  <= 1'b1;
                        gpio_oe_reg[instr[2:0]]  <= 1'b1;
                        gpio_oe_reg[instr[8:6]]  <= 1'b0;
                        delay_cnt                <= 16'd0;
                        pc                       <= pc + 7'd1;
                    end

                    4'h6: begin // CFG_OD: Configure open-drain mask for GPIO[7:0]
                        gpio_od   <= instr[7:0];
                        delay_cnt <= 16'd0;
                        pc        <= pc + 7'd1;
                    end

                    4'h0: begin // NOP: Pure delay
                        delay_cnt <= eff_delay;
                        pc        <= pc + 7'd1;
                    end

                    4'h7: begin // Hardware Loop Counters (DJNZ / SET_LC / PULL_LC / PUSH_LC / MOV_LC)
                        if (instr[10] == 1'b0) begin
                            // -------------------------------------------------
                            // DJNZ LCx, target: Decrement and Jump if Not Zero
                            //   instr[11]: 0=LC0, 1=LC1
                            //   instr[4:0]: target jump address
                            // Decrements selected LC. If LC != 1, jumps to target.
                            // When LC == 1, decrements to 0 and falls through (pc+1).
                            // If LC was 0 on entry, it wraps to 255 (256 iterations).
                            // -------------------------------------------------
                            if (instr[11] == 1'b0) begin
                                if (lc0 != 8'd1) begin
                                    lc0 <= lc0 - 8'd1;
                                    pc  <= target;
                                end else begin
                                    lc0 <= 8'd0;
                                    pc  <= pc + 7'd1;
                                end
                            end else begin
                                if (lc1 != 8'd1) begin
                                    lc1 <= lc1 - 8'd1;
                                    pc  <= target;
                                end else begin
                                    lc1 <= 8'd0;
                                    pc  <= pc + 7'd1;
                                end
                            end
                            delay_cnt <= 16'd0;
                        end else begin
                            // -------------------------------------------------
                            // Loop Counter Load/Store Operations:
                            //   instr[11]: 0=LC0, 1=LC1
                            //   instr[9:8]:
                            //     2'b00: SET_LC LCx, imm8  (load immediate count)
                            //     2'b01: PULL_LC LCx       (load count from i_data)
                            //     2'b10: PUSH_LC LCx       (latch LCx to o_data & osr)
                            //     2'b11: MOV_LC LCx, OSR   (load count from osr)
                            // -------------------------------------------------
                            case (instr[9:8])
                                2'b00: begin // SET_LC imm8
                                    if (instr[11] == 1'b0) lc0 <= instr[7:0];
                                    else                   lc1 <= instr[7:0];
                                end
                                2'b01: begin // PULL_LC (from i_data)
                                    if (instr[11] == 1'b0) lc0 <= i_data;
                                    else                   lc1 <= i_data;
                                end
                                2'b10: begin // PUSH_LC (to o_data & osr)
                                    if (instr[11] == 1'b0) begin
                                        o_data <= lc0;
                                        osr    <= lc0;
                                    end else begin
                                        o_data <= lc1;
                                        osr    <= lc1;
                                    end
                                end
                                2'b11: begin // MOV_LC (from osr)
                                    if (instr[11] == 1'b0) lc0 <= osr;
                                    else                   lc1 <= osr;
                                end
                            endcase
                            delay_cnt <= 16'd0;
                            pc        <= pc + 7'd1;
                        end
                    end

                    4'h8: begin // JMP [cond], target: Conditional or Unconditional Jump
                        delay_cnt <= 16'd0;
                        if (instr[7]) begin
                            // Extended I2C Slave Conditions (Task 21) & JTAG / SWD (Task 23)
                            case (instr[11:8])
                                4'h0: pc <= i2c_addr_match ? target : pc + 7'd1;                    // JMP I2C_MATCH
                                4'h1: pc <= i2c_start_flag ? target : pc + 7'd1;                    // JMP I2C_START
                                4'h2: pc <= i2c_stop_flag ? target : pc + 7'd1;                     // JMP I2C_STOP
                                4'h3: pc <= (i2c_addr_match & i2c_rw_bit) ? target : pc + 7'd1;     // JMP I2C_READ
                                4'h4: pc <= (i2c_addr_match & !i2c_rw_bit) ? target : pc + 7'd1;    // JMP I2C_WRITE
                                4'h5: pc <= !i2c_master_ack ? target : pc + 7'd1;                   // JMP I2C_ACK
                                4'h6: pc <= i2c_master_ack ? target : pc + 7'd1;                    // JMP I2C_NACK
                                4'h7: pc <= i2c_bus_active ? target : pc + 7'd1;                    // JMP I2C_BUS_ACTIVE
                                4'h8: pc <= (swd_last_ack == 3'b001) ? target : pc + 7'd1;          // JMP SWD_OK
                                4'h9: pc <= (swd_last_ack == 3'b010) ? target : pc + 7'd1;          // JMP SWD_WAIT
                                4'hA: pc <= (swd_last_ack == 3'b100) ? target : pc + 7'd1;          // JMP SWD_FAULT
                                4'hB: pc <= (jtag_state == 4'h1) ? target : pc + 7'd1;              // JMP JTAG_IDLE
                                default: pc <= target;
                            endcase
                        end else begin
                            case (instr[11:8])
                                4'h0: pc <= target;                              // Unconditional JMP target
                                4'h1: pc <= i_tx_valid ? target : pc + 7'd1;     // JMP TX_VALID, target
                                4'h2: pc <= !i_tx_valid ? target : pc + 7'd1;    // JMP TX_EMPTY, target
                                4'h3: pc <= i_rx_full ? target : pc + 7'd1;      // JMP RX_FULL,  target
                                4'h4: pc <= !i_rx_full ? target : pc + 7'd1;     // JMP RX_READY, target
                                4'h5: pc <= gpio_in[rx_pin] ? target : pc + 7'd1;// JMP PIN_HI,   target
                                4'h6: pc <= !gpio_in[rx_pin] ? target : pc + 7'd1;// JMP PIN_LO,  target
                                4'h7: pc <= (crc_reg == 32'h00000000) ? target : pc + 7'd1;// JMP CRC_OK, target
                                4'h8: pc <= zero_flag ? target : pc + 7'd1;      // JMP ZERO / EQ
                                4'h9: pc <= !zero_flag ? target : pc + 7'd1;     // JMP NOT_ZERO / NE
                                4'hA: pc <= carry_flag ? target : pc + 7'd1;     // JMP CARRY / ULT
                                4'hB: pc <= !carry_flag ? target : pc + 7'd1;    // JMP NOT_CARRY / UGE
                                4'hC: pc <= acc[7] ? target : pc + 7'd1;         // JMP NEG / SIGN
                                4'hD: pc <= !acc[7] ? target : pc + 7'd1;        // JMP POS
                                4'hE: pc <= (crc_reg != 32'h00000000) ? target : pc + 7'd1;// JMP CRC_ERR
                                4'hF: pc <= (stuff_error | manch_error) ? target : pc + 7'd1; // JMP STUFF_ERR / MANCH_ERR
                                default: pc <= target;
                            endcase
                        end
                    end

                    4'hE: begin // CRC: Hardware CRC Generator & Checksum Accelerator
                        delay_cnt <= 16'd0;
                        case (instr[11:9])
                            3'b000: begin // CRC_INIT poly, seed
                                if (instr[3]) begin
                                    // Extended polynomials (poly >= 4)
                                    crc_poly <= {1'b1, instr[2:1]};
                                    case (instr[5:4])
                                        2'b01: begin
                                            crc_seed <= 32'h00000000;
                                            crc_reg  <= 32'h00000000;
                                        end
                                        2'b10,
                                        2'b11: begin
                                            crc_seed <= 32'hFFFFFFFF;
                                            crc_reg  <= 32'hFFFFFFFF;
                                        end
                                        default: begin // 2'b00: default seed for extended poly
                                            case (instr[2:1])
                                                2'b00: begin // Poly 4: Ethernet CRC-32 default 0xFFFFFFFF
                                                    crc_seed <= 32'hFFFFFFFF;
                                                    crc_reg  <= 32'hFFFFFFFF;
                                                end
                                                2'b01: begin // Poly 5: USB CRC-5 default 0x0000001F
                                                    crc_seed <= 32'h0000001F;
                                                    crc_reg  <= 32'h0000001F;
                                                end
                                                default: begin
                                                    crc_seed <= 32'h00000000;
                                                    crc_reg  <= 32'h00000000;
                                                end
                                            endcase
                                        end
                                    endcase
                                end else begin
                                    // Standard legacy polynomials (poly 0..3: Dallas, SMBus, CCITT, Modbus)
                                    crc_poly <= {1'b0, instr[8:7]};
                                    case (instr[6:5])
                                        2'b01: begin
                                            crc_seed <= 32'h00000000;
                                            crc_reg  <= 32'h00000000;
                                        end
                                        2'b10,
                                        2'b11: begin
                                            crc_seed <= 32'h0000FFFF;
                                            crc_reg  <= 32'h0000FFFF;
                                        end
                                        default: begin // 2'b00: default seed for legacy poly
                                            case (instr[8:7])
                                                2'b11: begin // Modbus default 0xFFFF
                                                    crc_seed <= 32'h0000FFFF;
                                                    crc_reg  <= 32'h0000FFFF;
                                                end
                                                default: begin // Dallas, SMBus, CCITT default 0x0000
                                                    crc_seed <= 32'h00000000;
                                                    crc_reg  <= 32'h00000000;
                                                end
                                            endcase
                                        end
                                    endcase
                                end
                                pc <= pc + 7'd1;
                            end
                            3'b001,
                            3'b010,
                            3'b011: begin // CRC_BYTE (OSR=001, ISR=010, DATA=011)
                                crc_reg <= next_crc;
                                pc      <= pc + 7'd1;
                            end
                            3'b100: begin // CRC_READ_LOW / CRC_READ_B0: copy crc_reg[7:0] to OSR & o_data
                                osr    <= crc_reg[7:0];
                                o_data <= crc_reg[7:0];
                                pc     <= pc + 7'd1;
                            end
                            3'b101: begin // CRC_READ_HIGH / CRC_READ_B1: copy crc_reg[15:8] to OSR & o_data
                                osr    <= crc_reg[15:8];
                                o_data <= crc_reg[15:8];
                                pc     <= pc + 7'd1;
                            end
                            3'b110: begin // CRC_RESET: reload active seed
                                crc_reg <= crc_seed;
                                pc      <= pc + 7'd1;
                            end
                            3'b111: begin // CRC_READ_EXT: Byte 2 or Byte 3
                                if (instr[0] == 1'b0) begin
                                    // CRC_READ_B2: copy crc_reg[23:16] to OSR & o_data
                                    osr    <= crc_reg[23:16];
                                    o_data <= crc_reg[23:16];
                                end else begin
                                    // CRC_READ_B3: copy crc_reg[31:24] to OSR & o_data
                                    osr    <= crc_reg[31:24];
                                    o_data <= crc_reg[31:24];
                                end
                                pc <= pc + 7'd1;
                            end
                        endcase
                    end

                    4'hB: begin // ALU: 8-bit Micro-ALU & Arithmetic Engine
                        delay_cnt <= 16'd0;
                        pc        <= pc + 7'd1;
                        if (instr[11] == 1'b0) begin
                            // -------------------------------------------------
                            // Immediate ALU Operations (instr[11] == 0)
                            // -------------------------------------------------
                            case (instr[10:8])
                                3'b000: begin // ADD acc, imm8
                                    acc        <= alu_imm_add[7:0];
                                    carry_flag <= alu_imm_add[8];
                                    zero_flag  <= (alu_imm_add[7:0] == 8'h00);
                                end
                                3'b001: begin // SUB acc, imm8
                                    acc        <= alu_imm_sub[7:0];
                                    carry_flag <= alu_imm_sub[8]; // borrow
                                    zero_flag  <= (alu_imm_sub[7:0] == 8'h00);
                                end
                                3'b010: begin // CMP acc, imm8 (acc unchanged)
                                    carry_flag <= alu_imm_sub[8]; // borrow: 1 if acc < imm8
                                    zero_flag  <= (alu_imm_sub[7:0] == 8'h00);
                                end
                                3'b011: begin // AND acc, imm8
                                    acc        <= acc & instr[7:0];
                                    zero_flag  <= ((acc & instr[7:0]) == 8'h00);
                                    carry_flag <= 1'b0;
                                end
                                3'b100: begin // OR acc, imm8
                                    acc        <= acc | instr[7:0];
                                    zero_flag  <= ((acc | instr[7:0]) == 8'h00);
                                    carry_flag <= 1'b0;
                                end
                                3'b101: begin // XOR acc, imm8
                                    acc        <= acc ^ instr[7:0];
                                    zero_flag  <= ((acc ^ instr[7:0]) == 8'h00);
                                    carry_flag <= 1'b0;
                                end
                                3'b110: begin // MOV acc, imm8
                                    acc        <= instr[7:0];
                                    zero_flag  <= (instr[7:0] == 8'h00);
                                    carry_flag <= 1'b0;
                                end
                                3'b111: begin // NOT acc / Bank switching operations
                                    case (instr[7:6])
                                        2'b00: begin // NOT acc (bitwise inversion)
                                            acc        <= ~acc;
                                            zero_flag  <= ((~acc) == 8'h00);
                                            carry_flag <= 1'b0;
                                        end
                                        2'b01: begin // BANK imm2 / SET_BANK imm2 (switch active execution bank)
                                            active_bank <= instr[1:0];
                                            zero_flag   <= (instr[1:0] == 2'b00);
                                            carry_flag  <= 1'b0;
                                        end
                                        2'b10: begin // JMP_BANK imm2 (switch bank and jump to bank start offset 0)
                                            active_bank <= instr[1:0];
                                            pc          <= {instr[1:0], 5'd0};
                                            zero_flag   <= (instr[1:0] == 2'b00);
                                            carry_flag  <= 1'b0;
                                        end
                                        default: begin
                                            acc        <= ~acc;
                                            zero_flag  <= ((~acc) == 8'h00);
                                            carry_flag <= 1'b0;
                                        end
                                    endcase
                                end
                            endcase
                        end else begin
                            // -------------------------------------------------
                            // Register Transfer & Register-ALU Operations (instr[11] == 1)
                            // -------------------------------------------------
                            case (instr[10:8])
                                3'b000: begin // MOV acc, reg[src]
                                    acc        <= alu_reg_val;
                                    zero_flag  <= (alu_reg_val == 8'h00);
                                    carry_flag <= 1'b0;
                                end
                                3'b001: begin // MOV reg[dst], acc
                                    case (instr[5:3])
                                        3'b000: osr         <= acc;
                                        3'b001: isr         <= acc;
                                        3'b010: lc0         <= acc;
                                        3'b011: lc1         <= acc;
                                        3'b100: o_data      <= acc;
                                        3'b101: active_bank <= acc[1:0]; // MOV BANK, acc
                                        3'b110: crc_seed[7:0]  <= acc;
                                        3'b111: crc_seed[15:8] <= acc;
                                    endcase
                                end
                                3'b010: begin // ADD acc, reg[src]
                                    acc        <= alu_reg_add[7:0];
                                    carry_flag <= alu_reg_add[8];
                                    zero_flag  <= (alu_reg_add[7:0] == 8'h00);
                                end
                                3'b011: begin // SUB acc, reg[src]
                                    acc        <= alu_reg_sub[7:0];
                                    carry_flag <= alu_reg_sub[8]; // borrow
                                    zero_flag  <= (alu_reg_sub[7:0] == 8'h00);
                                end
                                3'b100: begin // CMP acc, reg[src] (acc unchanged)
                                    carry_flag <= alu_reg_sub[8];
                                    zero_flag  <= (alu_reg_sub[7:0] == 8'h00);
                                end
                                3'b101: begin // Bitwise logic with reg[src]
                                    case (instr[5:3])
                                        3'b000: begin // AND acc, reg
                                            acc        <= acc & alu_reg_val;
                                            zero_flag  <= ((acc & alu_reg_val) == 8'h00);
                                            carry_flag <= 1'b0;
                                        end
                                        3'b001: begin // OR acc, reg
                                            acc        <= acc | alu_reg_val;
                                            zero_flag  <= ((acc | alu_reg_val) == 8'h00);
                                            carry_flag <= 1'b0;
                                        end
                                        default: begin // XOR acc, reg
                                            acc        <= acc ^ alu_reg_val;
                                            zero_flag  <= ((acc ^ alu_reg_val) == 8'h00);
                                            carry_flag <= 1'b0;
                                        end
                                    endcase
                                end
                                3'b110: begin // Unary operations on acc
                                    case (instr[5:3])
                                        3'b000: begin // INC acc
                                            acc        <= acc + 8'd1;
                                            carry_flag <= (acc == 8'hFF);
                                            zero_flag  <= (acc + 8'd1 == 8'h00);
                                        end
                                        3'b001: begin // DEC acc
                                            acc        <= acc - 8'd1;
                                            carry_flag <= (acc == 8'h00); // borrow
                                            zero_flag  <= (acc - 8'd1 == 8'h00);
                                        end
                                        default: begin // CLR acc
                                            acc        <= 8'h00;
                                            zero_flag  <= 1'b1;
                                            carry_flag <= 1'b0;
                                        end
                                    endcase
                                end
                                3'b111: begin // Shifts and Rotates on acc
                                    case (instr[5:3])
                                        3'b000: begin // SHL acc (Shift Left, bit 7 to carry)
                                            carry_flag <= acc[7];
                                            acc        <= {acc[6:0], 1'b0};
                                            zero_flag  <= ({acc[6:0], 1'b0} == 8'h00);
                                        end
                                        3'b001: begin // SHR acc (Shift Right, bit 0 to carry)
                                            carry_flag <= acc[0];
                                            acc        <= {1'b0, acc[7:1]};
                                            zero_flag  <= ({1'b0, acc[7:1]} == 8'h00);
                                        end
                                        3'b010: begin // ROL acc (Rotate Left)
                                            acc        <= {acc[6:0], acc[7]};
                                            carry_flag <= acc[7];
                                            zero_flag  <= ({acc[6:0], acc[7]} == 8'h00);
                                        end
                                        default: begin // ROR acc (Rotate Right)
                                            acc        <= {acc[0], acc[7:1]};
                                            carry_flag <= acc[0];
                                            zero_flag  <= ({acc[0], acc[7:1]} == 8'h00);
                                        end
                                    endcase
                                end
                            endcase
                        end
                    end

                    4'hC: begin // CALL: Push return address, jump to target
                        call_stack[sp] <= pc + 7'd1;
                        sp             <= (sp == 2'd3) ? 2'd3 : sp + 2'd1;
                        delay_cnt      <= 16'd0;
                        pc             <= target;
                    end

                    4'hD: begin // RET: Pop return address from call stack
                        sp        <= (sp == 2'd0) ? 2'd0 : sp - 2'd1;
                        pc        <= (sp == 2'd0) ? 7'd0 : call_stack[sp - 2'd1];
                        delay_cnt <= 16'd0;
                    end

                    4'hF: begin // ASSIST: Autonomous Stream Accelerators (NRZI & Bit-Stuffing)
                        delay_cnt <= 16'd0;
                        case (instr[11:10])
                            2'b00: begin // ASSIST CFG, nrzi_en, stuff_mode, [init_val], [manch_cfg], [audio_subop]
                                if (instr[8:7] == 2'b11) begin
                                    // -------------------------------------------------
                                    // Audio Engine Sub-operations (Task 22)
                                    // -------------------------------------------------
                                    case (instr[6:4])
                                        3'b000: begin // AUDIO_CFG: instr[1:0]=mode, instr[9]&instr[3:2]=pin, instr[3]=diff
                                            audio_mode <= instr[1:0];
                                            audio_en   <= (instr[1:0] != 2'b00);
                                            audio_pin  <= {instr[9], instr[3:2]};
                                            audio_diff <= (instr[1:0] == 2'b11);
                                        end
                                        3'b001: begin // AUDIO_VOL: instr[3:0]=vol
                                            v0_vol <= instr[3:0];
                                            v1_vol <= instr[3:0];
                                            v2_vol <= instr[3:0];
                                            v3_vol <= instr[3:0];
                                        end
                                        3'b010: begin // AUDIO_SAMPLE: load 8-bit sample from acc
                                            audio_sample <= acc;
                                        end
                                        3'b011: begin // AUDIO_DUTY: instr[3:2]=v0_duty, instr[1:0]=v1_duty
                                            v0_duty <= instr[3:2];
                                            v1_duty <= instr[1:0];
                                        end
                                        3'b100: begin // AUDIO_NOTE_LO: load low 8 bits from acc into voice instr[1:0]
                                            case (instr[1:0])
                                                2'b00: v0_period[7:0] <= acc;
                                                2'b01: v1_period[7:0] <= acc;
                                                2'b10: v2_period[7:0] <= acc;
                                                2'b11: v3_period[7:0] <= acc;
                                            endcase
                                        end
                                        3'b101: begin // AUDIO_NOTE_HI: load high 8 bits from acc into voice instr[1:0]
                                            case (instr[1:0])
                                                2'b00: v0_period[15:8] <= acc;
                                                2'b01: v1_period[15:8] <= acc;
                                                2'b10: v2_period[15:8] <= acc;
                                                2'b11: v3_period[15:8] <= acc;
                                            endcase
                                        end
                                        3'b110: begin // AUDIO_PLAY <preset>: instr[3:0]=preset
                                            audio_en     <= 1'b1;
                                            audio_mode   <= 2'b10; // Chiptune APU mode
                                            audio_preset <= instr[3:0];
                                            preset_step  <= 4'd0;
                                            preset_timer <= 20'd0;
                                        end
                                        3'b111: begin // AUDIO_STOP
                                            audio_preset <= 4'd0;
                                            v0_vol       <= 4'd0;
                                            v1_vol       <= 4'd0;
                                            v2_vol       <= 4'd0;
                                            v3_vol       <= 4'd0;
                                            audio_en     <= 1'b0;
                                            audio_mode   <= 2'b00;
                                        end
                                    endcase
                                end else begin
                                    assist_nrzi_en    <= instr[9];
                                    assist_stuff_mode <= instr[8:7];
                                    if (instr[6]) begin // re-init line state if bit 6 set
                                        nrzi_tx_state <= instr[5];
                                        nrzi_rx_prev  <= instr[5];
                                    end
                                    if (instr[4]) begin // Manchester CFG: instr[3]=en, instr[2:1]=mode, instr[0]=state
                                        assist_manch_en   <= instr[3];
                                        assist_manch_mode <= instr[2:1];
                                        manch_tx_state    <= instr[0];
                                    end
                                end
                                pc <= pc + 7'd1;
                            end
                            2'b01: begin
                                case (instr[9:8])
                                    2'b00: begin // ASSIST RESET (clear counters, error flags, reset states)
                                        tx_stuff_cnt    <= 3'd0;
                                        rx_stuff_cnt    <= 3'd0;
                                        stuff_error     <= 1'b0;
                                        nrzi_tx_state   <= 1'b1;
                                        nrzi_rx_prev    <= 1'b1;
                                        tx_last_bit     <= 1'b1;
                                        rx_last_bit     <= 1'b1;
                                        manch_tx_phase  <= 1'b0;
                                        manch_rx_phase  <= 1'b0;
                                        manch_tx_state  <= 1'b0;
                                        manch_error     <= 1'b0;
                                        i2c_start_flag  <= 1'b0;
                                        i2c_stop_flag   <= 1'b0;
                                    end
                                    2'b01: begin
                                        case (instr[7:4])
                                            4'h0: begin // I2C_SLAVE_DISABLE
                                                i2c_slave_en     <= 1'b0;
                                                i2c_stretch_hold <= 1'b0;
                                                i2c_drive_ack    <= 1'b0;
                                                i2c_addr_match   <= 1'b0;
                                                pc               <= pc + 7'd1;
                                            end
                                            4'h1: begin // JTAG_CFG: instr[0]=en
                                                jtag_en <= instr[0];
                                                if (!instr[0]) begin
                                                    jtag_state     <= 4'h0;
                                                    jtag_tms_cnt   <= 4'd0;
                                                    jtag_shift_cnt <= 4'd0;
                                                    jtag_tck       <= 1'b0;
                                                    jtag_tms       <= 1'b1;
                                                end
                                                pc <= pc + 7'd1;
                                            end
                                            4'h2: begin // JTAG_TMS <count>: instr[3:0]=cnt (1..8)
                                                jtag_tms_shifter <= acc;
                                                jtag_tms_cnt     <= (instr[3:0] == 4'd0) ? 4'd8 : instr[3:0];
                                                jtag_phase       <= 1'b0;
                                                pc               <= pc;
                                            end
                                            4'h3: begin // JTAG_NAV <preset>: instr[3:0]=preset
                                                case (instr[3:0])
                                                    4'h0: begin // RESET (5 ones from any state)
                                                        jtag_tms_shifter <= 8'b0001_1111;
                                                        jtag_tms_cnt     <= 4'd5;
                                                    end
                                                    4'h1: begin // IDLE
                                                        if (jtag_state == 4'h4 || jtag_state == 4'hB) begin
                                                            // From SHIFT: TMS=1(EXIT1), 1(UPDATE), 0(IDLE)
                                                            jtag_tms_shifter <= 8'b0000_0011;
                                                            jtag_tms_cnt     <= 4'd3;
                                                        end else if (jtag_state == 4'h5 || jtag_state == 4'hC) begin
                                                            // From EXIT1: TMS=1(UPDATE), 0(IDLE)
                                                            jtag_tms_shifter <= 8'b0000_0001;
                                                            jtag_tms_cnt     <= 4'd2;
                                                        end else begin
                                                            // From RESET or UPDATE: TMS=0(IDLE)
                                                            jtag_tms_shifter <= 8'b0000_0000;
                                                            jtag_tms_cnt     <= 4'd1;
                                                        end
                                                    end
                                                    4'h2: begin // SHIFT_DR
                                                        if (jtag_state == 4'h0) begin
                                                            // From RESET: TMS=0(IDLE), 1, 0, 0
                                                            jtag_tms_shifter <= 8'b0000_0010;
                                                            jtag_tms_cnt     <= 4'd4;
                                                        end else begin
                                                            // From IDLE: TMS=1, 0, 0
                                                            jtag_tms_shifter <= 8'b0000_0001;
                                                            jtag_tms_cnt     <= 4'd3;
                                                        end
                                                    end
                                                    4'h3: begin // SHIFT_IR
                                                        if (jtag_state == 4'h0) begin
                                                            // From RESET: TMS=0(IDLE), 1, 1, 0, 0
                                                            jtag_tms_shifter <= 8'b0000_0110;
                                                            jtag_tms_cnt     <= 4'd5;
                                                        end else begin
                                                            // From IDLE: TMS=1, 1, 0, 0
                                                            jtag_tms_shifter <= 8'b0000_0011;
                                                            jtag_tms_cnt     <= 4'd4;
                                                        end
                                                    end
                                                    4'h4: begin // EXIT_TO_IDLE from EXIT1 (1, 0 -> UPDATE, IDLE)
                                                        jtag_tms_shifter <= 8'b0000_0001;
                                                        jtag_tms_cnt     <= 4'd2;
                                                    end
                                                    default: begin
                                                        jtag_tms_shifter <= 8'b0000_0000;
                                                        jtag_tms_cnt     <= 4'd1;
                                                    end
                                                endcase
                                                jtag_phase <= 1'b0;
                                                pc         <= pc;
                                            end
                                            4'h4: begin // SWD_CFG: instr[0]=en
                                                swd_en <= instr[0];
                                                if (!instr[0]) begin
                                                    swd_state <= 4'd0;
                                                    swd_oe    <= 1'b0;
                                                    swd_sclk  <= 1'b0;
                                                end
                                                pc <= pc + 7'd1;
                                            end
                                            4'h5: begin // SWD_REQ <ap_ndp>, <rnw>, <addr2>: instr[3]=ap, instr[2]=rnw, instr[1:0]=addr2
                                                // ADIv5 Request: [1, APnDP, RnW, A2, A3, Parity, 0, 1]
                                                swd_req_byte <= {1'b1, 1'b0, (instr[3] ^ instr[2] ^ instr[1] ^ instr[0]), instr[0], instr[1], instr[2], instr[3], 1'b1};
                                                swd_state    <= 4'd1; // REQ
                                                swd_bit_cnt  <= 6'd0;
                                                swd_phase    <= 1'b0;
                                                pc           <= pc;
                                            end
                                            4'h6: begin // SWD_RESET: instr[0]=switch_jtag_to_swd
                                                swd_state      <= 4'd7; // RESET_SYNC
                                                swd_reset_cnt  <= 8'd0;
                                                swd_switch_seq <= instr[0] ? 16'hE79E : 16'h0000;
                                                swd_phase      <= 1'b0;
                                                pc             <= pc;
                                            end
                                            4'h7: begin // JTAG_SHIFT: instr[2:0]=count (0=8), instr[3]=exit_on_last
                                                jtag_shift_cnt    <= (instr[2:0] == 3'd0) ? 4'd8 : {1'b0, instr[2:0]};
                                                jtag_exit_on_last <= instr[3];
                                                jtag_phase        <= 1'b0;
                                                pc                <= pc;
                                            end
                                            4'h8: begin // SWD_RD32: Read 32-bit data + parity
                                                swd_state   <= 4'd4;
                                                swd_bit_cnt <= 6'd0;
                                                swd_phase   <= 1'b0;
                                                pc          <= pc;
                                            end
                                            4'h9: begin // SWD_WR32: Write 32-bit data + parity
                                                swd_state      <= 4'd10; // Trn then write
                                                swd_bit_cnt    <= 6'd0;
                                                swd_parity_bit <= ^swd_data_reg;
                                                swd_phase      <= 1'b0;
                                                pc             <= pc;
                                            end
                                            4'hA: begin // SWD_LOAD_BYTE <byte_idx>: instr[1:0]=idx, loads acc into swd_data_reg
                                                case (instr[1:0])
                                                    2'b00: swd_data_reg[7:0]   <= acc;
                                                    2'b01: swd_data_reg[15:8]  <= acc;
                                                    2'b10: swd_data_reg[23:16] <= acc;
                                                    2'b11: swd_data_reg[31:24] <= acc;
                                                endcase
                                                pc <= pc + 7'd1;
                                            end
                                            4'hB: begin // QSPI_CFG: instr[0]=en, instr[2:1]=width, instr[3]=cpol
                                                qspi_en    <= instr[0];
                                                qspi_width <= instr[2:1];
                                                qspi_cpol  <= instr[3];
                                                if (!instr[0]) begin
                                                    qspi_state <= 4'd0;
                                                    qspi_oe    <= 1'b0;
                                                    qspi_sclk  <= instr[3];
                                                    qspi_cs    <= 1'b1;
                                                end else begin
                                                    qspi_sclk  <= instr[3];
                                                    qspi_cs    <= 1'b1;
                                                end
                                                pc <= pc + 7'd1;
                                            end
                                            4'hC: begin // QSPI_CS: instr[0]=cs_val (0=assert, 1=deassert)
                                                qspi_cs   <= instr[0];
                                                delay_cnt <= (debug_hdelay > 16'd0) ? debug_hdelay : 16'd1;
                                                pc        <= pc + 7'd1;
                                            end
                                            4'hD: begin // QSPI_CMD: Transmit 8-bit command in acc on MOSI (single-lane)
                                                qspi_cmd_byte <= acc;
                                                qspi_state    <= 4'd1;
                                                qspi_bit_cnt  <= 6'd0;
                                                qspi_phase    <= 1'b0;
                                                pc            <= pc;
                                            end
                                            4'hE: begin // QSPI_DUMMY: Clock dummy wait cycles (instr[3:0] or acc[3:0])
                                                qspi_dummy_cnt <= (instr[3:0] != 4'd0) ? instr[3:0] : acc[3:0];
                                                qspi_state     <= 4'd3;
                                                qspi_phase     <= 1'b0;
                                                pc             <= pc;
                                            end
                                            4'hF: begin // QSPI_ADDR / QSPI_LOAD_ADDR
                                                if (instr[3]) begin
                                                    // QSPI_ADDR: instr[0]=0 -> 24-bit, instr[0]=1 -> 32-bit
                                                    qspi_addr_bits <= instr[0] ? 6'd32 : 6'd24;
                                                    qspi_state     <= 4'd2;
                                                    qspi_phase     <= 1'b0;
                                                    pc             <= pc;
                                                end else begin
                                                    // QSPI_LOAD_ADDR <idx>: load acc into address byte
                                                    case (instr[1:0])
                                                        2'b00: qspi_addr_reg[31:24] <= acc;
                                                        2'b01: qspi_addr_reg[23:16] <= acc;
                                                        2'b10: qspi_addr_reg[15:8]  <= acc;
                                                        2'b11: qspi_addr_reg[7:0]   <= acc;
                                                    endcase
                                                    pc <= pc + 7'd1;
                                                end
                                            end
                                            default: pc <= pc + 7'd1;
                                        endcase
                                    end
                                    2'b10: begin // I2C_SLAVE_CFG <addr7> [, stretch=0|1]
                                        i2c_slave_en     <= 1'b1;
                                        i2c_stretch_en   <= instr[7];
                                        i2c_slave_addr   <= instr[6:0];
                                        i2c_addr_match   <= 1'b0;
                                        i2c_stretch_hold <= 1'b0;
                                        i2c_drive_ack    <= 1'b0;
                                        pc               <= pc + 7'd1;
                                    end
                                    2'b11: begin // I2C_RELEASE_SCL
                                        i2c_stretch_hold <= 1'b0;
                                        pc               <= pc + 7'd1;
                                    end
                                endcase
                            end
                            2'b10: begin // ASSIST READ (read status into acc)
                                case (instr[9:8])
                                    2'b00: begin // Standard framing / Manchester / NRZI status
                                        acc        <= {stuff_error, manch_error, assist_manch_en, assist_nrzi_en, assist_stuff_mode, tx_stuff_cnt[1:0]};
                                        zero_flag  <= ({stuff_error, manch_error} == 2'b00);
                                        carry_flag <= (stuff_error | manch_error);
                                    end
                                    2'b01: begin // I2C Slave Status Flags
                                        acc        <= {i2c_bus_active, i2c_start_flag, i2c_stop_flag, i2c_addr_match, i2c_rw_bit, i2c_master_ack, i2c_stretch_hold, i2c_slave_en};
                                        zero_flag  <= !i2c_addr_match;
                                        carry_flag <= i2c_master_ack;
                                    end
                                    2'b10: begin
                                        case (instr[7:6])
                                            2'b00: begin // Gamepad upper byte (Task 18)
                                                acc        <= pad_shift_reg[15:8];
                                                zero_flag  <= (pad_shift_reg[15:8] == 8'h00);
                                                carry_flag <= 1'b0;
                                            end
                                            2'b01: begin // JTAG Status (Task 23)
                                                acc        <= {jtag_tdo_sampled, jtag_state, jtag_tms, jtag_tck, jtag_en};
                                                zero_flag  <= (jtag_state == 4'h1); // IDLE
                                                carry_flag <= (jtag_state == 4'h0); // RESET
                                            end
                                            2'b10: begin // SWD Status & ACK (Task 23)
                                                acc        <= {swd_last_ack, swd_parity_err, swd_en, 3'b000};
                                                zero_flag  <= (swd_last_ack == 3'b001); // OK
                                                carry_flag <= swd_parity_err;
                                            end
                                            2'b11: begin // SWD 32-bit Data Bytes (Task 23)
                                                case (instr[5:4])
                                                    2'b00: begin acc <= swd_data_reg[7:0];   isr <= swd_data_reg[7:0];   o_data <= swd_data_reg[7:0];   end
                                                    2'b01: begin acc <= swd_data_reg[15:8];  isr <= swd_data_reg[15:8];  o_data <= swd_data_reg[15:8];  end
                                                    2'b10: begin acc <= swd_data_reg[23:16]; isr <= swd_data_reg[23:16]; o_data <= swd_data_reg[23:16]; end
                                                    2'b11: begin acc <= swd_data_reg[31:24]; isr <= swd_data_reg[31:24]; o_data <= swd_data_reg[31:24]; end
                                                endcase
                                            end
                                        endcase
                                    end
                                    2'b11: begin // I2C Received Address & RW bit
                                        acc        <= {i2c_rx_addr, i2c_rw_bit};
                                        zero_flag  <= (i2c_rx_addr == 7'd0);
                                        carry_flag <= i2c_rw_bit;
                                    end
                                endcase
                                pc <= pc + 7'd1;
                            end
                            2'b11: begin // ASSIST PULSE & GAMEPAD (Task 18)
                                case (instr[9:8])
                                    2'b00: begin // PULSE_CFG: instr[7:6]=mode, instr[5]=pol, instr[4]=msb_first, instr[3:2]=profile
                                        pulse_mode      <= instr[7:6];
                                        pulse_polarity  <= instr[5];
                                        pulse_msb_first <= instr[4];
                                        pulse_phase     <= 2'd0;
                                        if (instr[3:2] == 2'b01) begin
                                            // NEOPIXEL Profile (WS2812B @ 50MHz: 400ns/850ns 0, 800ns/450ns 1, MSB-first)
                                            pulse_mode      <= 2'b01;
                                            pulse_polarity  <= 1'b0; // Active High
                                            pulse_msb_first <= 1'b1; // MSB-first
                                            t_act_0         <= 8'd19; // 20 cycles
                                            t_rest_0        <= 8'd41; // 42 cycles
                                            t_act_1         <= 8'd39; // 40 cycles
                                            t_rest_1        <= 8'd21; // 22 cycles
                                            pulse_thresh    <= 8'd29; // 30 cycles
                                        end else if (instr[3:2] == 2'b10) begin
                                            // JOYBUS Profile (N64/GC @ 50MHz: 3us/1us 0, 1us/3us 1, LSB-first open-drain)
                                            pulse_mode      <= 2'b01;
                                            pulse_polarity  <= 1'b1; // Active Low Open-Drain
                                            pulse_msb_first <= 1'b0; // LSB-first
                                            t_act_0         <= 8'd149; // 150 cycles (3us)
                                            t_rest_0        <= 8'd49;  // 50 cycles (1us)
                                            t_act_1         <= 8'd49;  // 50 cycles (1us)
                                            t_rest_1        <= 8'd149; // 150 cycles (3us)
                                            pulse_thresh    <= 8'd99;  // 100 cycles (2us)
                                        end
                                        pc <= pc + 7'd1;
                                    end
                                    2'b01: begin // GAMEPAD_CFG: instr[7]=snes_16b, instr[6]=role (0=Host, 1=Device)
                                        pulse_mode   <= instr[6] ? 2'b11 : 2'b10;
                                        pad_snes_16b <= instr[7];
                                        pulse_phase  <= 2'd0;
                                        if (instr[5:0] != 6'd0) begin
                                            t_latch <= {2'b00, instr[5:0]};
                                        end
                                        pc <= pc + 7'd1;
                                    end
                                    2'b10: begin // PULSE_TIME0: t_act_0 <= instr[7:0]
                                        t_act_0 <= instr[7:0];
                                        pc <= pc + 7'd1;
                                    end
                                    2'b11: begin // PULSE_TIME1: t_act_1 <= instr[7:0]
                                        t_act_1 <= instr[7:0];
                                        pc <= pc + 7'd1;
                                    end
                                endcase
                            end
                            default: begin
                                pc <= pc + 7'd1;
                            end
                        endcase
                    end

                    default: begin
                        pc <= pc + 7'd1;
                    end
                endcase
            end
        end
    end

endmodule
