// =============================================================================
// File        : ProtocolEmulator_MP.v
// Module      : ProtocolEmulator_MP (Multi-Core Symmetric OmniBus Micro-Engine)
// Description : Parameterized Multi-Core OmniBus Protocol Engine.
//               Supports NUM_CORES = 1, 2, or 4 concurrent symmetric micro-engines.
//               Features:
//                 - Concurrent cycle-deterministic execution slices (OmniBus_Core)
//                 - 8 Shared Hardware Mailbox registers (0..7) with atomic R/W
//                 - 4 Atomic Hardware Spinlocks (0..3) with single-cycle grant
//                 - Hardware Rendezvous Barrier for phase-locked multi-core synchronization
//                 - Inter-Core Streaming FIFOs & Crossbar Routing Matrix (Direct/Cascade/Loopback)
//                 - GPIO pin crossbar arbitration with open-drain wire-AND support
//                 - Unified Wishbone programming port for bank-switched multi-core microcode
// License     : MIT License
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

`include "OmniBus_Config.vh"

module ProtocolEmulator_MP #(
    parameter integer NUM_CORES  = `NUM_CORES,     // Supported: 1, 2, or 4
    parameter integer FIFO_DEPTH = `DEFAULT_FIFO_DEPTH
)(
    input   wire            i_clk,
    input   wire            i_reset_n,

    // Streaming Data & FIFO Handshaking Interface (External / Wishbone)
    input   wire    [7:0]   i_data,             // Input stream byte from Host TX FIFO
    output  wire    [7:0]   o_data,             // Output stream byte to Host RX FIFO
    input   wire            i_tx_valid,         // 1 when input byte is available
    output  wire            o_tx_pop,           // 1-cycle active-high pop strobe
    input   wire            i_rx_full,          // 1 when downstream buffer is full
    output  wire            o_rx_push,          // 1-cycle active-high push strobe

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
    // Multi-Core MP Control & Status Interface
    // -------------------------------------------------------------------------
    input   wire    [3:0]   i_core_en,          // Run enable mask for Cores 0..3
    input   wire    [3:0]   i_core_rst,         // Soft reset mask for Cores 0..3
    input   wire    [1:0]   i_stream_mode,      // 00=Parallel/Direct, 01=Cascade, 10=Loopback
    input   wire            i_barrier_rst,      // Manual barrier reset strobe
    output  wire    [3:0]   o_active_cores,     // Mask of currently active cores
    output  wire    [3:0]   o_barrier_status,   // Mask of cores waiting at barrier
    output  wire    [3:0]   o_spinlock_status,  // Current spinlock status bits 0..3
    output  wire    [NUM_CORES*7-1:0] o_core_pc,// Concatenated PC telemetry
    output  wire    [NUM_CORES-1:0]   o_core_halted,

    // Host Mailbox Access Window (from Wishbone B4)
    input   wire    [2:0]   i_wb_mb_sel,
    input   wire    [7:0]   i_wb_mb_wdata,
    input   wire            i_wb_mb_we,
    output  wire    [31:0]  o_wb_mb_rdata_w0,   // Mailbox 3..0
    output  wire    [31:0]  o_wb_mb_rdata_w1    // Mailbox 7..4
);

    // =========================================================================
    // Core Signals Array
    // =========================================================================
    wire [7:0]  core_idata       [0:3];
    wire [7:0]  core_odata       [0:3];
    wire        core_tx_valid    [0:3];
    wire        core_tx_pop      [0:3];
    wire        core_rx_full     [0:3];
    wire        core_rx_push     [0:3];

    wire [7:0]  core_gpio        [0:3];
    wire [7:0]  core_gpio_oe     [0:3];
    wire        core_tx          [0:3];
    wire        core_spi_sck     [0:3];
    wire        core_spi_cs_n    [0:3];

    wire [15:0] core_prog_rdata  [0:3];

    wire [2:0]  core_mb_sel      [0:3];
    wire        core_mb_we       [0:3];
    wire [7:0]  core_mb_wdata    [0:3];

    wire [1:0]  core_spinlock_sel[0:3];
    wire        core_spinlock_req[0:3];
    wire        core_spinlock_rel[0:3];
    wire        core_spinlock_ack[0:3];

    wire        core_barrier_arrive[0:3];
    wire [6:0]  core_pc          [0:3];
    wire [7:0]  core_acc         [0:3];
    wire        core_zero_flag   [0:3];
    wire        core_carry_flag  [0:3];
    wire        core_halted      [0:3];

    genvar uc;
    generate
        for (uc = NUM_CORES; uc < 4; uc = uc + 1) begin : gen_unused_cores
            assign core_mb_we[uc]          = 1'b0;
            assign core_mb_sel[uc]         = 3'd0;
            assign core_mb_wdata[uc]       = 8'd0;
            assign core_spinlock_req[uc]   = 1'b0;
            assign core_spinlock_rel[uc]   = 1'b0;
            assign core_spinlock_sel[uc]   = 2'd0;
            assign core_spinlock_ack[uc]   = 1'b0;
            assign core_barrier_arrive[uc] = 1'b0;
            assign core_odata[uc]          = 8'd0;
            assign core_tx_pop[uc]         = 1'b0;
            assign core_rx_push[uc]        = 1'b0;
            assign core_gpio[uc]           = 8'd0;
            assign core_gpio_oe[uc]        = 8'd0;
            assign core_tx[uc]             = 1'b0;
            assign core_spi_sck[uc]        = 1'b0;
            assign core_spi_cs_n[uc]       = 1'b1;
            assign core_prog_rdata[uc]     = 16'd0;
            assign core_pc[uc]             = 7'd0;
            assign core_acc[uc]            = 8'd0;
            assign core_zero_flag[uc]      = 1'b0;
            assign core_carry_flag[uc]     = 1'b0;
            assign core_halted[uc]         = 1'b1;
        end
    endgenerate

    wire [NUM_CORES-1:0] core_rst_n;
    wire [NUM_CORES-1:0] core_en_eff;

    // =========================================================================
    // 8 Shared Hardware Mailbox Registers (0..7)
    // =========================================================================
    reg [7:0] mailbox [0:7];

    assign o_wb_mb_rdata_w0 = {mailbox[3], mailbox[2], mailbox[1], mailbox[0]};
    assign o_wb_mb_rdata_w1 = {mailbox[7], mailbox[6], mailbox[5], mailbox[4]};

    integer m_idx;
    always @(posedge i_clk) begin
        if (!i_reset_n) begin
            for (m_idx = 0; m_idx < 8; m_idx = m_idx + 1) begin
                mailbox[m_idx] <= 8'h00;
            end
        end else begin
            // Wishbone host write takes effect
            if (i_wb_mb_we) begin
                mailbox[i_wb_mb_sel] <= i_wb_mb_wdata;
            end

            // Core writes (Core 0 has priority if multiple cores write simultaneously to same mailbox)
            if (NUM_CORES > 3 && core_mb_we[3]) mailbox[core_mb_sel[3]] <= core_mb_wdata[3];
            if (NUM_CORES > 2 && core_mb_we[2]) mailbox[core_mb_sel[2]] <= core_mb_wdata[2];
            if (NUM_CORES > 1 && core_mb_we[1]) mailbox[core_mb_sel[1]] <= core_mb_wdata[1];
            if (core_mb_we[0])                  mailbox[core_mb_sel[0]] <= core_mb_wdata[0];
        end
    end

    // =========================================================================
    // 4 Atomic Hardware Spinlocks (0..3)
    // =========================================================================
    reg [3:0] spinlock;
    assign o_spinlock_status = spinlock;

    // Combinational single-cycle acquire grant arbiter (Core 0 > Core 1 > Core 2 > Core 3)
    genvar sc;
    generate
        for (sc = 0; sc < NUM_CORES; sc = sc + 1) begin : gen_spinlock_ack
            wire [1:0] l_idx = core_spinlock_sel[sc];
            wire lock_is_free = (spinlock[l_idx] == 1'b0);

            // Check if any lower-index core is requesting the exact same lock in this cycle
            wire lower_req = (sc == 0) ? 1'b0 :
                             (sc == 1) ? (core_spinlock_req[0] && core_spinlock_sel[0] == l_idx) :
                             (sc == 2) ? ((core_spinlock_req[0] && core_spinlock_sel[0] == l_idx) ||
                                          (core_spinlock_req[1] && core_spinlock_sel[1] == l_idx)) :
                                         ((core_spinlock_req[0] && core_spinlock_sel[0] == l_idx) ||
                                          (core_spinlock_req[1] && core_spinlock_sel[1] == l_idx) ||
                                          (core_spinlock_req[2] && core_spinlock_sel[2] == l_idx));

            assign core_spinlock_ack[sc] = core_spinlock_req[sc] && lock_is_free && !lower_req;
        end
    endgenerate

    integer sl_idx;
    always @(posedge i_clk) begin
        if (!i_reset_n) begin
            spinlock <= 4'b0000;
        end else begin
            // Release operations
            if (core_spinlock_rel[0])                                          spinlock[core_spinlock_sel[0]] <= 1'b0;
            if (NUM_CORES > 1 && core_spinlock_rel[1])                         spinlock[core_spinlock_sel[1]] <= 1'b0;
            if (NUM_CORES > 2 && core_spinlock_rel[2])                         spinlock[core_spinlock_sel[2]] <= 1'b0;
            if (NUM_CORES > 3 && core_spinlock_rel[3])                         spinlock[core_spinlock_sel[3]] <= 1'b0;

            // Acquire operations (granted core sets lock to 1)
            if (core_spinlock_ack[0])                                          spinlock[core_spinlock_sel[0]] <= 1'b1;
            if (NUM_CORES > 1 && core_spinlock_ack[1])                         spinlock[core_spinlock_sel[1]] <= 1'b1;
            if (NUM_CORES > 2 && core_spinlock_ack[2])                         spinlock[core_spinlock_sel[2]] <= 1'b1;
            if (NUM_CORES > 3 && core_spinlock_ack[3])                         spinlock[core_spinlock_sel[3]] <= 1'b1;
        end
    end

    // =========================================================================
    // Hardware Rendezvous Barrier
    // =========================================================================
    reg [NUM_CORES-1:0] barrier_arrived;
    reg                 barrier_released;

    wire [NUM_CORES-1:0] core_barrier_vec;
    genvar bv;
    generate
        for (bv = 0; bv < NUM_CORES; bv = bv + 1) begin : gen_barrier_vec
            assign core_barrier_vec[bv] = core_barrier_arrive[bv];
        end
    endgenerate

    wire [NUM_CORES-1:0] active_mask = core_en_eff[NUM_CORES-1:0];
    wire [NUM_CORES-1:0] next_barrier_mask = barrier_arrived | core_barrier_vec;
    wire barrier_all_met = ((next_barrier_mask & active_mask) == active_mask) && (active_mask != {NUM_CORES{1'b0}});

    always @(posedge i_clk) begin
        if (!i_reset_n || i_barrier_rst) begin
            barrier_arrived  <= {NUM_CORES{1'b0}};
            barrier_released <= 1'b0;
        end else begin
            if (barrier_all_met) begin
                barrier_released <= 1'b1;
                barrier_arrived  <= {NUM_CORES{1'b0}};
            end else begin
                barrier_released <= 1'b0;
                barrier_arrived  <= next_barrier_mask;
            end
        end
    end

    assign o_barrier_status = {{(4-NUM_CORES){1'b0}}, barrier_arrived};
    assign o_active_cores   = {{(4-NUM_CORES){1'b0}}, active_mask};

    // =========================================================================
    // Inter-Core Stream Pipeline & Crossbar Routing
    // =========================================================================
    // Inter-Core FIFOs for Cascade Mode (Core 0 -> FIFO 0 -> Core 1 -> FIFO 1 -> Core 2 -> ...)
    wire [7:0] fifo_rdata [0:2];
    wire       fifo_empty [0:2];
    wire       fifo_full  [0:2];
    wire       fifo_push  [0:2];
    wire       fifo_pop   [0:2];

    generate
        if (NUM_CORES >= 2) begin : gen_fifo0
            assign fifo_push[0] = (i_stream_mode == 2'b01) ? core_rx_push[0] : 1'b0;
            assign fifo_pop[0]  = (i_stream_mode == 2'b01) ? core_tx_pop[1]  : 1'b0;

            omnibus_fifo #(
                .DATA_WIDTH(8),
                .DEPTH(8)
            ) ic_fifo_0 (
                .i_clk         (i_clk),
                .i_rst_n       (i_reset_n),
                .i_clear       (1'b0),
                .i_push        (fifo_push[0]),
                .i_data        (core_odata[0]),
                .o_full        (fifo_full[0]),
                .o_almost_full (),
                .i_pop         (fifo_pop[0]),
                .o_data        (fifo_rdata[0]),
                .o_empty       (fifo_empty[0]),
                .o_almost_empty(),
                .o_level       ()
            );
        end

        if (NUM_CORES == 4) begin : gen_fifo1_2
            assign fifo_push[1] = (i_stream_mode == 2'b01) ? core_rx_push[1] : 1'b0;
            assign fifo_pop[1]  = (i_stream_mode == 2'b01) ? core_tx_pop[2]  : 1'b0;

            omnibus_fifo #(
                .DATA_WIDTH(8),
                .DEPTH(8)
            ) ic_fifo_1 (
                .i_clk         (i_clk),
                .i_rst_n       (i_reset_n),
                .i_clear       (1'b0),
                .i_push        (fifo_push[1]),
                .i_data        (core_odata[1]),
                .o_full        (fifo_full[1]),
                .o_almost_full (),
                .i_pop         (fifo_pop[1]),
                .o_data        (fifo_rdata[1]),
                .o_empty       (fifo_empty[1]),
                .o_almost_empty(),
                .o_level       ()
            );

            assign fifo_push[2] = (i_stream_mode == 2'b01) ? core_rx_push[2] : 1'b0;
            assign fifo_pop[2]  = (i_stream_mode == 2'b01) ? core_tx_pop[3]  : 1'b0;

            omnibus_fifo #(
                .DATA_WIDTH(8),
                .DEPTH(8)
            ) ic_fifo_2 (
                .i_clk         (i_clk),
                .i_rst_n       (i_reset_n),
                .i_clear       (1'b0),
                .i_push        (fifo_push[2]),
                .i_data        (core_odata[2]),
                .o_full        (fifo_full[2]),
                .o_almost_full (),
                .i_pop         (fifo_pop[2]),
                .o_data        (fifo_rdata[2]),
                .o_empty       (fifo_empty[2]),
                .o_almost_empty(),
                .o_level       ()
            );
        end
    endgenerate

    // Stream inputs & outputs multiplexing
    generate
        if (NUM_CORES == 1) begin : gen_stream_1core
            assign core_idata[0]    = i_data;
            assign core_tx_valid[0] = i_tx_valid;
            assign core_rx_full[0]  = i_rx_full;
            assign o_tx_pop         = core_tx_pop[0];
            assign o_rx_push        = core_rx_push[0];
            assign o_data           = core_odata[0];
        end else if (NUM_CORES == 2) begin : gen_stream_2core
            assign core_idata[0]    = (i_stream_mode == 2'b10) ? core_odata[1] : i_data;
            assign core_tx_valid[0] = (i_stream_mode == 2'b10) ? core_rx_push[1] : i_tx_valid;
            assign core_rx_full[0]  = (i_stream_mode == 2'b01) ? fifo_full[0] :
                                      (i_stream_mode == 2'b10) ? 1'b0 : i_rx_full;
            assign o_tx_pop         = (i_stream_mode == 2'b10) ? 1'b0 : core_tx_pop[0];

            assign core_idata[1]    = (i_stream_mode == 2'b01) ? fifo_rdata[0] :
                                      (i_stream_mode == 2'b10) ? core_odata[0] : 8'h00;
            assign core_tx_valid[1] = (i_stream_mode == 2'b01) ? !fifo_empty[0] :
                                      (i_stream_mode == 2'b10) ? core_rx_push[0] : 1'b0;
            assign core_rx_full[1]  = (i_stream_mode == 2'b01) ? i_rx_full : 1'b0;

            assign o_rx_push        = (i_stream_mode == 2'b01) ? core_rx_push[1] : core_rx_push[0];
            assign o_data           = (i_stream_mode == 2'b01) ? core_odata[1]   : core_odata[0];
        end else begin : gen_stream_4core
            assign core_idata[0]    = i_data;
            assign core_tx_valid[0] = i_tx_valid;
            assign core_rx_full[0]  = (i_stream_mode == 2'b01) ? fifo_full[0] : i_rx_full;
            assign o_tx_pop         = core_tx_pop[0];

            assign core_idata[1]    = (i_stream_mode == 2'b01) ? fifo_rdata[0] : 8'h00;
            assign core_tx_valid[1] = (i_stream_mode == 2'b01) ? !fifo_empty[0] : 1'b0;
            assign core_rx_full[1]  = (i_stream_mode == 2'b01) ? fifo_full[1] : 1'b0;

            assign core_idata[2]    = (i_stream_mode == 2'b01) ? fifo_rdata[1] : 8'h00;
            assign core_tx_valid[2] = (i_stream_mode == 2'b01) ? !fifo_empty[1] : 1'b0;
            assign core_rx_full[2]  = (i_stream_mode == 2'b01) ? fifo_full[2] : 1'b0;

            assign core_idata[3]    = (i_stream_mode == 2'b01) ? fifo_rdata[2] : 8'h00;
            assign core_tx_valid[3] = (i_stream_mode == 2'b01) ? !fifo_empty[2] : 1'b0;
            assign core_rx_full[3]  = (i_stream_mode == 2'b01) ? i_rx_full : 1'b0;

            assign o_rx_push        = (i_stream_mode == 2'b01) ? core_rx_push[3] : core_rx_push[0];
            assign o_data           = (i_stream_mode == 2'b01) ? core_odata[3]   : core_odata[0];
        end
    endgenerate

    // =========================================================================
    // Core Slices Instantiation
    // =========================================================================
    genvar c;
    generate
        for (c = 0; c < NUM_CORES; c = c + 1) begin : gen_cores
            assign core_rst_n[c]   = i_reset_n && !i_core_rst[c];
            assign core_en_eff[c]  = i_core_en[c];

            OmniBus_Core #(
                .CORE_ID   (c),
                .RESET_PC  (c * 32),
                .IMEM_SIZE (128)
            ) core_inst (
                .i_clk              (i_clk),
                .i_reset_n          (core_rst_n[c]),
                .i_core_en          (core_en_eff[c]),
                .i_data             (core_idata[c]),
                .o_data             (core_odata[c]),
                .i_tx_valid         (core_tx_valid[c]),
                .o_tx_pop           (core_tx_pop[c]),
                .i_rx_full          (core_rx_full[c]),
                .o_rx_push          (core_rx_push[c]),
                .i_baud_div         (i_baud_div),
                .i_gpio             (i_gpio),
                .o_gpio             (core_gpio[c]),
                .o_gpio_oe          (core_gpio_oe[c]),
                .i_rx               (i_rx),
                .o_tx               (core_tx[c]),
                .o_spi_sck          (core_spi_sck[c]),
                .o_spi_cs_n         (core_spi_cs_n[c]),
                .i_prog_en          (i_prog_en),
                .i_prog_we          (i_prog_we),
                .i_prog_addr        (i_prog_addr),
                .i_prog_data        (i_prog_data),
                .o_prog_rdata       (core_prog_rdata[c]),
                .i_mb_rdata         (mailbox[core_mb_sel[c]]),
                .o_mb_sel           (core_mb_sel[c]),
                .o_mb_we            (core_mb_we[c]),
                .o_mb_wdata         (core_mb_wdata[c]),
                .i_spinlock_status  (spinlock),
                .i_spinlock_ack     (core_spinlock_ack[c]),
                .o_spinlock_sel     (core_spinlock_sel[c]),
                .o_spinlock_req     (core_spinlock_req[c]),
                .o_spinlock_rel     (core_spinlock_rel[c]),
                .i_barrier_released (barrier_released),
                .o_barrier_arrive   (core_barrier_arrive[c]),
                .o_pc               (core_pc[c]),
                .o_acc              (core_acc[c]),
                .o_zero_flag        (core_zero_flag[c]),
                .o_carry_flag       (core_carry_flag[c]),
                .o_halted           (core_halted[c])
            );
        end
    endgenerate

    // Telemetry concatenation
    generate
        if (NUM_CORES == 1) begin : gen_telemetry_1
            assign o_core_pc     = core_pc[0];
            assign o_core_halted = core_halted[0];
        end else if (NUM_CORES == 2) begin : gen_telemetry_2
            assign o_core_pc     = {core_pc[1], core_pc[0]};
            assign o_core_halted = {core_halted[1], core_halted[0]};
        end else begin : gen_telemetry_4
            assign o_core_pc     = {core_pc[3], core_pc[2], core_pc[1], core_pc[0]};
            assign o_core_halted = {core_halted[3], core_halted[2], core_halted[1], core_halted[0]};
        end
    endgenerate

    assign o_prog_rdata = core_prog_rdata[0];

    // =========================================================================
    // GPIO Bus Combining & Arbitration
    // =========================================================================
    wire [7:0] combined_gpio_out;
    wire [7:0] combined_gpio_oe;

    genvar gp;
    generate
        for (gp = 0; gp < 8; gp = gp + 1) begin : gen_comb_gpio
            if (NUM_CORES == 1) begin : g1
                assign combined_gpio_out[gp] = core_gpio[0][gp];
                assign combined_gpio_oe[gp]  = core_gpio_oe[0][gp];
            end else if (NUM_CORES == 2) begin : g2
                assign combined_gpio_out[gp] = (core_gpio_oe[0][gp] ? core_gpio[0][gp] : 1'b0) |
                                               (core_gpio_oe[1][gp] ? core_gpio[1][gp] : 1'b0);
                assign combined_gpio_oe[gp]  = core_gpio_oe[0][gp] | core_gpio_oe[1][gp];
            end else begin : g4
                assign combined_gpio_out[gp] = (core_gpio_oe[0][gp] ? core_gpio[0][gp] : 1'b0) |
                                               (core_gpio_oe[1][gp] ? core_gpio[1][gp] : 1'b0) |
                                               (core_gpio_oe[2][gp] ? core_gpio[2][gp] : 1'b0) |
                                               (core_gpio_oe[3][gp] ? core_gpio[3][gp] : 1'b0);
                assign combined_gpio_oe[gp]  = core_gpio_oe[0][gp] | core_gpio_oe[1][gp] |
                                               core_gpio_oe[2][gp] | core_gpio_oe[3][gp];
            end
        end
    endgenerate

    assign o_gpio     = combined_gpio_out;
    assign o_gpio_oe  = combined_gpio_oe;
    assign o_tx       = core_tx[0];
    assign o_spi_sck  = (NUM_CORES > 1 && core_gpio_oe[1][core_spi_sck[1]]) ? core_spi_sck[1] : core_spi_sck[0];
    assign o_spi_cs_n = (NUM_CORES > 1 && core_gpio_oe[1][core_spi_cs_n[1]]) ? core_spi_cs_n[1] : core_spi_cs_n[0];

endmodule
`default_nettype wire
