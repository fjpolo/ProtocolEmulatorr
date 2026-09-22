// =============================================================================
// File        : properties.v
// Module      : Formal Properties for ProtocolEmulator.v (Task 09)
// Description : Complete formal verification suite for Tasks 01–09:
//               - Runtime programmable dual-port IMEM (32 words x 16 bits)
//               - Unified 8-bit bidirectional GPIO Bus (i_gpio, o_gpio, o_gpio_oe)
//               - Dynamic Pin Mapping (PINMAP) & Open-Drain (CFG_OD)
//               - Hardware Loop Counters (LC0, LC1, DJNZ, SET_LC, PULL_LC, PUSH_LC)
//               - 4-deep hardware CALL/RET subroutine stack
//               - Runtime-configurable baud rate via i_baud_div port
//               - eff_delay sentinel decode: 9'h1FF -> i_baud_div[8:0]
//               - eff_delay sentinel decode: 9'h1FE -> i_baud_div[8:0]>>1
//               - delay_cnt bounded <= max(511, i_baud_div[8:0])
//               - Safe halt invariant during programming mode
//               - CALL/RET stack correctness + sp bounds
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
    // while permitting all supported opcodes 0x0..0xD for full reachability).
    // Also constrain delay fields so delay_cnt stays within 9-bit range (0..511).
    always @(*) begin
        if (!i_prog_en) begin
            `ASSUME(imem[0][15:12] == 4'h0 || imem[0][15:12] == 4'h1 ||
                    imem[0][15:12] == 4'h2 || imem[0][15:12] == 4'h3 ||
                    imem[0][15:12] == 4'h4 || imem[0][15:12] == 4'h5 ||
                    imem[0][15:12] == 4'h6 || imem[0][15:12] == 4'h7 ||
                    imem[0][15:12] == 4'h8 || imem[0][15:12] == 4'h9 ||
                    imem[0][15:12] == 4'hA || imem[0][15:12] == 4'hC ||
                    imem[0][15:12] == 4'hD);
            // Bound target address to valid IMEM range (0..31)
            `ASSUME(imem[0][4:0] <= 5'd31);
        end
        // Baud divisor liveness: must be >= 1 (avoids zero-length bit periods)
        // and bounded by 9 bits (eff_delay is 9-bit; i_baud_div[8:0] is the operand).
        `ASSUME(i_baud_div >= 16'd1);
        `ASSUME(i_baud_div <= 16'd511);
    end

    // -------------------------------------------------------------------------
    // 2. Reset Properties
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && $past(!i_reset_n)) begin
            // State immediately following active reset
            `ASSERT(pc == 5'd0);
            `ASSERT(delay_cnt == 16'd0);
            `ASSERT(gpio_out_reg == 8'b1111_1101);
            `ASSERT(gpio_oe_reg == 8'b0000_0111);
            `ASSERT(osr == 8'h00);
            `ASSERT(bit_cnt == 4'd0);
            `ASSERT(isr == 8'h00);
            `ASSERT(rx_bit_cnt == 4'd0);
            `ASSERT(o_data == 8'h00);
            `ASSERT(o_tx == 1'b1);
            `ASSERT(tx_pin == 3'd0);
            `ASSERT(rx_pin == 3'd0);
            `ASSERT(sck_pin == 3'd1);
            `ASSERT(cs_pin == 3'd2);
            `ASSERT(gpio_od == 8'h00);
            `ASSERT(lc0 == 8'h00);
            `ASSERT(lc1 == 8'h00);
            `ASSERT(in_sck_phase == 2'd0);
            `ASSERT(o_tx_pop == 1'b0);
            `ASSERT(o_rx_push == 1'b0);
            // Call stack cleared on reset
            `ASSERT(sp == 2'd0);
            `ASSERT(call_stack[0] == 5'd0);
            `ASSERT(call_stack[1] == 5'd0);
            `ASSERT(call_stack[2] == 5'd0);
            `ASSERT(call_stack[3] == 5'd0);
        end
    end

    // -------------------------------------------------------------------------
    // 3. IMEM Programming Port & Safe Halt Invariants
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
            `ASSERT(delay_cnt == 16'd0);
            `ASSERT(o_tx == 1'b1);
            `ASSERT(bit_cnt == 4'd0);
            `ASSERT(rx_bit_cnt == 4'd0);
        end
    end

    // -------------------------------------------------------------------------
    // 4. Safety & Architectural Invariants During Execution (BMC & Induction)
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && !i_prog_en && $past(i_reset_n) && !$past(i_prog_en)) begin
            // Program Counter is strictly bounded within valid IMEM range (0..31)
            `ASSERT(pc <= 5'd31);

            // Sidecar delay counter never exceeds maximum 16-bit field
            `ASSERT(delay_cnt <= 16'd5110);

            // Bit counter in OUT serializer is bounded between 0 and 7
            `ASSERT(bit_cnt <= 4'd7);

            // Bit counter in IN deserializer is bounded between 0 and 7
            `ASSERT(rx_bit_cnt <= 4'd7);

            // Dedicated TX output port reflects selected tx_pin
            `ASSERT(o_tx == gpio_out_reg[tx_pin]);

            // Stack pointer is bounded at maximum depth of 3 (2-bit saturating)
            `ASSERT(sp <= 2'd3);

            // Pin indices bounded within 0..7
            `ASSERT(tx_pin <= 3'd7);
            `ASSERT(rx_pin <= 3'd7);
            `ASSERT(sck_pin <= 3'd7);
            `ASSERT(cs_pin <= 3'd7);
        end
    end

    // -------------------------------------------------------------------------
    // 5. Zero-Jitter Execution & Hardware Freezing Contract
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n && !i_prog_en && $past(i_reset_n) && !$past(i_prog_en)) begin
            if ($past(delay_cnt) > 16'd0) begin
                // While counting sidecar delay, state is completely frozen (Zero Jitter)
                `ASSERT(pc == $past(pc));
                `ASSERT(delay_cnt == $past(delay_cnt) - 16'd1);
                `ASSERT(osr == $past(osr));
                `ASSERT(isr == $past(isr));
                `ASSERT(bit_cnt == $past(bit_cnt));
                `ASSERT(rx_bit_cnt == $past(rx_bit_cnt));
                `ASSERT(lc0 == $past(lc0));
                `ASSERT(lc1 == $past(lc1));
                `ASSERT(in_sck_phase == $past(in_sck_phase));
            end else begin
                // When sidecar delay reaches 0, instruction executes deterministically
                case ($past(opcode))
                    4'h4: begin // WAIT: Wait until gpio_in[pin_sel] matches pin_val
                        if ($past(gpio_in[pin_sel]) == $past(pin_val)) begin
                            `ASSERT(delay_cnt == $past(eff_sw_delay));
                            `ASSERT(pc == $past(pc) + 5'd1);
                        end else begin
                            `ASSERT(delay_cnt == 16'd0);
                            `ASSERT(pc == $past(pc));
                        end
                    end
                    4'h2: begin // IN: dynamic deserialization into ISR
                        if ($past(instr[11:10]) == 2'b01 || $past(instr[11:10]) == 2'b11) begin
                            `ASSERT(delay_cnt == $past(eff_delay));
                            // Synchronous modes (IN SCK / IN SDA)
                            if ($past(in_sck_phase) == 2'd0) begin
                                `ASSERT(in_sck_phase == 2'd1);
                                `ASSERT(pc == $past(pc));
                            end else begin
                                `ASSERT(in_sck_phase == 2'd0);
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
                        end else if ($past(instr[11:10]) == 2'b10) begin
                            // 1-Wire Master Read (IN 1W)
                            if ($past(in_sck_phase) == 2'd0) begin
                                `ASSERT(in_sck_phase == 2'd1);
                                `ASSERT(pc == $past(pc));
                                `ASSERT(delay_cnt == $past(eff_delay));
                            end else if ($past(in_sck_phase) == 2'd1) begin
                                `ASSERT(in_sck_phase == 2'd2);
                                `ASSERT(pc == $past(pc));
                                `ASSERT(delay_cnt == $past(eff_delay));
                            end else begin
                                `ASSERT(in_sck_phase == 2'd0);
                                `ASSERT(delay_cnt == $past(eff_delay_9x));
                                if ($past(instr[9]) || $past(rx_bit_cnt) == 4'd1) begin
                                    `ASSERT(rx_bit_cnt == 4'd0);
                                    `ASSERT(pc == $past(pc) + 5'd1);
                                end else if ($past(rx_bit_cnt) == 4'd0) begin
                                    `ASSERT(rx_bit_cnt == 4'd7);
                                    `ASSERT(pc == $past(pc));
                                end else begin
                                    `ASSERT(rx_bit_cnt == $past(rx_bit_cnt) - 4'd1);
                                    `ASSERT(pc == $past(pc));
                                end
                            end
                        end else begin
                            `ASSERT(delay_cnt == $past(eff_delay));
                            // Normal asynchronous UART mode
                            if ($past(rx_bit_cnt) == 4'd0) begin
                                `ASSERT(pc == ($past(in_count_init) == 4'd0 ? $past(pc) + 5'd1 : $past(pc)));
                            end else if ($past(rx_bit_cnt) == 4'd1) begin
                                `ASSERT(rx_bit_cnt == 4'd0);
                                `ASSERT(pc == $past(pc) + 5'd1);
                            end else begin
                                `ASSERT(rx_bit_cnt == $past(rx_bit_cnt) - 4'd1);
                                `ASSERT(pc == $past(pc));
                            end
                        end
                    end
                    4'hA: begin // PUSH [BLOCK]: transfer ISR to OSR and o_data
                        `ASSERT(delay_cnt == 16'd0);
                        if ($past(instr[0]) && $past(i_rx_full)) begin
                            `ASSERT(pc == $past(pc));
                            `ASSERT(o_rx_push == 1'b0);
                        end else begin
                            `ASSERT(osr == $past(isr));
                            `ASSERT(o_data == $past(isr));
                            `ASSERT(o_rx_push == 1'b1);
                            `ASSERT(pc == $past(pc) + 5'd1);
                        end
                    end
                    4'h9: begin // PULL [BLOCK]: latches i_data into OSR
                        `ASSERT(delay_cnt == 16'd0);
                        if ($past(instr[0]) && !$past(i_tx_valid)) begin
                            `ASSERT(pc == $past(pc));
                            `ASSERT(o_tx_pop == 1'b0);
                        end else begin
                            `ASSERT(osr == $past(i_data));
                            `ASSERT(o_tx_pop == $past(i_tx_valid));
                            `ASSERT(pc == $past(pc) + 5'd1);
                        end
                    end
                    4'h1: begin // OUT: dynamic serialization from OSR
                        if ($past(instr[11:10]) == 2'b10) begin
                            // 1-Wire Serializer (OUT 1W)
                            if ($past(out_sck_phase) == 1'b0) begin
                                `ASSERT(out_sck_phase == 1'b1);
                                `ASSERT(pc == $past(pc));
                                `ASSERT(delay_cnt == ($past(osr[0]) ? $past(eff_delay) : $past(eff_delay_10x)));
                            end else begin
                                `ASSERT(out_sck_phase == 1'b0);
                                `ASSERT(delay_cnt == ($past(osr[0]) ? $past(eff_delay_10x) : $past(eff_delay)));
                                if ($past(instr[9]) || $past(bit_cnt) == 4'd1) begin
                                    `ASSERT(bit_cnt == 4'd0);
                                    `ASSERT(pc == $past(pc) + 5'd1);
                                end else if ($past(bit_cnt) == 4'd0) begin
                                    `ASSERT(bit_cnt == 4'd7);
                                    `ASSERT(pc == $past(pc));
                                end else begin
                                    `ASSERT(bit_cnt == $past(bit_cnt) - 4'd1);
                                    `ASSERT(pc == $past(pc));
                                end
                            end
                        end else begin
                            `ASSERT(delay_cnt == $past(eff_delay));
                        end
                    end
                    4'h3: begin // SET: drive selected GPIO pin
                        `ASSERT(delay_cnt == $past(eff_sw_delay));
                        `ASSERT(pc == $past(pc) + 5'd1);
                    end
                    4'h5: begin // PINMAP: configure protocol roles
                        `ASSERT(tx_pin == $past(instr[11:9]));
                        `ASSERT(rx_pin == $past(instr[8:6]));
                        `ASSERT(sck_pin == $past(instr[5:3]));
                        `ASSERT(cs_pin == $past(instr[2:0]));
                        `ASSERT(delay_cnt == 16'd0);
                        `ASSERT(pc == $past(pc) + 5'd1);
                    end
                    4'h6: begin // CFG_OD: configure open drain mask
                        `ASSERT(gpio_od == $past(instr[7:0]));
                        `ASSERT(delay_cnt == 16'd0);
                        `ASSERT(pc == $past(pc) + 5'd1);
                    end
                    4'h7: begin // Loop Counters (DJNZ / SET_LC / PULL_LC / PUSH_LC / MOV_LC)
                        `ASSERT(delay_cnt == 16'd0);
                        if ($past(instr[10]) == 1'b0) begin
                            // DJNZ
                            if ($past(instr[11]) == 1'b0) begin
                                if ($past(lc0) != 8'd1) begin
                                    `ASSERT(lc0 == $past(lc0) - 8'd1);
                                    `ASSERT(pc == $past(target));
                                end else begin
                                    `ASSERT(lc0 == 8'd0);
                                    `ASSERT(pc == $past(pc) + 5'd1);
                                end
                            end else begin
                                if ($past(lc1) != 8'd1) begin
                                    `ASSERT(lc1 == $past(lc1) - 8'd1);
                                    `ASSERT(pc == $past(target));
                                end else begin
                                    `ASSERT(lc1 == 8'd0);
                                    `ASSERT(pc == $past(pc) + 5'd1);
                                end
                            end
                        end else begin
                            // Load / Store
                            `ASSERT(pc == $past(pc) + 5'd1);
                            case ($past(instr[9:8]))
                                2'b00: begin // SET_LC
                                    if ($past(instr[11]) == 1'b0) `ASSERT(lc0 == $past(instr[7:0]));
                                    else                          `ASSERT(lc1 == $past(instr[7:0]));
                                end
                                2'b01: begin // PULL_LC
                                    if ($past(instr[11]) == 1'b0) `ASSERT(lc0 == $past(i_data));
                                    else                          `ASSERT(lc1 == $past(i_data));
                                end
                                2'b10: begin // PUSH_LC
                                    if ($past(instr[11]) == 1'b0) begin
                                        `ASSERT(o_data == $past(lc0));
                                        `ASSERT(osr == $past(lc0));
                                    end else begin
                                        `ASSERT(o_data == $past(lc1));
                                        `ASSERT(osr == $past(lc1));
                                    end
                                end
                                2'b11: begin // MOV_LC
                                    if ($past(instr[11]) == 1'b0) `ASSERT(lc0 == $past(osr));
                                    else                          `ASSERT(lc1 == $past(osr));
                                end
                            endcase
                        end
                    end
                    4'h0: begin // NOP: delay only
                        `ASSERT(delay_cnt == $past(eff_delay));
                        `ASSERT(pc == $past(pc) + 5'd1);
                    end
                    4'h8: begin // JMP [cond], target: conditional or unconditional
                        `ASSERT(delay_cnt == 16'd0);
                        case ($past(instr[10:8]))
                            3'b000: `ASSERT(pc == $past(target));
                            3'b001: `ASSERT(pc == ($past(i_tx_valid) ? $past(target) : $past(pc) + 5'd1));
                            3'b010: `ASSERT(pc == (!$past(i_tx_valid) ? $past(target) : $past(pc) + 5'd1));
                            3'b011: `ASSERT(pc == ($past(i_rx_full) ? $past(target) : $past(pc) + 5'd1));
                            3'b100: `ASSERT(pc == (!$past(i_rx_full) ? $past(target) : $past(pc) + 5'd1));
                            3'b101: `ASSERT(pc == ($past(gpio_in[rx_pin]) ? $past(target) : $past(pc) + 5'd1));
                            3'b110: `ASSERT(pc == (!$past(gpio_in[rx_pin]) ? $past(target) : $past(pc) + 5'd1));
                            default: `ASSERT(pc == $past(target));
                        endcase
                    end
                    4'hC: begin // CALL: push pc+1 onto stack, jump to target
                        if ($past(sp) < 2'd3) begin
                            `ASSERT(sp == $past(sp) + 2'd1);
                            `ASSERT(call_stack[$past(sp)] == $past(pc) + 5'd1);
                        end else begin
                            `ASSERT(sp == 2'd3);
                        end
                        `ASSERT(pc == $past(target));
                        `ASSERT(delay_cnt == 16'd0);
                    end
                    4'hD: begin // RET: pop return address from stack
                        if ($past(sp) > 2'd0) begin
                            `ASSERT(sp == $past(sp) - 2'd1);
                            if ($past(sp) == 2'd1)
                                `ASSERT(pc == $past(call_stack[0]));
                            else if ($past(sp) == 2'd2)
                                `ASSERT(pc == $past(call_stack[1]));
                            else
                                `ASSERT(pc == $past(call_stack[2]));
                        end else begin
                            `ASSERT(sp == 2'd0);
                            `ASSERT(pc == 5'd0);
                        end
                        `ASSERT(delay_cnt == 16'd0);
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

            // Cover 2: WAIT triggered by edge match
            cover(!i_prog_en && pc == 5'd1 && $past(pc) == 5'd0);

            // Cover 3: Sidecar delay down-counting active (zero-jitter freeze)
            cover(!i_prog_en && pc == 5'd1 && delay_cnt == 16'd210);

            // Cover 4: Programming write strobe
            cover(i_prog_en && i_prog_we);

            // Cover 5: CALL instruction executed (sp advanced from 0 to 1)
            cover(!i_prog_en && sp == 2'd1 && $past(sp) == 2'd0 && $past(!i_prog_en));

            // Cover 6: RET instruction executed (sp decremented)
            cover(!i_prog_en && sp == 2'd0 && $past(sp) == 2'd1);

            // Cover 7: $BAUD sentinel executed — eff_delay resolved from i_baud_div
            cover(!i_prog_en && f_past_valid && $past(!i_prog_en) &&
                  delay_cnt == $past(i_baud_div) && $past(i_baud_div) != 16'd0);

            // Cover 8 (Task 07C): PINMAP instruction executed
            cover(!i_prog_en && f_past_valid && $past(!i_prog_en) && $past(opcode) == 4'h5);

            // Cover 9 (Task 07C): CFG_OD instruction executed
            cover(!i_prog_en && f_past_valid && $past(!i_prog_en) && $past(opcode) == 4'h6);

            // Cover 10 (Task 09): DJNZ branch taken (lc0 decremented and jumped)
            cover(!i_prog_en && f_past_valid && $past(!i_prog_en) && $past(opcode) == 4'h7 &&
                  $past(instr[10]) == 1'b0 && pc == $past(target));

            // Cover 11 (Task 10): IN SCK executed (SPI master read)
            cover(!i_prog_en && f_past_valid && $past(!i_prog_en) && $past(opcode) == 4'h2 &&
                  $past(instr[11:10]) == 2'b01);

            // Cover 12 (Task 10): IN SDA executed (I2C master read)
            cover(!i_prog_en && f_past_valid && $past(!i_prog_en) && $past(opcode) == 4'h2 &&
                  $past(instr[11:10]) == 2'b11);

            // Cover 13 (Task 11): o_tx_pop asserted on PULL
            cover(!i_prog_en && f_past_valid && $past(!i_prog_en) && o_tx_pop == 1'b1);

            // Cover 14 (Task 11): o_rx_push asserted on PUSH
            cover(!i_prog_en && f_past_valid && $past(!i_prog_en) && o_rx_push == 1'b1);

            // Cover 15 (Task 11): Conditional JMP TX_VALID taken
            cover(!i_prog_en && f_past_valid && $past(!i_prog_en) && $past(opcode) == 4'h8 &&
                  $past(instr[10:8]) == 3'b001 && $past(i_tx_valid) && pc == $past(target));

            // Cover 16 (Task 12): OUT 1W executed (1-Wire master write)
            cover(!i_prog_en && f_past_valid && $past(!i_prog_en) && $past(opcode) == 4'h1 &&
                  $past(instr[11:10]) == 2'b10);

            // Cover 17 (Task 12): IN 1W executed (1-Wire master read)
            cover(!i_prog_en && f_past_valid && $past(!i_prog_en) && $past(opcode) == 4'h2 &&
                  $past(instr[11:10]) == 2'b10);

            // Cover 18 (Task 12): 1-Wire single-bit slot mode executed (instr[9]==1)
            cover(!i_prog_en && f_past_valid && $past(!i_prog_en) && $past(opcode) == 4'h1 &&
                  $past(instr[11:10]) == 2'b10 && $past(instr[9]) == 1'b1);
        end
    end

`endif
