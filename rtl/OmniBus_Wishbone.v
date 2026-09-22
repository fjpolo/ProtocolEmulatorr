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
    output wire        o_spi_cs_n
);

    // =========================================================================
    // Address Map Offsets (32-bit aligned words)
    // =========================================================================
    localparam [7:0] ADDR_DATA   = 8'h00;  // RW: TX FIFO write / RX FIFO read
    localparam [7:0] ADDR_STATUS = 8'h04;  // RO: FIFO flags, levels, PC telemetry
    localparam [7:0] ADDR_CTRL   = 8'h08;  // RW: Soft reset, prog_en, FIFO flushes, IRQ mask
    localparam [7:0] ADDR_BAUD   = 8'h0C;  // RW: Dynamic baud rate divisor
    localparam [7:0] ADDR_GPIO   = 8'h10;  // RO: GPIO pin readback [i_gpio, o_gpio, o_oe]
    localparam [7:0] ADDR_IMEM   = 8'h80;  // Base address for 32-word IMEM window (0x80..0xFC)

    // =========================================================================
    // Control & Configuration Registers
    // =========================================================================
    reg [15:0] reg_baud;
    reg        reg_prog_en;
    reg        reg_tx_flush;
    reg        reg_rx_flush;
    reg        reg_soft_rst;
    reg        reg_irq_tx_empty_en;
    reg        reg_irq_rx_ready_en;
    reg        reg_irq_rx_afull_en;

    // Combined active-low reset for core and FIFOs
    wire core_rst_n = i_wb_rst_n && !reg_soft_rst;

    // =========================================================================
    // TX & RX Hardware FIFOs
    // =========================================================================
    wire       tx_fifo_push;
    wire [7:0] tx_fifo_wdata = i_wb_data[7:0];
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
    wire       rx_fifo_pop;
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

    assign tx_fifo_pop   = core_tx_pop;
    assign rx_fifo_push  = core_rx_push;
    assign rx_fifo_wdata = core_odata;

    // Direct IMEM programming signals from Wishbone
    wire        wb_imem_sel  = (i_wb_addr[7] == 1'b1); // Address 0x80 to 0xFF
    wire [4:0]  wb_imem_addr = i_wb_addr[6:2];         // Word offset 0..31
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
        .i_prog_en    (core_prog_en),
        .i_prog_we    (wb_imem_we),
        .i_prog_addr  (wb_imem_addr),
        .i_prog_data  (i_wb_data[15:0]),
        .o_prog_rdata (core_prog_rdata)
    );

    // =========================================================================
    // Wishbone Bus Cycle & Register Decoding
    // =========================================================================
    wire wb_valid = i_wb_cyc && i_wb_stb;

    // Generate single-cycle strobes for FIFO reads / writes
    assign tx_fifo_push = wb_valid && i_wb_we && !o_wb_ack && (i_wb_addr == ADDR_DATA);
    assign rx_fifo_pop  = wb_valid && !i_wb_we && !o_wb_ack && (i_wb_addr == ADDR_DATA);

    // Status register composition
    wire [31:0] reg_status = {
        o_irq,                                      // [31] IRQ state
        !reg_prog_en,                               // [30] Core Running
        core.crc_reg == 16'd0,                      // [29] CRC Residue == 0
        core.pc,                                    // [28:24] Core PC
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
                ADDR_DATA:   wb_rdata_comb = {24'h000000, rx_fifo_rdata};
                ADDR_STATUS: wb_rdata_comb = reg_status;
                ADDR_CTRL:   wb_rdata_comb = reg_ctrl_read;
                ADDR_BAUD:   wb_rdata_comb = {16'h0000, reg_baud};
                ADDR_GPIO:   wb_rdata_comb = reg_gpio_read;
                default:     wb_rdata_comb = 32'h00000000;
            endcase
        end
    end

    // Wishbone Write & Register Updates
    always @(posedge i_wb_clk or negedge i_wb_rst_n) begin
        if (!i_wb_rst_n) begin
            reg_baud            <= DEFAULT_BAUD_DIV[15:0];
            reg_prog_en         <= 1'b0;
            reg_tx_flush        <= 1'b0;
            reg_rx_flush        <= 1'b0;
            reg_soft_rst        <= 1'b0;
            reg_irq_tx_empty_en <= 1'b0;
            reg_irq_rx_ready_en <= 1'b0;
            reg_irq_rx_afull_en <= 1'b0;
            o_wb_ack            <= 1'b0;
            o_wb_data           <= 32'h00000000;
        end else begin
            // Single-cycle self-clearing strobes
            reg_tx_flush <= 1'b0;
            reg_rx_flush <= 1'b0;

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
                   (reg_irq_rx_afull_en && rx_fifo_afull);

endmodule
