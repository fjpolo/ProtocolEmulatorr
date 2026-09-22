// =============================================================================
// File        : I2CSlaveStub.v
// Module      : I2CSlaveStub (Auto-ACK I2C Slave Stub for Loopback Testing)
// Description : Cycle-accurate internal I2C slave stub. Detects I2C START and
//               STOP framing conditions, counts 8 data pulses on SCL, drives
//               o_sda_drive = 1 (pulls SDA low) on the 9th SCL pulse for ACK,
//               and releases SDA on the falling edge of the 9th pulse.
// License     : MIT License
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module I2CSlaveStub (
    input   wire        i_clk,
    input   wire        i_reset_n,
    input   wire        i_scl,          // SCL line state
    input   wire        i_sda,          // SDA line state
    output  reg         o_sda_drive,    // 1 = pull SDA low (ACK), 0 = release Hi-Z
    output  reg         o_ack_pulse     // 1-cycle strobe on successful ACK
);

    // 2-stage input synchronizers to prevent metastability
    reg scl_sync_0, scl_sync_1, scl_prev;
    reg sda_sync_0, sda_sync_1, sda_prev;

    always @(posedge i_clk) begin
        if (!i_reset_n) begin
            scl_sync_0 <= 1'b1;
            scl_sync_1 <= 1'b1;
            scl_prev   <= 1'b1;
            sda_sync_0 <= 1'b1;
            sda_sync_1 <= 1'b1;
            sda_prev   <= 1'b1;
        end else begin
            scl_sync_0 <= i_scl;
            scl_sync_1 <= scl_sync_0;
            scl_prev   <= scl_sync_1;

            sda_sync_0 <= i_sda;
            sda_sync_1 <= sda_sync_0;
            sda_prev   <= sda_sync_1;
        end
    end

    // I2C Framing Conditions
    // START: SDA falling edge while SCL is high
    wire start_cond = (sda_prev == 1'b1 && sda_sync_1 == 1'b0 && scl_sync_1 == 1'b1);
    // STOP:  SDA rising edge while SCL is high
    wire stop_cond  = (sda_prev == 1'b0 && sda_sync_1 == 1'b1 && scl_sync_1 == 1'b1);

    // SCL Edges
    wire scl_rise   = (scl_prev == 1'b0 && scl_sync_1 == 1'b1);
    wire scl_fall   = (scl_prev == 1'b1 && scl_sync_1 == 1'b0);

    reg       active;
    reg [3:0] bit_cnt;

    always @(posedge i_clk) begin
        if (!i_reset_n) begin
            active      <= 1'b0;
            bit_cnt     <= 4'd0;
            o_sda_drive <= 1'b0;
            o_ack_pulse <= 1'b0;
        end else begin
            o_ack_pulse <= 1'b0;

            if (stop_cond) begin
                active      <= 1'b0;
                bit_cnt     <= 4'd0;
                o_sda_drive <= 1'b0;
            end else if (start_cond) begin
                active      <= 1'b1;
                bit_cnt     <= 4'd0;
                o_sda_drive <= 1'b0;
            end else if (active) begin
                // SCL Falling Edge: change SDA drive state
                if (scl_fall) begin
                    if (bit_cnt == 4'd8) begin
                        // 8 data bits completed; drive SDA low for the upcoming 9th (ACK) pulse
                        o_sda_drive <= 1'b1;
                        o_ack_pulse <= 1'b1;
                    end else if (bit_cnt == 4'd9) begin
                        // 9th (ACK) pulse completed; release SDA
                        o_sda_drive <= 1'b0;
                        bit_cnt     <= 4'd0;
                    end
                end

                // SCL Rising Edge: increment pulse counter
                if (scl_rise) begin
                    bit_cnt <= bit_cnt + 4'd1;
                end
            end
        end
    end

endmodule
