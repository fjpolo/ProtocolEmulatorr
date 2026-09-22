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
    input   wire    [4:0]   i_prog_addr,
    input   wire    [15:0]  i_prog_data,
    output  wire    [15:0]  o_prog_rdata
);

    // -------------------------------------------------------------------------
    // Execution State Registers
    // -------------------------------------------------------------------------
    reg [4:0]  pc;
    reg [15:0] delay_cnt;       // 16-bit hardware sidecar delay counter (0 to 65535 cycles)
    reg        out_sck_phase;   // OUT SCK/1W phase: 0=drive phase, 1=release phase
    reg [1:0]  in_sck_phase;    // IN phase: SPI/I2C: 0=high/active, 1=low/idle; 1W: 0=drive, 1=wait/sample, 2=recovery
    reg [7:0]  osr;             // Output Shift Register (Serializer)
    reg [3:0]  bit_cnt;         // Serialization bit counter
    reg [7:0]  isr;             // Input Shift Register (Deserializer)
    reg [3:0]  rx_bit_cnt;      // Deserialization bit counter

    // 4-deep x 5-bit hardware call stack for CALL/RET subroutines
    reg [4:0]  call_stack [0:3]; // Return address stack
    reg [1:0]  sp;               // Stack pointer (0..3, wraps-safe)

    // 2x 8-bit Hardware Loop Counters for zero-overhead loops (LC0, LC1)
    reg [7:0]  lc0;              // Loop counter 0
    reg [7:0]  lc1;              // Loop counter 1

    // Hardware CRC Generator & Checksum Accelerator State
    reg [15:0] crc_reg;          // 16-bit CRC accumulator
    reg [15:0] crc_seed;         // Initial/reload seed value
    reg [1:0]  crc_poly;         // Active polynomial: 0=Dallas CRC-8, 1=SMBus CRC-8, 2=CCITT CRC-16, 3=Modbus CRC-16

    // 8-bit Micro-ALU State & Condition Flags
    reg [7:0]  acc;              // 8-bit Accumulator register
    reg        zero_flag;        // Zero flag: set if last ALU result == 8'h00
    reg        carry_flag;       // Carry/Borrow flag: set on arithmetic overflow/borrow or bit shift

    // Pin Role Mapping & GPIO Control Registers
    reg [2:0]  tx_pin;          // Pin index for OUT serializer (default 0)
    reg [2:0]  rx_pin;          // Pin index for IN deserializer / default WAIT (default 0)
    reg [2:0]  sck_pin;         // Pin index for OUT SCK clock (default 1)
    reg [2:0]  cs_pin;          // Pin index for CS_n (default 2)
    reg [7:0]  gpio_od;         // Open-drain mask: 1=open-drain, 0=push-pull
    reg [7:0]  gpio_out_reg;    // 8-bit GPIO output levels
    reg [7:0]  gpio_oe_reg;     // 8-bit GPIO output enables (1=drive, 0=Hi-Z)

    assign o_gpio     = gpio_out_reg;
    assign o_gpio_oe  = gpio_oe_reg;
    assign o_tx       = gpio_out_reg[tx_pin];
    assign o_spi_sck  = gpio_out_reg[sck_pin];
    assign o_spi_cs_n = gpio_out_reg[cs_pin];

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
    // =========================================================================
    // Microcode RAM (32 words x 16 bits)
    // =========================================================================
    reg [15:0] imem [0:31];

    assign o_prog_rdata = imem[i_prog_addr];

    integer i;
    initial begin
        for (i = 0; i < 32; i = i + 1) begin
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
            imem[9]  <= 16'h0000;
            imem[10] <= 16'h0000;
            imem[11] <= 16'h0000;
            imem[12] <= 16'h0000;
            imem[13] <= 16'h0000;
            imem[14] <= 16'h0000;
            imem[15] <= 16'h0000;
            imem[16] <= 16'h0000;
            imem[17] <= 16'h0000;
            imem[18] <= 16'h0000;
            imem[19] <= 16'h0000;
            imem[20] <= 16'h0000;
            imem[21] <= 16'h0000;
            imem[22] <= 16'h0000;
            imem[23] <= 16'h0000;
            imem[24] <= 16'h0000;
            imem[25] <= 16'h0000;
            imem[26] <= 16'h0000;
            imem[27] <= 16'h0000;
            imem[28] <= 16'h0000;
            imem[29] <= 16'h0000;
            imem[30] <= 16'h0000;
            imem[31] <= 16'h0000;
        end else if (i_prog_en && i_prog_we) begin
            imem[i_prog_addr] <= i_prog_data;
        end
    end

    wire [15:0] instr   = imem[pc];
    wire [3:0]  opcode  = instr[15:12];

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
    wire [4:0]  target  = instr[4:0];

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

    // -------------------------------------------------------------------------
    // 2-stage input synchronizer for all 8 GPIO pins
    // Supports backward compatibility: merges i_rx with i_gpio[rx_pin] and i_gpio[0]
    // -------------------------------------------------------------------------
    wire [7:0] gpio_raw;
    genvar g;
    generate
        for (g = 0; g < 8; g = g + 1) begin : gen_gpio_raw
            assign gpio_raw[g] = (g == rx_pin || g == 3'd0) ? (i_gpio[g] & i_rx) : i_gpio[g];
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

    // -------------------------------------------------------------------------
    // Hardware CRC Generator Combinational Functions (Parallel 8-bit XOR Tree)
    // -------------------------------------------------------------------------
    function [15:0] fn_crc8_dallas;
        input [7:0]  data;
        input [15:0] current_crc;
        reg   [7:0]  c;
        reg          fb;
        integer      i;
        begin
            c = current_crc[7:0];
            for (i = 0; i < 8; i = i + 1) begin
                fb = c[0] ^ data[i];
                c  = (c >> 1) ^ (fb ? 8'h8C : 8'h00);
            end
            fn_crc8_dallas = {8'h00, c};
        end
    endfunction

    function [15:0] fn_crc8_smbus;
        input [7:0]  data;
        input [15:0] current_crc;
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
            fn_crc8_smbus = {8'h00, c};
        end
    endfunction

    function [15:0] fn_crc16_ccitt;
        input [7:0]  data;
        input [15:0] current_crc;
        reg   [15:0] c;
        integer      i;
        begin
            c = current_crc ^ {data, 8'h00};
            for (i = 0; i < 8; i = i + 1) begin
                if (c[15])
                    c = (c << 1) ^ 16'h1021;
                else
                    c = (c << 1);
            end
            fn_crc16_ccitt = c;
        end
    endfunction

    function [15:0] fn_crc16_modbus;
        input [7:0]  data;
        input [15:0] current_crc;
        reg   [15:0] c;
        integer      i;
        begin
            c = current_crc ^ {8'h00, data};
            for (i = 0; i < 8; i = i + 1) begin
                if (c[0])
                    c = (c >> 1) ^ 16'hA001;
                else
                    c = (c >> 1);
            end
            fn_crc16_modbus = c;
        end
    endfunction

    wire [7:0] crc_in_byte = (instr[10:9] == 2'b01) ? osr :
                             (instr[10:9] == 2'b10) ? isr : i_data;

    wire [15:0] next_crc_dallas = fn_crc8_dallas(crc_in_byte, crc_reg);
    wire [15:0] next_crc_smbus  = fn_crc8_smbus(crc_in_byte, crc_reg);
    wire [15:0] next_crc_ccitt  = fn_crc16_ccitt(crc_in_byte, crc_reg);
    wire [15:0] next_crc_modbus = fn_crc16_modbus(crc_in_byte, crc_reg);

    wire [15:0] next_crc = (crc_poly == 2'b00) ? next_crc_dallas :
                           (crc_poly == 2'b01) ? next_crc_smbus  :
                           (crc_poly == 2'b10) ? next_crc_ccitt  :
                                                 next_crc_modbus;

    // -------------------------------------------------------------------------
    // 8-bit Micro-ALU Combinatorial Logic
    // -------------------------------------------------------------------------
    wire [7:0] alu_reg_val = (instr[2:0] == 3'b000) ? osr :
                             (instr[2:0] == 3'b001) ? isr :
                             (instr[2:0] == 3'b010) ? lc0 :
                             (instr[2:0] == 3'b011) ? lc1 :
                             (instr[2:0] == 3'b100) ? i_data :
                             (instr[2:0] == 3'b101) ? acc :
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
            pc            <= 5'd0;
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
            call_stack[0] <= 5'd0;
            call_stack[1] <= 5'd0;
            call_stack[2] <= 5'd0;
            call_stack[3] <= 5'd0;
            lc0           <= 8'd0;
            lc1           <= 8'd0;
            crc_reg       <= 16'd0;
            crc_seed      <= 16'd0;
            crc_poly      <= 2'd0;
            acc           <= 8'h00;
            zero_flag     <= 1'b0;
            carry_flag    <= 1'b0;
            o_tx_pop      <= 1'b0;
            o_rx_push     <= 1'b0;
        end else begin
            // Default: clear single-cycle pop/push strobes
            o_tx_pop  <= 1'b0;
            o_rx_push <= 1'b0;

            if (delay_cnt > 16'd0) begin
                delay_cnt <= delay_cnt - 16'd1;
            end else begin
                case (opcode)
                    4'h4: begin // WAIT: Wait until gpio_in[pin_sel] == pin_val, then delay
                        if (gpio_in[pin_sel] == pin_val) begin
                            delay_cnt <= eff_sw_delay;
                            pc        <= pc + 5'd1;
                        end else begin
                            delay_cnt <= 16'd0;
                            pc        <= pc;
                        end
                    end

                    4'h2: begin // IN: Multi-cycle deserialization into ISR
                        if (instr[11:10] == 2'b01) begin
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
                                    pc         <= pc + 5'd1;
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
                                    pc         <= pc + 5'd1;
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
                                    pc         <= pc + 5'd1;
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
                            // Normal IN mode (instr[11:10]=00): LSB-first UART deserializer
                            // -------------------------------------------------------
                            isr       <= {gpio_in[rx_pin], isr[7:1]};
                            delay_cnt <= eff_delay;
                            if (rx_bit_cnt == 4'd0) begin
                                rx_bit_cnt <= in_count_init;
                                pc         <= (in_count_init == 4'd0) ? pc + 5'd1 : pc;
                            end else if (rx_bit_cnt == 4'd1) begin
                                rx_bit_cnt <= 4'd0;
                                pc         <= pc + 5'd1;
                            end else begin
                                rx_bit_cnt <= rx_bit_cnt - 4'd1;
                                pc         <= pc;
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
                            pc        <= pc + 5'd1;
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
                            pc       <= pc + 5'd1;
                        end
                    end

                    4'h1: begin // OUT: Multi-cycle serialization from OSR
                        if (instr[11:10] == 2'b01 || instr[11:10] == 2'b11) begin
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
                                    pc      <= pc + 5'd1;
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
                                    pc      <= pc + 5'd1;
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
                            // Normal OUT mode (instr[11:10]=00): LSB-first UART serializer
                            // Drives tx_pin with OSR[0]
                            // -------------------------------------------------------
                            gpio_out_reg[tx_pin] <= osr[0];
                            gpio_oe_reg[tx_pin]  <= 1'b1;
                            osr                  <= {1'b0, osr[7:1]};
                            delay_cnt            <= eff_delay;
                            if (bit_cnt == 4'd0) begin
                                bit_cnt <= 4'd7;
                                pc      <= pc;
                            end else if (bit_cnt == 4'd1) begin
                                bit_cnt <= 4'd0;
                                pc      <= pc + 5'd1;
                            end else begin
                                bit_cnt <= bit_cnt - 4'd1;
                                pc      <= pc;
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
                        pc        <= pc + 5'd1;
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
                        pc                       <= pc + 5'd1;
                    end

                    4'h6: begin // CFG_OD: Configure open-drain mask for GPIO[7:0]
                        gpio_od   <= instr[7:0];
                        delay_cnt <= 16'd0;
                        pc        <= pc + 5'd1;
                    end

                    4'h0: begin // NOP: Pure delay
                        delay_cnt <= eff_delay;
                        pc        <= pc + 5'd1;
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
                                    pc  <= pc + 5'd1;
                                end
                            end else begin
                                if (lc1 != 8'd1) begin
                                    lc1 <= lc1 - 8'd1;
                                    pc  <= target;
                                end else begin
                                    lc1 <= 8'd0;
                                    pc  <= pc + 5'd1;
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
                            pc        <= pc + 5'd1;
                        end
                    end

                    4'h8: begin // JMP [cond], target: Conditional or Unconditional Jump
                        delay_cnt <= 16'd0;
                        case (instr[11:8])
                            4'h0: pc <= target;                              // Unconditional JMP target
                            4'h1: pc <= i_tx_valid ? target : pc + 5'd1;     // JMP TX_VALID, target
                            4'h2: pc <= !i_tx_valid ? target : pc + 5'd1;    // JMP TX_EMPTY, target
                            4'h3: pc <= i_rx_full ? target : pc + 5'd1;      // JMP RX_FULL,  target
                            4'h4: pc <= !i_rx_full ? target : pc + 5'd1;     // JMP RX_READY, target
                            4'h5: pc <= gpio_in[rx_pin] ? target : pc + 5'd1;// JMP PIN_HI,   target
                            4'h6: pc <= !gpio_in[rx_pin] ? target : pc + 5'd1;// JMP PIN_LO,  target
                            4'h7: pc <= (crc_reg == 16'h0000) ? target : pc + 5'd1;// JMP CRC_OK, target
                            4'h8: pc <= zero_flag ? target : pc + 5'd1;      // JMP ZERO / EQ
                            4'h9: pc <= !zero_flag ? target : pc + 5'd1;     // JMP NOT_ZERO / NE
                            4'hA: pc <= carry_flag ? target : pc + 5'd1;     // JMP CARRY / ULT
                            4'hB: pc <= !carry_flag ? target : pc + 5'd1;    // JMP NOT_CARRY / UGE
                            4'hC: pc <= acc[7] ? target : pc + 5'd1;         // JMP NEG / SIGN
                            4'hD: pc <= !acc[7] ? target : pc + 5'd1;        // JMP POS
                            4'hE: pc <= (crc_reg != 16'h0000) ? target : pc + 5'd1;// JMP CRC_ERR
                            default: pc <= target;
                        endcase
                    end

                    4'hE: begin // CRC: Hardware CRC Generator & Checksum Accelerator
                        delay_cnt <= 16'd0;
                        case (instr[11:9])
                            3'b000: begin // CRC_INIT poly, seed
                                crc_poly <= instr[8:7];
                                case (instr[6:5])
                                    2'b01: begin
                                        crc_seed <= 16'h0000;
                                        crc_reg  <= 16'h0000;
                                    end
                                    2'b10,
                                    2'b11: begin
                                        crc_seed <= 16'hFFFF;
                                        crc_reg  <= 16'hFFFF;
                                    end
                                    default: begin // 2'b00: default seed for poly
                                        case (instr[8:7])
                                            2'b11: begin
                                                crc_seed <= 16'hFFFF; // Modbus default 0xFFFF
                                                crc_reg  <= 16'hFFFF;
                                            end
                                            default: begin
                                                crc_seed <= 16'h0000; // Dallas, SMBus, CCITT default 0x0000
                                                crc_reg  <= 16'h0000;
                                            end
                                        endcase
                                    end
                                endcase
                                pc <= pc + 5'd1;
                            end
                            3'b001,
                            3'b010,
                            3'b011: begin // CRC_BYTE (OSR=001, ISR=010, DATA=011)
                                crc_reg <= next_crc;
                                pc      <= pc + 5'd1;
                            end
                            3'b100: begin // CRC_READ_LOW: copy crc_reg[7:0] to OSR & o_data
                                osr    <= crc_reg[7:0];
                                o_data <= crc_reg[7:0];
                                pc     <= pc + 5'd1;
                            end
                            3'b101: begin // CRC_READ_HIGH: copy crc_reg[15:8] to OSR & o_data
                                osr    <= crc_reg[15:8];
                                o_data <= crc_reg[15:8];
                                pc     <= pc + 5'd1;
                            end
                            3'b110: begin // CRC_RESET: reload active seed
                                crc_reg <= crc_seed;
                                pc      <= pc + 5'd1;
                            end
                            default: begin
                                pc <= pc + 5'd1;
                            end
                        endcase
                    end

                    4'hB: begin // ALU: 8-bit Micro-ALU & Arithmetic Engine
                        delay_cnt <= 16'd0;
                        pc        <= pc + 5'd1;
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
                                3'b111: begin // NOT acc (bitwise inversion)
                                    acc        <= ~acc;
                                    zero_flag  <= ((~acc) == 8'h00);
                                    carry_flag <= 1'b0;
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
                                        3'b000: osr    <= acc;
                                        3'b001: isr    <= acc;
                                        3'b010: lc0    <= acc;
                                        3'b011: lc1    <= acc;
                                        3'b100: o_data <= acc;
                                        3'b101: acc    <= acc;
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
                        call_stack[sp] <= pc + 5'd1;
                        sp             <= (sp == 2'd3) ? 2'd3 : sp + 2'd1;
                        delay_cnt      <= 16'd0;
                        pc             <= target;
                    end

                    4'hD: begin // RET: Pop return address from call stack
                        sp        <= (sp == 2'd0) ? 2'd0 : sp - 2'd1;
                        pc        <= (sp == 2'd0) ? 5'd0 : call_stack[sp - 2'd1];
                        delay_cnt <= 16'd0;
                    end

                    default: begin
                        pc <= pc + 5'd1;
                    end
                endcase
            end
        end
    end

endmodule
