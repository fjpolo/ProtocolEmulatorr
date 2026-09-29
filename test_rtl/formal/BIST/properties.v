// =============================================================================
// File        : properties.v
// Module      : Virtual Crossbar & Autonomous BIST Formal Properties (Task 30)
// Description : Formally proves Section 7.1 of CONCEPT.md:
//               1. Virtual Crossbar Matrix Routing:
//                  - Direct loopback mode connects outputs directly to inputs.
//                  - Dual-channel split mode routes Ch0 (0->1) and Ch1 (4->5).
//               2. BIST Autonomous Controller Invariants:
//                  - Reset initializes BIST registers to known safe state.
//                  - Sticky Error Flag: once bist_fail_flag is asserted, it
//                    remains asserted until explicit BIST reset (no false clears).
//                  - Monotonic score counter: score values never decrement.
//               3. Functional Coverage:
//                  - BIST start, execution, and error detection.
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
        `ASSUME(!i_profiler_wb_arm && !i_profiler_wb_stop && !i_profiler_wb_rst);
        `ASSUME(!usb_sie_en && !glitch_en && !audio_en && !mitm_en && !i2c_slave_en);
    end

    // -------------------------------------------------------------------------
    // 1. Reset Invariants
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && $past(!i_reset_n)) begin
            `ASSERT(bist_en == 1'b0);
            `ASSERT(bist_active == 1'b0);
            `ASSERT(bist_stage == 4'd0);
            `ASSERT(bist_fail_flag == 1'b0);
            `ASSERT(bist_vec_cnt == 16'd0);
            `ASSERT(bist_pass_cnt == 16'd0);
            `ASSERT(bist_fail_cnt == 16'd0);
        end
    end

    // -------------------------------------------------------------------------
    // 2. Virtual Crossbar Routing Invariants
    // -------------------------------------------------------------------------
    always @(*) begin
        if (i_reset_n && !i_prog_en) begin
            if (!bist_en) begin
                `ASSERT(eff_gpio_src == i_gpio);
            end else if (!bist_jitter_en && (bist_mode != 2'b11)) begin
                if (bist_mode == 2'b01) begin
                    // Direct loopback mode: output looped to input
                    `ASSERT(eff_gpio_src == o_gpio);
                end else if (bist_mode == 2'b10) begin
                    // Dual-channel split crossbar mode
                    `ASSERT(eff_gpio_src == bist_split_mux);
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // 3. Sticky Error Invariant (Never clears during active test)
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && !i_prog_en && $past(i_reset_n) && !$past(i_prog_en)) begin
            if ($past(bist_fail_flag) && !i_bist_wb_rst && !($past(delay_cnt) == 16'd0 && $past(opcode) == 4'hF && $past(instr[11:0]) == 12'h4E6)) begin
                `ASSERT(bist_fail_flag == 1'b1);
            end
        end
    end

    // -------------------------------------------------------------------------
    // 4. Monotonic Scoring Invariant
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && !i_prog_en && $past(i_reset_n) && !$past(i_prog_en)) begin
            if (!i_bist_wb_rst && !($past(delay_cnt) == 16'd0 && $past(opcode) == 4'hF && $past(instr[11:0]) == 12'h4E6)) begin
                `ASSERT(bist_pass_cnt >= $past(bist_pass_cnt));
                `ASSERT(bist_fail_cnt >= $past(bist_fail_cnt));
            end
        end
    end

    // -------------------------------------------------------------------------
    // 5. Functional Coverage
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && !i_prog_en) begin
            // Cover 1: BIST activated
            cover(bist_en && bist_active);

            // Cover 2: Direct loopback mode active
            cover(bist_en && bist_mode == 2'b01);

            // Cover 3: Split channel mode active
            cover(bist_en && bist_mode == 2'b10);

            // Cover 4: Sticky fail flag captured
            cover(bist_fail_flag);
        end
    end

`endif
