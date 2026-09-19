// =============================================================================
// File        : properties.v
// Module      : Formal Properties for ProtocolEmulator.v (Task 02)
// Author      : @fjpolo
// Description : Complete formal verification suite for Task 02 dynamic
//               serializer (OSR, OUT, PULL) with zero-jitter proofs.
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

    // Constrain ROM contents to remain constant across induction steps
    always @(*) begin
        `ASSUME(rom[0]  == 16'h9000); // PULL
        `ASSUME(rom[1]  == 16'h31B1); // SET tx=0 [433]
        `ASSUME(rom[2]  == 16'h11B1); // OUT tx, 8 [433]
        `ASSUME(rom[3]  == 16'h33B1); // SET tx=1 [433]
        `ASSUME(rom[4]  == 16'h01B1); // NOP [433]
        `ASSUME(rom[5]  == 16'h8000); // JMP 0x0
    end

    // -------------------------------------------------------------------------
    // 2. Reset Properties
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && $past(!i_reset_n)) begin
            // State immediately following active reset
            `ASSERT(pc == 4'd0);
            `ASSERT(delay_cnt == 9'd0);
            `ASSERT(tx_reg == 1'b1);
            `ASSERT(osr == 8'h00);
            `ASSERT(bit_cnt == 4'd0);
            `ASSERT(o_data == 8'h01);
        end
    end

    // -------------------------------------------------------------------------
    // 3. Safety & Architectural Invariants (BMC & Induction)
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && $past(i_reset_n)) begin
            // Program Counter is strictly bounded within valid microcode range (0..5)
            `ASSERT(pc <= 4'd5);

            // Sidecar delay counter never exceeds maximum programmed delay (433)
            `ASSERT(delay_cnt <= 9'd433);

            // Bit counter in OUT serializer is bounded between 0 and 7
            `ASSERT(bit_cnt <= 4'd7);

            // Output data formatting:
            `ASSERT(o_data[0]   == $past(tx_reg));
            `ASSERT(o_data[4:1] == $past(pc));
            `ASSERT(o_data[6:5] == 2'b00);
            `ASSERT(o_data[7]   == ($past(pc) != 4'd0));
        end
    end

    // -------------------------------------------------------------------------
    // 4. Zero-Jitter Execution & Hardware Freezing Contract
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && $past(i_reset_n)) begin
            if ($past(delay_cnt) > 9'd0) begin
                // While counting sidecar delay, state is completely frozen (Zero Jitter)
                `ASSERT(pc == $past(pc));
                `ASSERT(tx_reg == $past(tx_reg));
                `ASSERT(delay_cnt == $past(delay_cnt) - 9'd1);
                `ASSERT(osr == $past(osr));
                `ASSERT(bit_cnt == $past(bit_cnt));
            end else begin
                // When sidecar delay reaches 0, instruction executes deterministically
                case ($past(opcode))
                    4'h9: begin // PULL: latches i_data into OSR
                        `ASSERT(osr == $past(i_data));
                        `ASSERT(delay_cnt == 9'd0);
                        `ASSERT(pc == $past(pc) + 4'd1);
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
                            `ASSERT(pc == $past(pc) + 4'd1);
                        end else begin
                            `ASSERT(bit_cnt == $past(bit_cnt) - 4'd1);
                            `ASSERT(pc == $past(pc));
                        end
                    end
                    4'h3: begin // SET: drive immediate pin value
                        `ASSERT(tx_reg == $past(pin_val));
                        `ASSERT(delay_cnt == $past(delay));
                        `ASSERT(pc == $past(pc) + 4'd1);
                    end
                    4'h0: begin // NOP: delay only
                        `ASSERT(tx_reg == $past(tx_reg));
                        `ASSERT(delay_cnt == $past(delay));
                        `ASSERT(pc == $past(pc) + 4'd1);
                    end
                    4'h8: begin // JMP: loop
                        `ASSERT(delay_cnt == 9'd0);
                        `ASSERT(pc == $past(target));
                    end
                    default: begin
                        `ASSERT(pc == $past(pc) + 4'd1);
                    end
                endcase
            end
        end
    end

    // -------------------------------------------------------------------------
    // 5. Reachability & Functional Coverage (Cover)
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n) begin
            // Cover 1: Normal exit from reset
            cover($past(!i_reset_n) && i_reset_n);

            // Cover 2: PULL executed and latched dynamic byte into OSR
            cover(pc == 4'd1 && osr == $past(i_data));

            // Cover 3: Start bit 0 asserted on TX
            cover(tx_reg == 1'b0);

            // Cover 4: Start bit sidecar countdown in progress (PC stalled at 2 while counting down start bit)
            cover(pc == 4'd2 && delay_cnt == 9'd420);
        end
    end

`endif
