// =============================================================================
// File        : properties.v
// Module      : Formal Properties for omnibus_fifo.v
// Description : Formal verification suite for Parameterized FWFT FIFO:
//               - Reset sanity checks
//               - Count and pointer consistency bounds
//               - No overflow when full, no underflow when empty
//               - FIFO ordering correctness (FIFO data integrity)
//               - Reachability / Coverage (fill, drain, concurrent push/pop)
// License     : MIT License
// =============================================================================

`ifdef FORMAL

`define ASSERT assert
`define ASSUME assume

    // -------------------------------------------------------------------------
    // 1. Auxiliary Tracking & Assumptions
    // -------------------------------------------------------------------------
    reg f_past_valid;
    initial f_past_valid = 1'b0;
    always @(posedge i_clk)
        f_past_valid <= 1'b1;

    // Reset sequence: assert reset initially for at least 1 cycle
    initial `ASSUME(!i_rst_n);

    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_rst_n)) begin
            `ASSUME(i_rst_n);
        end
    end

    // -------------------------------------------------------------------------
    // 2. Reset Invariants
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && $past(!i_rst_n || i_clear)) begin
            `ASSERT(wr_ptr == {ADDR_WIDTH{1'b0}});
            `ASSERT(rd_ptr == {ADDR_WIDTH{1'b0}});
            `ASSERT(count  == {(ADDR_WIDTH+1){1'b0}});
            `ASSERT(o_empty == 1'b1);
            `ASSERT(o_full  == 1'b0);
        end
    end

    // -------------------------------------------------------------------------
    // 3. Structural & Flag Invariants
    // -------------------------------------------------------------------------
    always @(*) begin
        `ASSERT(count <= DEPTH);
        `ASSERT(o_empty == (count == {(ADDR_WIDTH+1){1'b0}}));
        `ASSERT(o_full  == (count == DEPTH));
        `ASSERT(o_level == count);
        `ASSERT(o_almost_full == (count >= ALMOST_FULL_THRESH));
        `ASSERT(o_almost_empty == (count <= ALMOST_EMPTY_THRESH && !o_empty));

        if (wr_ptr >= rd_ptr) begin
            if (count == DEPTH)
                `ASSERT(wr_ptr == rd_ptr);
            else
                `ASSERT(count == (wr_ptr - rd_ptr));
        end else begin
            `ASSERT(count == (DEPTH + wr_ptr - rd_ptr));
        end
    end

    // -------------------------------------------------------------------------
    // 4. Push / Pop Operational Invariants
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_rst_n && !i_clear && $past(i_rst_n && !i_clear)) begin
            // Count transitions
            if ($past(push_valid) && !$past(pop_valid)) begin
                `ASSERT(count == $past(count) + 1'b1);
            end else if (!$past(push_valid) && $past(pop_valid)) begin
                `ASSERT(count == $past(count) - 1'b1);
            end else begin
                `ASSERT(count == $past(count));
            end

            // Pointer increments
            if ($past(push_valid)) begin
                if ($past(wr_ptr) == DEPTH - 1)
                    `ASSERT(wr_ptr == {ADDR_WIDTH{1'b0}});
                else
                    `ASSERT(wr_ptr == $past(wr_ptr) + 1'b1);
            end

            if ($past(pop_valid)) begin
                if ($past(rd_ptr) == DEPTH - 1)
                    `ASSERT(rd_ptr == {ADDR_WIDTH{1'b0}});
                else
                    `ASSERT(rd_ptr == $past(rd_ptr) + 1'b1);
            end
        end
    end

    // -------------------------------------------------------------------------
    // 5. FIFO Data Ordering Verification (First-In, First-Out)
    // -------------------------------------------------------------------------
    // Prove that data written to any memory slot f_addr is accurately preserved
    // and read back when rd_ptr reaches f_addr.
    (* anyconst *) reg [ADDR_WIDTH-1:0] f_addr;
    reg [DATA_WIDTH-1:0] f_shadow_data;
    reg f_written;

    initial f_written = 1'b0;

    always @(posedge i_clk) begin
        if (!i_rst_n || i_clear) begin
            f_written <= 1'b0;
        end else begin
            if (push_valid && wr_ptr == f_addr) begin
                f_shadow_data <= i_data;
                f_written     <= 1'b1;
            end
        end
    end

    always @(*) begin
        if (f_written) begin
            `ASSERT(mem[f_addr] == f_shadow_data);
            if (!o_empty && rd_ptr == f_addr) begin
                `ASSERT(o_data == f_shadow_data);
            end
        end
    end

    // -------------------------------------------------------------------------
    // 6. Functional Coverage (Cover)
    // -------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (f_past_valid && i_rst_n && !i_clear) begin
            // Cover 1: FIFO completely filled to DEPTH
            cover(o_full);

            // Cover 2: FIFO drained completely to empty
            cover($past(count > 0) && o_empty);

            // Cover 3: Simultaneous push and pop when partially full
            cover(push_valid && pop_valid && count > 1 && count < DEPTH - 1);

            // Cover 4: FIFO almost full watermark asserted
            cover(o_almost_full && !o_full);

            // Cover 5: FIFO almost empty watermark asserted
            cover(o_almost_empty && !o_empty);
        end
    end

`endif
