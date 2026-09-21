// =============================================================================
// File        : OmniBootloader.v
// Module      : OmniBootloader
// Description : In-band UART microcode bootloader for the OmniBus architecture.
//               Enables runtime loading, verification, and execution of microcode
//               at 115200 baud on a 50 MHz system clock without FPGA re-synthesis.
//               Supports runtime baud rate divisor configuration via 'B' command.
//               Task 07B: 'D' command sets i_data byte for PULL-based SPI programs.
// License     : MIT License
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module OmniBootloader #(
    parameter CLK_FREQ_HZ = 50_000_000,
    parameter BAUD_RATE   = 115_200
)(
    input   wire            i_clk,
    input   wire            i_reset_n,
    input   wire            i_rx,
    output  wire            o_tx,
    output  wire            o_prog_active,

    // Runtime baud divisor output → drives ProtocolEmulator.i_baud_div
    output  wire    [15:0]  o_baud_div,

    // SPI data register output → drives ProtocolEmulator.i_data
    // Updated by 'D' command: host sends 'D' <byte> to set the byte for PULL.
    output  wire    [7:0]   o_data_reg,

    // Interface to ProtocolEmulator IMEM
    output  wire            o_prog_en,
    output  reg             o_prog_we,
    output  reg     [4:0]   o_prog_addr,
    output  reg     [15:0]  o_prog_data,
    input   wire    [15:0]  i_prog_rdata
);

    localparam integer CYCLES_PER_BIT  = CLK_FREQ_HZ / BAUD_RATE; // 434 cycles
    localparam integer HALF_BIT_CYCLES = CYCLES_PER_BIT / 2;      // 217 cycles

    // -------------------------------------------------------------------------
    // 1. Synchronizer & UART RX Deserializer
    // -------------------------------------------------------------------------
    reg rx_sync_0, rx_sync_1;
    always @(posedge i_clk) begin
        if (!i_reset_n) begin
            rx_sync_0 <= 1'b1;
            rx_sync_1 <= 1'b1;
        end else begin
            rx_sync_0 <= i_rx;
            rx_sync_1 <= rx_sync_0;
        end
    end
    wire rx_in = rx_sync_1;

    localparam [1:0]
        RX_IDLE  = 2'd0,
        RX_START = 2'd1,
        RX_DATA  = 2'd2,
        RX_STOP  = 2'd3;

    reg [1:0]  rx_state;
    reg [15:0] rx_clk_cnt;
    reg [2:0]  rx_bit_idx;
    reg [7:0]  rx_shift;
    reg [7:0]  rx_byte;
    reg        rx_valid;

    always @(posedge i_clk) begin
        if (!i_reset_n) begin
            rx_state   <= RX_IDLE;
            rx_clk_cnt <= 16'd0;
            rx_bit_idx <= 3'd0;
            rx_shift   <= 8'd0;
            rx_byte    <= 8'd0;
            rx_valid   <= 1'b0;
        end else begin
            rx_valid <= 1'b0;
            case (rx_state)
                RX_IDLE: begin
                    rx_clk_cnt <= 16'd0;
                    rx_bit_idx <= 3'd0;
                    if (rx_in == 1'b0) begin // Start bit falling edge
                        rx_state <= RX_START;
                    end
                end

                RX_START: begin
                    if (rx_clk_cnt == HALF_BIT_CYCLES - 1) begin
                        if (rx_in == 1'b0) begin // Midpoint of start bit
                            rx_clk_cnt <= 16'd0;
                            rx_state   <= RX_DATA;
                        end else begin
                            rx_state   <= RX_IDLE; // False start glitch
                        end
                    end else begin
                        rx_clk_cnt <= rx_clk_cnt + 16'd1;
                    end
                end

                RX_DATA: begin
                    if (rx_clk_cnt == CYCLES_PER_BIT - 1) begin
                        rx_clk_cnt <= 16'd0;
                        rx_shift   <= {rx_in, rx_shift[7:1]};
                        if (rx_bit_idx == 3'd7) begin
                            rx_state <= RX_STOP;
                        end else begin
                            rx_bit_idx <= rx_bit_idx + 3'd1;
                        end
                    end else begin
                        rx_clk_cnt <= rx_clk_cnt + 16'd1;
                    end
                end

                RX_STOP: begin
                    if (rx_clk_cnt == CYCLES_PER_BIT - 1) begin
                        rx_byte  <= rx_shift;
                        rx_valid <= 1'b1;
                        rx_state <= RX_IDLE;
                    end else begin
                        rx_clk_cnt <= rx_clk_cnt + 16'd1;
                    end
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // 2. Single-Byte UART TX Serializer
    // -------------------------------------------------------------------------
    reg        tx_reg;
    assign o_tx = tx_reg;

    reg [7:0]  tx_data_byte;
    reg        tx_start_req;
    reg        tx_busy;

    localparam [1:0]
        TX_IDLE  = 2'd0,
        TX_START = 2'd1,
        TX_DATA  = 2'd2,
        TX_STOP  = 2'd3;

    reg [1:0]  tx_state;
    reg [15:0] tx_clk_cnt;
    reg [2:0]  tx_bit_idx;
    reg [7:0]  tx_shift;

    always @(posedge i_clk) begin
        if (!i_reset_n) begin
            tx_reg     <= 1'b1;
            tx_busy    <= 1'b0;
            tx_state   <= TX_IDLE;
            tx_clk_cnt <= 16'd0;
            tx_bit_idx <= 3'd0;
            tx_shift   <= 8'd0;
        end else begin
            case (tx_state)
                TX_IDLE: begin
                    tx_reg     <= 1'b1;
                    tx_clk_cnt <= 16'd0;
                    tx_bit_idx <= 3'd0;
                    if (tx_start_req) begin
                        tx_shift <= tx_data_byte;
                        tx_busy  <= 1'b1;
                        tx_state <= TX_START;
                    end else begin
                        tx_busy  <= 1'b0;
                    end
                end

                TX_START: begin
                    tx_reg <= 1'b0; // Start bit
                    if (tx_clk_cnt == CYCLES_PER_BIT - 1) begin
                        tx_clk_cnt <= 16'd0;
                        tx_state   <= TX_DATA;
                    end else begin
                        tx_clk_cnt <= tx_clk_cnt + 16'd1;
                    end
                end

                TX_DATA: begin
                    tx_reg <= tx_shift[0]; // LSB first
                    if (tx_clk_cnt == CYCLES_PER_BIT - 1) begin
                        tx_clk_cnt <= 16'd0;
                        tx_shift   <= {1'b0, tx_shift[7:1]};
                        if (tx_bit_idx == 3'd7) begin
                            tx_state <= TX_STOP;
                        end else begin
                            tx_bit_idx <= tx_bit_idx + 3'd1;
                        end
                    end else begin
                        tx_clk_cnt <= tx_clk_cnt + 16'd1;
                    end
                end

                TX_STOP: begin
                    tx_reg <= 1'b1; // Stop bit
                    if (tx_clk_cnt == CYCLES_PER_BIT - 1) begin
                        tx_clk_cnt <= 16'd0;
                        tx_bit_idx <= 3'd0;
                        tx_busy    <= 1'b0;
                        tx_state   <= TX_IDLE;
                    end else begin
                        tx_clk_cnt <= tx_clk_cnt + 16'd1;
                    end
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // 3. Command Parser & Response Sequencer FSM
    // -------------------------------------------------------------------------
    localparam [3:0]
        CMD_IDLE        = 4'd0,
        CMD_WAIT_OP     = 4'd1,
        CMD_W_ADDR      = 4'd2,
        CMD_W_DATA_HI   = 4'd3,
        CMD_W_DATA_LO   = 4'd4,
        CMD_R_ADDR      = 4'd5,
        CMD_R_SETTLE    = 4'd6,
        CMD_SEND_RESP   = 4'd7,
        CMD_EXIT_MODE   = 4'd8,
        CMD_B_HI        = 4'd9,   // SetBaud: receive baud_div MSB
        CMD_B_LO        = 4'd10,  // SetBaud: receive baud_div LSB
        CMD_D_BYTE      = 4'd11;  // SetData: receive 1 data byte -> data_reg

    reg [3:0] cmd_state;
    reg [1:0] token_step;
    reg [7:0] data_hi_reg;
    reg       prog_active_reg;

    // Runtime baud rate divisor register (default: 433 = 115200 baud @ 50 MHz)
    reg [15:0] baud_div;
    assign o_baud_div = baud_div;

    // SPI data register: holds byte for ProtocolEmulator PULL instruction
    reg [7:0] spi_data_reg;
    assign o_data_reg = spi_data_reg;

    // Response buffer
    reg [7:0] resp_bytes [0:7];
    reg [2:0] resp_len;
    reg [2:0] resp_idx;
    reg [3:0] next_cmd_state;

    assign o_prog_active = prog_active_reg;
    assign o_prog_en     = prog_active_reg;

    always @(posedge i_clk) begin
        if (!i_reset_n) begin
            prog_active_reg <= 1'b0;
            o_prog_we       <= 1'b0;
            o_prog_addr     <= 5'd0;
            o_prog_data     <= 16'd0;
            cmd_state       <= CMD_IDLE;
            token_step      <= 2'd0;
            data_hi_reg     <= 8'd0;
            tx_data_byte    <= 8'd0;
            tx_start_req    <= 1'b0;
            resp_len        <= 3'd0;
            resp_idx        <= 3'd0;
            next_cmd_state  <= CMD_IDLE;
            baud_div        <= 16'd433; // Default: 115200 baud @ 50 MHz
            spi_data_reg    <= 8'd0;    // Default data byte = 0x00
        end else begin
            o_prog_we    <= 1'b0; // 1-cycle default pulse
            tx_start_req <= 1'b0;

            case (cmd_state)
                CMD_IDLE: begin
                    prog_active_reg <= 1'b0;

                    if (rx_valid) begin
                        // Match 3-byte token: 0xAA -> 0x55 -> 0x50 ('P')
                        if (token_step == 2'd0) begin
                            if (rx_byte == 8'hAA) token_step <= 2'd1;
                            else token_step <= 2'd0;
                        end else if (token_step == 2'd1) begin
                            if (rx_byte == 8'h55) token_step <= 2'd2;
                            else if (rx_byte == 8'hAA) token_step <= 2'd1;
                            else token_step <= 2'd0;
                        end else if (token_step == 2'd2) begin
                            if (rx_byte == 8'h50) begin // 'P'
                                // ENTER PROGRAMMING MODE!
                                prog_active_reg <= 1'b1;
                                token_step      <= 2'd0;

                                // Load response: ACK + "OK\r\n"
                                resp_bytes[0]  <= 8'h06; // ACK
                                resp_bytes[1]  <= 8'h4F; // 'O'
                                resp_bytes[2]  <= 8'h4B; // 'K'
                                resp_bytes[3]  <= 8'h0D; // '\r'
                                resp_bytes[4]  <= 8'h0A; // '\n'
                                resp_len       <= 3'd5;
                                resp_idx       <= 3'd0;
                                next_cmd_state <= CMD_WAIT_OP;
                                cmd_state      <= CMD_SEND_RESP;
                            end else if (rx_byte == 8'hAA) begin
                                token_step <= 2'd1;
                            end else begin
                                token_step <= 2'd0;
                            end
                        end
                    end
                end

                CMD_WAIT_OP: begin
                    if (rx_valid) begin
                        case (rx_byte)
                            8'h57: cmd_state <= CMD_W_ADDR;    // 'W' = Write IMEM
                            8'h52: cmd_state <= CMD_R_ADDR;    // 'R' = Read IMEM
                            8'h42: cmd_state <= CMD_B_HI;      // 'B' = SetBaud divisor
                            8'h44: cmd_state <= CMD_D_BYTE;    // 'D' = SetData byte
                            8'h58: begin                      // 'X' = Exit / Run
                                // Load response: ACK + "RUN\r\n"
                                resp_bytes[0]  <= 8'h06; // ACK
                                resp_bytes[1]  <= 8'h52; // 'R'
                                resp_bytes[2]  <= 8'h55; // 'U'
                                resp_bytes[3]  <= 8'h4E; // 'N'
                                resp_bytes[4]  <= 8'h0D; // '\r'
                                resp_bytes[5]  <= 8'h0A; // '\n'
                                resp_len       <= 3'd6;
                                resp_idx       <= 3'd0;
                                next_cmd_state <= CMD_EXIT_MODE;
                                cmd_state      <= CMD_SEND_RESP;
                            end
                            default: cmd_state <= CMD_WAIT_OP;
                        endcase
                    end
                end

                CMD_W_ADDR: begin
                    if (rx_valid) begin
                        o_prog_addr <= rx_byte[4:0];
                        cmd_state   <= CMD_W_DATA_HI;
                    end
                end

                CMD_W_DATA_HI: begin
                    if (rx_valid) begin
                        data_hi_reg <= rx_byte;
                        cmd_state   <= CMD_W_DATA_LO;
                    end
                end

                CMD_W_DATA_LO: begin
                    if (rx_valid) begin
                        o_prog_data <= {data_hi_reg, rx_byte};
                        o_prog_we   <= 1'b1; // Pulse write enable

                        // Reply ACK + echo written address
                        resp_bytes[0]  <= 8'h06; // ACK
                        resp_bytes[1]  <= {3'b0, o_prog_addr};
                        resp_len       <= 3'd2;
                        resp_idx       <= 3'd0;
                        next_cmd_state <= CMD_WAIT_OP;
                        cmd_state      <= CMD_SEND_RESP;
                    end
                end

                CMD_R_ADDR: begin
                    if (rx_valid) begin
                        o_prog_addr <= rx_byte[4:0];
                        cmd_state   <= CMD_R_SETTLE;
                    end
                end

                CMD_R_SETTLE: begin
                    // Read data is now settled from i_prog_rdata
                    resp_bytes[0]  <= 8'h06; // ACK
                    resp_bytes[1]  <= i_prog_rdata[15:8];
                    resp_bytes[2]  <= i_prog_rdata[7:0];
                    resp_len       <= 3'd3;
                    resp_idx       <= 3'd0;
                    next_cmd_state <= CMD_WAIT_OP;
                    cmd_state      <= CMD_SEND_RESP;
                end

                CMD_SEND_RESP: begin
                    if (!tx_busy && !tx_start_req) begin
                        if (resp_idx < resp_len) begin
                            tx_data_byte <= resp_bytes[resp_idx];
                            tx_start_req <= 1'b1;
                            resp_idx     <= resp_idx + 3'd1;
                        end else begin
                            cmd_state <= next_cmd_state;
                        end
                    end
                end

                CMD_EXIT_MODE: begin
                    prog_active_reg <= 1'b0;
                    cmd_state       <= CMD_IDLE;
                end

                CMD_B_HI: begin
                    // SetBaud: receive high byte of baud divisor
                    if (rx_valid) begin
                        data_hi_reg <= rx_byte;
                        cmd_state   <= CMD_B_LO;
                    end
                end

                CMD_B_LO: begin
                    // SetBaud: receive low byte, update baud_div, respond ACK
                    if (rx_valid) begin
                        baud_div       <= {data_hi_reg, rx_byte};
                        // Reply ACK + echo new divisor MSB + LSB
                        resp_bytes[0]  <= 8'h06;           // ACK
                        resp_bytes[1]  <= data_hi_reg;     // div[15:8]
                        resp_bytes[2]  <= rx_byte;         // div[7:0]
                        resp_len       <= 3'd3;
                        resp_idx       <= 3'd0;
                        next_cmd_state <= CMD_WAIT_OP;
                        cmd_state      <= CMD_SEND_RESP;
                    end
                end

                CMD_D_BYTE: begin
                    // SetData: receive 1 byte, store in spi_data_reg for PULL access
                    // Reply ACK + echo the byte back
                    if (rx_valid) begin
                        spi_data_reg   <= rx_byte;
                        resp_bytes[0]  <= 8'h06;   // ACK
                        resp_bytes[1]  <= rx_byte;  // echo
                        resp_len       <= 3'd2;
                        resp_idx       <= 3'd0;
                        next_cmd_state <= CMD_WAIT_OP;
                        cmd_state      <= CMD_SEND_RESP;
                    end
                end

                default: cmd_state <= CMD_IDLE;
            endcase
        end
    end

endmodule
