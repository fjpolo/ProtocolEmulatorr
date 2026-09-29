// =============================================================================
// File        : properties.v
// Module      : BusSafety Formal Invariants (Task 30)
// Description : Formally proves:
//               1. Open-Drain No-Contention Invariant:
//                  Whenever gpio_od[p] is enabled and o_gpio_oe[p] is active,
//                  o_gpio[p] MUST be 1'b0 (driven LOW).
//                  o_gpio[p] NEVER actively drives logic 1 into an open-drain bus.
//               2. When pin_val=1 in open-drain mode, line is released to Hi-Z
//                  (o_gpio_oe[p] == 0), safely allowing pull-up resistors.
//               3. CFG_OD opcode 0x6 updates gpio_od mask deterministically.
// License     : MIT License
// =============================================================================

`ifdef FORMAL

`define ASSERT assert
`define ASSUME assume

    reg f_past_valid;
    initial f_past_valid = 1'b0;
    always @(posedge i_clk)
        f_past_valid <= 1'b1;

    initial `ASSUME(!i_reset_n);

    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_reset_n)) begin
            `ASSUME(i_reset_n);
        end
    end

    // Restrict to microcode execution (not programming mode, sequencers & WB accelerators idle)
    always @(*) begin
        `ASSUME(!i_prog_en);
        `ASSUME(i_baud_div >= 16'd1 && i_baud_div <= 16'd511);
        `ASSUME(!jtag_en && !swd_en && !qspi_en);
        `ASSUME(jtag_tms_cnt == 4'd0 && jtag_shift_cnt == 4'd0 && swd_state == 4'd0 && qspi_state == 4'd0);
        `ASSUME(!i_usb_wb_sie_en && !i_usb_wb_tx_token_req && !i_usb_wb_tx_handshake_req);
        `ASSUME(!i_bist_wb_en && !i_bist_wb_start && !i_bist_wb_stop && !i_bist_wb_rst);
        `ASSUME(!i_profiler_wb_arm && !i_profiler_wb_stop && !i_profiler_wb_rst);
        `ASSUME(!bist_en && !usb_sie_en && !glitch_en && !audio_en && !mitm_en && !i2c_slave_en);
    end

    // -------------------------------------------------------------------------
    // Invariant 1: Open-Drain No-Contention Safety
    // -------------------------------------------------------------------------
    // For every GPIO pin 0..7:
    // If open-drain mode is active and the pin is enabled for output,
    // the pin MUST be driven low (0). It can NEVER drive high (1) into an open-drain bus!
    genvar p_idx;
    generate
        for (p_idx = 0; p_idx < 8; p_idx = p_idx + 1) begin : gen_od_safety
            always @(*) begin
                if (i_reset_n && !i_prog_en) begin
                    if (gpio_od[p_idx]) begin
                        if (o_gpio_oe[p_idx]) begin
                            `ASSERT(o_gpio[p_idx] == 1'b0);
                        end
                    end
                end
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Invariant 2: Open-Drain Release Invariant
    // -------------------------------------------------------------------------
    // When SET executes on an open-drain pin with pin_val == 1:
    // The driver is released (gpio_oe_reg[p] == 0) and out is set to 1.
    genvar p_set;
    generate
        for (p_set = 0; p_set < 8; p_set = p_set + 1) begin : gen_set_safety
            always @(posedge i_clk) begin
                if (f_past_valid && i_reset_n && !i_prog_en && $past(i_reset_n) && !$past(i_prog_en)) begin
                    if ($past(delay_cnt) == 16'd0 && $past(opcode) == 4'h3 && $past(pin_sel) == p_set[2:0]) begin
                        if ($past(gpio_od[p_set])) begin
                            if ($past(pin_val) == 1'b1) begin
                                `ASSERT(gpio_oe_reg[p_set] == 1'b0);
                                `ASSERT(gpio_out_reg[p_set] == 1'b1);
                            end else begin
                                `ASSERT(gpio_oe_reg[p_set] == 1'b1);
                                `ASSERT(gpio_out_reg[p_set] == 1'b0);
                            end
                        end
                    end
                end
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Invariant 3: CFG_OD Mask Integrity
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && !i_prog_en && $past(i_reset_n) && !$past(i_prog_en)) begin
            if ($past(delay_cnt) == 16'd0 && $past(opcode) == 4'h6) begin // CFG_OD
                `ASSERT(gpio_od == $past(instr[7:0]));
            end
        end
    end

    // -------------------------------------------------------------------------
    // Cover Statements
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n) begin
            // Cover 1: Normal exit from reset
            cover($past(!i_reset_n) && i_reset_n);

            // Cover 2: Microcode execution advancing past reset vector
            cover(!i_prog_en && pc == 7'd1);

            // Cover 3: Sidecar delay counter active
            cover(!i_prog_en && delay_cnt > 16'd0);

            // Cover 4: Input event causing state transition
            cover(!i_prog_en && $past(i_gpio[0]) == 1'b0 && pc == 7'd1);
        end
    end

`endif
