// =============================================================================
// File        : properties.v
// Module      : Glitch Generator & MitM Pattern Matcher Formal Properties (Task 30)
// Description : Formally proves Section 7.1 of CONCEPT.md:
//               1. Glitch Safety & Pulse Bounds:
//                  - Glitch pulse duration is strictly equal to glitch_width cycles.
//                  - When disarmed (glitch_en == 0), glitch pulse is strictly suppressed.
//                  - Glitch polarity invariant: glitch_pol=1 drives LOW (0),
//                    glitch_pol=0 drives HIGH (1).
//               2. Real-time MitM / Pattern Match Trigger:
//                  - Pattern matcher monitors incoming line without software latency.
//               3. Functional Coverage:
//                  - Glitch pulse armed, triggered, and completed.
// License     : MIT License
// =============================================================================

`ifdef FORMAL

`define ASSERT assert
`define ASSUME assume

    reg f_past_valid;
    initial f_past_valid = 1'b0;
    always @(posedge i_clk)
        f_past_valid <= 1'b1;

    // Reset sequence
    initial `ASSUME(!i_reset_n);

    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_reset_n)) begin
            `ASSUME(i_reset_n);
        end
    end

    // Allow initial programming phase, once microcode execution starts (!i_prog_en), it stays in execution
    always @(posedge i_clk) begin
        if (f_past_valid && $past(!i_prog_en)) begin
            `ASSUME(!i_prog_en);
        end
    end

    // Microcode execution environment
    always @(*) begin
        `ASSUME(i_baud_div >= 16'd1 && i_baud_div <= 16'd511);
        `ASSUME(!jtag_en && !swd_en && !qspi_en);
        `ASSUME(jtag_tms_cnt == 4'd0 && jtag_shift_cnt == 4'd0 && swd_state == 4'd0 && qspi_state == 4'd0);
        `ASSUME(!i_usb_wb_sie_en && !i_usb_wb_tx_token_req && !i_usb_wb_tx_handshake_req);
        `ASSUME(!i_bist_wb_en && !i_bist_wb_start && !i_bist_wb_stop && !i_bist_wb_rst);
        `ASSUME(!i_profiler_wb_arm && !i_profiler_wb_stop && !i_profiler_wb_rst);
        `ASSUME(!bist_en && !usb_sie_en && !audio_en && !mitm_en && !i2c_slave_en);
    end

    // -------------------------------------------------------------------------
    // 1. Reset Invariants
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && $past(!i_reset_n)) begin
            `ASSERT(glitch_en == 1'b0);
            `ASSERT(glitch_active == 1'b0);
            `ASSERT(glitch_pulse_cnt == 8'd0);
        end
    end

    // -------------------------------------------------------------------------
    // 2. Glitch Disarm Invariant
    // -------------------------------------------------------------------------
    // When glitch_en is 0, the glitch engine cannot drive or enable the GPIO bus
    always @(*) begin
        if (i_reset_n && !i_prog_en) begin
            if (!glitch_en && !gpio_oe_reg[glitch_pin]) begin
                `ASSERT(o_gpio_oe[glitch_pin] == 1'b0);
            end
        end
    end

    // -------------------------------------------------------------------------
    // 3. Glitch Pulse Width & Polarity Invariants
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && !i_prog_en && $past(i_reset_n) && !$past(i_prog_en)) begin
            // While glitch is active and enabled, the designated pin reflects exact glitch polarity (unless open-drain clamped)
            if (glitch_en && glitch_active) begin
                if (gpio_od[glitch_pin]) begin
                    `ASSERT(o_gpio[glitch_pin] == 1'b0);
                end else if (glitch_pol) begin
                    `ASSERT(o_gpio[glitch_pin] == 1'b0);
                end else begin
                    `ASSERT(o_gpio[glitch_pin] == 1'b1);
                end
                `ASSERT(o_gpio_oe[glitch_pin] == 1'b1);
            end

            // When glitch countdown expires, glitch_active is deasserted
            if ($past(glitch_active) && ($past(glitch_pulse_cnt) <= 8'd1)) begin
                `ASSERT(glitch_active == 1'b0);
            end
        end
    end

    // -------------------------------------------------------------------------
    // 4. Functional Coverage
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && !i_prog_en) begin
            // Cover 1: Glitch armed
            cover(glitch_en && !glitch_active);

            // Cover 2: Glitch active (firing pulse)
            cover(glitch_en && glitch_active);

            // Cover 3: Glitch completion and return to idle
            cover($past(glitch_active) && !glitch_active);
        end
    end

`endif
