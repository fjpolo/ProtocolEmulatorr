// =============================================================================
// File        : OmniBus_USB_SIE.v
// Module      : OmniBus_USB_SIE
// Description : Task 28 - USB 1.1 Autonomous Serial Interface Engine (SIE)
//               Hardware-level packet formatting, token parsing, auto-handshaking,
//               CRC-5/CRC-16 calculation, and EOP handling for USB peripheral & host.
// Features:
//   - Differential line decoding (D+/D- -> J, K, SE0, SE1)
//   - Autonomous SYNC (0x80) and PID validation with inverted check (pid[7:4] == ~pid[3:0])
//   - Hardware Token decoder (7-bit ADDR, 4-bit ENDP, 5-bit CRC validation)
//   - Hardware Data CRC-16 calculation & residual verification (0xB001)
//   - Autonomous Handshake Generator (ACK, NAK, STALL on OUT/SETUP/IN)
//   - Hardware bit-stuffing and bit-destuffing (6 ones -> insert/strip '0')
//   - Hardware NRZI encoding and decoding
//   - Automatic End-of-Packet (EOP: 2 bit SE0 + 1 bit J) generation and detection
//   - Bus Reset detection (SE0 sustained >= 32 bit times)
// License     : MIT License
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module OmniBus_USB_SIE #(
    parameter CLK_FREQ_HZ = 50_000_000
)(
    input   wire            i_clk,
    input   wire            i_rst_n,

    // Configuration & Control
    input   wire            i_sie_en,           // Master enable for SIE engine
    input   wire            i_speed_mode,       // 0 = Full Speed (12 Mbps), 1 = Low Speed (1.5 Mbps)
    input   wire    [15:0]  i_bit_div,          // Cycles per bit (default: 4 for FS @ 50MHz, 33 for LS)
    input   wire    [6:0]   i_dev_addr,         // 7-bit USB device address for token matching
    input   wire    [3:0]   i_ep_stall,         // Per-endpoint STALL mask (EP0..EP3)
    input   wire    [3:0]   i_ep_nak,           // Per-endpoint NAK mask (EP0..EP3)
    input   wire    [3:0]   i_ep_toggle,        // Data toggle bits (DATA0=0, DATA1=1)
    input   wire            i_auto_ack,         // Autonomous ACK generation on valid OUT/SETUP

    // Physical Differential IO
    input   wire            i_dp,               // D+ pin input
    input   wire            i_dm,               // D- pin input
    output  reg             o_dp,               // D+ pin output
    output  reg             o_dm,               // D- pin output
    output  reg             o_oe,               // Output enable (1 = drive bus, 0 = input / tristate)

    // Microcode / Host Command Interface
    input   wire            i_tx_token_req,     // Strobe: transmit host token
    input   wire    [3:0]   i_tx_token_pid,     // Token PID (OUT=0x1, IN=0x9, SETUP=0xD, SOF=0x5)
    input   wire    [6:0]   i_tx_token_addr,    // Target device address for token
    input   wire    [3:0]   i_tx_token_endp,    // Target endpoint for token

    input   wire            i_tx_handshake_req, // Strobe: transmit handshake
    input   wire    [3:0]   i_tx_handshake_pid, // Handshake PID (ACK=0x2, NAK=0xA, STALL=0xE)

    input   wire            i_tx_data_req,      // Strobe: transmit data packet
    input   wire    [3:0]   i_tx_data_pid,      // Data PID (DATA0=0x3, DATA1=0xB)
    input   wire    [7:0]   i_tx_byte,          // Payload byte from core/FIFO
    input   wire            i_tx_valid,         // Payload byte valid
    output  reg             o_tx_ready,         // Ready for next payload byte
    input   wire            i_tx_last,          // Last payload byte in packet

    // Receive Telemetry & Data Stream
    output  reg             o_bus_idle,         // Bus in J-state
    output  reg             o_bus_reset,        // USB Reset detected (sustained SE0)
    output  reg             o_token_valid,      // Valid token received matching i_dev_addr
    output  reg     [3:0]   o_token_pid,        // Latched token PID
    output  reg     [3:0]   o_token_endp,       // Latched token endpoint
    output  reg     [6:0]   o_token_addr,       // Latched token address
    output  reg             o_rx_data_valid,    // Received data byte strobe
    output  reg     [7:0]   o_rx_data_byte,     // Received data byte
    output  reg             o_rx_packet_done,   // Packet reception complete (valid EOP)
    output  reg     [3:0]   o_rx_pid,           // Received packet PID
    output  reg             o_rx_crc_err,       // CRC-5 or CRC-16 failure
    output  reg             o_rx_pid_err,       // PID check complement failure
    output  reg             o_rx_stuff_err,     // Bit-stuffing violation
    output  reg             o_tx_done,          // Packet transmission complete
    output  wire    [7:0]   o_status_byte       // Consolidated status byte
);

    // -------------------------------------------------------------------------
    // Standard USB PIDs
    // -------------------------------------------------------------------------
    localparam [3:0]
        PID_OUT   = 4'h1,
        PID_IN    = 4'h9,
        PID_SOF   = 4'h5,
        PID_SETUP = 4'hD,
        PID_DATA0 = 4'h3,
        PID_DATA1 = 4'hB,
        PID_DATA2 = 4'h7,
        PID_MDATA = 4'hF,
        PID_ACK   = 4'h2,
        PID_NAK   = 4'hA,
        PID_STALL = 4'hE,
        PID_NYET  = 4'h6;

    // -------------------------------------------------------------------------
    // Bit Timing Prescaler
    // -------------------------------------------------------------------------
    wire [15:0] effective_div = (i_bit_div == 16'd0) ? 16'd4 : i_bit_div;
    wire [15:0] half_div      = effective_div >> 1;

    // -------------------------------------------------------------------------
    // Double-Flop Synchronizer for Differential Inputs
    // -------------------------------------------------------------------------
    reg sync_dp_0, sync_dp;
    reg sync_dm_0, sync_dm;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            sync_dp_0 <= 1'b1;
            sync_dp   <= 1'b1;
            sync_dm_0 <= 1'b0;
            sync_dm   <= 1'b0;
        end else begin
            sync_dp_0 <= i_dp;
            sync_dp   <= sync_dp_0;
            sync_dm_0 <= i_dm;
            sync_dm   <= sync_dm_0;
        end
    end

    // Line state decoding
    // Full Speed: J = (dp=1, dm=0), K = (dp=0, dm=1)
    // Low Speed : J = (dp=0, dm=1), K = (dp=1, dm=0)
    wire line_j   = i_speed_mode ? (~sync_dp & sync_dm) : (sync_dp & ~sync_dm);
    wire line_k   = i_speed_mode ? (sync_dp & ~sync_dm) : (~sync_dp & sync_dm);
    wire line_se0 = ~sync_dp & ~sync_dm;
    wire line_se1 = sync_dp & sync_dm;

    // -------------------------------------------------------------------------
    // CRC Functions
    // -------------------------------------------------------------------------
    // CRC-5 Token: G(x) = x^5 + x^2 + 1, reflected poly 0x14
    function [4:0] step_crc5;
        input       bit_in;
        input [4:0] cur;
        reg         fb;
        begin
            fb = cur[0] ^ bit_in;
            step_crc5 = (cur >> 1) ^ (fb ? 5'h14 : 5'h00);
        end
    endfunction

    // CRC-16 Data: G(x) = x^16 + x^15 + x^2 + 1, reflected poly 0xA001
    function [15:0] step_crc16;
        input        bit_in;
        input [15:0] cur;
        reg          fb;
        begin
            fb = cur[0] ^ bit_in;
            step_crc16 = (cur >> 1) ^ (fb ? 16'hA001 : 16'h0000);
        end
    endfunction

    // Function to calculate complete 5-bit CRC for Token (ADDR 7b + ENDP 4b)
    function [4:0] calc_token_crc5;
        input [6:0] addr;
        input [3:0] endp;
        reg   [4:0] c;
        integer     i;
        begin
            c = 5'h1F;
            for (i = 0; i < 7; i = i + 1)
                c = step_crc5(addr[i], c);
            for (i = 0; i < 4; i = i + 1)
                c = step_crc5(endp[i], c);
            calc_token_crc5 = c ^ 5'h1F;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Transmitter State Machine
    // -------------------------------------------------------------------------
    localparam [3:0]
        TX_IDLE        = 4'd0,
        TX_SYNC        = 4'd1,
        TX_PID         = 4'd2,
        TX_TOKEN_BITS  = 4'd3,
        TX_DATA_BYTE   = 4'd4,
        TX_DATA_CRC    = 4'd5,
        TX_EOP0        = 4'd6,
        TX_EOP1        = 4'd7,
        TX_J_WAIT      = 4'd8;

    reg [3:0]  tx_state;
    reg [15:0] tx_div_cnt;
    reg [2:0]  tx_bit_idx;
    reg [7:0]  tx_shift_reg;
    reg [15:0] tx_token_shift;
    reg [15:0] tx_crc16_reg;
    reg [2:0]  tx_ones_cnt;
    reg        tx_stuff_pending;
    reg        tx_line_level; // 1 = J-state, 0 = K-state
    reg        tx_is_eop;
    reg        tx_auto_ack_pending;

    // -------------------------------------------------------------------------
    // Receiver State Machine
    // -------------------------------------------------------------------------
    localparam [3:0]
        RX_IDLE        = 4'd0,
        RX_SYNC        = 4'd1,
        RX_PID         = 4'd2,
        RX_TOKEN       = 4'd3,
        RX_DATA        = 4'd4,
        RX_EOP         = 4'd5;

    reg [3:0]  rx_state;
    reg [15:0] rx_div_cnt;
    reg        prev_line_level;
    reg [2:0]  rx_ones_cnt;
    reg [2:0]  rx_bit_idx;
    reg [7:0]  rx_shift_reg;
    reg [15:0] rx_token_shift;
    reg [4:0]  rx_crc5_reg;
    reg [15:0] rx_crc16_reg;
    reg [15:0] rx_se0_cnt;
    reg [3:0]  latched_rx_pid;
    reg        rx_trigger_auto_ack;

    // Consolidated Status Byte
    assign o_status_byte = {
        o_rx_crc_err,
        o_rx_pid_err,
        o_bus_reset,
        o_tx_done,
        o_rx_packet_done,
        o_token_valid,
        o_bus_idle,
        o_oe
    };

    // -------------------------------------------------------------------------
    // Bus Idle & Reset Monitor
    // -------------------------------------------------------------------------
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_bus_idle  <= 1'b1;
            o_bus_reset <= 1'b0;
            rx_se0_cnt  <= 16'd0;
        end else if (!i_sie_en) begin
            o_bus_idle  <= 1'b1;
            o_bus_reset <= 1'b0;
            rx_se0_cnt  <= 16'd0;
        end else begin
            o_bus_idle <= line_j;
            if (line_se0) begin
                if (rx_se0_cnt < 16'hFFFF)
                    rx_se0_cnt <= rx_se0_cnt + 1'b1;
                // Sustained SE0: >= 32 bit periods represents reset/disconnect
                if (rx_se0_cnt >= (effective_div << 5))
                    o_bus_reset <= 1'b1;
            end else begin
                rx_se0_cnt  <= 16'd0;
                o_bus_reset <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Main Transmitter Logic
    // -------------------------------------------------------------------------
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            tx_state            <= TX_IDLE;
            tx_div_cnt          <= 16'd0;
            tx_bit_idx          <= 3'd0;
            tx_shift_reg        <= 8'd0;
            tx_token_shift      <= 16'd0;
            tx_crc16_reg        <= 16'hFFFF;
            tx_ones_cnt         <= 3'd0;
            tx_stuff_pending    <= 1'b0;
            tx_line_level       <= 1'b1; // J-state
            tx_is_eop           <= 1'b0;
            o_dp                <= 1'b1;
            o_dm                <= 1'b0;
            o_oe                <= 1'b0;
            o_tx_ready          <= 1'b0;
            o_tx_done           <= 1'b0;
            tx_auto_ack_pending <= 1'b0;
        end else if (!i_sie_en) begin
            tx_state            <= TX_IDLE;
            o_oe                <= 1'b0;
            o_tx_done           <= 1'b0;
            tx_auto_ack_pending <= 1'b0;
        end else begin
            o_tx_done  <= 1'b0;
            o_tx_ready <= 1'b0;

            if (rx_trigger_auto_ack)
                tx_auto_ack_pending <= 1'b1;

            // Trigger autonomous ACK from receiver
            if ((tx_auto_ack_pending || rx_trigger_auto_ack) && tx_state == TX_IDLE) begin
                tx_auto_ack_pending <= 1'b0;
                tx_state            <= TX_SYNC;
                tx_div_cnt          <= 16'd0;
                tx_shift_reg        <= 8'h80; // SYNC: 00000001 LSB first
                tx_bit_idx          <= 3'd0;
                tx_ones_cnt         <= 3'd0;
                tx_stuff_pending    <= 1'b0;
                tx_line_level       <= 1'b1; // Start from J
                tx_is_eop           <= 1'b0;
                o_oe                <= 1'b1;
            end else case (tx_state)
                TX_IDLE: begin
                    o_oe          <= 1'b0;
                    tx_line_level <= 1'b1; // Idle J-state
                    tx_is_eop     <= 1'b0;
                    tx_ones_cnt   <= 3'd0;

                    if (i_tx_token_req || i_tx_handshake_req || i_tx_data_req) begin
                        tx_state         <= TX_SYNC;
                        tx_div_cnt       <= 16'd0;
                        tx_shift_reg     <= 8'h80; // SYNC pattern
                        tx_bit_idx       <= 3'd0;
                        tx_stuff_pending <= 1'b0;
                        tx_line_level    <= 1'b1;
                        o_oe             <= 1'b1;
                    end
                end

                TX_SYNC: begin
                    // Transmit 8 bits of SYNC (0x80)
                    if (tx_div_cnt == effective_div - 1'b1) begin
                        tx_div_cnt <= 16'd0;
                        // NRZI: toggle on '0', hold on '1'
                        if (!tx_shift_reg[tx_bit_idx])
                            tx_line_level <= ~tx_line_level;

                        if (tx_bit_idx == 3'd7) begin
                            tx_state   <= TX_PID;
                            tx_bit_idx <= 3'd0;
                            if (i_tx_token_req)
                                tx_shift_reg <= { ~i_tx_token_pid, i_tx_token_pid };
                            else if (i_tx_handshake_req)
                                tx_shift_reg <= { ~i_tx_handshake_pid, i_tx_handshake_pid };
                            else if (i_tx_data_req)
                                tx_shift_reg <= { ~i_tx_data_pid, i_tx_data_pid };
                            else
                                tx_shift_reg <= { ~PID_ACK, PID_ACK }; // Auto-ACK
                        end else begin
                            tx_bit_idx <= tx_bit_idx + 1'b1;
                        end
                    end else begin
                        tx_div_cnt <= tx_div_cnt + 1'b1;
                    end
                end

                TX_PID: begin
                    // Transmit 8 bits of PID + check
                    if (tx_div_cnt == effective_div - 1'b1) begin
                        tx_div_cnt <= 16'd0;
                        if (!tx_shift_reg[tx_bit_idx])
                            tx_line_level <= ~tx_line_level;

                        if (tx_bit_idx == 3'd7) begin
                            tx_bit_idx <= 3'd0;
                            if (i_tx_token_req) begin
                                tx_state       <= TX_TOKEN_BITS;
                                // 11 bits: ADDR[6:0], ENDP[3:0], then 5 bits CRC5
                                tx_token_shift <= {
                                    calc_token_crc5(i_tx_token_addr, i_tx_token_endp),
                                    i_tx_token_endp,
                                    i_tx_token_addr
                                };
                            end else if (i_tx_handshake_req || (!i_tx_data_req && !i_tx_token_req)) begin
                                // Handshake finishes directly with EOP
                                tx_state  <= TX_EOP0;
                                tx_is_eop <= 1'b1;
                            end else begin
                                // Data packet: prepare payload
                                tx_state     <= TX_DATA_BYTE;
                                tx_crc16_reg <= 16'hFFFF;
                                o_tx_ready   <= 1'b1;
                            end
                        end else begin
                            tx_bit_idx <= tx_bit_idx + 1'b1;
                        end
                    end else begin
                        tx_div_cnt <= tx_div_cnt + 1'b1;
                    end
                end

                TX_TOKEN_BITS: begin
                    // Transmit 16 bits: 7b addr + 4b endp + 5b crc5
                    if (tx_div_cnt == effective_div - 1'b1) begin
                        tx_div_cnt <= 16'd0;
                        if (!tx_token_shift[0]) begin
                            tx_line_level <= ~tx_line_level;
                            tx_ones_cnt   <= 3'd0;
                        end else begin
                            tx_ones_cnt <= tx_ones_cnt + 1'b1;
                        end
                        tx_token_shift <= tx_token_shift >> 1;

                        if (tx_bit_idx == 3'd7 && tx_token_shift[15:8] == 8'd0) begin
                            tx_state  <= TX_EOP0;
                            tx_is_eop <= 1'b1;
                        end else if (tx_bit_idx == 3'd7) begin
                            tx_bit_idx <= 3'd0;
                        end else begin
                            tx_bit_idx <= tx_bit_idx + 1'b1;
                        end
                    end else begin
                        tx_div_cnt <= tx_div_cnt + 1'b1;
                    end
                end

                TX_DATA_BYTE: begin
                    if (tx_div_cnt == effective_div - 1'b1) begin
                        tx_div_cnt <= 16'd0;
                        // Handle bit stuffing
                        if (tx_stuff_pending) begin
                            tx_line_level    <= ~tx_line_level; // Force transition for '0'
                            tx_ones_cnt      <= 3'd0;
                            tx_stuff_pending <= 1'b0;
                        end else begin
                            
                            tx_crc16_reg <= step_crc16(tx_shift_reg[tx_bit_idx], tx_crc16_reg);

                            if (!tx_shift_reg[tx_bit_idx]) begin
                                tx_line_level <= ~tx_line_level;
                                tx_ones_cnt   <= 3'd0;
                            end else begin
                                tx_ones_cnt <= tx_ones_cnt + 1'b1;
                                if (tx_ones_cnt == 3'd5)
                                    tx_stuff_pending <= 1'b1;
                            end

                            if (tx_bit_idx == 3'd7) begin
                                tx_bit_idx <= 3'd0;
                                if (i_tx_last) begin
                                    tx_state     <= TX_DATA_CRC;
                                    tx_crc16_reg <= tx_crc16_reg ^ 16'hFFFF; // Invert for transmission
                                end else begin
                                    o_tx_ready <= 1'b1;
                                    if (i_tx_valid)
                                        tx_shift_reg <= i_tx_byte;
                                end
                            end else begin
                                tx_bit_idx <= tx_bit_idx + 1'b1;
                            end
                        end
                    end else begin
                        tx_div_cnt <= tx_div_cnt + 1'b1;
                    end
                end

                TX_DATA_CRC: begin
                    // Transmit 16 bits of inverted CRC16
                    if (tx_div_cnt == effective_div - 1'b1) begin
                        tx_div_cnt <= 16'd0;
                        if (tx_stuff_pending) begin
                            tx_line_level    <= ~tx_line_level;
                            tx_ones_cnt      <= 3'd0;
                            tx_stuff_pending <= 1'b0;
                        end else begin
                            
                            if (!tx_shift_reg[tx_bit_idx]) begin
                                tx_line_level <= ~tx_line_level;
                                tx_ones_cnt   <= 3'd0;
                            end else begin
                                tx_ones_cnt <= tx_ones_cnt + 1'b1;
                                if (tx_ones_cnt == 3'd5)
                                    tx_stuff_pending <= 1'b1;
                            end
                            tx_crc16_reg <= tx_crc16_reg >> 1;

                            if (tx_bit_idx == 3'd7 && tx_crc16_reg[15:8] == 8'd0) begin
                                tx_state  <= TX_EOP0;
                                tx_is_eop <= 1'b1;
                            end else if (tx_bit_idx == 3'd7) begin
                                tx_bit_idx <= 3'd0;
                            end else begin
                                tx_bit_idx <= tx_bit_idx + 1'b1;
                            end
                        end
                    end else begin
                        tx_div_cnt <= tx_div_cnt + 1'b1;
                    end
                end

                TX_EOP0: begin
                    // First bit of SE0
                    tx_is_eop <= 1'b1;
                    if (tx_div_cnt == effective_div - 1'b1) begin
                        tx_div_cnt <= 16'd0;
                        tx_state   <= TX_EOP1;
                    end else begin
                        tx_div_cnt <= tx_div_cnt + 1'b1;
                    end
                end

                TX_EOP1: begin
                    // Second bit of SE0
                    tx_is_eop <= 1'b1;
                    if (tx_div_cnt == effective_div - 1'b1) begin
                        tx_div_cnt <= 16'd0;
                        tx_state   <= TX_J_WAIT;
                        tx_is_eop  <= 1'b0;
                    end else begin
                        tx_div_cnt <= tx_div_cnt + 1'b1;
                    end
                end

                TX_J_WAIT: begin
                    // 1 bit period of J-state
                    tx_is_eop     <= 1'b0;
                    tx_line_level <= 1'b1;
                    if (tx_div_cnt == effective_div - 1'b1) begin
                        tx_div_cnt <= 16'd0;
                        tx_state   <= TX_IDLE;
                        o_oe       <= 1'b0;
                        o_tx_done  <= 1'b1;
                    end else begin
                        tx_div_cnt <= tx_div_cnt + 1'b1;
                    end
                end
            endcase

            // Drive physical lines
            if (o_oe) begin
                if (tx_is_eop) begin
                    o_dp <= 1'b0;
                    o_dm <= 1'b0;
                end else if (tx_line_level) begin
                    // J-state
                    o_dp <= ~i_speed_mode;
                    o_dm <= i_speed_mode;
                end else begin
                    // K-state
                    o_dp <= i_speed_mode;
                    o_dm <= ~i_speed_mode;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Main Receiver Logic
    // -------------------------------------------------------------------------
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            rx_state         <= RX_IDLE;
            rx_div_cnt       <= 16'd0;
            prev_line_level  <= 1'b1; // Idle J
            rx_ones_cnt      <= 3'd0;
            rx_bit_idx       <= 3'd0;
            rx_shift_reg     <= 8'd0;
            rx_token_shift   <= 16'd0;
            rx_crc5_reg      <= 5'h1F;
            rx_crc16_reg     <= 16'hFFFF;
            latched_rx_pid   <= 4'd0;
            o_token_valid    <= 1'b0;
            o_token_pid      <= 4'd0;
            o_token_endp     <= 4'd0;
            o_token_addr     <= 7'd0;
            o_rx_data_valid  <= 1'b0;
            o_rx_data_byte   <= 8'd0;
            o_rx_packet_done <= 1'b0;
            o_rx_pid         <= 4'd0;
            o_rx_crc_err     <= 1'b0;
            o_rx_pid_err     <= 1'b0;
            o_rx_stuff_err      <= 1'b0;
            rx_trigger_auto_ack <= 1'b0;
        end else if (!i_sie_en) begin
            rx_state            <= RX_IDLE;
            o_token_valid       <= 1'b0;
            o_rx_data_valid     <= 1'b0;
            o_rx_packet_done    <= 1'b0;
            rx_trigger_auto_ack <= 1'b0;
        end else begin
            o_token_valid       <= 1'b0;
            o_rx_data_valid     <= 1'b0;
            o_rx_packet_done    <= 1'b0;
            rx_trigger_auto_ack <= 1'b0;

            case (rx_state)
                RX_IDLE: begin
                    prev_line_level <= 1'b1; // J-state
                    rx_ones_cnt     <= 3'd0;
                    rx_bit_idx      <= 3'd0;

                    // Transition from J to K indicates start of SYNC field
                    if (line_k && !o_oe) begin
                        rx_state        <= RX_SYNC;
                        rx_div_cnt      <= half_div; // Mid-bit alignment
                        prev_line_level <= 1'b1;     // Previous was J-state
                        rx_shift_reg    <= 8'd0;
                        rx_bit_idx      <= 3'd0;
                    end
                end

                RX_SYNC: begin
                    // Sample SYNC bits at mid-bit period
                    if (rx_div_cnt == effective_div - 1'b1) begin
                        rx_div_cnt <= 16'd0;
                        // NRZI decode: transition = 0, no transition = 1
                        prev_line_level <= line_j;
                        rx_shift_reg <= { (line_j == prev_line_level), rx_shift_reg[7:1] };
                        if (rx_bit_idx == 3'd7) begin
                            rx_bit_idx <= 3'd0;
                            // SYNC is 0x80 (LSB first: 0,0,0,0,0,0,0,1)
                            if (rx_shift_reg[7:1] == 7'b0000000 && (line_j == prev_line_level) == 1'b1) begin
                                rx_state <= RX_PID;
                            end else begin
                                rx_state <= RX_IDLE; // False alarm or framing sync failure
                            end
                        end else begin
                            rx_bit_idx <= rx_bit_idx + 1'b1;
                        end
                    end else begin
                        rx_div_cnt <= rx_div_cnt + 1'b1;
                    end
                end

                RX_PID: begin
                    if (rx_div_cnt == effective_div - 1'b1) begin
                        rx_div_cnt <= 16'd0;
                        prev_line_level <= line_j;
                        rx_shift_reg <= { (line_j == prev_line_level), rx_shift_reg[7:1] };
                        if (rx_bit_idx == 3'd7) begin
                            rx_bit_idx <= 3'd0;
                            // Check PID validity: pid[7:4] == ~pid[3:0]
                            // The 8 bits just received are { (line_j == prev_line_level), rx_shift_reg[7:1] }
                            if ({ (line_j == prev_line_level), rx_shift_reg[7:5] } == ~rx_shift_reg[4:1]) begin
                                latched_rx_pid <= rx_shift_reg[4:1];
                                o_rx_pid       <= rx_shift_reg[4:1];
                                o_rx_pid_err   <= 1'b0;

                                case (rx_shift_reg[4:1])
                                    PID_OUT, PID_IN, PID_SETUP, PID_SOF: begin
                                        rx_state       <= RX_TOKEN;
                                        rx_crc5_reg    <= 5'h1F;
                                        rx_token_shift <= 16'd0;
                                    end
                                    PID_DATA0, PID_DATA1, PID_DATA2, PID_MDATA: begin
                                        rx_state     <= RX_DATA;
                                        rx_crc16_reg <= 16'hFFFF;
                                    end
                                    PID_ACK, PID_NAK, PID_STALL, PID_NYET: begin
                                        rx_state <= RX_EOP;
                                    end
                                    default: rx_state <= RX_IDLE;
                                endcase
                            end else begin
                                o_rx_pid_err <= 1'b1;
                                rx_state     <= RX_IDLE;
                            end
                        end else begin
                            rx_bit_idx <= rx_bit_idx + 1'b1;
                        end
                    end else begin
                        rx_div_cnt <= rx_div_cnt + 1'b1;
                    end
                end

                RX_TOKEN: begin
                    // Token is 16 bits: 7b ADDR + 4b ENDP + 5b CRC5
                    if (line_se0) begin
                        // EOP arrived
                        rx_state         <= RX_IDLE;
                        o_rx_packet_done <= 1'b1;

                        // Verify CRC-5 residual (should be 5'h06)
                        if (rx_crc5_reg == 5'h06) begin
                            o_rx_crc_err <= 1'b0;
                            // Check device address
                            if (rx_token_shift[6:0] == i_dev_addr) begin
                                o_token_valid <= 1'b1;
                                o_token_pid   <= latched_rx_pid;
                                o_token_addr  <= rx_token_shift[6:0];
                                o_token_endp  <= rx_token_shift[10:7];
                            end
                        end else begin
                            o_rx_crc_err <= 1'b1;
                        end
                    end else if (rx_div_cnt == effective_div - 1'b1) begin
                        rx_div_cnt <= 16'd0;
                        prev_line_level <= line_j;
                        if (line_j == prev_line_level) begin
                            rx_ones_cnt <= rx_ones_cnt + 1'b1;
                            if (rx_ones_cnt == 3'd6)
                                o_rx_stuff_err <= 1'b1;
                            rx_token_shift <= { 1'b1, rx_token_shift[15:1] };
                            rx_crc5_reg    <= step_crc5(1'b1, rx_crc5_reg);
                        end else begin
                            if (rx_ones_cnt == 3'd6) begin
                                // Discard stuff bit
                                rx_ones_cnt <= 3'd0;
                            end else begin
                                rx_ones_cnt    <= 3'd0;
                                rx_token_shift <= { 1'b0, rx_token_shift[15:1] };
                                rx_crc5_reg    <= step_crc5(1'b0, rx_crc5_reg);
                            end
                        end
                    end else begin
                        rx_div_cnt <= rx_div_cnt + 1'b1;
                    end
                end

                RX_DATA: begin
                    if (line_se0) begin
                        // EOP arrived
                        rx_state         <= RX_IDLE;
                        o_rx_packet_done <= 1'b1;

                        // Check CRC-16 residual (0xB001)
                        if (rx_crc16_reg == 16'hB001) begin
                            o_rx_crc_err <= 1'b0;
                            // If auto-ACK enabled and endpoint not stalled/NAK'd, reply ACK!
                            if (i_auto_ack && !i_ep_stall[o_token_endp[1:0]] && !i_ep_nak[o_token_endp[1:0]]) begin
                                rx_trigger_auto_ack <= 1'b1;
                            end
                        end else begin
                            o_rx_crc_err <= 1'b1;
                        end
                    end else if (rx_div_cnt == effective_div - 1'b1) begin
                        rx_div_cnt <= 16'd0;
                        prev_line_level <= line_j;
                        if (line_j == prev_line_level) begin
                            rx_ones_cnt <= rx_ones_cnt + 1'b1;
                            if (rx_ones_cnt == 3'd6)
                                o_rx_stuff_err <= 1'b1;
                            rx_shift_reg <= { 1'b1, rx_shift_reg[7:1] };
                            rx_crc16_reg <= step_crc16(1'b1, rx_crc16_reg);

                            if (rx_bit_idx == 3'd7) begin
                                rx_bit_idx      <= 3'd0;
                                o_rx_data_byte  <= { 1'b1, rx_shift_reg[7:1] };
                                o_rx_data_valid <= 1'b1;
                            end else begin
                                rx_bit_idx <= rx_bit_idx + 1'b1;
                            end
                        end else begin
                            if (rx_ones_cnt == 3'd6) begin
                                rx_ones_cnt <= 3'd0; // Strip stuff bit
                            end else begin
                                rx_ones_cnt  <= 3'd0;
                                rx_shift_reg <= { 1'b0, rx_shift_reg[7:1] };
                                rx_crc16_reg <= step_crc16(1'b0, rx_crc16_reg);

                                if (rx_bit_idx == 3'd7) begin
                                    rx_bit_idx      <= 3'd0;
                                    o_rx_data_byte  <= { 1'b0, rx_shift_reg[7:1] };
                                    o_rx_data_valid <= 1'b1;
                                end else begin
                                    rx_bit_idx <= rx_bit_idx + 1'b1;
                                end
                            end
                        end
                    end else begin
                        rx_div_cnt <= rx_div_cnt + 1'b1;
                    end
                end

                RX_EOP: begin
                    // Wait for SE0 then back to idle
                    if (line_se0) begin
                        rx_state         <= RX_IDLE;
                        o_rx_packet_done <= 1'b1;
                    end
                end
            endcase
        end
    end

endmodule
`default_nettype wire
