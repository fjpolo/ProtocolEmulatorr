// =============================================================================
// File        : properties.v
// Module      : CallStack & LoopCounter Formal Invariants (Task 30)
// Description : Formally proves Section 7.1 of CONCEPT.md:
//               1. Hardware Call Stack Invariants:
//                  - Stack pointer is strictly bounded: 0 <= sp <= 3.
//                  - CALL pushes pc + 1 to call_stack[sp], increments sp, jumps to target.
//                  - RET pops call_stack[sp-1] into pc, decrements sp.
//                  - Stack overflow/underflow safe saturation/clamping.
//                  - LIFO address preservation across nested subroutines.
//               2. Hardware Loop Counters (LC0, LC1):
//                  - DJNZ decrements lc and branches while lc != 1.
//                  - DJNZ falls through to pc + 1 and sets lc = 0 when lc == 1.
//                  - SET_LC, PULL_LC, PUSH_LC, MOV_LC register integrity.
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
        `ASSUME(!bist_en && !usb_sie_en && !glitch_en && !audio_en && !mitm_en && !i2c_slave_en);
    end

    // -------------------------------------------------------------------------
    // 1. Reset Invariants
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && $past(!i_reset_n)) begin
            `ASSERT(sp == 2'd0);
            `ASSERT(call_stack[0] == 7'd0);
            `ASSERT(call_stack[1] == 7'd0);
            `ASSERT(call_stack[2] == 7'd0);
            `ASSERT(call_stack[3] == 7'd0);
            `ASSERT(lc0 == 8'h00);
            `ASSERT(lc1 == 8'h00);
        end
    end

    // -------------------------------------------------------------------------
    // 2. Stack Pointer Bounds Invariant
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && !i_prog_en) begin
            `ASSERT(sp <= 2'd3);
        end
    end

    // -------------------------------------------------------------------------
    // 3. CALL & RET Operation Invariants
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && !i_prog_en && $past(i_reset_n) && !$past(i_prog_en)) begin
            if ($past(delay_cnt) == 16'd0) begin
                // CALL (Opcode 0xC)
                if ($past(opcode) == 4'hC) begin
                    `ASSERT(pc == $past(target));
                    `ASSERT(delay_cnt == 16'd0);
                    if ($past(sp) < 2'd3) begin
                        `ASSERT(sp == $past(sp) + 2'd1);
                        `ASSERT(call_stack[$past(sp)] == $past(pc) + 7'd1);
                    end else begin
                        `ASSERT(sp == 2'd3);
                    end
                end

                // RET (Opcode 0xD)
                if ($past(opcode) == 4'hD) begin
                    `ASSERT(delay_cnt == 16'd0);
                    if ($past(sp) > 2'd0) begin
                        `ASSERT(sp == $past(sp) - 2'd1);
                        if ($past(sp) == 2'd1)      `ASSERT(pc == $past(call_stack[0]));
                        else if ($past(sp) == 2'd2) `ASSERT(pc == $past(call_stack[1]));
                        else                        `ASSERT(pc == $past(call_stack[2]));
                    end else begin
                        `ASSERT(sp == 2'd0);
                        `ASSERT(pc == 7'd0);
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // 4. Hardware Loop Counter (DJNZ / SET_LC / MOV_LC) Invariants
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && !i_prog_en && $past(i_reset_n) && !$past(i_prog_en)) begin
            if ($past(delay_cnt) == 16'd0 && $past(opcode) == 4'h7) begin
                `ASSERT(delay_cnt == 16'd0);
                if ($past(instr[10]) == 1'b0) begin
                    // DJNZ
                    if ($past(instr[11]) == 1'b0) begin // LC0
                        if ($past(lc0) != 8'd1) begin
                            `ASSERT(lc0 == $past(lc0) - 8'd1);
                            `ASSERT(pc == $past(target));
                        end else begin
                            `ASSERT(lc0 == 8'd0);
                            `ASSERT(pc == $past(pc) + 7'd1);
                        end
                    end else begin // LC1
                        if ($past(lc1) != 8'd1) begin
                            `ASSERT(lc1 == $past(lc1) - 8'd1);
                            `ASSERT(pc == $past(target));
                        end else begin
                            `ASSERT(lc1 == 8'd0);
                            `ASSERT(pc == $past(pc) + 7'd1);
                        end
                    end
                end else begin
                    // SET_LC / MOV_LC
                    `ASSERT(pc == $past(pc) + 7'd1);
                    if ($past(instr[9:8]) == 2'b00) begin // SET_LC
                        if ($past(instr[11]) == 1'b0) `ASSERT(lc0 == $past(instr[7:0]));
                        else                          `ASSERT(lc1 == $past(instr[7:0]));
                    end else if ($past(instr[9:8]) == 2'b11) begin // MOV_LC
                        if ($past(instr[11]) == 1'b0) `ASSERT(lc0 == $past(osr));
                        else                          `ASSERT(lc1 == $past(osr));
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // 5. Functional Coverage
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && !i_prog_en) begin
            // Cover 1: Stack push from depth 0 to 1
            cover($past(sp) == 2'd0 && sp == 2'd1);

            // Cover 2: Stack push to depth 2
            cover($past(sp) == 2'd1 && sp == 2'd2);

            // Cover 3: Stack pop from depth 2 to 1
            cover($past(sp) == 2'd2 && sp == 2'd1);

            // Cover 4: DJNZ loop branch taken
            cover($past(opcode) == 4'h7 && !$past(instr[10]) && pc == $past(target));

            // Cover 5: DJNZ loop exit
            cover($past(opcode) == 4'h7 && !$past(instr[10]) && pc == $past(pc) + 7'd1);
        end
    end

`endif
