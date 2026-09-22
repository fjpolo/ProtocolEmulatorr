// =============================================================================
// File        : omnibus_fifo.v
// Module      : omnibus_fifo
// Description : Parameterized First-Word Fall-Through (FWFT) Circular FIFO
//               with programmable depth, watermarks, and level tracking.
// License     : MIT License
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module omnibus_fifo #(
    parameter integer DATA_WIDTH          = 8,
    parameter integer DEPTH               = 16,
    parameter integer ALMOST_FULL_THRESH  = DEPTH - 2,
    parameter integer ALMOST_EMPTY_THRESH = 2
)(
    input  wire                   i_clk,
    input  wire                   i_rst_n,
    input  wire                   i_clear,

    // Write / Push Interface
    input  wire                   i_push,
    input  wire [DATA_WIDTH-1:0]  i_data,
    output wire                   o_full,
    output wire                   o_almost_full,

    // Read / Pop Interface (First-Word Fall-Through)
    input  wire                   i_pop,
    output wire [DATA_WIDTH-1:0]  o_data,
    output wire                   o_empty,
    output wire                   o_almost_empty,

    // Status
    output wire [$clog2(DEPTH):0] o_level
);

    localparam integer ADDR_WIDTH = $clog2(DEPTH);

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [ADDR_WIDTH-1:0] wr_ptr;
    reg [ADDR_WIDTH-1:0] rd_ptr;
    reg [ADDR_WIDTH:0]   count;

    assign o_empty        = (count == {(ADDR_WIDTH+1){1'b0}});
    assign o_full         = (count == DEPTH);
    assign o_almost_full  = (count >= ALMOST_FULL_THRESH);
    assign o_almost_empty = (count <= ALMOST_EMPTY_THRESH && !o_empty);
    assign o_level        = count;

    // First-Word Fall-Through: data at read pointer is immediately available
    assign o_data = mem[rd_ptr];

    wire push_valid = i_push && !o_full;
    wire pop_valid  = i_pop && !o_empty;

    integer idx;
    initial begin
        wr_ptr = {ADDR_WIDTH{1'b0}};
        rd_ptr = {ADDR_WIDTH{1'b0}};
        count  = {(ADDR_WIDTH+1){1'b0}};
        for (idx = 0; idx < DEPTH; idx = idx + 1) begin
            mem[idx] = {DATA_WIDTH{1'b0}};
        end
    end

    always @(posedge i_clk) begin
        if (!i_rst_n || i_clear) begin
            wr_ptr <= {ADDR_WIDTH{1'b0}};
            rd_ptr <= {ADDR_WIDTH{1'b0}};
            count  <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            // Memory write
            if (push_valid) begin
                mem[wr_ptr] <= i_data;
                wr_ptr      <= (wr_ptr == DEPTH - 1) ? {ADDR_WIDTH{1'b0}} : wr_ptr + 1'b1;
            end

            // Memory read pointer
            if (pop_valid) begin
                rd_ptr <= (rd_ptr == DEPTH - 1) ? {ADDR_WIDTH{1'b0}} : rd_ptr + 1'b1;
            end

            // Count tracking
            case ({push_valid, pop_valid})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end

endmodule
