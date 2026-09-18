// =============================================================================
// File        : ProtocolEmulator.v
// Module      : ProtocolEmulator (OmniBus Minimal 3-Instruction Core)
// Description : Cycle-deterministic micro-engine executing SET, NOP, JMP
//               with hardware sidecar delay to output 115200-baud UART.
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

    // -------------------------------------------------------------------------
    // Microcode ROM (16 words x 16 bits)
    // -------------------------------------------------------------------------
    // Instruction format:
    // [15:12] Opcode: 0x0 = NOP, 0x3 = SET, 0x8 = JMP
    // [11:10] Pin index: 2'b00
    // [9]     Pin value: 1'b0 or 1'b1
    // [8:0]   Sidecar delay: 9-bit counter
    //
    // Timing for 115200 baud on 50 MHz clock:
    // 50,000,000 / 115,200 = 434 cycles per bit.
    // 1 execution cycle + 433 delay cycles = 434 cycles.
    // 433 decimal = 9'h1B1 (bit 8 is 1!).
    //
    // Opcode 0x3 with val=0 and delay 9'h1B1 -> [15:12]=3, [11:9]=000, [8:0]=1B1 -> 16'h31B1
    // Opcode 0x3 with val=1 and delay 9'h1B1 -> [15:12]=3, [11:9]=001, [8:0]=1B1 -> 16'h33B1
    // Opcode 0x0 with delay 9'h1B1          -> [15:12]=0, [11:9]=000, [8:0]=1B1  -> 16'h01B1
    // Opcode 0x8 targeting address 0        -> [15:12]=8, [3:0]=0                -> 16'h8000
    reg [15:0] rom [0:15];

    initial begin
        // UART Transmitter sending 'U' (0x55 = 8'b01010101) @ 115200 baud
        rom[0]  = 16'h31B1; // SET tx=0 [433] (Start bit, logic 0)
        rom[1]  = 16'h33B1; // SET tx=1 [433] (Bit 0 = 1)
        rom[2]  = 16'h31B1; // SET tx=0 [433] (Bit 1 = 0)
        rom[3]  = 16'h33B1; // SET tx=1 [433] (Bit 2 = 1)
        rom[4]  = 16'h31B1; // SET tx=0 [433] (Bit 3 = 0)
        rom[5]  = 16'h33B1; // SET tx=1 [433] (Bit 4 = 1)
        rom[6]  = 16'h31B1; // SET tx=0 [433] (Bit 5 = 0)
        rom[7]  = 16'h33B1; // SET tx=1 [433] (Bit 6 = 1)
        rom[8]  = 16'h31B1; // SET tx=0 [433] (Bit 7 = 0)
        rom[9]  = 16'h33B1; // SET tx=1 [433] (Stop bit, logic 1)
        rom[10] = 16'h01B1; // NOP      [433] (Inter-character gap, idle 1)
        rom[11] = 16'h8000; // JMP 0x0        (Repeat transmission)
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

    always @(posedge i_clk) begin
        if (!i_reset_n) begin
            pc        <= 4'd0;
            delay_cnt <= 9'd0;
            tx_reg    <= 1'b1; // UART idle line state is high
            o_data    <= 8'h01;
        end else begin
            if (delay_cnt > 9'd0) begin
                // Counting down sidecar delay
                delay_cnt <= delay_cnt - 9'd1;
            end else begin
                // Execute current instruction and advance
                case (opcode)
                    4'h3: begin // SET
                        tx_reg    <= pin_val;
                        delay_cnt <= delay;
                        pc        <= pc + 4'd1;
                    end
                    4'h0: begin // NOP
                        delay_cnt <= delay;
                        pc        <= pc + 4'd1;
                    end
                    4'h8: begin // JMP
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
            // bits [7:5]: constant zeros
            o_data <= {3'b000, pc, tx_reg};
        end
    end

endmodule
