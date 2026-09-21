module top (
    input   wire            i_sys_clk,          // 50 MHz clock input (Pin V22)
    input   wire            i_sys_rst_n,        // S0 button, active-low reset (Pin AA13)
    input   wire            uart_rx,            // UART RX input on Pin V14 (BL616 TX -> FPGA RX)
    output  wire    [7:0]   o_led,              // 8 PMOD LEDs on PMOD1
    output  wire            uart_tx             // UART TX output on Pin U15 (FPGA TX -> BL616 RX)
);

    wire [7:0]  core_data;
    wire        core_tx;

    // Power-on Reset Generator (guarantees 64-cycle clean reset upon bitstream load)
    reg [5:0] por_cnt = 6'd0;
    wire por_rst_n = (por_cnt == 6'd63);
    always @(posedge i_sys_clk) begin
        if (!por_rst_n) begin
            por_cnt <= por_cnt + 6'd1;
        end
    end
    wire sys_rst_n = i_sys_rst_n && por_rst_n;

    // Programming interface wires between Bootloader and Core
    wire        prog_en;
    wire        prog_we;
    wire [4:0]  prog_addr;
    wire [15:0] prog_wdata;
    wire [15:0] prog_rdata;
    wire        bootloader_tx;
    wire        prog_active;
    wire [15:0] baud_div;     // Runtime baud divisor from bootloader

    ProtocolEmulator DUT (
        .i_clk        (i_sys_clk),
        .i_reset_n    (sys_rst_n),
        .i_rx         (uart_rx),
        .i_data       (8'h00),
        .o_tx         (core_tx),
        .o_data       (core_data),
        .i_baud_div   (baud_div),
        .i_prog_en    (prog_en),
        .i_prog_we    (prog_we),
        .i_prog_addr  (prog_addr),
        .i_prog_data  (prog_wdata),
        .o_prog_rdata (prog_rdata)
    );

    OmniBootloader #(
        .CLK_FREQ_HZ  (50_000_000),
        .BAUD_RATE    (115_200)
    ) bootloader (
        .i_clk        (i_sys_clk),
        .i_reset_n    (sys_rst_n),
        .i_rx         (uart_rx),
        .o_tx         (bootloader_tx),
        .o_prog_active(prog_active),
        .o_baud_div   (baud_div),
        .o_prog_en    (prog_en),
        .o_prog_we    (prog_we),
        .o_prog_addr  (prog_addr),
        .o_prog_data  (prog_wdata),
        .i_prog_rdata (prog_rdata)
    );

    // TX output mux: Bootloader controls TX when programming; Core controls TX during normal execution
    assign uart_tx = prog_active ? bootloader_tx : core_tx;

    // PMOD LEDs:
    // LED 7 indicates Programming Mode is active (lights up during programming!)
    // LEDs 4..0 indicate address during programming, or full byte during normal execution
    assign o_led   = prog_active ? {1'b1, 2'b00, prog_addr[4:0]} : core_data;

endmodule

