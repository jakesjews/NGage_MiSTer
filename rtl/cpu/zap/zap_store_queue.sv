// SPDX-License-Identifier: GPL-3.0-or-later
// Ordered FIFO for permission-checked physical write misses. The requester
// acknowledges a CPU store only on i_push. Errors complete buffered writes,
// matching TI925T's documented buffered-abort behavior. A source arbiter
// must keep later memory transactions behind o_busy (including the last
// pop/new-push bubble). CYC/payload describe the next registered bus beat.
module zap_store_queue #(
    parameter integer AW = 2
) (
    input logic i_clk, i_reset, i_push, i_take,
    input logic [31:0] i_address, i_data,
    input logic [3:0] i_ben,
    output logic o_full, o_busy, o_cyc_nxt,
    output logic [31:0] o_address_nxt, o_data_nxt,
    output logic [3:0] o_ben_nxt
);
    localparam integer DEPTH = 1 << AW;
    logic [67:0] entries [0:DEPTH-1];
    logic [AW-1:0] head, tail, read_index;
    logic [AW:0] count, count_nxt;
    assign read_index = head + {{(AW-1){1'b0}}, i_take};
    assign {o_address_nxt, o_data_nxt, o_ben_nxt} = entries[read_index];
    // Do not forward the CPU's live tag/address/data cone to the bus mux.
    // A newly enqueued first entry launches on the following clock.
    assign o_cyc_nxt = count > {{AW{1'b0}}, i_take};
    assign o_busy = count != 0;
    always_comb begin
        count_nxt = count;
        case ({i_push, i_take})
            2'b10: count_nxt = count + 1'b1;
            2'b01: count_nxt = count - 1'b1;
            default: ;
        endcase
    end
    always_ff @(posedge i_clk) begin
        if (i_reset) begin
            head <= '0;
            tail <= '0;
            count <= '0;
            o_full <= 1'b0;
        end else begin
            count <= count_nxt;
            o_full <= count_nxt == DEPTH;
            if (i_push) begin
                entries[tail] <= {i_address, i_data, i_ben};
                tail <= tail + 1'b1;
            end
            if (i_take) head <= head + 1'b1;
        end
    end
`ifndef SYNTHESIS
    always_ff @(posedge i_clk) if (!i_reset) begin
        assert (!(i_push && o_full)) else $fatal(1, "Posted store queue overflow");
        assert (!(i_take && !o_busy)) else $fatal(1, "Posted store queue underflow");
        assert (o_full == (count == DEPTH)) else $fatal(1, "Posted store queue full flag");
    end
`endif
endmodule
