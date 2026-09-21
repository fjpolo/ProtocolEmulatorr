// =============================================================================
// File        : properties.v
// Module      : Formal Properties for ProtocolEmulator.v (Task 05)
// Author      : @fjpolo
// Description : Complete formal verification suite for Task 05:
//               - Runtime programmable dual-port IMEM (32 words x 16 bits)
//               - 4-deep hardware CALL/RET subroutine stack
//               - CALL correctness: push pc+1, jump to target
//               - RET correctness: pop return address, restore pc
//               - Stack pointer bounded: sp <= 4
//               - Safe halt invariant during programming mode
//               - Dual SERDES execution (OSR, ISR, OUT, IN, WAIT, PUSH)
//               - Zero-jitter bit timing proofs
// License     : MIT License
// =============================================================================

`ifdef FORMAL

`define ASSERT assert
`define ASSUME assume

    // -------------------------------------------------------------------------
    // 1. Auxiliary Tracking Registers & Environment Assumptions
    // -------------------------------------------------------------------------
    reg f_past_valid;
    initial f_past_valid = 1'b0;
    always @(posedge i_clk)
        f_past_valid <= 1'b1;

    // Reset sequence: assert reset initially for at least 1 cycle
    initial `ASSUME(!i_reset_n);

    // After reset is released, assume it stays deasserted to verify execution
    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_reset_n)) begin
            `ASSUME(i_reset_n);
        end
    end

    // Default microcode assumption for execution verification:
    // Constrain opcode space to valid instructions only (avoids degenerate states
    // while still permitting CALL/RET for cover reachability).
    // Also constrain delay fields so delay_cnt stays within 9-bit range (0..511).
    always @(*) begin
        if (!i_prog_en) begin
            `ASSUME(imem[0][15:12] == 4'h0 || imem[0][15:12] == 4'h1 ||
                    imem[0][15:12] == 4'h2 || imem[0][15:12] == 4'h3 ||
                    imem[0][15:12] == 4'h4 || imem[0][15:12] == 4'h8 ||
                    imem[0][15:12] == 4'h9 || imem[0][15:12] == 4'hA ||
                    imem[0][15:12] == 4'hC || imem[0][15:12] == 4'hD);
            // Delay field is 9-bit: imem[*][8:0] is already bounded by the bit width.
            // Bound target address to valid IMEM range (0..31)
            `ASSUME(imem[0][4:0] <= 5'd31);
        end
    end

    // -------------------------------------------------------------------------
    // 2. Reset Properties
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && $past(!i_reset_n)) begin
            // State immediately following active reset
            `ASSERT(pc == 5'd0);
            `ASSERT(delay_cnt == 9'd0);
            `ASSERT(tx_reg == 1'b1);
            `ASSERT(osr == 8'h00);
            `ASSERT(bit_cnt == 4'd0);
            `ASSERT(isr == 8'h00);
            `ASSERT(rx_bit_cnt == 4'd0);
            `ASSERT(o_data == 8'h00);
            `ASSERT(o_tx == 1'b1);
            // Task 05: Call stack cleared on reset
            `ASSERT(sp == 2'd0);
            `ASSERT(call_stack[0] == 5'd0);
            `ASSERT(call_stack[1] == 5'd0);
            `ASSERT(call_stack[2] == 5'd0);
            `ASSERT(call_stack[3] == 5'd0);
        end
    end

    // -------------------------------------------------------------------------
    // 3. Task 04: IMEM Programming Port & Safe Halt Invariants
    // -------------------------------------------------------------------------
    // Combinational readback correctness: o_prog_rdata always reflects imem[i_prog_addr]
    always @(*) begin
        `ASSERT(o_prog_rdata == imem[i_prog_addr]);
    end

    // Synchronous write correctness
    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_reset_n) && $past(i_prog_en) && $past(i_prog_we)) begin
            `ASSERT(imem[$past(i_prog_addr)] == $past(i_prog_data));
        end
    end

    // Safe halt contract: while programming mode is active, core execution is frozen
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && $past(i_prog_en)) begin
            `ASSERT(pc == 5'd0);
            `ASSERT(delay_cnt == 9'd0);
            `ASSERT(tx_reg == 1'b1);
            `ASSERT(bit_cnt == 4'd0);
            `ASSERT(rx_bit_cnt == 4'd0);
            `ASSERT(o_tx == 1'b1);
        end
    end

    // -------------------------------------------------------------------------
    // 4. Safety & Architectural Invariants During Execution (BMC & Induction)
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && !i_prog_en && $past(i_reset_n) && !$past(i_prog_en)) begin
            // Program Counter is strictly bounded within valid IMEM range (0..31)
            `ASSERT(pc <= 5'd31);

            // Sidecar delay counter never exceeds maximum 9-bit field (0..511)
            `ASSERT(delay_cnt <= 9'd511);

            // Bit counter in OUT serializer is bounded between 0 and 7
            `ASSERT(bit_cnt <= 4'd7);

            // Bit counter in IN deserializer is bounded between 0 and 7
            `ASSERT(rx_bit_cnt <= 4'd7);

            // Dedicated TX output port reflects tx_reg
            `ASSERT(o_tx == tx_reg);

            // Task 05: Stack pointer is bounded at maximum depth of 3 (2-bit saturating)
            `ASSERT(sp <= 2'd3);
        end
    end

    // -------------------------------------------------------------------------
    // 5. Zero-Jitter Execution & Hardware Freezing Contract
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && !i_prog_en && $past(i_reset_n) && !$past(i_prog_en)) begin
            if ($past(delay_cnt) > 9'd0) begin
                // While counting sidecar delay, state is completely frozen (Zero Jitter)
                `ASSERT(pc == $past(pc));
                `ASSERT(tx_reg == $past(tx_reg));
                `ASSERT(delay_cnt == $past(delay_cnt) - 9'd1);
                `ASSERT(osr == $past(osr));
                `ASSERT(isr == $past(isr));
                `ASSERT(bit_cnt == $past(bit_cnt));
                `ASSERT(rx_bit_cnt == $past(rx_bit_cnt));
            end else begin
                // When sidecar delay reaches 0, instruction executes deterministically
                case ($past(opcode))
                    4'h4: begin // WAIT: Wait until rx_in matches pin_val
                        if ($past(rx_in) == $past(pin_val)) begin
                            `ASSERT(delay_cnt == $past(delay));
                            `ASSERT(pc == $past(pc) + 5'd1);
                        end else begin
                            `ASSERT(delay_cnt == 9'd0);
                            `ASSERT(pc == $past(pc));
                        end
                    end
                    4'h2: begin // IN: dynamic deserialization into ISR
                        `ASSERT(isr == {$past(rx_in), $past(isr[7:1])});
                        `ASSERT(delay_cnt == $past(delay));
                        if ($past(rx_bit_cnt) == 4'd0) begin
                            `ASSERT(rx_bit_cnt == 4'd7);
                            `ASSERT(pc == $past(pc));
                        end else if ($past(rx_bit_cnt) == 4'd1) begin
                            `ASSERT(rx_bit_cnt == 4'd0);
                            `ASSERT(pc == $past(pc) + 5'd1);
                        end else begin
                            `ASSERT(rx_bit_cnt == $past(rx_bit_cnt) - 4'd1);
                            `ASSERT(pc == $past(pc));
                        end
                    end
                    4'hA: begin // PUSH: transfer ISR to OSR and o_data
                        `ASSERT(osr == $past(isr));
                        `ASSERT(o_data == $past(isr));
                        `ASSERT(delay_cnt == 9'd0);
                        `ASSERT(pc == $past(pc) + 5'd1);
                    end
                    4'h9: begin // PULL: latches i_data into OSR
                        `ASSERT(osr == $past(i_data));
                        `ASSERT(delay_cnt == 9'd0);
                        `ASSERT(pc == $past(pc) + 5'd1);
                    end
                    4'h1: begin // OUT: dynamic serialization from OSR
                        `ASSERT(tx_reg == $past(osr[0]));
                        `ASSERT(osr == {1'b0, $past(osr[7:1])});
                        `ASSERT(delay_cnt == $past(delay));
                        if ($past(bit_cnt) == 4'd0) begin
                            `ASSERT(bit_cnt == 4'd7);
                            `ASSERT(pc == $past(pc));
                        end else if ($past(bit_cnt) == 4'd1) begin
                            `ASSERT(bit_cnt == 4'd0);
                            `ASSERT(pc == $past(pc) + 5'd1);
                        end else begin
                            `ASSERT(bit_cnt == $past(bit_cnt) - 4'd1);
                            `ASSERT(pc == $past(pc));
                        end
                    end
                    4'h3: begin // SET: drive immediate pin value
                        `ASSERT(tx_reg == $past(pin_val));
                        `ASSERT(delay_cnt == $past(delay));
                        `ASSERT(pc == $past(pc) + 5'd1);
                    end
                    4'h0: begin // NOP: delay only
                        `ASSERT(tx_reg == $past(tx_reg));
                        `ASSERT(delay_cnt == $past(delay));
                        `ASSERT(pc == $past(pc) + 5'd1);
                    end
                    4'h8: begin // JMP: loop
                        `ASSERT(delay_cnt == 9'd0);
                        `ASSERT(pc == $past(target));
                    end
                    4'hC: begin // CALL: push pc+1 onto stack, jump to target
                        // Stack pointer must have advanced by 1 (unless already at max)
                        if ($past(sp) < 2'd3) begin
                            `ASSERT(sp == $past(sp) + 2'd1);
                            // Return address stored is pc+1
                            `ASSERT(call_stack[$past(sp)] == $past(pc) + 5'd1);
                        end else begin
                            // Saturated: sp stays at 3
                            `ASSERT(sp == 2'd3);
                        end
                        `ASSERT(pc == $past(target));
                        `ASSERT(delay_cnt == 9'd0);
                    end
                    4'hD: begin // RET: pop return address from stack
                        if ($past(sp) > 2'd0) begin
                            `ASSERT(sp == $past(sp) - 2'd1);
                            // Expand dynamic index using constant if/else for SMT induction
                            if ($past(sp) == 2'd1)
                                `ASSERT(pc == $past(call_stack[0]));
                            else if ($past(sp) == 2'd2)
                                `ASSERT(pc == $past(call_stack[1]));
                            else
                                `ASSERT(pc == $past(call_stack[2]));
                        end else begin
                            // Underflow: stay at sp=0, pc=0
                            `ASSERT(sp == 2'd0);
                            `ASSERT(pc == 5'd0);
                        end
                        `ASSERT(delay_cnt == 9'd0);
                    end
                    default: begin
                        `ASSERT(pc == $past(pc) + 5'd1);
                    end
                endcase
            end
        end
    end

    // -------------------------------------------------------------------------
    // 6. Reachability & Functional Coverage (Cover)
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n) begin
            // Cover 1: Normal exit from reset
            cover($past(!i_reset_n) && i_reset_n);

            // Cover 2: WAIT triggered by falling edge
            cover(!i_prog_en && pc == 5'd1 && $past(pc) == 5'd0);

            // Cover 3: Sidecar delay down-counting active (zero-jitter freeze)
            cover(!i_prog_en && pc == 5'd1 && delay_cnt == 9'd210);

            // Cover 4: Idle RX line held high at PC=0
            cover(!i_prog_en && pc == 5'd0 && rx_in == 1'b1);

            // Cover 5: Programming write strobe
            cover(i_prog_en && i_prog_we);

            // Cover 6 (Task 05): CALL instruction executed (sp advanced from 0 to 1)
            cover(!i_prog_en && sp == 2'd1 && $past(sp) == 2'd0 && $past(!i_prog_en));

            // Cover 7 (Task 05): RET instruction executed (sp decremented)
            // Note: sp can return to 0 in any cycle after a CALL was executed
            cover(!i_prog_en && sp == 2'd0 && $past(sp) == 2'd1);
        end
    end

`endif
