module top (
    input   wire            i_sys_clk,          // 50 MHz clock input (Pin V22)
    input   wire            i_sys_rst_n,        // S0 button, active-low reset (Pin AA13)
    output  wire    [7:0]   o_led,              // 8 PMOD LEDs on PMOD1
    output  wire            uart_tx             // UART TX to BL616 USB-Serial MCU (Pin U15)
);

wire [7:0] o_output;

ProtocolEmulator DUT (
    .i_clk      (i_sys_clk),
    .i_reset_n  (i_sys_rst_n),
    .i_data     (8'h00),
    .o_data     (o_output)
);

// Map bit 0 to physical UART TX pin and PMOD LED 0
assign uart_tx  = o_output[0];
assign o_led    = o_output;

endmodule
