// SPDX-License-Identifier: GPL-3.0-or-later
// ARM data processing operation numbers are instruction bits [24:21].
// Flags are NZCV. This leaf produces candidate flags; its caller controls
// architectural writes, including condition failure and SPSR restoration.
module arm9_alu (
    input  logic [31:0] i_a,
    input  logic [31:0] i_b,
    input  logic [3:0]  i_op,
    input  logic [3:0]  i_flags,
    input  logic        i_shift_carry,
    output logic [31:0] o_result,
    output logic [3:0]  o_flags
);
    logic inv_a, inv_b, cin, arithmetic;
    logic [31:0] a, b;
    logic [32:0] sum;
    wire unused = &{1'b0, i_flags[3:2]};
    assign inv_a = i_op == 4'h3 || i_op == 4'h7; // RSB/RSC
    assign inv_b = i_op == 4'h2 || i_op == 4'h6 || i_op == 4'ha;
    assign cin = (i_op == 4'h5 || i_op == 4'h6 || i_op == 4'h7) ?
                 i_flags[1] : (inv_a || inv_b);
    assign a = i_a ^ {32{inv_a}};
    assign b = i_b ^ {32{inv_b}};
    assign sum = {1'b0, a} + {1'b0, b} + {32'd0, cin};
    always_comb begin
        arithmetic = 1'b0;
        case (i_op)
            4'h0, 4'h8: o_result = i_a & i_b;
            4'h1, 4'h9: o_result = i_a ^ i_b;
            4'hc: o_result = i_a | i_b;
            4'hd: o_result = i_b;
            4'he: o_result = i_a & ~i_b;
            4'hf: o_result = ~i_b;
            default: begin o_result = sum[31:0]; arithmetic = 1'b1; end
        endcase
        o_flags = {o_result[31], o_result == 0, i_shift_carry, i_flags[0]};
        if (arithmetic) begin
            o_flags[1] = sum[32];
            o_flags[0] = (a[31] == b[31]) && (a[31] != sum[31]);
        end
    end
endmodule
