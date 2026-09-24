// =============================================================================
// File        : OmniBus_DMA.v
// Module      : OmniBus_DMA
// Description : High-Throughput Direct Memory Access (DMA) Scatter-Gather Controller
//               & Host Memory Streamer for OmniBus Protocol Processor Core.
// Features:
//   - Wishbone B4 Pipelined Master interface for high-speed host memory streaming
//   - Dual independent channels:
//       * TX DMA (Memory -> TX FIFO) for autonomous transmit streaming
//       * RX DMA (RX FIFO -> Memory) for autonomous receive capture
//   - Scatter-Gather Linked-List Descriptor Engine (16-byte descriptors):
//       * Word 0: 32-bit buffer physical address
//       * Word 1: [15:0] transfer byte length, [31:16] control flags (EOT, IRQ, CIRC)
//       * Word 2: 32-bit pointer to next descriptor
//       * Word 3: 32-bit status write-back (actual bytes transferred)
//   - Linear Direct Buffer transfer mode (address + length registers)
//   - 32-bit word packing/unpacking with automatic byte-lane strobe generation
//   - Interrupt generation for transfer complete, descriptor complete, and bus error
// License     : MIT License
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module OmniBus_DMA #(
    parameter integer ADDR_WIDTH = 32,
    parameter integer DATA_WIDTH = 32
)(
    input  wire        i_clk,
    input  wire        i_rst_n,

    // -------------------------------------------------------------------------
    // Wishbone B4 Master Interface (Host System Memory Bus)
    // -------------------------------------------------------------------------
    output reg         o_m_wb_cyc,
    output reg         o_m_wb_stb,
    output reg         o_m_wb_we,
    output reg  [31:0] o_m_wb_addr,
    output reg  [31:0] o_m_wb_data,
    output reg  [3:0]  o_m_wb_sel,
    input  wire [31:0] i_m_wb_data,
    input  wire        i_m_wb_ack,
    input  wire        i_m_wb_err,

    // -------------------------------------------------------------------------
    // Internal FIFO Interface (TX Channel: Memory -> TX FIFO)
    // -------------------------------------------------------------------------
    output reg         o_tx_fifo_push,
    output reg  [7:0]  o_tx_fifo_wdata,
    input  wire        i_tx_fifo_full,
    input  wire        i_tx_fifo_afull,

    // -------------------------------------------------------------------------
    // Internal FIFO Interface (RX Channel: RX FIFO -> Memory)
    // -------------------------------------------------------------------------
    output reg         o_rx_fifo_pop,
    input  wire [7:0]  i_rx_fifo_rdata,
    input  wire        i_rx_fifo_empty,
    input  wire        i_rx_fifo_aempty,

    // -------------------------------------------------------------------------
    // Control & Configuration Inputs (from Wishbone Slave Register Window)
    // -------------------------------------------------------------------------
    input  wire        i_dma_tx_en,
    input  wire        i_dma_tx_start,
    input  wire        i_dma_tx_irq_en,
    input  wire        i_dma_tx_sg_en,

    input  wire        i_dma_rx_en,
    input  wire        i_dma_rx_start,
    input  wire        i_dma_rx_irq_en,
    input  wire        i_dma_rx_sg_en,

    input  wire        i_dma_abort,

    input  wire [31:0] i_dma_tx_addr,
    input  wire [15:0] i_dma_tx_len,
    input  wire [31:0] i_dma_rx_addr,
    input  wire [15:0] i_dma_rx_len,

    // -------------------------------------------------------------------------
    // Status & Telemetry Outputs (to Wishbone Slave Register Window)
    // -------------------------------------------------------------------------
    output wire [31:0] o_dma_status,
    output reg  [31:0] o_dma_tx_desc,
    output reg  [31:0] o_dma_rx_desc,
    output reg  [15:0] o_dma_tx_bytes_rem,
    output reg  [15:0] o_dma_rx_bytes_rem,
    output reg  [31:0] o_dma_tx_curr_addr,
    output reg  [31:0] o_dma_rx_curr_addr,
    output wire        o_dma_irq
);

    // =========================================================================
    // FSM States Definition
    // =========================================================================
    localparam [3:0]
        TX_IDLE        = 4'd0,
        TX_SG_FETCH0   = 4'd1, // Fetch buf_addr
        TX_SG_FETCH1   = 4'd2, // Fetch len & flags
        TX_SG_FETCH2   = 4'd3, // Fetch next_desc
        TX_SG_FETCH3   = 4'd4, // Dummy fetch / prepare
        TX_READ_MEM    = 4'd5, // Issue Wishbone Read cycle
        TX_WAIT_ACK    = 4'd6, // Await Wishbone Read ACK
        TX_PUSH_FIFO   = 4'd7, // Push unpacked bytes to TX FIFO
        TX_SG_UPDATE   = 4'd8, // Write back status to descriptor
        TX_DONE_ST     = 4'd9;

    localparam [3:0]
        RX_IDLE        = 4'd0,
        RX_SG_FETCH0   = 4'd1, // Fetch buf_addr
        RX_SG_FETCH1   = 4'd2, // Fetch len & flags
        RX_SG_FETCH2   = 4'd3, // Fetch next_desc
        RX_SG_FETCH3   = 4'd4, // Dummy fetch / prepare
        RX_POP_FIFO    = 4'd5, // Pop bytes from RX FIFO into pack buffer
        RX_WRITE_MEM   = 4'd6, // Issue Wishbone Write cycle
        RX_WAIT_ACK    = 4'd7, // Await Wishbone Write ACK
        RX_SG_UPDATE   = 4'd8, // Write back status to descriptor
        RX_DONE_ST     = 4'd9;

    reg [3:0] tx_fsm;
    reg [3:0] rx_fsm;

    // Sticky status flags
    reg tx_busy;
    reg tx_done;
    reg tx_err;
    reg rx_busy;
    reg rx_done;
    reg rx_err;

    // Scatter-gather internal descriptor registers
    reg [31:0] tx_desc_buf_addr;
    reg [15:0] tx_desc_len;
    reg [15:0] tx_desc_flags;
    reg [31:0] tx_desc_next;
    reg [15:0] tx_desc_transferred;

    reg [31:0] rx_desc_buf_addr;
    reg [15:0] rx_desc_len;
    reg [15:0] rx_desc_flags;
    reg [31:0] rx_desc_next;
    reg [15:0] rx_desc_transferred;

    // Unpack buffer for TX (32-bit word -> bytes)
    reg [31:0] tx_unpack_buf;
    reg [1:0]  tx_unpack_cnt;
    reg [1:0]  tx_unpack_idx;

    // Pack buffer for RX (bytes -> 32-bit word)
    reg [31:0] rx_pack_buf;
    reg [1:0]  rx_pack_cnt;
    reg [3:0]  rx_pack_sel;
    reg        rx_pop_phase;

    // Master Bus Arbiter: 0 = TX channel, 1 = RX channel
    reg bus_grant;
    reg bus_req_tx;
    reg bus_req_rx;

    // Bus cycle registers for each channel
    reg        tx_wb_cyc;
    reg        tx_wb_stb;
    reg        tx_wb_we;
    reg [31:0] tx_wb_addr;
    reg [31:0] tx_wb_data;
    reg [3:0]  tx_wb_sel;

    reg        rx_wb_cyc;
    reg        rx_wb_stb;
    reg        rx_wb_we;
    reg [31:0] rx_wb_addr;
    reg [31:0] rx_wb_data;
    reg [3:0]  rx_wb_sel;

    // Multiplex Master Wishbone signals to the external bus
    always @(*) begin
        if (bus_grant == 1'b0) begin
            o_m_wb_cyc  = tx_wb_cyc;
            o_m_wb_stb  = tx_wb_stb;
            o_m_wb_we   = tx_wb_we;
            o_m_wb_addr = tx_wb_addr;
            o_m_wb_data = tx_wb_data;
            o_m_wb_sel  = tx_wb_sel;
        end else begin
            o_m_wb_cyc  = rx_wb_cyc;
            o_m_wb_stb  = rx_wb_stb;
            o_m_wb_we   = rx_wb_we;
            o_m_wb_addr = rx_wb_addr;
            o_m_wb_data = rx_wb_data;
            o_m_wb_sel  = rx_wb_sel;
        end
    end

    // Master bus arbiter logic
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            bus_grant <= 1'b0;
        end else begin
            if (i_dma_abort) begin
                bus_grant <= 1'b0;
            end else if (!o_m_wb_cyc) begin
                // When bus is idle, toggle between requests to prevent starvation
                if (bus_req_tx && !bus_req_rx) begin
                    bus_grant <= 1'b0;
                end else if (!bus_req_tx && bus_req_rx) begin
                    bus_grant <= 1'b1;
                end else if (bus_req_tx && bus_req_rx) begin
                    bus_grant <= ~bus_grant; // Alternate
                end
            end
        end
    end

    // =========================================================================
    // TX Channel FSM (Memory -> TX FIFO)
    // =========================================================================
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            tx_fsm              <= TX_IDLE;
            tx_busy             <= 1'b0;
            tx_done             <= 1'b0;
            tx_err              <= 1'b0;
            tx_wb_cyc           <= 1'b0;
            tx_wb_stb           <= 1'b0;
            tx_wb_we            <= 1'b0;
            tx_wb_addr          <= 32'd0;
            tx_wb_data          <= 32'd0;
            tx_wb_sel           <= 4'b1111;
            bus_req_tx          <= 1'b0;
            o_tx_fifo_push      <= 1'b0;
            o_tx_fifo_wdata     <= 8'd0;
            o_dma_tx_desc       <= 32'd0;
            o_dma_tx_bytes_rem  <= 16'd0;
            o_dma_tx_curr_addr  <= 32'd0;
            tx_desc_buf_addr    <= 32'd0;
            tx_desc_len         <= 16'd0;
            tx_desc_flags       <= 16'd0;
            tx_desc_next        <= 32'd0;
            tx_desc_transferred <= 16'd0;
            tx_unpack_buf       <= 32'd0;
            tx_unpack_cnt       <= 2'd0;
            tx_unpack_idx       <= 2'd0;
        end else if (i_dma_abort) begin
            tx_fsm          <= TX_IDLE;
            tx_busy         <= 1'b0;
            tx_wb_cyc       <= 1'b0;
            tx_wb_stb       <= 1'b0;
            bus_req_tx      <= 1'b0;
            o_tx_fifo_push  <= 1'b0;
        end else begin
            o_tx_fifo_push <= 1'b0; // Default pulse

            case (tx_fsm)
                TX_IDLE: begin
                    if (i_dma_tx_en && i_dma_tx_start) begin
                        tx_busy <= 1'b1;
                        tx_done <= 1'b0;
                        tx_err  <= 1'b0;
                        if (i_dma_tx_sg_en) begin
                            o_dma_tx_desc <= i_dma_tx_addr;
                            tx_fsm        <= TX_SG_FETCH0;
                        end else begin
                            o_dma_tx_curr_addr <= i_dma_tx_addr;
                            o_dma_tx_bytes_rem <= i_dma_tx_len;
                            tx_fsm             <= TX_READ_MEM;
                        end
                    end
                end

                // -------------------------------------------------------------
                // Scatter-Gather Descriptor Fetch (4 words: addr, len/flags, next, status)
                // -------------------------------------------------------------
                TX_SG_FETCH0: begin
                    bus_req_tx <= 1'b1;
                    if (bus_grant == 1'b0 && (!o_m_wb_cyc || (tx_wb_cyc && tx_wb_stb))) begin
                        tx_wb_cyc  <= 1'b1;
                        tx_wb_stb  <= 1'b1;
                        tx_wb_we   <= 1'b0;
                        tx_wb_addr <= o_dma_tx_desc;
                        tx_wb_sel  <= 4'b1111;
                        if (tx_wb_stb && i_m_wb_ack) begin
                            tx_wb_stb        <= 1'b0;
                            tx_desc_buf_addr <= i_m_wb_data;
                            tx_fsm           <= TX_SG_FETCH1;
                        end else if (tx_wb_stb && i_m_wb_err) begin
                            tx_wb_cyc  <= 1'b0;
                            tx_wb_stb  <= 1'b0;
                            bus_req_tx <= 1'b0;
                            tx_err     <= 1'b1;
                            tx_fsm     <= TX_DONE_ST;
                        end
                    end
                end

                TX_SG_FETCH1: begin
                    if (bus_grant == 1'b0) begin
                        tx_wb_cyc  <= 1'b1;
                        tx_wb_stb  <= 1'b1;
                        tx_wb_we   <= 1'b0;
                        tx_wb_addr <= o_dma_tx_desc + 32'd4;
                        tx_wb_sel  <= 4'b1111;
                        if (tx_wb_stb && i_m_wb_ack) begin
                            tx_wb_stb          <= 1'b0;
                            tx_desc_len        <= i_m_wb_data[15:0];
                            tx_desc_flags      <= i_m_wb_data[31:16];
                            o_dma_tx_bytes_rem <= i_m_wb_data[15:0];
                            tx_fsm             <= TX_SG_FETCH2;
                        end else if (tx_wb_stb && i_m_wb_err) begin
                            tx_wb_cyc  <= 1'b0;
                            tx_wb_stb  <= 1'b0;
                            bus_req_tx <= 1'b0;
                            tx_err     <= 1'b1;
                            tx_fsm     <= TX_DONE_ST;
                        end
                    end
                end

                TX_SG_FETCH2: begin
                    if (bus_grant == 1'b0) begin
                        tx_wb_cyc  <= 1'b1;
                        tx_wb_stb  <= 1'b1;
                        tx_wb_we   <= 1'b0;
                        tx_wb_addr <= o_dma_tx_desc + 32'd8;
                        tx_wb_sel  <= 4'b1111;
                        if (tx_wb_stb && i_m_wb_ack) begin
                            tx_wb_stb          <= 1'b0;
                            tx_wb_cyc          <= 1'b0;
                            bus_req_tx         <= 1'b0;
                            tx_desc_next       <= i_m_wb_data;
                            o_dma_tx_curr_addr <= tx_desc_buf_addr;
                            tx_desc_transferred<= 16'd0;
                            if (tx_desc_len == 16'd0) begin
                                tx_fsm <= TX_SG_UPDATE;
                            end else begin
                                tx_fsm <= TX_READ_MEM;
                            end
                        end else if (tx_wb_stb && i_m_wb_err) begin
                            tx_wb_cyc  <= 1'b0;
                            tx_wb_stb  <= 1'b0;
                            bus_req_tx <= 1'b0;
                            tx_err     <= 1'b1;
                            tx_fsm     <= TX_DONE_ST;
                        end
                    end
                end

                // -------------------------------------------------------------
                // Data Transfer: Read Word from Host Memory into Unpack Buffer
                // -------------------------------------------------------------
                TX_READ_MEM: begin
                    if (o_dma_tx_bytes_rem == 16'd0) begin
                        if (i_dma_tx_sg_en) begin
                            tx_fsm <= TX_SG_UPDATE;
                        end else begin
                            tx_fsm <= TX_DONE_ST;
                        end
                    end else if (!i_tx_fifo_afull) begin
                        bus_req_tx <= 1'b1;
                        if (bus_grant == 1'b0 && !o_m_wb_cyc) begin
                            tx_wb_cyc  <= 1'b1;
                            tx_wb_stb  <= 1'b1;
                            tx_wb_we   <= 1'b0;
                            tx_wb_addr <= o_dma_tx_curr_addr;
                            tx_wb_sel  <= 4'b1111;
                            tx_fsm     <= TX_WAIT_ACK;
                        end
                    end
                end

                TX_WAIT_ACK: begin
                    if (i_m_wb_ack) begin
                        tx_wb_cyc     <= 1'b0;
                        tx_wb_stb     <= 1'b0;
                        bus_req_tx    <= 1'b0;
                        tx_unpack_buf <= i_m_wb_data;
                        tx_unpack_idx <= 2'd0;
                        // Count valid bytes in this word (1..4)
                        if (o_dma_tx_bytes_rem >= 16'd4) begin
                            tx_unpack_cnt <= 2'd3; // 4 bytes (0, 1, 2, 3)
                        end else begin
                            tx_unpack_cnt <= o_dma_tx_bytes_rem[1:0] - 2'd1;
                        end
                        o_dma_tx_curr_addr <= o_dma_tx_curr_addr + 32'd4;
                        tx_fsm             <= TX_PUSH_FIFO;
                    end else if (i_m_wb_err) begin
                        tx_wb_cyc  <= 1'b0;
                        tx_wb_stb  <= 1'b0;
                        bus_req_tx <= 1'b0;
                        tx_err     <= 1'b1;
                        tx_fsm     <= TX_DONE_ST;
                    end
                end

                // -------------------------------------------------------------
                // Push Unpacked Bytes into TX FIFO
                // -------------------------------------------------------------
                TX_PUSH_FIFO: begin
                    if (!i_tx_fifo_full) begin
                        o_tx_fifo_push     <= 1'b1;
                        o_dma_tx_bytes_rem <= o_dma_tx_bytes_rem - 16'd1;
                        tx_desc_transferred<= tx_desc_transferred + 16'd1;

                        case (tx_unpack_idx)
                            2'd0: o_tx_fifo_wdata <= tx_unpack_buf[7:0];
                            2'd1: o_tx_fifo_wdata <= tx_unpack_buf[15:8];
                            2'd2: o_tx_fifo_wdata <= tx_unpack_buf[23:16];
                            2'd3: o_tx_fifo_wdata <= tx_unpack_buf[31:24];
                        endcase

                        if (tx_unpack_idx == tx_unpack_cnt || o_dma_tx_bytes_rem == 16'd1) begin
                            // Word fully pushed
                            if (o_dma_tx_bytes_rem == 16'd1) begin
                                if (i_dma_tx_sg_en) begin
                                    tx_fsm <= TX_SG_UPDATE;
                                end else begin
                                    tx_fsm <= TX_DONE_ST;
                                end
                            end else begin
                                tx_fsm <= TX_READ_MEM;
                            end
                        end else begin
                            tx_unpack_idx <= tx_unpack_idx + 2'd1;
                        end
                    end
                end

                // -------------------------------------------------------------
                // Scatter-Gather Status Write-back (+0x0C)
                // -------------------------------------------------------------
                TX_SG_UPDATE: begin
                    bus_req_tx <= 1'b1;
                    if (bus_grant == 1'b0 && (!o_m_wb_cyc || (tx_wb_cyc && tx_wb_stb))) begin
                        tx_wb_cyc  <= 1'b1;
                        tx_wb_stb  <= 1'b1;
                        tx_wb_we   <= 1'b1;
                        tx_wb_addr <= o_dma_tx_desc + 32'd12;
                        tx_wb_data <= {16'h0000, tx_desc_transferred};
                        tx_wb_sel  <= 4'b1111;
                        if (tx_wb_stb && i_m_wb_ack) begin
                            tx_wb_cyc  <= 1'b0;
                            tx_wb_stb  <= 1'b0;
                            bus_req_tx <= 1'b0;
                            // Check flags[0] (EOT: End of Transmission)
                            if (tx_desc_flags[0] == 1'b1) begin
                                tx_fsm <= TX_DONE_ST;
                            end else begin
                                // Follow next descriptor
                                o_dma_tx_desc <= tx_desc_next;
                                tx_fsm        <= TX_SG_FETCH0;
                            end
                        end else if (tx_wb_stb && i_m_wb_err) begin
                            tx_wb_cyc  <= 1'b0;
                            tx_wb_stb  <= 1'b0;
                            bus_req_tx <= 1'b0;
                            tx_err     <= 1'b1;
                            tx_fsm     <= TX_DONE_ST;
                        end
                    end
                end

                TX_DONE_ST: begin
                    tx_busy <= 1'b0;
                    tx_done <= 1'b1;
                    tx_fsm  <= TX_IDLE;
                end
            endcase
        end
    end

    // =========================================================================
    // RX Channel FSM (RX FIFO -> Memory)
    // =========================================================================
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            rx_fsm              <= RX_IDLE;
            rx_busy             <= 1'b0;
            rx_done             <= 1'b0;
            rx_err              <= 1'b0;
            rx_wb_cyc           <= 1'b0;
            rx_wb_stb           <= 1'b0;
            rx_wb_we            <= 1'b0;
            rx_wb_addr          <= 32'd0;
            rx_wb_data          <= 32'd0;
            rx_wb_sel           <= 4'b1111;
            bus_req_rx          <= 1'b0;
            o_rx_fifo_pop       <= 1'b0;
            o_dma_rx_desc       <= 32'd0;
            o_dma_rx_bytes_rem  <= 16'd0;
            o_dma_rx_curr_addr  <= 32'd0;
            rx_desc_buf_addr    <= 32'd0;
            rx_desc_len         <= 16'd0;
            rx_desc_flags       <= 16'd0;
            rx_desc_next        <= 32'd0;
            rx_desc_transferred <= 16'd0;
            rx_pack_buf         <= 32'd0;
            rx_pack_cnt         <= 2'd0;
            rx_pack_sel         <= 4'b0000;
            rx_pop_phase        <= 1'b0;
        end else if (i_dma_abort) begin
            rx_fsm         <= RX_IDLE;
            rx_busy        <= 1'b0;
            rx_wb_cyc      <= 1'b0;
            rx_wb_stb      <= 1'b0;
            bus_req_rx     <= 1'b0;
            o_rx_fifo_pop  <= 1'b0;
            rx_pop_phase   <= 1'b0;
        end else begin
            o_rx_fifo_pop <= 1'b0; // Default pulse

            case (rx_fsm)
                RX_IDLE: begin
                    if (i_dma_rx_en && i_dma_rx_start) begin
                        rx_busy <= 1'b1;
                        rx_done <= 1'b0;
                        rx_err  <= 1'b0;
                        rx_pop_phase <= 1'b0;
                        if (i_dma_rx_sg_en) begin
                            o_dma_rx_desc <= i_dma_rx_addr;
                            rx_fsm        <= RX_SG_FETCH0;
                        end else begin
                            o_dma_rx_curr_addr <= i_dma_rx_addr;
                            o_dma_rx_bytes_rem <= i_dma_rx_len;
                            rx_pack_cnt        <= 2'd0;
                            rx_pack_sel        <= 4'b0000;
                            rx_fsm             <= RX_POP_FIFO;
                        end
                    end
                end

                // -------------------------------------------------------------
                // Scatter-Gather Descriptor Fetch (4 words: addr, len/flags, next, status)
                // -------------------------------------------------------------
                RX_SG_FETCH0: begin
                    bus_req_rx <= 1'b1;
                    if (bus_grant == 1'b1 && (!o_m_wb_cyc || (rx_wb_cyc && rx_wb_stb))) begin
                        rx_wb_cyc  <= 1'b1;
                        rx_wb_stb  <= 1'b1;
                        rx_wb_we   <= 1'b0;
                        rx_wb_addr <= o_dma_rx_desc;
                        rx_wb_sel  <= 4'b1111;
                        if (rx_wb_stb && i_m_wb_ack) begin
                            rx_wb_stb        <= 1'b0;
                            rx_desc_buf_addr <= i_m_wb_data;
                            rx_fsm           <= RX_SG_FETCH1;
                        end else if (rx_wb_stb && i_m_wb_err) begin
                            rx_wb_cyc  <= 1'b0;
                            rx_wb_stb  <= 1'b0;
                            bus_req_rx <= 1'b0;
                            rx_err     <= 1'b1;
                            rx_fsm     <= RX_DONE_ST;
                        end
                    end
                end

                RX_SG_FETCH1: begin
                    if (bus_grant == 1'b1) begin
                        rx_wb_cyc  <= 1'b1;
                        rx_wb_stb  <= 1'b1;
                        rx_wb_we   <= 1'b0;
                        rx_wb_addr <= o_dma_rx_desc + 32'd4;
                        rx_wb_sel  <= 4'b1111;
                        if (rx_wb_stb && i_m_wb_ack) begin
                            rx_wb_stb          <= 1'b0;
                            rx_desc_len        <= i_m_wb_data[15:0];
                            rx_desc_flags      <= i_m_wb_data[31:16];
                            o_dma_rx_bytes_rem <= i_m_wb_data[15:0];
                            rx_fsm             <= RX_SG_FETCH2;
                        end else if (rx_wb_stb && i_m_wb_err) begin
                            rx_wb_cyc  <= 1'b0;
                            rx_wb_stb  <= 1'b0;
                            bus_req_rx <= 1'b0;
                            rx_err     <= 1'b1;
                            rx_fsm     <= RX_DONE_ST;
                        end
                    end
                end

                RX_SG_FETCH2: begin
                    if (bus_grant == 1'b1) begin
                        rx_wb_cyc  <= 1'b1;
                        rx_wb_stb  <= 1'b1;
                        rx_wb_we   <= 1'b0;
                        rx_wb_addr <= o_dma_rx_desc + 32'd8;
                        rx_wb_sel  <= 4'b1111;
                        if (rx_wb_stb && i_m_wb_ack) begin
                            rx_wb_stb          <= 1'b0;
                            rx_wb_cyc          <= 1'b0;
                            bus_req_rx         <= 1'b0;
                            rx_desc_next       <= i_m_wb_data;
                            o_dma_rx_curr_addr <= rx_desc_buf_addr;
                            rx_desc_transferred<= 16'd0;
                            rx_pack_cnt        <= 2'd0;
                            rx_pack_sel        <= 4'b0000;
                            rx_pop_phase       <= 1'b0;
                            if (rx_desc_len == 16'd0) begin
                                rx_fsm <= RX_SG_UPDATE;
                            end else begin
                                rx_fsm <= RX_POP_FIFO;
                            end
                        end else if (rx_wb_stb && i_m_wb_err) begin
                            rx_wb_cyc  <= 1'b0;
                            rx_wb_stb  <= 1'b0;
                            bus_req_rx <= 1'b0;
                            rx_err     <= 1'b1;
                            rx_fsm     <= RX_DONE_ST;
                        end
                    end
                end

                // -------------------------------------------------------------
                // Pop Bytes from RX FIFO and Pack into 32-bit Word
                // -------------------------------------------------------------
                RX_POP_FIFO: begin
                    if (rx_pop_phase == 1'b1) begin
                        rx_pop_phase <= 1'b0;
                        if (rx_pack_cnt == 2'd3 || o_dma_rx_bytes_rem == 16'd0) begin
                            rx_pack_cnt <= 2'd0;
                            rx_fsm      <= RX_WRITE_MEM;
                        end else begin
                            rx_pack_cnt <= rx_pack_cnt + 2'd1;
                        end
                    end else if (o_dma_rx_bytes_rem == 16'd0) begin
                        if (i_dma_rx_sg_en) begin
                            rx_fsm <= RX_SG_UPDATE;
                        end else begin
                            rx_fsm <= RX_DONE_ST;
                        end
                    end else if (!i_rx_fifo_empty) begin
                        o_rx_fifo_pop       <= 1'b1;
                        o_dma_rx_bytes_rem  <= o_dma_rx_bytes_rem - 16'd1;
                        rx_desc_transferred <= rx_desc_transferred + 16'd1;

                        case (rx_pack_cnt)
                            2'd0: begin
                                rx_pack_buf[7:0] <= i_rx_fifo_rdata;
                                rx_pack_sel[0]   <= 1'b1;
                            end
                            2'd1: begin
                                rx_pack_buf[15:8] <= i_rx_fifo_rdata;
                                rx_pack_sel[1]    <= 1'b1;
                            end
                            2'd2: begin
                                rx_pack_buf[23:16] <= i_rx_fifo_rdata;
                                rx_pack_sel[2]     <= 1'b1;
                            end
                            2'd3: begin
                                rx_pack_buf[31:24] <= i_rx_fifo_rdata;
                                rx_pack_sel[3]     <= 1'b1;
                            end
                        endcase
                        rx_pop_phase <= 1'b1;
                    end
                end

                // -------------------------------------------------------------
                // Write Word to Host System Memory via Wishbone Master
                // -------------------------------------------------------------
                RX_WRITE_MEM: begin
                    bus_req_rx <= 1'b1;
                    if (bus_grant == 1'b1 && !o_m_wb_cyc) begin
                        rx_wb_cyc  <= 1'b1;
                        rx_wb_stb  <= 1'b1;
                        rx_wb_we   <= 1'b1;
                        rx_wb_addr <= o_dma_rx_curr_addr;
                        rx_wb_data <= rx_pack_buf;
                        rx_wb_sel  <= rx_pack_sel;
                        rx_fsm     <= RX_WAIT_ACK;
                    end
                end

                RX_WAIT_ACK: begin
                    if (i_m_wb_ack) begin
                        rx_wb_cyc          <= 1'b0;
                        rx_wb_stb          <= 1'b0;
                        bus_req_rx         <= 1'b0;
                        o_dma_rx_curr_addr <= o_dma_rx_curr_addr + 32'd4;
                        rx_pack_sel        <= 4'b0000;
                        if (o_dma_rx_bytes_rem == 16'd0) begin
                            if (i_dma_rx_sg_en) begin
                                rx_fsm <= RX_SG_UPDATE;
                            end else begin
                                rx_fsm <= RX_DONE_ST;
                            end
                        end else begin
                            rx_fsm <= RX_POP_FIFO;
                        end
                    end else if (i_m_wb_err) begin
                        rx_wb_cyc  <= 1'b0;
                        rx_wb_stb  <= 1'b0;
                        bus_req_rx <= 1'b0;
                        rx_err     <= 1'b1;
                        rx_fsm     <= RX_DONE_ST;
                    end
                end

                // -------------------------------------------------------------
                // Scatter-Gather Status Write-back (+0x0C)
                // -------------------------------------------------------------
                RX_SG_UPDATE: begin
                    bus_req_rx <= 1'b1;
                    if (bus_grant == 1'b1 && (!o_m_wb_cyc || (rx_wb_cyc && rx_wb_stb))) begin
                        rx_wb_cyc  <= 1'b1;
                        rx_wb_stb  <= 1'b1;
                        rx_wb_we   <= 1'b1;
                        rx_wb_addr <= o_dma_rx_desc + 32'd12;
                        rx_wb_data <= {16'h0000, rx_desc_transferred};
                        rx_wb_sel  <= 4'b1111;
                        if (rx_wb_stb && i_m_wb_ack) begin
                            rx_wb_cyc  <= 1'b0;
                            rx_wb_stb  <= 1'b0;
                            bus_req_rx <= 1'b0;
                            // Check flags[0] (EOT: End of Transmission)
                            if (rx_desc_flags[0] == 1'b1) begin
                                rx_fsm <= RX_DONE_ST;
                            end else begin
                                // Follow next descriptor
                                o_dma_rx_desc <= rx_desc_next;
                                rx_fsm        <= RX_SG_FETCH0;
                            end
                        end else if (rx_wb_stb && i_m_wb_err) begin
                            rx_wb_cyc  <= 1'b0;
                            rx_wb_stb  <= 1'b0;
                            bus_req_rx <= 1'b0;
                            rx_err     <= 1'b1;
                            rx_fsm     <= RX_DONE_ST;
                        end
                    end
                end

                RX_DONE_ST: begin
                    rx_busy <= 1'b0;
                    rx_done <= 1'b1;
                    rx_fsm  <= RX_IDLE;
                end
            endcase
        end
    end

    // =========================================================================
    // Status & Interrupt Signals
    // =========================================================================
    assign o_dma_status = {
        rx_fsm,             // [31:28] RX FSM State
        tx_fsm,             // [27:24] TX FSM State
        17'd0,              // [23:7] Reserved
        rx_err,             // [6] RX Bus Error
        rx_done,            // [5] RX Transfer Done
        rx_busy,            // [4] RX Busy
        1'b0,               // [3] Reserved
        tx_err,             // [2] TX Bus Error
        tx_done,            // [1] TX Transfer Done
        tx_busy             // [0] TX Busy
    };

    assign o_dma_irq = (i_dma_tx_irq_en && tx_done) ||
                       (i_dma_rx_irq_en && rx_done);

endmodule
