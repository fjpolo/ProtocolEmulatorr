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
    wire [6:0]  prog_addr;
    wire [15:0] prog_wdata;
    wire [15:0] prog_rdata;
    wire        bootloader_tx;
    wire        prog_active;
    wire [15:0] baud_div;     // Runtime baud divisor from bootloader
    wire [7:0]  spi_data;     // SPI data byte from bootloader 'D' command -> PULL

    // SPI wires
    wire        core_sck;         // o_spi_sck from ProtocolEmulator
    wire        core_cs_n;        // o_spi_cs_n from ProtocolEmulator

    assign spi_sck  = core_sck;
    assign spi_mosi = core_tx;
    assign spi_cs_n = core_cs_n;

    // Core RX input routing:
    // When SPI transaction is active (!core_cs_n), MISO is internally looped back from MOSI (core_tx).
    // When SPI is idle (core_cs_n == 1), RX is connected to the board UART RX pin (uart_rx on Pin V14).
    wire spi_active = !core_cs_n;
    wire core_rx_in = spi_active ? core_tx : uart_rx;

    // 8-bit GPIO bus from ProtocolEmulator
    wire [7:0]  core_gpio_out;
    wire [7:0]  core_gpio_oe;
    wire [7:0]  core_gpio_in;

    // -------------------------------------------------------------------------
    // I2C Loopback Stub on GPIO 4 (SDA) and GPIO 1 (SCL)
    // -------------------------------------------------------------------------
    wire slave_sda_drive;
    wire slave_ack_pulse;

    // SCL wire (Pin 1): 0 when master drives low, 1 when released (pull-up)
    wire scl_wire = !(core_gpio_oe[1] && !core_gpio_out[1]);

    // SDA wire (Pin 4): 0 when master drives low OR slave pulls low (ACK), 1 when both release
    wire sda_wire = !( (core_gpio_oe[4] && !core_gpio_out[4]) || slave_sda_drive );

    I2CSlaveStub i2c_slave (
        .i_clk       (i_sys_clk),
        .i_reset_n   (sys_rst_n),
        .i_scl       (scl_wire),
        .i_sda       (sda_wire),
        .o_sda_drive (slave_sda_drive),
        .o_ack_pulse (slave_ack_pulse)
    );

    assign core_gpio_in[0] = core_rx_in;
    assign core_gpio_in[1] = scl_wire;
    assign core_gpio_in[2] = 1'b1;
    assign core_gpio_in[3] = core_tx; // Dedicated MISO loopback pin (Pin 3)
    assign core_gpio_in[4] = sda_wire;
    assign core_gpio_in[5] = 1'b1;
    assign core_gpio_in[6] = 1'b1;
    assign core_gpio_in[7] = 1'b1;

    wire        bist_active;
    wire        bist_fail_flag;
    wire [3:0]  bist_stage;

    ProtocolEmulator DUT (
        .i_clk        (i_sys_clk),
        .i_reset_n    (sys_rst_n),
        .i_data       (spi_data),
        .o_data       (core_data),
        .i_tx_valid   (1'b1),
        .o_tx_pop     (),
        .i_rx_full    (1'b0),
        .o_rx_push    (),
        .i_baud_div   (baud_div),
        .i_gpio       (core_gpio_in),
        .o_gpio       (core_gpio_out),
        .o_gpio_oe    (core_gpio_oe),
        .i_rx         (core_rx_in),
        .o_tx         (core_tx),
        .o_spi_sck    (core_sck),
        .o_spi_cs_n   (core_cs_n),
        .i_prog_en    (prog_en),
        .i_prog_we    (prog_we),
        .i_prog_addr  (prog_addr),
        .i_prog_data  (prog_wdata),
        .o_prog_rdata (prog_rdata),
        // Task 27 Profiler
        .i_profiler_wb_arm   (1'b0),
        .i_profiler_wb_stop  (1'b0),
        .i_profiler_wb_rst   (1'b0),
        .i_profiler_wb_pin   (3'd0),
        .i_profiler_wb_filter(4'd0),
        .o_profiler_busy     (),
        .o_profiler_done     (),
        .o_profiler_idle_pol (),
        .o_profiler_is_clock (),
        .o_profiler_proto_id (),
        .o_profiler_edges    (),
        .o_profiler_tmin     (),
        .o_profiler_tmax     (),
        .o_profiler_tmin_high(),
        .o_profiler_tmin_low (),
        // Task 28 USB SIE
        .i_usb_wb_sie_en          (1'b0),
        .i_usb_wb_speed_mode      (1'b0),
        .i_usb_wb_auto_ack        (1'b0),
        .i_usb_wb_dev_addr        (7'd0),
        .i_usb_wb_bit_div         (16'd4),
        .i_usb_wb_ep_stall        (4'd0),
        .i_usb_wb_ep_nak          (4'd0),
        .i_usb_wb_ep_toggle       (4'd0),
        .i_usb_wb_tx_token_req    (1'b0),
        .i_usb_wb_tx_token_pid    (4'd0),
        .i_usb_wb_tx_token_addr   (7'd0),
        .i_usb_wb_tx_token_endp   (4'd0),
        .i_usb_wb_tx_handshake_req(1'b0),
        .i_usb_wb_tx_handshake_pid(4'd0),
        .o_usb_status_byte        (),
        .o_usb_token_pid          (),
        .o_usb_token_endp         (),
        .o_usb_token_addr         (),
        .o_usb_rx_pid             (),
        .o_usb_bus_reset          (),
        .o_usb_bus_idle           (),
        // Task 29 BIST
        .i_bist_wb_en           (1'b0),
        .i_bist_wb_mode         (2'd0),
        .i_bist_wb_jitter_en    (1'b0),
        .i_bist_wb_start        (1'b0),
        .i_bist_wb_stop         (1'b0),
        .i_bist_wb_rst          (1'b0),
        .i_bist_wb_stage        (4'd0),
        .o_bist_active          (bist_active),
        .o_bist_fail_flag       (bist_fail_flag),
        .o_bist_mode            (),
        .o_bist_stage           (bist_stage),
        .o_bist_vec_cnt         (),
        .o_bist_pass_cnt        (),
        .o_bist_fail_cnt        ()
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
    // LED 7: CS_n active (SPI transaction in progress) or BIST fail flag
    // LED 6..4: SCK, ACK, core data OR BIST stage / activity
    // Normal execution: {!core_cs_n, core_sck, slave_ack_pulse, core_data[4:0]}
    assign o_led = prog_active ? {1'b1, prog_addr[6:0]} :
                   bist_active ? {bist_fail_flag, bist_stage[2:0], bist_active, core_gpio_out[2:0]} :
                                 {!core_cs_n, core_sck, slave_ack_pulse, core_data[4:0]};

endmodule
