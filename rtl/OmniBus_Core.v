// =============================================================================
// File        : OmniBus_Core.v
// Module      : OmniBus_Core (OmniBus MP Symmetric Micro-Engine Slice)
// Description : Deterministic 16-bit protocol micro-engine slice for OmniBus MP.
//               Features:
//                 - Parameterized CORE_ID (0..3) & start vector RESET_PC
//                 - 7-bit Program Counter (0..127 instructions), 4-deep CALL stack
//                 - Registers: ACC, OSR, ISR, LC0, LC1, CRC_REG, Flags (ZERO, CARRY)
//                 - 16-bit sidecar delay counter for zero-jitter execution
//                 - Full ISA support: NOP, OUT, IN, SET, WAIT, PINMAP, CFG_OD,
//                   DJNZ/LC, JMP, PULL, PUSH, ALU, CALL, RET, CRC, ASSIST
//                 - MP Extensions:
//                   * CORE_ID readback
//                   * Atomic Hardware Spinlock Acquire / Release
//                   * Rendezvous Barrier Wait & Synchronization
//                   * Shared Hardware Mailbox Read / Write
// License     : MIT License
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module OmniBus_Core #(
    parameter integer CORE_ID   = 0,
    parameter integer RESET_PC  = CORE_ID * 32,
    parameter integer IMEM_SIZE = 128
)(
    input   wire            i_clk,
    input   wire            i_reset_n,
    input   wire            i_core_en,          // 1=running, 0=halted/stalled

    // Streaming Data & FIFO Handshaking Interface
    input   wire    [7:0]   i_data,             // Input stream byte
    output  reg     [7:0]   o_data,             // Output stream byte
    input   wire            i_tx_valid,         // 1 when input byte is available
    output  reg             o_tx_pop,           // 1-cycle active-high pop strobe
    input   wire            i_rx_full,          // 1 when downstream buffer is full
    output  reg             o_rx_push,          // 1-cycle active-high push strobe

    // Runtime Baud Rate Divisor (cycles_per_bit - 1)
    input   wire    [15:0]  i_baud_div,

    // Physical GPIO Bus Interface
    input   wire    [7:0]   i_gpio,             // 8 GPIO input pins
    output  wire    [7:0]   o_gpio,             // 8 GPIO output drive levels
    output  wire    [7:0]   o_gpio_oe,          // 8 GPIO output enables

    // Backward-compatibility convenience ports
    input   wire            i_rx,
    output  wire            o_tx,
    output  wire            o_spi_sck,
    output  wire            o_spi_cs_n,

    // Runtime Microcode Programming Interface
    input   wire            i_prog_en,
    input   wire            i_prog_we,
    input   wire    [6:0]   i_prog_addr,
    input   wire    [15:0]  i_prog_data,
    output  wire    [15:0]  o_prog_rdata,

    // -------------------------------------------------------------------------
    // Multi-Core MP Synchronization & Interconnect Interfaces
    // -------------------------------------------------------------------------
    // Shared Hardware Mailboxes (0..7)
    input   wire    [7:0]   i_mb_rdata,         // Data from selected mailbox
    output  wire    [2:0]   o_mb_sel,           // Mailbox index 0..7
    output  wire            o_mb_we,            // 1-cycle active-high write strobe
    output  wire    [7:0]   o_mb_wdata,         // Mailbox write data

    // Shared Atomic Spinlocks (0..3)
    input   wire    [3:0]   i_spinlock_status,  // Current lock status bits
    input   wire            i_spinlock_ack,     // 1=Acquire granted, 0=Busy
    output  wire    [1:0]   o_spinlock_sel,     // Spinlock index 0..3
    output  wire            o_spinlock_req,     // 1-cycle active-high acquire request
    output  wire            o_spinlock_rel,     // 1-cycle active-high release request

    // Hardware Rendezvous Barrier
    input   wire            i_barrier_released, // Pulse when all active cores arrive
    output  reg             o_barrier_arrive,   // 1 when this core is waiting at barrier

    // Telemetry Outputs
    output  wire    [6:0]   o_pc,
    output  wire    [7:0]   o_acc,
    output  wire            o_zero_flag,
    output  wire            o_carry_flag,
    output  wire            o_halted
);

    // -------------------------------------------------------------------------
    // Execution State Registers
    // -------------------------------------------------------------------------
    reg [6:0]  pc;              // 7-bit Program Counter (0 to 127)
    reg [15:0] delay_cnt;       // 16-bit hardware sidecar delay counter
    reg        out_sck_phase;   // OUT SCK phase: 0=drive, 1=release
    reg [1:0]  in_sck_phase;    // IN phase: 0=active, 1=sample/idle
    reg [7:0]  osr;             // Output Shift Register (Serializer)
    reg [3:0]  bit_cnt;         // Serialization bit counter
    reg [7:0]  isr;             // Input Shift Register (Deserializer)
    reg [3:0]  rx_bit_cnt;      // Deserialization bit counter

    // 4-deep hardware call stack
    reg [6:0]  call_stack [0:3];
    reg [1:0]  sp;

    // Active execution bank (0..3)
    reg [1:0]  active_bank;

    // 2x 8-bit Hardware Loop Counters (LC0, LC1)
    reg [7:0]  lc0;
    reg [7:0]  lc1;

    // Hardware CRC Generator State (5b, 8b, 16b, 32b)
    reg [31:0] crc_reg;
    reg [31:0] crc_seed;
    reg [2:0]  crc_poly;

    // 8-bit Micro-ALU State & Flags
    reg [7:0]  acc;
    reg        zero_flag;
    reg        carry_flag;

    // Autonomous Stream Accelerators State: NRZI & Bit-Stuffing
    reg        assist_nrzi_en;
    reg [1:0]  assist_stuff_mode;
    reg        nrzi_tx_state;
    reg        nrzi_rx_prev;
    reg [2:0]  tx_stuff_cnt;
    reg [2:0]  rx_stuff_cnt;
    reg        tx_last_bit;
    reg        rx_last_bit;
    reg        stuff_error;

    // Pin Mapping & GPIO Output Registers
    reg [2:0]  tx_pin;
    reg [2:0]  rx_pin;
    reg [2:0]  sck_pin;
    reg [2:0]  cs_pin;
    reg [7:0]  gpio_od;
    reg [7:0]  gpio_out_reg;
    reg [7:0]  gpio_oe_reg;

    assign o_pc         = pc;
    assign o_acc        = acc;
    assign o_zero_flag  = zero_flag;
    assign o_carry_flag = carry_flag;
    assign o_halted     = !i_core_en || i_prog_en || o_barrier_arrive;

    // -------------------------------------------------------------------------
    // Microcode RAM (128 words x 16 bits = 4 banks of 32 words)
    // -------------------------------------------------------------------------
    reg [15:0] imem [0:127];

    assign o_prog_rdata = imem[i_prog_addr];

    integer init_idx;
    initial begin
        for (init_idx = 0; init_idx < 128; init_idx = init_idx + 1) begin
            imem[init_idx] = 16'h0000;
        end
        // Bank 0 Default: UART Echo Transceiver
        imem[0] = 16'h40FE; // WAIT rx=0, $HBAUD
        imem[1] = 16'h01FF; // NOP       $BAUD
        imem[2] = 16'h21FF; // IN  rx, 8 $BAUD
        imem[3] = 16'h4100; // WAIT rx=1, 0
        imem[4] = 16'hA000; // PUSH
        imem[5] = 16'h30FF; // SET tx=0, $BAUD
        imem[6] = 16'h11FF; // OUT tx, 8 $BAUD
        imem[7] = 16'h31FF; // SET tx=1, $BAUD
        imem[8] = 16'h8000; // JMP 0x0

        // Bank 1 Default: Core 1 SPI / Stream Echo
        imem[32] = 16'h9001; // PULL BLOCK
        imem[33] = 16'h15FF; // OUT SCK, 8 $BAUD
        imem[34] = 16'hA000; // PUSH
        imem[35] = 16'h8020; // JMP 32

        // Bank 2 Default: Core 2 Echo
        imem[64] = 16'h9001; // PULL BLOCK
        imem[65] = 16'hA000; // PUSH
        imem[66] = 16'h8040; // JMP 64

        // Bank 3 Default: Core 3 Echo
        imem[96] = 16'h9001; // PULL BLOCK
        imem[97] = 16'hA000; // PUSH
        imem[98] = 16'h8060; // JMP 96
    end

    // Synchronous write port for microcode RAM
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

            imem[32] <= 16'h9001;
            imem[33] <= 16'h15FF;
            imem[34] <= 16'hA000;
            imem[35] <= 16'h8020;

            imem[64] <= 16'h9001;
            imem[65] <= 16'hA000;
            imem[66] <= 16'h8040;

            imem[96] <= 16'h9001;
            imem[97] <= 16'hA000;
            imem[98] <= 16'h8060;
        end else if (i_prog_en && i_prog_we) begin
            imem[i_prog_addr] <= i_prog_data;
        end
    end

    wire [15:0] instr   = imem[pc];
    wire [3:0]  opcode  = instr[15:12];

    // -------------------------------------------------------------------------
    // GPIO Output Pin Mapping
    // -------------------------------------------------------------------------
    wire [7:0] core_gpio_out;
    wire [7:0] core_gpio_oe;

    genvar p;
    generate
        for (p = 0; p < 8; p = p + 1) begin : gen_gpio_pin
            assign core_gpio_out[p] = (gpio_od[p] && gpio_oe_reg[p]) ? 1'b0 : gpio_out_reg[p];
            assign core_gpio_oe[p]  = gpio_oe_reg[p];
        end
    endgenerate

    assign o_gpio     = core_gpio_out;
    assign o_gpio_oe  = core_gpio_oe;
    assign o_tx       = core_gpio_out[tx_pin];
    assign o_spi_sck  = core_gpio_out[sck_pin];
    assign o_spi_cs_n = core_gpio_out[cs_pin];

    // Operands for SET / WAIT:
    wire [2:0]  pin_sel  = instr[11:9];
    wire        pin_val  = instr[8];
    wire [7:0]  sw_delay = instr[7:0];

    // Combinational Multi-Core MP Interface Signals
    wire exec_cycle = i_core_en && !i_prog_en && (delay_cnt == 16'd0) && !o_barrier_arrive;
    wire is_f_op    = (opcode == 4'hF);

    assign o_spinlock_sel = instr[1:0];
    assign o_spinlock_req = exec_cycle && is_f_op && (instr[11:10] == 2'b11) && (instr[9:8] == 2'b01);
    assign o_spinlock_rel = exec_cycle && is_f_op && (instr[11:10] == 2'b11) && (instr[9:8] == 2'b10);

    assign o_mb_sel   = instr[2:0];
    assign o_mb_we    = exec_cycle && is_f_op && (instr[11:10] == 2'b10) && (instr[9:8] == 2'b01);
    assign o_mb_wdata = acc;

    // IN bit count
    wire [3:0] in_count_init = (instr[11:9] == 3'd0) ? 4'd7 : ({1'b0, instr[11:9]} - 4'd1);

    // Standard 9-bit delay
    wire [8:0]  delay   = instr[8:0];
    wire [6:0]  target  = instr[6:0];

    // Resolved delays
    wire [15:0] eff_delay = (delay == 9'h1FF) ? i_baud_div :
                            (delay == 9'h1FE) ? (i_baud_div >> 1) :
                            {7'd0, delay};

    wire [15:0] eff_sw_delay = (sw_delay == 8'hFF) ? i_baud_div :
                               (sw_delay == 8'hFE) ? (i_baud_div >> 1) :
                               {8'd0, sw_delay};

    wire [15:0] eff_delay_10x = (eff_delay << 3) + (eff_delay << 1);
    wire [15:0] eff_hdelay    = (eff_delay >> 1);

    // 2-stage input synchronizer for GPIO pins with legacy i_rx merge
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

    // Stream Accelerator RX Decoding: NRZI transition detector
    wire nrzi_rx_bit = (gpio_in[rx_pin] == nrzi_rx_prev) ? 1'b1 : 1'b0;
    wire dec_rx_bit  = assist_nrzi_en ? nrzi_rx_bit : gpio_in[rx_pin];

    // -------------------------------------------------------------------------
    // CRC Functions
    // -------------------------------------------------------------------------
    function [31:0] fn_crc8_dallas;
        input [7:0]  data;
        input [31:0] current_crc;
        reg   [7:0]  c;
        reg          fb;
        integer      k;
        begin
            c = current_crc[7:0];
            for (k = 0; k < 8; k = k + 1) begin
                fb = c[0] ^ data[k];
                c  = (c >> 1) ^ (fb ? 8'h8C : 8'h00);
            end
            fn_crc8_dallas = {24'h000000, c};
        end
    endfunction

    function [31:0] fn_crc8_smbus;
        input [7:0]  data;
        input [31:0] current_crc;
        reg   [7:0]  c;
        integer      k;
        begin
            c = current_crc[7:0] ^ data;
            for (k = 0; k < 8; k = k + 1) begin
                if (c[7]) c = (c << 1) ^ 8'h07;
                else      c = (c << 1);
            end
            fn_crc8_smbus = {24'h000000, c};
        end
    endfunction

    function [31:0] fn_crc16_ccitt;
        input [7:0]  data;
        input [31:0] current_crc;
        reg   [15:0] c;
        integer      k;
        begin
            c = current_crc[15:0] ^ {data, 8'h00};
            for (k = 0; k < 8; k = k + 1) begin
                if (c[15]) c = (c << 1) ^ 16'h1021;
                else       c = (c << 1);
            end
            fn_crc16_ccitt = {16'h0000, c};
        end
    endfunction

    function [31:0] fn_crc16_modbus;
        input [7:0]  data;
        input [31:0] current_crc;
        reg   [15:0] c;
        integer      k;
        begin
            c = current_crc[15:0] ^ {8'h00, data};
            for (k = 0; k < 8; k = k + 1) begin
                if (c[0]) c = (c >> 1) ^ 16'hA001;
                else      c = (c >> 1);
            end
            fn_crc16_modbus = {16'h0000, c};
        end
    endfunction

    wire [7:0] crc_in_byte = (instr[10:9] == 2'b01) ? osr :
                             (instr[10:9] == 2'b10) ? isr : i_data;

    wire [31:0] next_crc_dallas = fn_crc8_dallas(crc_in_byte, crc_reg);
    wire [31:0] next_crc_smbus  = fn_crc8_smbus(crc_in_byte, crc_reg);
    wire [31:0] next_crc_ccitt  = fn_crc16_ccitt(crc_in_byte, crc_reg);
    wire [31:0] next_crc_modbus = fn_crc16_modbus(crc_in_byte, crc_reg);

    wire [31:0] next_crc = (crc_poly == 3'b000) ? next_crc_dallas :
                           (crc_poly == 3'b001) ? next_crc_smbus  :
                           (crc_poly == 3'b010) ? next_crc_ccitt  :
                                                  next_crc_modbus;

    // -------------------------------------------------------------------------
    // 8-bit Micro-ALU Logic
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
    // Micro-Engine Main Execution Loop
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (!i_reset_n || i_prog_en) begin
            pc            <= RESET_PC[6:0];
            delay_cnt     <= 16'd0;
            tx_pin        <= (CORE_ID == 1) ? 3'd4 : (CORE_ID == 2) ? 3'd6 : 3'd0;
            rx_pin        <= (CORE_ID == 1) ? 3'd5 : (CORE_ID == 2) ? 3'd7 : 3'd0;
            sck_pin       <= (CORE_ID == 1) ? 3'd6 : 3'd1;
            cs_pin        <= (CORE_ID == 1) ? 3'd7 : 3'd2;
            gpio_od       <= 8'h00;
            gpio_out_reg  <= (CORE_ID == 0) ? 8'b1111_1101 : (CORE_ID == 1) ? 8'b1101_0000 : 8'b0000_0000;
            gpio_oe_reg   <= (CORE_ID == 0) ? 8'b0000_0111 : (CORE_ID == 1) ? 8'b1101_0000 : 8'b0000_0000;
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
            active_bank   <= CORE_ID[1:0];
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
            o_barrier_arrive  <= 1'b0;
        end else if (!i_core_en || i_prog_en) begin
            // Core halted / programming mode
            o_tx_pop       <= 1'b0;
            o_rx_push      <= 1'b0;
        end else if (o_barrier_arrive) begin
            // Waiting at rendezvous barrier
            o_tx_pop       <= 1'b0;
            o_rx_push      <= 1'b0;
            if (i_barrier_released) begin
                o_barrier_arrive <= 1'b0;
                pc               <= pc + 7'd1;
            end
        end else begin
            // Default: clear single-cycle strobes
            o_tx_pop       <= 1'b0;
            o_rx_push      <= 1'b0;

            if (delay_cnt > 16'd0) begin
                delay_cnt <= delay_cnt - 16'd1;
            end else begin
                case (opcode)
                    4'h4: begin // WAIT: Wait until gpio_in[pin_sel] == pin_val
                        if (gpio_in[pin_sel] == pin_val) begin
                            delay_cnt <= eff_sw_delay;
                            pc        <= pc + 7'd1;
                        end else begin
                            delay_cnt <= 16'd0;
                            pc        <= pc;
                        end
                    end

                    4'h2: begin // IN: Deserialization into ISR
                        if (instr[11:10] == 2'b01) begin
                            // SPI Master Read (IN SCK)
                            delay_cnt <= eff_delay;
                            if (in_sck_phase == 2'd0) begin
                                gpio_out_reg[sck_pin] <= 1'b1;
                                gpio_oe_reg[sck_pin]  <= ~gpio_od[sck_pin];
                                in_sck_phase          <= 2'd1;
                                pc                    <= pc;
                            end else begin
                                isr                   <= {isr[6:0], gpio_in[rx_pin]};
                                gpio_out_reg[sck_pin] <= 1'b0;
                                gpio_oe_reg[sck_pin]  <= 1'b1;
                                in_sck_phase          <= 2'd0;
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
                        end else begin
                            // Normal UART / Stream IN
                            isr       <= {dec_rx_bit, isr[7:1]};
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

                    4'hA: begin // PUSH [BLOCK]
                        delay_cnt <= 16'd0;
                        if (instr[0] && i_rx_full) begin
                            pc        <= pc;
                            o_rx_push <= 1'b0;
                        end else begin
                            osr       <= isr;
                            o_data    <= isr;
                            o_rx_push <= 1'b1;
                            pc        <= pc + 7'd1;
                        end
                    end

                    4'h9: begin // PULL [BLOCK]
                        delay_cnt <= 16'd0;
                        if (instr[0] && !i_tx_valid) begin
                            pc       <= pc;
                            o_tx_pop <= 1'b0;
                        end else begin
                            osr      <= i_data;
                            o_tx_pop <= i_tx_valid;
                            pc       <= pc + 7'd1;
                        end
                    end

                    4'h1: begin // OUT: Serialization from OSR
                        if (instr[11:10] == 2'b01) begin
                            // SPI Master Write (OUT SCK)
                            delay_cnt <= eff_delay;
                            if (out_sck_phase == 1'b0) begin
                                gpio_out_reg[tx_pin]  <= osr[7];
                                gpio_oe_reg[tx_pin]   <= 1'b1;
                                gpio_out_reg[sck_pin] <= 1'b1;
                                gpio_oe_reg[sck_pin]  <= ~gpio_od[sck_pin];
                                out_sck_phase         <= 1'b1;
                                pc                    <= pc;
                            end else begin
                                isr                   <= {isr[6:0], gpio_in[rx_pin]};
                                gpio_out_reg[sck_pin] <= 1'b0;
                                gpio_oe_reg[sck_pin]  <= 1'b1;
                                osr                   <= {osr[6:0], 1'b0};
                                out_sck_phase         <= 1'b0;
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
                        end else begin
                            // Normal UART / Stream OUT
                            if (assist_nrzi_en) begin
                                if (osr[0] == 1'b0) nrzi_tx_state <= ~nrzi_tx_state;
                                gpio_out_reg[tx_pin] <= osr[0] ? nrzi_tx_state : ~nrzi_tx_state;
                            end else begin
                                gpio_out_reg[tx_pin] <= osr[0];
                            end
                            gpio_oe_reg[tx_pin] <= 1'b1;
                            osr                 <= {1'b0, osr[7:1]};
                            delay_cnt           <= eff_delay;
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

                    4'h3: begin // SET: Drive GPIO pin
                        if (gpio_od[pin_sel]) begin
                            if (pin_val == 1'b0) begin
                                gpio_out_reg[pin_sel] <= 1'b0;
                                gpio_oe_reg[pin_sel]  <= 1'b1;
                            end else begin
                                gpio_out_reg[pin_sel] <= 1'b1;
                                gpio_oe_reg[pin_sel]  <= 1'b0;
                            end
                        end else begin
                            gpio_out_reg[pin_sel] <= pin_val;
                            gpio_oe_reg[pin_sel]  <= 1'b1;
                        end
                        delay_cnt <= eff_sw_delay;
                        pc        <= pc + 7'd1;
                    end

                    4'h5: begin // PINMAP
                        tx_pin  <= instr[11:9];
                        rx_pin  <= instr[8:6];
                        sck_pin <= instr[5:3];
                        cs_pin  <= instr[2:0];
                        gpio_oe_reg[instr[11:9]] <= 1'b1;
                        gpio_oe_reg[instr[5:3]]  <= 1'b1;
                        gpio_oe_reg[instr[2:0]]  <= 1'b1;
                        gpio_oe_reg[instr[8:6]]  <= 1'b0;
                        delay_cnt                <= 16'd0;
                        pc                       <= pc + 7'd1;
                    end

                    4'h6: begin // CFG_OD
                        gpio_od   <= instr[7:0];
                        delay_cnt <= 16'd0;
                        pc        <= pc + 7'd1;
                    end

                    4'h0: begin // NOP
                        delay_cnt <= eff_delay;
                        pc        <= pc + 7'd1;
                    end

                    4'h7: begin // DJNZ / Loop Counters
                        if (instr[10] == 1'b0) begin
                            // DJNZ LCx, target
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
                            // SET_LC / PULL_LC / PUSH_LC / MOV_LC
                            case (instr[9:8])
                                2'b00: begin
                                    if (instr[11] == 1'b0) lc0 <= instr[7:0];
                                    else                   lc1 <= instr[7:0];
                                end
                                2'b01: begin
                                    if (instr[11] == 1'b0) lc0 <= i_data;
                                    else                   lc1 <= i_data;
                                end
                                2'b10: begin
                                    if (instr[11] == 1'b0) begin o_data <= lc0; osr <= lc0; end
                                    else                   begin o_data <= lc1; osr <= lc1; end
                                end
                                2'b11: begin
                                    if (instr[11] == 1'b0) lc0 <= osr;
                                    else                   lc1 <= osr;
                                end
                            endcase
                            delay_cnt <= 16'd0;
                            pc        <= pc + 7'd1;
                        end
                    end

                    4'h8: begin // JMP [cond], target
                        delay_cnt <= 16'd0;
                        case (instr[11:8])
                            4'h0: pc <= target;                              // Unconditional JMP
                            4'h1: pc <= i_tx_valid ? target : pc + 7'd1;     // JMP TX_VALID
                            4'h2: pc <= !i_tx_valid ? target : pc + 7'd1;    // JMP TX_EMPTY
                            4'h3: pc <= i_rx_full ? target : pc + 7'd1;      // JMP RX_FULL
                            4'h4: pc <= !i_rx_full ? target : pc + 7'd1;     // JMP RX_READY
                            4'h5: pc <= gpio_in[rx_pin] ? target : pc + 7'd1;// JMP PIN_HI
                            4'h6: pc <= !gpio_in[rx_pin] ? target : pc + 7'd1;// JMP PIN_LO
                            4'h7: pc <= (crc_reg == 32'h0) ? target : pc + 7'd1;// JMP CRC_OK
                            4'h8: pc <= zero_flag ? target : pc + 7'd1;      // JMP ZERO
                            4'h9: pc <= !zero_flag ? target : pc + 7'd1;     // JMP NOT_ZERO
                            4'hA: pc <= carry_flag ? target : pc + 7'd1;     // JMP CARRY
                            4'hB: pc <= !carry_flag ? target : pc + 7'd1;    // JMP NOT_CARRY
                            4'hC: pc <= acc[7] ? target : pc + 7'd1;         // JMP NEG
                            4'hD: pc <= !acc[7] ? target : pc + 7'd1;        // JMP POS
                            4'hE: pc <= (crc_reg != 32'h0) ? target : pc + 7'd1;// JMP CRC_ERR
                            4'hF: pc <= stuff_error ? target : pc + 7'd1;    // JMP STUFF_ERR
                        endcase
                    end

                    4'hE: begin // CRC operations
                        delay_cnt <= 16'd0;
                        case (instr[11:9])
                            3'b000: begin // CRC_INIT
                                crc_poly <= {1'b0, instr[8:7]};
                                crc_seed <= (instr[8:7] == 2'b11) ? 32'h0000FFFF : 32'h00000000;
                                crc_reg  <= (instr[8:7] == 2'b11) ? 32'h0000FFFF : 32'h00000000;
                                pc       <= pc + 7'd1;
                            end
                            3'b001, 3'b010, 3'b011: begin // CRC_BYTE
                                crc_reg <= next_crc;
                                pc      <= pc + 7'd1;
                            end
                            3'b100: begin // CRC_READ_LOW
                                osr    <= crc_reg[7:0];
                                o_data <= crc_reg[7:0];
                                pc     <= pc + 7'd1;
                            end
                            3'b101: begin // CRC_READ_HIGH
                                osr    <= crc_reg[15:8];
                                o_data <= crc_reg[15:8];
                                pc     <= pc + 7'd1;
                            end
                            3'b110: begin // CRC_RESET
                                crc_reg <= crc_seed;
                                pc      <= pc + 7'd1;
                            end
                            default: pc <= pc + 7'd1;
                        endcase
                    end

                    4'hB: begin // Micro-ALU
                        delay_cnt <= 16'd0;
                        pc        <= pc + 7'd1;
                        if (instr[11] == 1'b0) begin
                            // Immediate ALU
                            case (instr[10:8])
                                3'b000: begin // ADD
                                    acc        <= alu_imm_add[7:0];
                                    carry_flag <= alu_imm_add[8];
                                    zero_flag  <= (alu_imm_add[7:0] == 8'h00);
                                end
                                3'b001: begin // SUB
                                    acc        <= alu_imm_sub[7:0];
                                    carry_flag <= alu_imm_sub[8];
                                    zero_flag  <= (alu_imm_sub[7:0] == 8'h00);
                                end
                                3'b010: begin // CMP
                                    carry_flag <= alu_imm_sub[8];
                                    zero_flag  <= (alu_imm_sub[7:0] == 8'h00);
                                end
                                3'b011: begin // AND
                                    acc        <= acc & instr[7:0];
                                    zero_flag  <= ((acc & instr[7:0]) == 8'h00);
                                    carry_flag <= 1'b0;
                                end
                                3'b100: begin // OR
                                    acc        <= acc | instr[7:0];
                                    zero_flag  <= ((acc | instr[7:0]) == 8'h00);
                                    carry_flag <= 1'b0;
                                end
                                3'b101: begin // XOR
                                    acc        <= acc ^ instr[7:0];
                                    zero_flag  <= ((acc ^ instr[7:0]) == 8'h00);
                                    carry_flag <= 1'b0;
                                end
                                3'b110: begin // MOV
                                    acc        <= instr[7:0];
                                    zero_flag  <= (instr[7:0] == 8'h00);
                                    carry_flag <= 1'b0;
                                end
                                3'b111: begin // NOT / BANK
                                    case (instr[7:6])
                                        2'b00: begin
                                            acc        <= ~acc;
                                            zero_flag  <= ((~acc) == 8'h00);
                                            carry_flag <= 1'b0;
                                        end
                                        2'b01: begin
                                            active_bank <= instr[1:0];
                                            zero_flag   <= (instr[1:0] == 2'b00);
                                            carry_flag  <= 1'b0;
                                        end
                                        2'b10: begin
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
                            // Register ALU
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
                                        3'b101: active_bank <= acc[1:0];
                                        3'b110: crc_seed[7:0]  <= acc;
                                        3'b111: crc_seed[15:8] <= acc;
                                    endcase
                                end
                                3'b010: begin // ADD acc, reg
                                    acc        <= alu_reg_add[7:0];
                                    carry_flag <= alu_reg_add[8];
                                    zero_flag  <= (alu_reg_add[7:0] == 8'h00);
                                end
                                3'b011: begin // SUB acc, reg
                                    acc        <= alu_reg_sub[7:0];
                                    carry_flag <= alu_reg_sub[8];
                                    zero_flag  <= (alu_reg_sub[7:0] == 8'h00);
                                end
                                3'b100: begin // CMP acc, reg
                                    carry_flag <= alu_reg_sub[8];
                                    zero_flag  <= (alu_reg_sub[7:0] == 8'h00);
                                end
                                3'b101: begin // Bitwise Logic
                                    case (instr[5:3])
                                        3'b000: begin
                                            acc        <= acc & alu_reg_val;
                                            zero_flag  <= ((acc & alu_reg_val) == 8'h00);
                                            carry_flag <= 1'b0;
                                        end
                                        3'b001: begin
                                            acc        <= acc | alu_reg_val;
                                            zero_flag  <= ((acc | alu_reg_val) == 8'h00);
                                            carry_flag <= 1'b0;
                                        end
                                        default: begin
                                            acc        <= acc ^ alu_reg_val;
                                            zero_flag  <= ((acc ^ alu_reg_val) == 8'h00);
                                            carry_flag <= 1'b0;
                                        end
                                    endcase
                                end
                                3'b110: begin // Unary
                                    case (instr[5:3])
                                        3'b000: begin
                                            acc        <= acc + 8'd1;
                                            carry_flag <= (acc == 8'hFF);
                                            zero_flag  <= (acc + 8'd1 == 8'h00);
                                        end
                                        3'b001: begin
                                            acc        <= acc - 8'd1;
                                            carry_flag <= (acc == 8'h00);
                                            zero_flag  <= (acc - 8'd1 == 8'h00);
                                        end
                                        default: begin
                                            acc        <= 8'h00;
                                            zero_flag  <= 1'b1;
                                            carry_flag <= 1'b0;
                                        end
                                    endcase
                                end
                                3'b111: begin // Shift/Rotate
                                    case (instr[5:3])
                                        3'b000: begin
                                            carry_flag <= acc[7];
                                            acc        <= {acc[6:0], 1'b0};
                                            zero_flag  <= ({acc[6:0], 1'b0} == 8'h00);
                                        end
                                        3'b001: begin
                                            carry_flag <= acc[0];
                                            acc        <= {1'b0, acc[7:1]};
                                            zero_flag  <= ({1'b0, acc[7:1]} == 8'h00);
                                        end
                                        3'b010: begin
                                            acc        <= {acc[6:0], acc[7]};
                                            carry_flag <= acc[7];
                                            zero_flag  <= ({acc[6:0], acc[7]} == 8'h00);
                                        end
                                        default: begin
                                            acc        <= {acc[0], acc[7:1]};
                                            carry_flag <= acc[0];
                                            zero_flag  <= ({acc[0], acc[7:1]} == 8'h00);
                                        end
                                    endcase
                                end
                            endcase
                        end
                    end

                    4'hC: begin // CALL
                        call_stack[sp] <= pc + 7'd1;
                        sp             <= (sp == 2'd3) ? 2'd3 : sp + 2'd1;
                        delay_cnt      <= 16'd0;
                        pc             <= target;
                    end

                    4'hD: begin // RET
                        sp        <= (sp == 2'd0) ? 2'd0 : sp - 2'd1;
                        pc        <= (sp == 2'd0) ? 7'd0 : call_stack[sp - 2'd1];
                        delay_cnt <= 16'd0;
                    end

                    4'hF: begin // ASSIST & Multi-Core MP Instructions
                        delay_cnt <= 16'd0;
                        if (instr[11:10] == 2'b11) begin
                            // =================================================
                            // Task 35: Multi-Core MP Instructions
                            // =================================================
                            case (instr[9:8])
                                2'b00: begin // CORE_ID: load core ID into acc
                                    acc        <= CORE_ID[7:0];
                                    zero_flag  <= (CORE_ID == 0);
                                    carry_flag <= 1'b0;
                                    pc         <= pc + 7'd1;
                                end
                                2'b01: begin // SPINLOCK_ACQ lock_id (instr[1:0])
                                    if (i_spinlock_ack) begin
                                        acc        <= 8'h00; // Success
                                        zero_flag  <= 1'b1;
                                        carry_flag <= 1'b0;
                                    end else begin
                                        acc        <= 8'h01; // Lock busy
                                        zero_flag  <= 1'b0;
                                        carry_flag <= 1'b1;
                                    end
                                    pc <= pc + 7'd1;
                                end
                                2'b10: begin // SPINLOCK_REL lock_id (instr[1:0])
                                    pc <= pc + 7'd1;
                                end
                                2'b11: begin // BARRIER_WAIT
                                    o_barrier_arrive <= 1'b1;
                                    pc               <= pc; // Stall until release
                                end
                            endcase
                        end else if (instr[11:10] == 2'b10) begin
                            // =================================================
                            // Task 35: Inter-Core Hardware Mailboxes
                            // =================================================
                            case (instr[9:8])
                                2'b00: begin // MB_READ mb_id (instr[2:0])
                                    acc        <= i_mb_rdata;
                                    o_data     <= i_mb_rdata;
                                    zero_flag  <= (i_mb_rdata == 8'h00);
                                    carry_flag <= 1'b0;
                                    pc         <= pc + 7'd1;
                                end
                                2'b01: begin // MB_WRITE mb_id (instr[2:0])
                                    pc <= pc + 7'd1;
                                end
                                default: pc <= pc + 7'd1;
                            endcase
                        end else begin
                            // Legacy ASSIST CFG / RESET
                            if (instr[11:10] == 2'b00) begin
                                assist_nrzi_en    <= instr[9];
                                assist_stuff_mode <= instr[8:7];
                                if (instr[6]) begin
                                    nrzi_tx_state <= instr[5];
                                    nrzi_rx_prev  <= instr[5];
                                end
                            end else begin
                                tx_stuff_cnt  <= 3'd0;
                                rx_stuff_cnt  <= 3'd0;
                                stuff_error   <= 1'b0;
                                nrzi_tx_state <= 1'b1;
                                nrzi_rx_prev  <= 1'b1;
                            end
                            pc <= pc + 7'd1;
                        end
                    end

                    default: pc <= pc + 7'd1;
                endcase
            end
        end
    end

endmodule
`default_nettype wire
