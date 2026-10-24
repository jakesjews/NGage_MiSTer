// SPDX-License-Identifier: GPL-3.0-or-later
// S operand forwarding selects registered M/W producer records, newest
// first. Two lanes allow long multiply/base-writeback pairs.
// Match and hazard decisions are registered before this data selector.
module arm9v2_forward (
    input logic [3:0][31:0] i_value,
    input logic [3:0][4:0] i_grant,
    input logic [1:0][1:0][31:0] i_producer_value,
    output logic [3:0][31:0] o_value
);
    // The five one-hot grants (M lane1/0, W lane1/0, RF) are registered
    // before S. This module contains only a masked data OR tree.
    always_comb begin
        o_value=0;
        for(int s=0;s<4;s++)begin
            for(int rank=0;rank<4;rank++)
                o_value[s]|=i_producer_value[rank/2][1-rank%2]&{32{i_grant[s][rank]}};
            o_value[s]|=i_value[s]&{32{i_grant[s][4]}};
        end
    end
endmodule
