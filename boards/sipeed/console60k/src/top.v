module top (
    input   wire            i_sys_clk,          // 50 MHz clock input (Pin V22)
    input   wire            i_sys_rst_n,        // S0 button, active-low reset (Pin AA13)
    input   wire            uart_rx,            // UART RX input on Pin V14 (BL616 TX -> FPGA RX)
    output  wire    [7:0]   o_led,              // 8 PMOD LEDs on PMOD1 (displays received ASCII byte)
    output  wire            uart_tx             // UART TX output on Pin U15 (FPGA TX -> BL616 RX)
);

wire [7:0] o_output;
wire       core_tx;

ProtocolEmulator DUT (
    .i_clk      (i_sys_clk),
    .i_reset_n  (i_sys_rst_n),
    .i_rx       (uart_rx),
    .i_data     (8'h00),
    .o_tx       (core_tx),
    .o_data     (o_output)
);

assign uart_tx = core_tx;
assign o_led   = o_output; // Displays isr[7:0] (active received ASCII byte)

endmodule

