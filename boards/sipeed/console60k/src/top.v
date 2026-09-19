module top (
    input   wire            i_sys_clk,          // 50 MHz clock input (Pin V22)
    input   wire            i_sys_rst_n,        // S0 button, active-low reset (Pin AA13)
    output  wire    [7:0]   o_led,              // 8 PMOD LEDs on PMOD1
    output  wire            uart_tx,            // UART TX attempt on U15
    output  wire            uart_tx_v14         // UART TX attempt on V14
);

wire [7:0] o_output;

ProtocolEmulator DUT (
    .i_clk      (i_sys_clk),
    .i_reset_n  (i_sys_rst_n),
    .i_data     (8'h55), // Transmit 'U' (0x55) over 115200 baud UART
    .o_data     (o_output)
);

// Drive TX on both candidate pins -- one of them reaches the BL616
assign uart_tx     = o_output[0];
assign uart_tx_v14 = o_output[0];
assign o_led       = o_output;

endmodule

