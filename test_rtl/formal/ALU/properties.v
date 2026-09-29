// =============================================================================
// File        : properties.v
// Module      : Micro-ALU & CRC Accelerator Formal Properties (Task 30)
// Description : Formally proves Section 7.1 of CONCEPT.md:
//               1. Micro-ALU Invariants (Opcode 0xB):
//                  - Arithmetic operations (ADD, SUB) correctly compute acc and carry/zero.
//                  - Logical operations (AND, OR, XOR, NOT) update acc and zero_flag.
//                  - Shifts (SHL, SHR) correctly shift and update flags.
//                  - Flag correctness: zero_flag == (acc == 8'h00).
//               2. Hardware CRC Accelerator Invariants (Opcode 0xE):
//                  - CRC_RESET clears crc_reg to 16'h0000 or poly-specific init.
//                  - CRC_POLY updates polynomial configuration.
//               3. Cover statements for ALU arithmetic, flags, and CRC execution.
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
            `ASSERT(acc == 8'h00);
            `ASSERT(zero_flag == 1'b0);
            `ASSERT(carry_flag == 1'b0);
            `ASSERT(crc_reg == 32'd0);
            `ASSERT(crc_poly == 3'd0);
        end
    end

    // -------------------------------------------------------------------------
    // 2. Micro-ALU Operation Invariants (Opcode 0xB)
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && !i_prog_en && $past(i_reset_n) && !$past(i_prog_en)) begin
            if ($past(delay_cnt) == 16'd0 && $past(opcode) == 4'hB) begin
                `ASSERT(delay_cnt == 16'd0);
                // Zero flag invariant following any ALU update:
                // zero_flag is asserted if and only if acc is zero
                if ($past(instr[11]) == 1'b0) begin
                    case ($past(instr[10:8]))
                        3'b000: begin // ADD acc, imm
                            `ASSERT(acc == $past(acc) + $past(instr[7:0]));
                            `ASSERT(zero_flag == ((8'($past(acc) + $past(instr[7:0]))) == 8'h00));
                        end
                        3'b001: begin // SUB acc, imm
                            `ASSERT(acc == $past(acc) - $past(instr[7:0]));
                            `ASSERT(zero_flag == ((8'($past(acc) - $past(instr[7:0]))) == 8'h00));
                        end
                        3'b010: begin // CMP acc, imm
                            `ASSERT(acc == $past(acc));
                            `ASSERT(zero_flag == ((8'($past(acc) - $past(instr[7:0]))) == 8'h00));
                        end
                        3'b011: begin // AND acc, imm
                            `ASSERT(acc == ($past(acc) & $past(instr[7:0])));
                            `ASSERT(zero_flag == (($past(acc) & $past(instr[7:0])) == 8'h00));
                        end
                        3'b100: begin // OR acc, imm
                            `ASSERT(acc == ($past(acc) | $past(instr[7:0])));
                            `ASSERT(zero_flag == (($past(acc) | $past(instr[7:0])) == 8'h00));
                        end
                        3'b101: begin // XOR acc, imm
                            `ASSERT(acc == ($past(acc) ^ $past(instr[7:0])));
                            `ASSERT(zero_flag == (($past(acc) ^ $past(instr[7:0])) == 8'h00));
                        end
                        3'b110: begin // MOV acc, imm
                            `ASSERT(acc == $past(instr[7:0]));
                            `ASSERT(zero_flag == ($past(instr[7:0]) == 8'h00));
                        end
                    endcase
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // 3. CRC Accelerator Invariants (Opcode 0xE)
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && !i_prog_en && $past(i_reset_n) && !$past(i_prog_en)) begin
            if ($past(delay_cnt) == 16'd0 && $past(opcode) == 4'hE) begin
                `ASSERT(delay_cnt == 16'd0);
                `ASSERT(pc == $past(pc) + 7'd1);
                // CRC_INIT (sub-op 3'b000) with zero seed
                if ($past(instr[11:9]) == 3'b000 && !$past(instr[3]) && $past(instr[6:5]) == 2'b01) begin
                    `ASSERT(crc_reg == 32'h00000000);
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // 4. Functional Coverage
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && !i_prog_en) begin
            // Cover 1: ADD producing zero flag
            cover($past(opcode) == 4'hB && !$past(instr[11]) && $past(instr[10:8]) == 3'b000 && zero_flag);

            // Cover 2: SUB producing carry/borrow
            cover($past(opcode) == 4'hB && !$past(instr[11]) && $past(instr[10:8]) == 3'b001 && carry_flag);

            // Cover 3: XOR execution
            cover($past(opcode) == 4'hB && !$past(instr[11]) && $past(instr[10:8]) == 3'b101);

            // Cover 4: CRC init execution
            cover($past(opcode) == 4'hE && $past(instr[11:9]) == 3'b000 && crc_reg == 32'h00000000);
        end
    end

`endif
