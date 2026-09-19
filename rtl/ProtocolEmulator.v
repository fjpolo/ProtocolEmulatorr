// =============================================================================
// File        : ProtocolEmulator.v
// Module      : ProtocolEmulator (OmniBus Deterministic Protocol Engine)
// Description : Cycle-deterministic micro-engine with Output Shift Register (OSR)
//               and multi-cycle bit serializer (OUT) executing 115200-baud UART.
// License     : MIT License
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module ProtocolEmulator(
    input   wire            i_clk,
    input   wire            i_reset_n,
    input   wire    [7:0]   i_data,
    output  reg     [7:0]   o_data
);

    // -------------------------------------------------------------------------
    // Execution State Registers
    // -------------------------------------------------------------------------
    reg [3:0]  pc;
    reg [8:0]  delay_cnt;
    reg        tx_reg;
    reg [7:0]  osr;       // Output Shift Register
    reg [3:0]  bit_cnt;   // Serialization bit counter

    // -------------------------------------------------------------------------
    // Microcode ROM (16 words x 16 bits)
    // -------------------------------------------------------------------------
    // Opcode [15:12]:
    //   0x0 = NOP  [8:0 delay]
    //   0x1 = OUT  [9 dir, 8:0 delay] (Serializes bits from OSR to TX)
    //   0x3 = SET  [9 pin_val, 8:0 delay]
    //   0x8 = JMP  [3:0 target]
    //   0x9 = PULL (Latches i_data[7:0] into OSR)
    reg [15:0] rom [0:15];

    initial begin
        // UART Transmitter sending dynamic i_data @ 115200 baud on 50 MHz clock
        // 50 MHz / 115200 baud = 434 cycles/bit (1 cycle execution + 433 delay)
        rom[0]  = 16'h9000; // PULL        (Latch i_data into OSR)
        rom[1]  = 16'h31B1; // SET tx=0 [433] (Start bit, logic 0)
        rom[2]  = 16'h11B1; // OUT tx, 8 [433] (Serialize 8 data bits LSB-first)
        rom[3]  = 16'h33B1; // SET tx=1 [433] (Stop bit, logic 1)
        rom[4]  = 16'h01B1; // NOP      [433] (Inter-character gap, idle 1)
        rom[5]  = 16'h8000; // JMP 0x0        (Repeat / fetch next byte)
        rom[6]  = 16'h0000;
        rom[7]  = 16'h0000;
        rom[8]  = 16'h0000;
        rom[9]  = 16'h0000;
        rom[10] = 16'h0000;
        rom[11] = 16'h0000;
        rom[12] = 16'h0000;
        rom[13] = 16'h0000;
        rom[14] = 16'h0000;
        rom[15] = 16'h0000;
    end

    wire [15:0] instr   = rom[pc];
    wire [3:0]  opcode  = instr[15:12];
    wire        pin_val = instr[9];
    wire [8:0]  delay   = instr[8:0];
    wire [3:0]  target  = instr[3:0];

    wire        tx_busy = (pc != 4'd0);

    always @(posedge i_clk) begin
        if (!i_reset_n) begin
            pc        <= 4'd0;
            delay_cnt <= 9'd0;
            tx_reg    <= 1'b1; // UART idle state is high
            osr       <= 8'h00;
            bit_cnt   <= 4'd0;
            o_data    <= 8'h01;
        end else begin
            if (delay_cnt > 9'd0) begin
                // Counting down sidecar delay
                delay_cnt <= delay_cnt - 9'd1;
            end else begin
                // Execute current instruction
                case (opcode)
                    4'h9: begin // PULL: Latch input data into OSR
                        osr       <= i_data;
                        delay_cnt <= 9'd0;
                        pc        <= pc + 4'd1;
                    end
                    4'h1: begin // OUT: Multi-cycle dynamic serialization from OSR
                        tx_reg    <= osr[0];
                        osr       <= {1'b0, osr[7:1]};
                        delay_cnt <= delay;
                        if (bit_cnt == 4'd0) begin
                            // First bit being driven; 7 more bits follow
                            bit_cnt <= 4'd7;
                            pc      <= pc;
                        end else if (bit_cnt == 4'd1) begin
                            // Last bit (bit 7) being driven; advance PC for next instruction
                            bit_cnt <= 4'd0;
                            pc      <= pc + 4'd1;
                        end else begin
                            // Middle bits (1 through 6)
                            bit_cnt <= bit_cnt - 4'd1;
                            pc      <= pc;
                        end
                    end
                    4'h3: begin // SET: Drive immediate pin value
                        tx_reg    <= pin_val;
                        delay_cnt <= delay;
                        pc        <= pc + 4'd1;
                    end
                    4'h0: begin // NOP: Pure delay
                        delay_cnt <= delay;
                        pc        <= pc + 4'd1;
                    end
                    4'h8: begin // JMP: Jump to target address
                        delay_cnt <= 9'd0;
                        pc        <= target;
                    end
                    default: begin
                        pc        <= pc + 4'd1;
                    end
                endcase
            end

            // Drive outputs:
            // bit 0: UART TX signal
            // bits [4:1]: current PC (visible activity on debug LEDs)
            // bits [6:5]: constant zeros
            // bit 7: tx_busy flag
            o_data <= {tx_busy, 2'b00, pc, tx_reg};
        end
    end

endmodule
