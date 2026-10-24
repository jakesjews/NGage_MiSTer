// SPDX-License-Identifier: GPL-3.0-or-later
// The ONLY operand forwarding network. A/M/W are registered, ready producer
// records, newest first. Two lanes allow long multiply/base-writeback pairs.
// Pending destinations are interlocked in D2, never inside this data selector.
module arm9v2_forward (
    input logic [3:0][31:0] i_value,
    input logic [3:0][1:0][1:0] i_match,
    input logic [1:0][1:0][31:0] i_producer_value,
    output logic [3:0][31:0] o_value
);
    logic [3:0][3:0] match_word,grant;
    logic [3:0] seen;
    always_comb begin
        match_word=0;grant=0;seen=0;o_value=0;
        for(int s=0;s<4;s++)begin
            // Control priority is separate from the wide data mux. A masked
            // OR tree avoids putting all six destination lanes in series.
            for(int rank=0;rank<4;rank++)begin
                match_word[s][rank]=i_match[s][rank/2][1-rank%2];
                grant[s][rank]=match_word[s][rank]&&!seen[s];
                seen[s]|=match_word[s][rank];
                o_value[s]|=i_producer_value[rank/2][1-rank%2]&{32{grant[s][rank]}};
            end
            o_value[s]|=i_value[s]&{32{!seen[s]}};
        end
    end
endmodule
