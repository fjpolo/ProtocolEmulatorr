// =============================================================================
// File        : properties.v
// Module      : Formal Properties for ProtocolEmulator.v
// Author      : @fjpolo
// Description : Complete formal verification suite for OmniBus core.
//               Covers reset determinism, zero-jitter delay invariant,
//               PC/delay bounding, instruction decoding, and reachability.
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
        `ASSUME(rom[0]  == 16'h31B1);
        `ASSUME(rom[1]  == 16'h33B1);
        `ASSUME(rom[2]  == 16'h31B1);
        `ASSUME(rom[3]  == 16'h33B1);
        `ASSUME(rom[4]  == 16'h31B1);
        `ASSUME(rom[5]  == 16'h33B1);
        `ASSUME(rom[6]  == 16'h31B1);
        `ASSUME(rom[7]  == 16'h33B1);
        `ASSUME(rom[8]  == 16'h31B1);
        `ASSUME(rom[9]  == 16'h33B1);
        `ASSUME(rom[10] == 16'h01B1);
        `ASSUME(rom[11] == 16'h8000);
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
            `ASSERT(o_data == 8'h01);
        end
    end

    // -------------------------------------------------------------------------
    // 3. Safety & Architectural Invariants (BMC & Induction)
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && $past(i_reset_n)) begin
            // Program Counter is strictly bounded within valid microcode range (0..11)
            `ASSERT(pc <= 4'd11);

            // Sidecar delay counter never exceeds maximum programmed delay (433)
            `ASSERT(delay_cnt <= 9'd433);

            // Output data is a registered capture of {3'b000, past(pc), past(tx_reg)}
            `ASSERT(o_data[7:5] == 3'b000);
            `ASSERT(o_data[4:1] == $past(pc));
            `ASSERT(o_data[0] == $past(tx_reg));
        end
    end

    // -------------------------------------------------------------------------
    // 4. Zero-Jitter Execution & Hardware Freezing Contract
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && $past(i_reset_n)) begin
            if ($past(delay_cnt) > 9'd0) begin
                // While counting sidecar delay, PC and TX MUST NOT change (Zero Jitter)
                `ASSERT(pc == $past(pc));
                `ASSERT(tx_reg == $past(tx_reg));
                `ASSERT(delay_cnt == $past(delay_cnt) - 9'd1);
            end else begin
                // When sidecar delay reaches 0, instruction executes deterministically
                case ($past(opcode))
                    4'h3: begin // SET
                        `ASSERT(tx_reg == $past(pin_val));
                        `ASSERT(delay_cnt == $past(delay));
                        `ASSERT(pc == $past(pc) + 4'd1);
                    end
                    4'h0: begin // NOP
                        `ASSERT(tx_reg == $past(tx_reg));
                        `ASSERT(delay_cnt == $past(delay));
                        `ASSERT(pc == $past(pc) + 4'd1);
                    end
                    4'h8: begin // JMP
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
            // Cover 1: Normal transition out of reset
            cover($past(!i_reset_n) && i_reset_n);

            // Cover 2: Start bit driven LOW on UART line
            cover(tx_reg == 1'b0);

            // Cover 3: First instruction (SET tx=0 [433]) loaded and counting down
            cover(pc == 4'd1 && delay_cnt == 9'd430);

            // Cover 4: Countdown progression
            cover(delay_cnt == 9'd420);
        end
    end

`endif
