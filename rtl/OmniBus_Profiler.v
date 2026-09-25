// =============================================================================
// File        : OmniBus_Profiler.v
// Module      : OmniBus_Profiler
// Description : Task 27 - The Protocol Detective
//               Autonomous Waveform Profiler, Auto-Baud & Bus Analyzer Engine
//               Features:
//                 - High-speed 16-bit pulse-width transition timer (20 ns @ 50 MHz)
//                 - Minimum pulse-width discovery (t_min_high, t_min_low, t_min)
//                 - Idle bus polarity detection (Idle-High vs Idle-Low)
//                 - Clock vs. Data duty-cycle symmetry discriminator
//                 - Autonomous framing signature detector (UART, I2C, SPI, 1-Wire)
//                 - Configurable glitch/noise rejection filter threshold
// License     : MIT License
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module OmniBus_Profiler #(
    parameter CLK_FREQ_HZ = 50_000_000
)(
    input   wire            i_clk,
    input   wire            i_rst_n,

    // Monitored GPIO pin bus
    input   wire    [7:0]   i_gpio,

    // Configuration & Control
    input   wire    [2:0]   i_pin_sel,          // Selected target GPIO pin (0..7)
    input   wire    [3:0]   i_glitch_thresh,    // Glitch filter rejection threshold (cycles)
    input   wire            i_arm,              // Arm capture engine (strobe or level)
    input   wire            i_stop,             // Freeze / stop profiling
    input   wire            i_rst,              // Clear counters and statistics

    // Status & Telemetry Outputs
    output  reg             o_busy,             // Profiler active
    output  reg             o_done,             // Stable t_min measurement converged
    output  reg             o_idle_pol,         // Detected idle polarity: 0=Low, 1=High
    output  reg             o_is_clock,         // Line classified as periodic clock
    output  reg     [3:0]   o_protocol_id,      // Detected protocol framing ID
    output  reg     [7:0]   o_edge_count,       // Total observed valid transitions (0..255)
    output  reg     [15:0]  o_tmin,             // Minimum pulse width / bit period (baud divisor)
    output  reg     [15:0]  o_tmax,             // Maximum observed pulse width / idle duration
    output  reg     [15:0]  o_tmin_high,        // Minimum stable high pulse width
    output  reg     [15:0]  o_tmin_low          // Minimum stable low pulse width
);

    // Protocol IDs:
    localparam [3:0]
        PROTO_UNKNOWN = 4'd0,
        PROTO_UART    = 4'd1,
        PROTO_I2C     = 4'd2,
        PROTO_SPI     = 4'd3,
        PROTO_1WIRE   = 4'd4;

    // -------------------------------------------------------------------------
    // 1. Target Pin Selection & Double-Flop Synchronizer
    // -------------------------------------------------------------------------
    wire target_raw = i_gpio[i_pin_sel];
    reg  sync_0, sync_1;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            sync_0 <= 1'b1;
            sync_1 <= 1'b1;
        end else begin
            sync_0 <= target_raw;
            sync_1 <= sync_0;
        end
    end

    // Secondary line monitoring for multi-wire framing signatures (e.g. SCL/SDA, SCK/CS)
    wire scl_or_sck_raw = (i_pin_sel == 3'd4) ? i_gpio[1] :
                          (i_pin_sel == 3'd0) ? i_gpio[1] : i_gpio[i_pin_sel ^ 3'd1];
    reg  sync_pair_0, sync_pair_1, sync_pair_prev;
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            sync_pair_0    <= 1'b1;
            sync_pair_1    <= 1'b1;
            sync_pair_prev <= 1'b1;
        end else begin
            sync_pair_0    <= scl_or_sck_raw;
            sync_pair_1    <= sync_pair_0;
            sync_pair_prev <= sync_pair_1;
        end
    end

    wire pair_edge = (sync_pair_1 != sync_pair_prev);
    reg [5:0] pair_edge_cnt;

    // -------------------------------------------------------------------------
    // 2. Configurable Glitch / Noise Rejection Filter
    // -------------------------------------------------------------------------
    reg        filt_sig;
    reg        filt_sig_prev;
    reg  [3:0] filt_cnt;
    wire [3:0] active_thresh = (i_glitch_thresh == 4'd0) ? 4'd1 : i_glitch_thresh;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            filt_sig      <= 1'b1;
            filt_sig_prev <= 1'b1;
            filt_cnt      <= 4'd0;
        end else begin
            filt_sig_prev <= filt_sig;
            if (sync_1 != filt_sig) begin
                if (filt_cnt >= active_thresh - 4'd1) begin
                    filt_sig <= sync_1;
                    filt_cnt <= 4'd0;
                end else begin
                    filt_cnt <= filt_cnt + 4'd1;
                end
            end else begin
                filt_cnt <= 4'd0;
            end
        end
    end

    wire pos_edge = (!filt_sig_prev && filt_sig);
    wire neg_edge = (filt_sig_prev && !filt_sig);
    wire any_edge = pos_edge || neg_edge;

    // -------------------------------------------------------------------------
    // 3. Pulse-Width Measurement Timer & Minimum Pulse Latch
    // -------------------------------------------------------------------------
    reg [15:0] pulse_timer;
    reg [15:0] last_high_pulse;
    reg [15:0] last_low_pulse;
    reg        has_seen_high;
    reg        has_seen_low;
    reg        first_edge_seen;
    reg        arm_prev;

    wire [15:0] pulse_diff = (o_tmin_high >= o_tmin_low) ?
                             (o_tmin_high - o_tmin_low) : (o_tmin_low - o_tmin_high);
    wire [15:0] allowed_jitter = (o_tmin >> 2) + 16'd2; // 25% + 2 cycles tolerance

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_busy          <= 1'b0;
            o_done          <= 1'b0;
            o_idle_pol      <= 1'b1;
            o_is_clock      <= 1'b0;
            o_protocol_id   <= PROTO_UNKNOWN;
            o_edge_count    <= 8'd0;
            o_tmin          <= 16'hFFFF;
            o_tmax          <= 16'h0000;
            o_tmin_high     <= 16'hFFFF;
            o_tmin_low      <= 16'hFFFF;
            pulse_timer     <= 16'd0;
            last_high_pulse <= 16'd0;
            last_low_pulse  <= 16'd0;
            has_seen_high   <= 1'b0;
            has_seen_low    <= 1'b0;
            first_edge_seen <= 1'b0;
            pair_edge_cnt   <= 6'd0;
            arm_prev        <= 1'b0;
        end else begin
            arm_prev <= i_arm;

            if (i_rst) begin
                o_busy          <= 1'b0;
                o_done          <= 1'b0;
                o_idle_pol      <= sync_1;
                o_is_clock      <= 1'b0;
                o_protocol_id   <= PROTO_UNKNOWN;
                o_edge_count    <= 8'd0;
                o_tmin          <= 16'hFFFF;
                o_tmax          <= 16'h0000;
                o_tmin_high     <= 16'hFFFF;
                o_tmin_low      <= 16'hFFFF;
                pulse_timer     <= 16'd0;
                last_high_pulse <= 16'd0;
                last_low_pulse  <= 16'd0;
                has_seen_high   <= 1'b0;
                has_seen_low    <= 1'b0;
                first_edge_seen <= 1'b0;
                pair_edge_cnt   <= 6'd0;
            end else if (i_arm && !arm_prev) begin
                // Arming sequence: snapshot initial idle polarity
                o_busy          <= 1'b1;
                o_done          <= 1'b0;
                o_idle_pol      <= sync_1;
                o_is_clock      <= 1'b0;
                o_protocol_id   <= PROTO_UNKNOWN;
                o_edge_count    <= 8'd0;
                o_tmin          <= 16'hFFFF;
                o_tmax          <= 16'h0000;
                o_tmin_high     <= 16'hFFFF;
                o_tmin_low      <= 16'hFFFF;
                pulse_timer     <= 16'd0;
                last_high_pulse <= 16'd0;
                last_low_pulse  <= 16'd0;
                has_seen_high   <= 1'b0;
                has_seen_low    <= 1'b0;
                first_edge_seen <= 1'b0;
                pair_edge_cnt   <= 6'd0;
            end else if (i_stop) begin
                o_busy <= 1'b0;
            end else if (o_busy) begin
                // Track transitions on secondary pin (for multi-line detection like I2C/SPI)
                if (pair_edge && (pair_edge_cnt != 6'h3F)) begin
                    pair_edge_cnt <= pair_edge_cnt + 6'd1;
                end

                // -------------------------------------------------------------
                // Real-time Pulse Measurement
                // -------------------------------------------------------------
                if (any_edge) begin
                    if (o_edge_count != 8'hFF) begin
                        o_edge_count <= o_edge_count + 8'd1;
                    end

                    if (!first_edge_seen) begin
                        // First transition synchronizes timer to avoid partial pulse artifact
                        first_edge_seen <= 1'b1;
                        pulse_timer     <= 16'd0;
                    end else begin
                        if (filt_sig_prev == 1'b1) begin
                            // A High pulse just ended (neg_edge)
                            has_seen_high   <= 1'b1;
                            last_high_pulse <= pulse_timer;
                            if (pulse_timer < o_tmin_high) begin
                                o_tmin_high <= pulse_timer;
                            end
                        end else begin
                            // A Low pulse just ended (pos_edge)
                            has_seen_low   <= 1'b1;
                            last_low_pulse <= pulse_timer;
                            if (pulse_timer < o_tmin_low) begin
                                o_tmin_low <= pulse_timer;
                            end
                        end

                        if (pulse_timer > o_tmax) begin
                            o_tmax <= pulse_timer;
                        end

                        pulse_timer <= 16'd0;
                    end
                end else begin
                    // Pulse continuing
                    if (pulse_timer != 16'hFFFF) begin
                        pulse_timer <= pulse_timer + 16'd1;
                    end
                end

                // -------------------------------------------------------------
                // Update Fundamental Bit Period (t_min)
                // -------------------------------------------------------------
                if (has_seen_high && has_seen_low) begin
                    if (o_tmin_high <= o_tmin_low) begin
                        o_tmin <= o_tmin_high;
                    end else begin
                        o_tmin <= o_tmin_low;
                    end
                end else if (has_seen_high) begin
                    o_tmin <= o_tmin_high;
                end else if (has_seen_low) begin
                    o_tmin <= o_tmin_low;
                end

                // -------------------------------------------------------------
                // Clock vs. Data Discrimination
                // -------------------------------------------------------------
                // Line has multiple edges and High/Low widths match within ~25%
                if (o_edge_count >= 8'd6 && has_seen_high && has_seen_low) begin
                    // If pulse sits idle longer than 1.5 * tmin, line is not a continuous clock
                    if (pulse_timer > (o_tmin + (o_tmin >> 1))) begin
                        o_is_clock <= 1'b0;
                    end else if (pulse_diff <= allowed_jitter && (o_tmax <= o_tmin + (o_tmin >> 1))) begin
                        o_is_clock <= 1'b1;
                    end else begin
                        o_is_clock <= 1'b0;
                    end
                end

                // -------------------------------------------------------------
                // Framing Signature Detector
                // -------------------------------------------------------------
                // 1. I2C START/STOP Detection:
                // START = Target (SDA) falling while Pair (SCL) is High, AND SCL has clock edges
                // STOP  = Target (SDA) rising while Pair (SCL) is High, AND SCL has clock edges
                if (sync_pair_1 == 1'b1 && pair_edge_cnt >= 6'd2) begin
                    if (neg_edge || pos_edge) begin
                        o_protocol_id <= PROTO_I2C;
                    end
                end

                // 2. 1-Wire Reset Detection:
                // Master reset is a sustained Low pulse > 400 us (20,000 cycles @ 50 MHz)
                if (filt_sig_prev == 1'b0 && pulse_timer >= 16'd15000) begin
                    o_protocol_id <= PROTO_1WIRE;
                end

                // 3. SPI Detection:
                // If Pair (CS_n) is Low while Target (SCK) toggles periodically
                if (sync_pair_1 == 1'b0 && o_is_clock && pair_edge_cnt >= 6'd2) begin
                    o_protocol_id <= PROTO_SPI;
                end

                // 4. UART Detection:
                // Idle polarity High, first edge is falling (Start bit), non-clock data
                if (o_protocol_id == PROTO_UNKNOWN && o_idle_pol == 1'b1 &&
                    o_edge_count >= 8'd4 && !o_is_clock) begin
                    o_protocol_id <= PROTO_UART;
                end

                // -------------------------------------------------------------
                // Convergence & Completion Flag (o_done)
                // -------------------------------------------------------------
                // Converges when:
                // a) At least 6 edges observed and either idle timeout or clock established
                // b) Or 16 edges observed
                if (o_edge_count >= 8'd16 || (o_edge_count >= 8'd6 && pulse_timer >= (o_tmin << 3))) begin
                    o_done <= 1'b1;
                end
            end
        end
    end

endmodule
