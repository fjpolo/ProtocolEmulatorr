// =============================================================================
// File        : OmniBus_Wishbone.v
// Module      : OmniBus_Wishbone
// Description : Standard Wishbone B4 Slave SoC Wrapper for OmniBus Protocol Engine.
//               Integrates:
//                 - Parameterized TX and RX hardware circular FIFOs
//                 - Memory-mapped registers for Data, Status, Control, Baud Divisor
//                 - Direct CPU Microcode RAM programming window (0x80..0xFC)
//                 - Watermark interrupt generation for host CPU
// License     : MIT License
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module OmniBus_Wishbone #(
    parameter integer FIFO_DEPTH        = 16,
    parameter integer DEFAULT_BAUD_DIV  = 433   // 115200 baud @ 50MHz
)(
    // -------------------------------------------------------------------------
    // Wishbone B4 Slave Interface
    // -------------------------------------------------------------------------
    input  wire        i_wb_clk,
    input  wire        i_wb_rst_n,
    input  wire        i_wb_cyc,
    input  wire        i_wb_stb,
    input  wire        i_wb_we,
    input  wire [7:0]  i_wb_addr,      // 8-bit byte address (0x00 to 0xFF)
    input  wire [31:0] i_wb_data,
    input  wire [3:0]  i_wb_sel,
    output reg  [31:0] o_wb_data,
    output reg         o_wb_ack,
    output wire        o_irq,

    // -------------------------------------------------------------------------
    // External Physical Protocol Pins (OmniBus Unified GPIO Bus)
    // -------------------------------------------------------------------------
    input  wire [7:0]  i_gpio,
    output wire [7:0]  o_gpio,
    output wire [7:0]  o_gpio_oe,

    // Backward-compatibility convenience ports
    input  wire        i_rx,
    output wire        o_tx,
    output wire        o_spi_sck,
    output wire        o_spi_cs_n,

    // -------------------------------------------------------------------------
    // Wishbone B4 Master Interface (DMA Host System Memory Bus)
    // -------------------------------------------------------------------------
    output wire        o_m_wb_cyc,
    output wire        o_m_wb_stb,
    output wire        o_m_wb_we,
    output wire [31:0] o_m_wb_addr,
    output wire [31:0] o_m_wb_data,
    output wire [3:0]  o_m_wb_sel,
    input  wire [31:0] i_m_wb_data,
    input  wire        i_m_wb_ack,
    input  wire        i_m_wb_err
);

    // =========================================================================
    // Address Map Offsets (32-bit aligned words)
    // =========================================================================
    localparam [7:0] ADDR_DATA      = 8'h00;  // RW: TX FIFO write / RX FIFO read
    localparam [7:0] ADDR_STATUS    = 8'h04;  // RO: FIFO flags, levels, PC telemetry
    localparam [7:0] ADDR_CTRL      = 8'h08;  // RW: Soft reset, prog_en, FIFO flushes, IRQ mask
    localparam [7:0] ADDR_BAUD      = 8'h0C;  // RW: Dynamic baud rate divisor
    localparam [7:0] ADDR_GPIO      = 8'h10;  // RO: GPIO pin readback [i_gpio, o_gpio, o_oe]
    localparam [7:0] ADDR_IMEM_BANK = 8'h14;  // RW: Active IMEM bank for programming window (0..3)
    localparam [7:0] ADDR_AUDIO     = 8'h18;  // RW: Audio sample, mode, APU control, and telemetry
    localparam [7:0] ADDR_DEBUG     = 8'h1C;  // RO: Hardware JTAG TAP state, SWD ACK, parity error & telemetry
    localparam [7:0] ADDR_QSPI      = 8'h20;  // RO: Hardware Quad-SPI state, width, cpol, rx_byte & addr_reg telemetry
    localparam [7:0] ADDR_GLITCH    = 8'h24;  // RO: Hardware Glitch status, timer & MitM telemetry
    localparam [7:0] ADDR_DMA_CTRL    = 8'h30;  // RW: DMA global & channel control / start
    localparam [7:0] ADDR_DMA_STATUS  = 8'h34;  // RO: DMA channel status & FSM states
    localparam [7:0] ADDR_DMA_TX_ADDR = 8'h38;  // RW: Linear TX Source Address / SG Desc Address
    localparam [7:0] ADDR_DMA_TX_LEN  = 8'h3C;  // RW: Linear TX Byte Count
    localparam [7:0] ADDR_DMA_RX_ADDR = 8'h40;  // RW: Linear RX Dest Address / SG Desc Address
    localparam [7:0] ADDR_DMA_RX_LEN  = 8'h44;  // RW: Linear RX Byte Count
    localparam [7:0] ADDR_DMA_TX_DESC = 8'h48;  // RO: Current active TX descriptor address
    localparam [7:0] ADDR_DMA_RX_DESC = 8'h4C;  // RO: Current active RX descriptor address
    localparam [7:0] ADDR_PROFILER_CTRL   = 8'h50;  // RW: Profiler Control: [2:0]=pin, [6:3]=filter, [8]=arm, [9]=stop, [10]=rst, [11]=irq_en
    localparam [7:0] ADDR_PROFILER_STATUS = 8'h54;  // RO: Profiler Status: [0]=busy, [1]=done, [2]=idle_pol, [3]=is_clock, [7:4]=proto_id, [15:8]=edge_count
    localparam [7:0] ADDR_PROFILER_TMIN   = 8'h58;  // RO: Profiler t_min: [15:0]=tmin (baud divisor), [31:16]=tmax
    localparam [7:0] ADDR_PROFILER_PERIOD = 8'h5C;  // RO: Profiler Symmetry: [15:0]=tmin_high, [31:16]=tmin_low
    localparam [7:0] ADDR_IMEM        = 8'h80;  // Base address for 32-word IMEM window (0x80..0xFC)

    // =========================================================================
    // Control & Configuration Registers
    // =========================================================================
    reg [15:0] reg_baud;
    reg [1:0]  reg_imem_bank;                 // Active Wishbone IMEM programming bank (0..3)
    reg        reg_prog_en;
    reg        reg_tx_flush;
    reg        reg_rx_flush;
    reg        reg_soft_rst;
    reg        reg_irq_tx_empty_en;
    reg        reg_irq_rx_ready_en;
    reg        reg_irq_rx_afull_en;

    // DMA Control Registers
    reg        reg_dma_tx_en;
    reg        reg_dma_tx_start;
    reg        reg_dma_tx_irq_en;
    reg        reg_dma_tx_sg_en;
    reg        reg_dma_rx_en;
    reg        reg_dma_rx_start;
    reg        reg_dma_rx_irq_en;
    reg        reg_dma_rx_sg_en;
    reg        reg_dma_abort;
    reg [31:0] reg_dma_tx_addr;
    reg [15:0] reg_dma_tx_len;
    reg [31:0] reg_dma_rx_addr;
    reg [15:0] reg_dma_rx_len;

    // Autonomous Waveform Profiler Registers (Task 27)
    reg [2:0]  reg_profiler_pin;
    reg [3:0]  reg_profiler_filter;
    reg        reg_profiler_arm;
    reg        reg_profiler_stop;
    reg        reg_profiler_rst;
    reg        reg_profiler_irq_en;

    // Combined active-low reset for core and FIFOs
    wire core_rst_n = i_wb_rst_n && !reg_soft_rst;

    // =========================================================================
    // TX & RX Hardware FIFOs
    // =========================================================================
    wire wb_valid = i_wb_cyc && i_wb_stb;

    wire       dma_tx_fifo_push;
    wire [7:0] dma_tx_fifo_wdata;
    wire       dma_rx_fifo_pop;

    wire       cpu_tx_fifo_push = wb_valid && i_wb_we && !o_wb_ack && (i_wb_addr == ADDR_DATA);
    wire       cpu_rx_fifo_pop  = wb_valid && !i_wb_we && !o_wb_ack && (i_wb_addr == ADDR_DATA);

    wire       tx_fifo_push  = cpu_tx_fifo_push || dma_tx_fifo_push;
    wire [7:0] tx_fifo_wdata = dma_tx_fifo_push ? dma_tx_fifo_wdata : i_wb_data[7:0];
    wire       tx_fifo_full;
    wire       tx_fifo_afull;
    wire       tx_fifo_pop;
    wire [7:0] tx_fifo_rdata;
    wire       tx_fifo_empty;
    wire       tx_fifo_aempty;
    wire [$clog2(FIFO_DEPTH):0] tx_fifo_level;

    omnibus_fifo #(
        .DATA_WIDTH(8),
        .DEPTH(FIFO_DEPTH)
    ) tx_fifo (
        .i_clk         (i_wb_clk),
        .i_rst_n       (core_rst_n),
        .i_clear       (reg_tx_flush),
        .i_push        (tx_fifo_push),
        .i_data        (tx_fifo_wdata),
        .o_full        (tx_fifo_full),
        .o_almost_full (tx_fifo_afull),
        .i_pop         (tx_fifo_pop),
        .o_data        (tx_fifo_rdata),
        .o_empty       (tx_fifo_empty),
        .o_almost_empty(tx_fifo_aempty),
        .o_level       (tx_fifo_level)
    );

    wire       rx_fifo_push;
    wire [7:0] rx_fifo_wdata;
    wire       rx_fifo_full;
    wire       rx_fifo_afull;
    wire       rx_fifo_pop = cpu_rx_fifo_pop || dma_rx_fifo_pop;
    wire [7:0] rx_fifo_rdata;
    wire       rx_fifo_empty;
    wire       rx_fifo_aempty;
    wire [$clog2(FIFO_DEPTH):0] rx_fifo_level;

    omnibus_fifo #(
        .DATA_WIDTH(8),
        .DEPTH(FIFO_DEPTH)
    ) rx_fifo (
        .i_clk         (i_wb_clk),
        .i_rst_n       (core_rst_n),
        .i_clear       (reg_rx_flush),
        .i_push        (rx_fifo_push),
        .i_data        (rx_fifo_wdata),
        .o_full        (rx_fifo_full),
        .o_almost_full (rx_fifo_afull),
        .i_pop         (rx_fifo_pop),
        .o_data        (rx_fifo_rdata),
        .o_empty       (rx_fifo_empty),
        .o_almost_empty(rx_fifo_aempty),
        .o_level       (rx_fifo_level)
    );

    // =========================================================================
    // Core Handshaking & Wires
    // =========================================================================
    wire [7:0]  core_odata;
    wire        core_tx_pop;
    wire        core_rx_push;
    wire [15:0] core_prog_rdata;

    // Autonomous Profiler Telemetry Wires (Task 27)
    wire        profiler_busy;
    wire        profiler_done;
    wire        profiler_idle_pol;
    wire        profiler_is_clock;
    wire [3:0]  profiler_proto_id;
    wire [7:0]  profiler_edges;
    wire [15:0] profiler_tmin;
    wire [15:0] profiler_tmax;
    wire [15:0] profiler_tmin_high;
    wire [15:0] profiler_tmin_low;

    assign tx_fifo_pop   = core_tx_pop;
    assign rx_fifo_push  = core_rx_push;
    assign rx_fifo_wdata = core_odata;

    // Direct IMEM programming signals from Wishbone (mapped through reg_imem_bank)
    wire        wb_imem_sel  = (i_wb_addr[7] == 1'b1); // Address 0x80 to 0xFF
    wire [6:0]  wb_imem_addr = {reg_imem_bank, i_wb_addr[6:2]}; // 7-bit word offset 0..127
    wire        wb_imem_we   = i_wb_cyc && i_wb_stb && i_wb_we && wb_imem_sel;

    // The core is placed in programming mode either via reg_prog_en OR when writing to IMEM window
    wire core_prog_en = reg_prog_en || wb_imem_sel;

    // =========================================================================
    // ProtocolEmulator Instance
    // =========================================================================
    ProtocolEmulator core (
        .i_clk        (i_wb_clk),
        .i_reset_n    (core_rst_n),
        .i_data       (tx_fifo_rdata),
        .o_data       (core_odata),
        .i_tx_valid   (!tx_fifo_empty),
        .o_tx_pop     (core_tx_pop),
        .i_rx_full    (rx_fifo_full),
        .o_rx_push    (core_rx_push),
        .i_baud_div   (reg_baud),
        .i_gpio       (i_gpio),
        .o_gpio       (o_gpio),
        .o_gpio_oe    (o_gpio_oe),
        .i_rx         (i_rx),
        .o_tx         (o_tx),
        .o_spi_sck    (o_spi_sck),
        .o_spi_cs_n   (o_spi_cs_n),
        // Task 27 Profiler
        .i_profiler_wb_arm   (reg_profiler_arm),
        .i_profiler_wb_stop  (reg_profiler_stop),
        .i_profiler_wb_rst   (reg_profiler_rst),
        .i_profiler_wb_pin   (reg_profiler_pin),
        .i_profiler_wb_filter(reg_profiler_filter),
        .o_profiler_busy     (profiler_busy),
        .o_profiler_done     (profiler_done),
        .o_profiler_idle_pol (profiler_idle_pol),
        .o_profiler_is_clock (profiler_is_clock),
        .o_profiler_proto_id (profiler_proto_id),
        .o_profiler_edges    (profiler_edges),
        .o_profiler_tmin     (profiler_tmin),
        .o_profiler_tmax     (profiler_tmax),
        .o_profiler_tmin_high(profiler_tmin_high),
        .o_profiler_tmin_low (profiler_tmin_low),
        .i_prog_en    (core_prog_en),
        .i_prog_we    (wb_imem_we),
        .i_prog_addr  (wb_imem_addr),
        .i_prog_data  (i_wb_data[15:0]),
        .o_prog_rdata (core_prog_rdata)
    );

    // =========================================================================
    // Direct Memory Access (DMA) Scatter-Gather Controller Instance
    // =========================================================================
    wire [31:0] dma_status;
    wire [31:0] dma_tx_desc;
    wire [31:0] dma_rx_desc;
    wire [15:0] dma_tx_bytes_rem;
    wire [15:0] dma_rx_bytes_rem;
    wire [31:0] dma_tx_curr_addr;
    wire [31:0] dma_rx_curr_addr;
    wire        dma_irq;

    OmniBus_DMA dma_inst (
        .i_clk              (i_wb_clk),
        .i_rst_n            (core_rst_n),

        // Wishbone Master
        .o_m_wb_cyc         (o_m_wb_cyc),
        .o_m_wb_stb         (o_m_wb_stb),
        .o_m_wb_we          (o_m_wb_we),
        .o_m_wb_addr        (o_m_wb_addr),
        .o_m_wb_data        (o_m_wb_data),
        .o_m_wb_sel         (o_m_wb_sel),
        .i_m_wb_data        (i_m_wb_data),
        .i_m_wb_ack         (i_m_wb_ack),
        .i_m_wb_err         (i_m_wb_err),

        // FIFO Interfaces
        .o_tx_fifo_push     (dma_tx_fifo_push),
        .o_tx_fifo_wdata    (dma_tx_fifo_wdata),
        .i_tx_fifo_full     (tx_fifo_full),
        .i_tx_fifo_afull    (tx_fifo_afull),

        .o_rx_fifo_pop      (dma_rx_fifo_pop),
        .i_rx_fifo_rdata    (rx_fifo_rdata),
        .i_rx_fifo_empty    (rx_fifo_empty),
        .i_rx_fifo_aempty   (rx_fifo_aempty),

        // Control Inputs
        .i_dma_tx_en        (reg_dma_tx_en),
        .i_dma_tx_start     (reg_dma_tx_start),
        .i_dma_tx_irq_en    (reg_dma_tx_irq_en),
        .i_dma_tx_sg_en     (reg_dma_tx_sg_en),

        .i_dma_rx_en        (reg_dma_rx_en),
        .i_dma_rx_start     (reg_dma_rx_start),
        .i_dma_rx_irq_en    (reg_dma_rx_irq_en),
        .i_dma_rx_sg_en     (reg_dma_rx_sg_en),

        .i_dma_abort        (reg_dma_abort),

        .i_dma_tx_addr      (reg_dma_tx_addr),
        .i_dma_tx_len       (reg_dma_tx_len),
        .i_dma_rx_addr      (reg_dma_rx_addr),
        .i_dma_rx_len       (reg_dma_rx_len),

        // Status & Telemetry
        .o_dma_status       (dma_status),
        .o_dma_tx_desc      (dma_tx_desc),
        .o_dma_rx_desc      (dma_rx_desc),
        .o_dma_tx_bytes_rem (dma_tx_bytes_rem),
        .o_dma_rx_bytes_rem (dma_rx_bytes_rem),
        .o_dma_tx_curr_addr (dma_tx_curr_addr),
        .o_dma_rx_curr_addr (dma_rx_curr_addr),
        .o_dma_irq          (dma_irq)
    );

    // =========================================================================
    // Wishbone Bus Cycle & Register Decoding
    // =========================================================================

    // Status register composition
    wire [31:0] reg_status = {
        o_irq,                                      // [31] IRQ state
        core.i2c_addr_match,                        // [30] I2C Slave Address Match
        core.crc_reg == 32'd0,                      // [29] CRC Residue == 0
        core.pc[4:0],                               // [28:24] Core PC
        {(8-$clog2(FIFO_DEPTH)-1){1'b0}}, rx_fifo_level, // [23:16] RX FIFO Level
        {(8-$clog2(FIFO_DEPTH)-1){1'b0}}, tx_fifo_level, // [15:8]  TX FIFO Level
        rx_fifo_aempty,                             // [7] RX Almost Empty
        rx_fifo_afull,                              // [6] RX Almost Full
        rx_fifo_empty,                              // [5] RX Empty
        rx_fifo_full,                               // [4] RX Full
        tx_fifo_aempty,                             // [3] TX Almost Empty
        tx_fifo_afull,                              // [2] TX Almost Full
        tx_fifo_empty,                              // [1] TX Empty
        tx_fifo_full                                // [0] TX Full
    };

    wire [31:0] reg_ctrl_read = {
        25'd0,
        reg_irq_rx_afull_en, // [6]
        reg_irq_rx_ready_en, // [5]
        reg_irq_tx_empty_en, // [4]
        1'b0,                // [3] rx_flush (auto-clears)
        1'b0,                // [2] tx_flush (auto-clears)
        reg_prog_en,         // [1]
        reg_soft_rst         // [0]
    };

    wire [31:0] reg_gpio_read = {
        8'd0,
        o_gpio_oe,
        o_gpio,
        i_gpio
    };

    // Combinational Read Multiplexer
    reg [31:0] wb_rdata_comb;
    always @(*) begin
        if (wb_imem_sel) begin
            wb_rdata_comb = {16'h0000, core_prog_rdata};
        end else begin
            case (i_wb_addr)
                ADDR_DATA:        wb_rdata_comb = {24'h000000, rx_fifo_rdata};
                ADDR_STATUS:      wb_rdata_comb = reg_status;
                ADDR_CTRL:        wb_rdata_comb = reg_ctrl_read;
                ADDR_BAUD:        wb_rdata_comb = {16'h0000, reg_baud};
                ADDR_GPIO:        wb_rdata_comb = reg_gpio_read;
                ADDR_IMEM_BANK:   wb_rdata_comb = {14'd0, core.active_bank, 1'b0, core.pc, 6'd0, reg_imem_bank};
                ADDR_AUDIO:       wb_rdata_comb = {core.audio_sample, core.audio_en, core.audio_mode, core.audio_pin, core.audio_preset, core.pdm_bit, 11'd0};
                ADDR_DEBUG:       wb_rdata_comb = {16'h0000, core.swd_last_ack, core.swd_parity_err, core.swd_en, 3'b000, core.jtag_tdo_sampled, core.jtag_state, core.jtag_tms, core.jtag_tck, core.jtag_en};
                ADDR_QSPI:        wb_rdata_comb = {core.qspi_addr_reg[15:0], core.qspi_rx_byte, core.qspi_state, core.qspi_cpol, core.qspi_width, core.qspi_en};
                ADDR_GLITCH:      wb_rdata_comb = {core.mitm_match_count, core.glitch_timer[7:0], core.mitm_replace_byte, core.glitch_fired, core.mitm_match_found, core.glitch_armed, core.glitch_active, core.glitch_pol, core.glitch_pin};
                ADDR_DMA_CTRL:    wb_rdata_comb = {23'd0, reg_dma_abort, reg_dma_rx_sg_en, reg_dma_rx_irq_en, reg_dma_rx_start, reg_dma_rx_en, reg_dma_tx_sg_en, reg_dma_tx_irq_en, reg_dma_tx_start, reg_dma_tx_en};
                ADDR_DMA_STATUS:  wb_rdata_comb = dma_status;
                ADDR_DMA_TX_ADDR: wb_rdata_comb = reg_dma_tx_addr;
                ADDR_DMA_TX_LEN:  wb_rdata_comb = {16'd0, reg_dma_tx_len};
                ADDR_DMA_RX_ADDR: wb_rdata_comb = reg_dma_rx_addr;
                ADDR_DMA_RX_LEN:  wb_rdata_comb = {16'd0, reg_dma_rx_len};
                ADDR_DMA_TX_DESC: wb_rdata_comb = dma_tx_desc;
                ADDR_DMA_RX_DESC: wb_rdata_comb = dma_rx_desc;
                ADDR_PROFILER_CTRL:   wb_rdata_comb = {20'd0, reg_profiler_irq_en, 3'd0, 1'b0, reg_profiler_filter, reg_profiler_pin};
                ADDR_PROFILER_STATUS: wb_rdata_comb = {16'd0, profiler_edges, profiler_proto_id, profiler_is_clock, profiler_idle_pol, profiler_done, profiler_busy};
                ADDR_PROFILER_TMIN:   wb_rdata_comb = {profiler_tmax, profiler_tmin};
                ADDR_PROFILER_PERIOD: wb_rdata_comb = {profiler_tmin_low, profiler_tmin_high};
                default:          wb_rdata_comb = 32'h00000000;
            endcase
        end
    end

    // Wishbone Write & Register Updates
    always @(posedge i_wb_clk or negedge i_wb_rst_n) begin
        if (!i_wb_rst_n) begin
            reg_baud            <= DEFAULT_BAUD_DIV[15:0];
            reg_imem_bank       <= 2'b00;
            reg_prog_en         <= 1'b0;
            reg_tx_flush        <= 1'b0;
            reg_rx_flush        <= 1'b0;
            reg_soft_rst        <= 1'b0;
            reg_irq_tx_empty_en <= 1'b0;
            reg_irq_rx_ready_en <= 1'b0;
            reg_irq_rx_afull_en <= 1'b0;
            reg_dma_tx_en       <= 1'b0;
            reg_dma_tx_start    <= 1'b0;
            reg_dma_tx_irq_en   <= 1'b0;
            reg_dma_tx_sg_en    <= 1'b0;
            reg_dma_rx_en       <= 1'b0;
            reg_dma_rx_start    <= 1'b0;
            reg_dma_rx_irq_en   <= 1'b0;
            reg_dma_rx_sg_en    <= 1'b0;
            reg_dma_abort       <= 1'b0;
            reg_dma_tx_addr     <= 32'd0;
            reg_dma_tx_len      <= 16'd0;
            reg_dma_rx_addr     <= 32'd0;
            reg_dma_rx_len      <= 16'd0;
            reg_profiler_pin    <= 3'd0;
            reg_profiler_filter <= 4'd2;
            reg_profiler_arm    <= 1'b0;
            reg_profiler_stop   <= 1'b0;
            reg_profiler_rst    <= 1'b0;
            reg_profiler_irq_en <= 1'b0;
            o_wb_ack            <= 1'b0;
            o_wb_data           <= 32'h00000000;
        end else begin
            // Single-cycle self-clearing strobes
            reg_tx_flush      <= 1'b0;
            reg_rx_flush      <= 1'b0;
            reg_dma_tx_start  <= 1'b0;
            reg_dma_rx_start  <= 1'b0;
            reg_dma_abort     <= 1'b0;
            reg_profiler_arm  <= 1'b0;
            reg_profiler_stop <= 1'b0;
            reg_profiler_rst  <= 1'b0;

            if (wb_valid && !o_wb_ack) begin
                o_wb_ack  <= 1'b1;
                o_wb_data <= wb_rdata_comb;
                if (i_wb_we) begin
                    case (i_wb_addr)
                        ADDR_CTRL: begin
                            reg_soft_rst        <= i_wb_data[0];
                            reg_prog_en         <= i_wb_data[1];
                            reg_tx_flush        <= i_wb_data[2];
                            reg_rx_flush        <= i_wb_data[3];
                            reg_irq_tx_empty_en <= i_wb_data[4];
                            reg_irq_rx_ready_en <= i_wb_data[5];
                            reg_irq_rx_afull_en <= i_wb_data[6];
                        end
                        ADDR_BAUD: begin
                            reg_baud <= i_wb_data[15:0];
                        end
                        ADDR_IMEM_BANK: begin
                            reg_imem_bank <= i_wb_data[1:0];
                        end
                        ADDR_DMA_CTRL: begin
                            reg_dma_tx_en     <= i_wb_data[0];
                            reg_dma_tx_start  <= i_wb_data[1];
                            reg_dma_tx_irq_en <= i_wb_data[2];
                            reg_dma_tx_sg_en  <= i_wb_data[3];
                            reg_dma_rx_en     <= i_wb_data[4];
                            reg_dma_rx_start  <= i_wb_data[5];
                            reg_dma_rx_irq_en <= i_wb_data[6];
                            reg_dma_rx_sg_en  <= i_wb_data[7];
                            reg_dma_abort     <= i_wb_data[8];
                        end
                        ADDR_DMA_TX_ADDR: reg_dma_tx_addr <= i_wb_data;
                        ADDR_DMA_TX_LEN:  reg_dma_tx_len  <= i_wb_data[15:0];
                        ADDR_DMA_RX_ADDR: reg_dma_rx_addr <= i_wb_data;
                        ADDR_DMA_RX_LEN:  reg_dma_rx_len  <= i_wb_data[15:0];
                        ADDR_PROFILER_CTRL: begin
                            reg_profiler_pin    <= i_wb_data[2:0];
                            reg_profiler_filter <= i_wb_data[6:3];
                            reg_profiler_arm    <= i_wb_data[8];
                            reg_profiler_stop   <= i_wb_data[9];
                            reg_profiler_rst    <= i_wb_data[10];
                            reg_profiler_irq_en <= i_wb_data[11];
                        end
                        default: ;
                    endcase
                end
            end else begin
                o_wb_ack <= 1'b0;
            end
        end
    end

    // Interrupt Generation Logic
    assign o_irq = (reg_irq_tx_empty_en && tx_fifo_empty) ||
                   (reg_irq_rx_ready_en && !rx_fifo_empty) ||
                   (reg_irq_rx_afull_en && rx_fifo_afull) ||
                   dma_irq ||
                   (reg_profiler_irq_en && profiler_done);

endmodule
