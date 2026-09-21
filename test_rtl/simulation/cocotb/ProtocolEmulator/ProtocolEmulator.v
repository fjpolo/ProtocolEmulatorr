// =============================================================================
// File        : ProtocolEmulator.v
// Module      : ProtocolEmulator (OmniBus Deterministic Protocol Engine)
// Description : Cycle-deterministic micro-engine with Output Shift Register (OSR),
//               multi-cycle bit serializer (OUT), and 4-deep hardware call stack
//               supporting CALL/RET subroutine instructions.
// License     : MIT License
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module ProtocolEmulator(
    input   wire            i_clk,
    input   wire            i_reset_n,
    input   wire            i_rx,
    input   wire    [7:0]   i_data,
    output  wire            o_tx,
    output  reg     [7:0]   o_data,

    // Runtime Microcode Programming Interface
    input   wire            i_prog_en,
    input   wire            i_prog_we,
    input   wire    [4:0]   i_prog_addr,
    input   wire    [15:0]  i_prog_data,
    output  wire    [15:0]  o_prog_rdata
);

    // -------------------------------------------------------------------------
    // Execution State Registers
    // -------------------------------------------------------------------------
    reg [4:0]  pc;
    reg [8:0]  delay_cnt;
    reg        tx_reg;
    reg [7:0]  osr;             // Output Shift Register (Serializer)
    reg [3:0]  bit_cnt;         // Serialization bit counter
    reg [7:0]  isr;             // Input Shift Register (Deserializer)
    reg [3:0]  rx_bit_cnt;      // Deserialization bit counter

    // 4-deep x 5-bit hardware call stack for CALL/RET subroutines
    reg [4:0]  call_stack [0:3]; // Return address stack
    reg [1:0]  sp;               // Stack pointer (0..4, wraps-safe)

    assign o_tx = tx_reg;

    // -------------------------------------------------------------------------
    // Microcode RAM (32 words x 16 bits)
    // -------------------------------------------------------------------------
    // Opcode [15:12]:
    //   0x0 = NOP  [8:0 delay]
    //   0x1 = OUT  [9 dir, 8:0 delay] (Serializes bits from OSR to TX)
    //   0x2 = IN   [9 dir, 8:0 delay] (Deserializes bits from RX into ISR)
    //   0x3 = SET  [9 pin_val, 8:0 delay]
    //   0x4 = WAIT [9 pin_val, 8:0 delay] (Wait for RX == pin_val, then delay)
    //   0x8 = JMP  [4:0 target]
    //   0x9 = PULL (Latches i_data[7:0] into OSR)
    //   0xA = PUSH (Transfers ISR into OSR and updates o_data)
    //   0xC = CALL [4:0 target] (Push pc+1 to call stack, jump to target)
    //   0xD = RET  (Pop return address from call stack, restore pc)
    reg [15:0] imem [0:31];

    assign o_prog_rdata = imem[i_prog_addr];

    integer i;
    initial begin
        for (i = 0; i < 32; i = i + 1) begin
            imem[i] = 16'h0000;
        end
        // UART Echo Transceiver @ 115200 baud on 50 MHz clock
        // 50 MHz / 115200 baud = 434 cycles/bit (1 execution + 433 delay)
        // Midpoint of start bit = 217 cycles (1 execution + 216 delay)
        imem[0]  = 16'h40D8; // WAIT rx=0 [216]   (Wait for Start bit edge; delay to mid-start)
        imem[1]  = 16'h01B1; // NOP       [433]   (Advance 1.0 bit to center of Data Bit 0)
        imem[2]  = 16'h21B1; // IN  rx, 8 [433]   (Sample 8 data bits LSB-first into ISR)
        imem[3]  = 16'h4200; // WAIT rx=1 [0]     (Confirm Stop bit logic 1)
        imem[4]  = 16'hA000; // PUSH              (Transfer ISR -> OSR for echo transmission)
        imem[5]  = 16'h31B1; // SET tx=0  [433]   (Transmit Start bit 0)
        imem[6]  = 16'h11B1; // OUT tx, 8 [433]   (Transmit 8 data bits from OSR)
        imem[7]  = 16'h33B1; // SET tx=1  [433]   (Transmit Stop bit 1)
        imem[8]  = 16'h8000; // JMP 0x0           (Loop back to WAIT for next byte immediately)
    end

    // Synchronous write port for runtime programming with power-on reset defaults
    always @(posedge i_clk) begin
        if (!i_reset_n) begin
            imem[0]  <= 16'h40D8; // WAIT rx=0 [216]   (Wait for Start bit edge; delay to mid-start)
            imem[1]  <= 16'h01B1; // NOP       [433]   (Advance 1.0 bit to center of Data Bit 0)
            imem[2]  <= 16'h21B1; // IN  rx, 8 [433]   (Sample 8 data bits LSB-first into ISR)
            imem[3]  <= 16'h4200; // WAIT rx=1 [0]     (Confirm Stop bit logic 1)
            imem[4]  <= 16'hA000; // PUSH              (Transfer ISR -> OSR for echo transmission)
            imem[5]  <= 16'h31B1; // SET tx=0  [433]   (Transmit Start bit 0)
            imem[6]  <= 16'h11B1; // OUT tx, 8 [433]   (Transmit 8 data bits from OSR)
            imem[7]  <= 16'h33B1; // SET tx=1  [433]   (Transmit Stop bit 1)
            imem[8]  <= 16'h8000; // JMP 0x0           (Loop back to WAIT for next byte immediately)
            imem[9]  <= 16'h0000;
            imem[10] <= 16'h0000;
            imem[11] <= 16'h0000;
            imem[12] <= 16'h0000;
            imem[13] <= 16'h0000;
            imem[14] <= 16'h0000;
            imem[15] <= 16'h0000;
            imem[16] <= 16'h0000;
            imem[17] <= 16'h0000;
            imem[18] <= 16'h0000;
            imem[19] <= 16'h0000;
            imem[20] <= 16'h0000;
            imem[21] <= 16'h0000;
            imem[22] <= 16'h0000;
            imem[23] <= 16'h0000;
            imem[24] <= 16'h0000;
            imem[25] <= 16'h0000;
            imem[26] <= 16'h0000;
            imem[27] <= 16'h0000;
            imem[28] <= 16'h0000;
            imem[29] <= 16'h0000;
            imem[30] <= 16'h0000;
            imem[31] <= 16'h0000;
        end else if (i_prog_en && i_prog_we) begin
            imem[i_prog_addr] <= i_prog_data;
        end
    end

    wire [15:0] instr   = imem[pc];
    wire [3:0]  opcode  = instr[15:12];
    wire        pin_val = instr[9];
    wire [8:0]  delay   = instr[8:0];
    wire [4:0]  target  = instr[4:0];

    // 2-stage input synchronizer for i_rx to prevent metastability
    reg rx_sync_0, rx_sync_1;
    always @(posedge i_clk) begin
        if (!i_reset_n) begin
            rx_sync_0 <= 1'b1;
            rx_sync_1 <= 1'b1;
        end else begin
            rx_sync_0 <= i_rx;
            rx_sync_1 <= rx_sync_0;
        end
    end
    wire rx_in = rx_sync_1;

    always @(posedge i_clk) begin
        if (!i_reset_n || i_prog_en) begin
            pc             <= 5'd0;
            delay_cnt      <= 9'd0;
            tx_reg         <= 1'b1; // UART idle state is high
            osr            <= 8'h00;
            bit_cnt        <= 4'd0;
            isr            <= 8'h00;
            rx_bit_cnt     <= 4'd0;
            o_data         <= 8'h00;
            sp             <= 2'd0;
            call_stack[0]  <= 5'd0;
            call_stack[1]  <= 5'd0;
            call_stack[2]  <= 5'd0;
            call_stack[3]  <= 5'd0;
        end else begin
            if (delay_cnt > 9'd0) begin
                // Counting down sidecar delay
                delay_cnt <= delay_cnt - 9'd1;
            end else begin
                // Execute current instruction
                case (opcode)
                    4'h4: begin // WAIT: Wait until rx_in matches pin_val, then delay
                        if (rx_in == pin_val) begin
                            delay_cnt <= delay;
                            pc        <= pc + 5'd1;
                        end else begin
                            delay_cnt <= 9'd0;
                            pc        <= pc;
                        end
                    end
                    4'h2: begin // IN: Multi-cycle dynamic deserialization into ISR
                        isr       <= {rx_in, isr[7:1]};
                        delay_cnt <= delay;
                        if (rx_bit_cnt == 4'd0) begin
                            // First bit sampled; 7 more bits follow
                            rx_bit_cnt <= 4'd7;
                            pc         <= pc;
                        end else if (rx_bit_cnt == 4'd1) begin
                            // Last bit sampled; advance PC
                            rx_bit_cnt <= 4'd0;
                            pc         <= pc + 5'd1;
                        end else begin
                            rx_bit_cnt <= rx_bit_cnt - 4'd1;
                            pc         <= pc;
                        end
                    end
                    4'hA: begin // PUSH: Transfer ISR to OSR (for echo) and latch to o_data
                        osr       <= isr;
                        o_data    <= isr;
                        delay_cnt <= 9'd0;
                        pc        <= pc + 5'd1;
                    end
                    4'h9: begin // PULL: Latch input data into OSR
                        osr       <= i_data;
                        delay_cnt <= 9'd0;
                        pc        <= pc + 5'd1;
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
                            pc      <= pc + 5'd1;
                        end else begin
                            // Middle bits (1 through 6)
                            bit_cnt <= bit_cnt - 4'd1;
                            pc      <= pc;
                        end
                    end
                    4'h3: begin // SET: Drive immediate pin value
                        tx_reg    <= pin_val;
                        delay_cnt <= delay;
                        pc        <= pc + 5'd1;
                    end
                    4'h0: begin // NOP: Pure delay
                        delay_cnt <= delay;
                        pc        <= pc + 5'd1;
                    end
                    4'h8: begin // JMP: Jump to target address
                        delay_cnt <= 9'd0;
                        pc        <= target;
                    end
                    4'hC: begin // CALL: Push return address, jump to target
                        // Push pc+1 onto the call stack (saturate at depth 4)
                        call_stack[sp] <= pc + 5'd1;
                        sp             <= (sp == 2'd3) ? 2'd3 : sp + 2'd1;
                        delay_cnt      <= 9'd0;
                        pc             <= target;
                    end
                    4'hD: begin // RET: Pop return address from call stack
                        // Pop top of stack back to pc (underflow-safe: stays at 0)
                        sp        <= (sp == 2'd0) ? 2'd0 : sp - 2'd1;
                        pc        <= (sp == 2'd0) ? 5'd0 : call_stack[sp - 2'd1];
                        delay_cnt <= 9'd0;
                    end
                    default: begin
                        pc        <= pc + 5'd1;
                    end
                endcase
            end
        end
    end

endmodule
