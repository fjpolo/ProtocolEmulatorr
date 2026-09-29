// =============================================================================
// File        : properties.v
// Module      : TimingZeroJitter Formal Invariants (Task 30)
// Description : Formally proves Section 7.1 of CONCEPT.md:
//               1. Zero-Jitter Hardware Freezing Contract:
//                  While delay_cnt > 0, architectural state (pc, osr, isr,
//                  bit_cnt, rx_bit_cnt, lc0, lc1, in_sck_phase) is strictly frozen.
//               2. Deterministic Timing Countdown:
//                  delay_cnt strictly decrements by 1 each clock cycle until 0.
//               3. Sentinel Baud Resolution:
//                  0xFF ($BAUD) resolves strictly to i_baud_div[8:0].
//                  0xFE ($HBAUD) resolves strictly to i_baud_div[8:1].
//                  0..253 resolves to literal delay value.
//               4. Zero-Overhead Transitions:
//                  Instruction fetch and register state update completes in 1 cycle
//                  when delay_cnt == 0. Total Cycles = 1 + Delay.
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

    // Restrict environment to active microcode execution
    always @(*) begin
        `ASSUME(!i_prog_en);
        `ASSUME(i_baud_div >= 16'd1 && i_baud_div <= 16'd511);
        `ASSUME(imem[0][6:0] <= 7'd127);
        `ASSUME(!jtag_en && !swd_en && !qspi_en);
        `ASSUME(jtag_tms_cnt == 4'd0 && jtag_shift_cnt == 4'd0 && swd_state == 4'd0 && qspi_state == 4'd0);
        `ASSUME(!i_usb_wb_sie_en && !i_usb_wb_tx_token_req && !i_usb_wb_tx_handshake_req);
        `ASSUME(!i_bist_wb_en && !i_bist_wb_start && !i_bist_wb_stop && !i_bist_wb_rst);
        `ASSUME(!i_profiler_wb_arm && !i_profiler_wb_stop && !i_profiler_wb_rst);
        `ASSUME(!bist_en && !usb_sie_en && !glitch_en && !audio_en && !mitm_en && !i2c_slave_en);
    end

    // -------------------------------------------------------------------------
    // 1. Reset Invariants
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && $past(!i_reset_n)) begin
            `ASSERT(pc == 7'd0);
            `ASSERT(delay_cnt == 16'd0);
            `ASSERT(bit_cnt == 4'd0);
            `ASSERT(rx_bit_cnt == 4'd0);
        end
    end

    // -------------------------------------------------------------------------
    // 2. Zero-Jitter Hardware Freezing Invariant
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && !i_prog_en && $past(i_reset_n) && !$past(i_prog_en)) begin
            if ($past(delay_cnt) > 16'd0) begin
                // While delay_cnt is active, core registers are strictly frozen
                `ASSERT(pc == $past(pc));
                `ASSERT(delay_cnt == $past(delay_cnt) - 16'd1);
                `ASSERT(osr == $past(osr));
                `ASSERT(isr == $past(isr));
                `ASSERT(bit_cnt == $past(bit_cnt));
                `ASSERT(rx_bit_cnt == $past(rx_bit_cnt));
                `ASSERT(lc0 == $past(lc0));
                `ASSERT(lc1 == $past(lc1));
                `ASSERT(in_sck_phase == $past(in_sck_phase));
            end
        end
    end

    // -------------------------------------------------------------------------
    // 3. Sentinel Baud Resolution Invariant
    // -------------------------------------------------------------------------
    always @(*) begin
        if (i_reset_n && !i_prog_en) begin
            // eff_sw_delay resolution
            if (instr[7:0] == 8'hFF) begin
                `ASSERT(eff_sw_delay == {7'd0, i_baud_div[8:0]});
            end else if (instr[7:0] == 8'hFE) begin
                `ASSERT(eff_sw_delay == {7'd0, i_baud_div[8:1]});
            end else begin
                `ASSERT(eff_sw_delay == {8'd0, instr[7:0]});
            end

            // eff_delay resolution (9-bit field)
            if (instr[8:0] == 9'h1FF) begin
                `ASSERT(eff_delay == {7'd0, i_baud_div[8:0]});
            end else if (instr[8:0] == 9'h1FE) begin
                `ASSERT(eff_delay == {7'd0, i_baud_div[8:1]});
            end else begin
                `ASSERT(eff_delay == {7'd0, instr[8:0]});
            end
        end
    end

    // -------------------------------------------------------------------------
    // 4. Deterministic Single-Cycle Transitions (Cycles = 1 + Delay)
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && !i_prog_en && $past(i_reset_n) && !$past(i_prog_en)) begin
            if ($past(delay_cnt) == 16'd0) begin
                // NOP (0x0): PC increments by 1, delay_cnt loaded with eff_delay
                if ($past(opcode) == 4'h0) begin
                    `ASSERT(pc == $past(pc) + 7'd1);
                    `ASSERT(delay_cnt == $past(eff_delay));
                end

                // SET (0x3): PC increments by 1, delay_cnt loaded with eff_sw_delay
                if ($past(opcode) == 4'h3) begin
                    `ASSERT(pc == $past(pc) + 7'd1);
                    `ASSERT(delay_cnt == $past(eff_sw_delay));
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // 5. Functional Coverage
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && !i_prog_en) begin
            // Cover 1: Active down-counting freeze
            cover(delay_cnt > 16'd0 && $past(delay_cnt) == delay_cnt + 16'd1);

            // Cover 2: $BAUD sentinel load into delay_cnt
            cover($past(delay_cnt) == 16'd0 && delay_cnt == {7'd0, i_baud_div[8:0]} && i_baud_div[8:0] > 9'd0);

            // Cover 3: $HBAUD sentinel load into delay_cnt
            cover($past(delay_cnt) == 16'd0 && delay_cnt == {7'd0, i_baud_div[8:1]} && i_baud_div[8:1] > 8'd0);
        end
    end

`endif
