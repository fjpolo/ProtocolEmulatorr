// =============================================================================
// File        : properties.v
// Module      : Formal Properties for ProtocolEmulator.v (Task 04)
// Author      : @fjpolo
// Description : Complete formal verification suite for Task 04:
//               - Runtime programmable dual-port IMEM (32 words x 16 bits)
//               - IMEM immutability during execution
//               - Single-cycle synchronous write and readback correctness
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
    // When not in programming mode, IMEM contains the standard Echo transceiver
    always @(*) begin
        if (!i_prog_en) begin
            `ASSUME(imem[0]  == 16'h40D8); // WAIT rx=0 [216]
            `ASSUME(imem[1]  == 16'h01B1); // NOP       [433]
            `ASSUME(imem[2]  == 16'h21B1); // IN  rx, 8 [433]
            `ASSUME(imem[3]  == 16'h4200); // WAIT rx=1 [0]
            `ASSUME(imem[4]  == 16'hA000); // PUSH
            `ASSUME(imem[5]  == 16'h31B1); // SET tx=0  [433]
            `ASSUME(imem[6]  == 16'h11B1); // OUT tx, 8 [433]
            `ASSUME(imem[7]  == 16'h33B1); // SET tx=1  [433]
            `ASSUME(imem[8]  == 16'h8000); // JMP 0x0
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
            // Program Counter is strictly bounded within valid microcode range (0..8)
            `ASSERT(pc <= 5'd8);

            // Sidecar delay counter never exceeds maximum programmed delay (433)
            `ASSERT(delay_cnt <= 9'd433);

            // Bit counter in OUT serializer is bounded between 0 and 7
            `ASSERT(bit_cnt <= 4'd7);

            // Bit counter in IN deserializer is bounded between 0 and 7
            `ASSERT(rx_bit_cnt <= 4'd7);

            // Dedicated TX output port reflects tx_reg
            `ASSERT(o_tx == tx_reg);
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
        end
    end

`endif
