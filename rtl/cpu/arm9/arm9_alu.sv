// SPDX-License-Identifier: GPL-3.0-or-later
// ARM data processing operation numbers are instruction bits [24:21].
// Flags are NZCV. This leaf produces candidate flags; its caller controls
// architectural writes, including condition failure and SPSR restoration.
// FAST_Z: Z without the adder or the result mux. a+b+cin is zero (mod 2^32)
// exactly when every bit's carry-in equals a^b at that bit, and the carry
// out of a zero-sum bit is a|b: (a^b) == {a[30:0]|b[30:0], cin}. Each bit
// is one function of a, b and their lower neighbours, then one AND tree.
// Logical N and Z come from the logical result itself, never the adder.
module arm9_alu #(parameter logic FAST_Z = 1'b0) (
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
    logic [31:0] logic_result;
    logic arith_zero, logic_zero;
    always_comb begin
        case (i_op)
            4'h0, 4'h8: logic_result = i_a & i_b;
            4'h1, 4'h9: logic_result = i_a ^ i_b;
            4'hc: logic_result = i_a | i_b;
            4'he: logic_result = i_a & ~i_b;
            4'hf: logic_result = ~i_b;
            default: logic_result = i_b;
        endcase
        arith_zero = (a ^ b) == {a[30:0] | b[30:0], cin};
        logic_zero = logic_result == 0;
    end
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
        if (FAST_Z) o_flags[3:2] = {logic_result[31], logic_zero};
        if (arithmetic) begin
            // Arithmetic NZ does not need to wait for the logical/result mux.
            o_flags[3:2] = {sum[31], FAST_Z ? arith_zero : sum[31:0] == 0};
            o_flags[1] = sum[32];
            o_flags[0] = (a[31] == b[31]) && (a[31] != sum[31]);
        end
    end
endmodule
