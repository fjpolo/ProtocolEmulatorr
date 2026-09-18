module top (
    input   wire            i_sys_clk,          // 50 MHz clock input (Pin V22)
    input   wire            i_sys_rst_n,        // S0 button, active-low reset (Pin AA13)
    input   wire            i_btn_s1_n,         // S1 button, active-low reset (Pin AB13)
    output  wire    [7:0]   o_led,              // 8 LEDs on Top PMOD (PMOD1)
    output  wire            uart_tx             // UART TX to BL616 USB-Serial MCU (Pin U15)
);

// Reset is active-low: pressing EITHER S0 or S1 resets the engine
wire rst_n = i_sys_rst_n & i_btn_s1_n;

// Heartbeat counter (~1.5 Hz blink on 50 MHz clock)
reg [24:0] hb_cnt = 25'd0;
always @(posedge i_sys_clk) begin
    hb_cnt <= hb_cnt + 25'd1;
end

wire [7:0] o_output;

ProtocolEmulator DUT (
    .i_clk      (i_sys_clk),
    .i_reset_n  (rst_n),
    .i_data     (8'h00),
    .o_data     (o_output)
);

// Physical UART TX to BL616 MCU
assign uart_tx = o_output[0];

// Top PMOD (PMOD1) LED mapping:
// [7] (W19): Heartbeat (~1.5 Hz blink proves 50 MHz clock is alive)
// [6] (W20): Run indicator (solid ON when active, OFF when in reset)
// [5] (F19): Reset active indicator (lights up when S0 or S1 is pressed)
// [4:1]    : ProtocolEmulator live PC state
// [0] (D21): UART TX activity (matches serial data stream)
assign o_led[7]   = hb_cnt[24];
assign o_led[6]   = rst_n;
assign o_led[5]   = ~rst_n;
assign o_led[4:1] = o_output[4:1];
assign o_led[0]   = o_output[0];

endmodule
