module top (
    input   wire            i_sys_clk,          // 50 MHz clock input (Pin V22)
    input   wire            i_sys_rst_n,        // S0 button, active-low reset (Pin AA13)
    input   wire            uart_rx,            // UART RX input on Pin V14 (BL616 TX -> FPGA RX)
    output  wire    [7:0]   o_led,              // 8 PMOD LEDs on PMOD1
    output  wire            uart_tx,            // UART TX output on Pin U15 (FPGA TX -> BL616 RX)
    // SPI pins (PMOD2) - exposed for external SPI slave connection
    output  wire            spi_sck,            // SPI Clock  (drives o_spi_sck)
    output  wire            spi_mosi,           // SPI MOSI   (same as core TX)
    output  wire            spi_cs_n            // SPI CS_n   (drives o_spi_cs_n)
    // spi_miso is looped back internally from spi_mosi for loopback test
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
    wire [7:0]  spi_data;     // SPI data byte from bootloader 'D' command -> PULL

    // SPI wires
    wire        core_sck;         // o_spi_sck from ProtocolEmulator
    wire        core_cs_n;        // o_spi_cs_n from ProtocolEmulator
    // Internal SPI loopback: MISO = MOSI (no physical jumper needed for loopback test)
    // core_tx (MOSI) is looped back as the MISO input to the PE core.
    // For external SPI slaves: replace spi_miso_in with a real MISO input pin.
    wire        spi_miso_in = core_tx;  // loopback: MOSI -> MISO

    assign spi_sck  = core_sck;
    assign spi_mosi = core_tx;
    assign spi_cs_n = core_cs_n;

    ProtocolEmulator DUT (
        .i_clk        (i_sys_clk),
        .i_reset_n    (sys_rst_n),
        .i_rx         (spi_miso_in),   // MISO input: internal loopback from MOSI
        .i_data       (spi_data),      // SPI TX byte from bootloader 'D' command
        .o_tx         (core_tx),
        .o_data       (core_data),
        .i_baud_div   (baud_div),
        .o_spi_sck    (core_sck),
        .o_spi_cs_n   (core_cs_n),
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
        .o_data_reg   (spi_data),
        .o_prog_en    (prog_en),
        .o_prog_we    (prog_we),
        .o_prog_addr  (prog_addr),
        .o_prog_data  (prog_wdata),
        .i_prog_rdata (prog_rdata)
    );

    // TX output mux: Bootloader controls TX when programming; Core controls TX during normal execution
    assign uart_tx = prog_active ? bootloader_tx : core_tx;

    // PMOD LEDs:
    // LED 7: CS_n active (SPI transaction in progress)
    // LED 6: SCK (SPI clock visible on LED)
    // LED 5: Programming Mode active
    // LED 4..0: address during programming, or full byte during normal execution
    assign o_led = prog_active ? {1'b0, 1'b0, 1'b1, 2'b00, prog_addr[4:0]} :
                                 {!core_cs_n, core_sck, 1'b0, core_data[4:0]};

endmodule

