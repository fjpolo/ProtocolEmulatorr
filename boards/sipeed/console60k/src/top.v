module top (
    input   wire            i_sys_clk,          // 50 MHz clock input (Pin V22)
    input   wire            i_sys_rst_n,        // S0 button, active-low reset (Pin AA13)
    output  wire    [7:0]   o_led               // 8 PMOD LEDs on PMOD1
);

// module ProtocolEmulator(
//     input   wire    [0:0]   i_clk,
//     input   wire    [0:0]   i_reset_n,
//     input   wire    [7:0]   i_data,
//     output  reg     [7:0]   o_data
// );
wire [7:0] o_output;
ProtocolEmulator DUT(
    .i_clk(i_sys_clk),
    .i_reset_n(i_sys_rst_n),
    .i_data(8'h00),     // Example input data, modify as needed
    .o_data(o_output)   // Connect output to LED pins
);
assign o_led = o_output; // Assign 8 bits to the PMOD1 LED output

/*
// Manta Logic Analyzer instantiation placeholder
// Note: To use this, add the generated manta_core.v to your project file list,
// and make sure to add uart_rx and uart_tx to top ports and constraints (.cst).
wire uart_rx; // Map to physical RX pin (Pin V14) in physical constraints (.cst)
wire uart_tx; // Map to physical TX pin (Pin U15) in physical constraints (.cst)

manta my_manta (
    .clk(i_sys_clk),
    .rx(uart_rx),
    .tx(uart_tx),
    .la_core_i_reset_n(i_sys_rst_n),
    .la_core_i_data(DUT.i_data),
    .la_core_o_data(o_output)
);
*/

endmodule
