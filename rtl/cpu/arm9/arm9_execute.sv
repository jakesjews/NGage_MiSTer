// SPDX-License-Identifier: GPL-3.0-or-later
// Execute datapath for the new ARM9 pipeline, independent of the controller.
// D supplies registered operands/control; producers are registered M/W values.
// PRE_SHIFTED moves the barrel into D: i_value[1] and i_shift_carry then carry
// its captured output, and i_used[1:2] must be zero (already resolved in D).
// Do not connect a combinational o_result back to this module's forwarding.
module arm9_execute #(
    parameter bit PRE_SHIFTED = 1'b0
) (
    input  logic        i_valid,
    input  logic [3:0]  i_condition,
    input  logic [3:0]  i_op,
    input  logic        i_set_flags,
    input  logic [3:0]  i_flags,
    // Rn, Rm (or decoded immediate), Rs, store data. PC is a supplied value.
    input  logic [3:0][31:0] i_value,
    input  logic [3:0][5:0]  i_tag,
    input  logic [3:0]       i_used,
    input  logic [2:0][31:0] i_write_value,
    input  logic [2:0][5:0]  i_write_tag,
    input  logic [2:0]       i_write_valid,
    input  logic [2:0]       i_write_ready,
    input  logic [1:0]  i_shift_type,
    input  logic [4:0]  i_shift_amount,
    input  logic        i_shift_register,
    // A decoded ARM immediate is already rotated, with its correct carry.
    input  logic        i_immediate,
    input  logic        i_shift_carry,
    input  logic [31:0] i_pc8,
    input  logic [31:0] i_branch_offset,
    output logic [31:0] o_result,
    output logic [31:0] o_store_data,
    output logic [31:0] o_branch_target,
    output logic [3:0]  o_flags,
    output logic        o_condition_pass,
    output logic        o_wait,
    output logic        o_execute,
    output logic        o_write_result,
    output logic        o_write_flags
);
    logic [3:0][31:0] operand;
    logic [3:0] operand_wait, flags;
    logic [31:0] shifted;
    logic shift_carry, test_op;
    arm9_forward u_forward (
        .i_value(i_value), .i_tag(i_tag), .i_used(i_used),
        .i_write_value(i_write_value), .i_write_tag(i_write_tag),
        .i_write_valid(i_write_valid), .i_write_ready(i_write_ready),
        .o_value(operand), .o_wait(operand_wait)
    );
    if (!PRE_SHIFTED) begin : g_shift
        logic [31:0] value;
        logic carry;
        wire unused = &{1'b0, operand[2][31:8]};
        arm9_shift u_shift (
            .i_value(operand[1]),
            .i_amount(i_shift_register ? operand[2][7:0] : {3'd0, i_shift_amount}),
            .i_type(i_shift_type), .i_register(i_shift_register), .i_carry(i_flags[1]),
            .o_value(value), .o_carry(carry)
        );
        assign shifted = i_immediate ? operand[1] : value;
        assign shift_carry = i_immediate ? i_shift_carry : carry;
    end else begin : g_pre_shifted
        assign shifted = operand[1];
        assign shift_carry = i_shift_carry;
        // These controls belong to the D shifter in this configuration.
        wire unused = &{1'b0, i_shift_type, i_shift_amount, i_shift_register, i_immediate, operand[2]};
    end
    arm9_alu u_alu (
        .i_a(operand[0]), .i_b(shifted), .i_op(i_op), .i_flags(i_flags),
        .i_shift_carry(shift_carry), .o_result(o_result), .o_flags(flags)
    );
    always_comb begin
        case (i_condition)
            4'h0: o_condition_pass = i_flags[2];
            4'h1: o_condition_pass = !i_flags[2];
            4'h2: o_condition_pass = i_flags[1];
            4'h3: o_condition_pass = !i_flags[1];
            4'h4: o_condition_pass = i_flags[3];
            4'h5: o_condition_pass = !i_flags[3];
            4'h6: o_condition_pass = i_flags[0];
            4'h7: o_condition_pass = !i_flags[0];
            4'h8: o_condition_pass = i_flags[1] && !i_flags[2];
            4'h9: o_condition_pass = !i_flags[1] || i_flags[2];
            4'ha: o_condition_pass = i_flags[3] == i_flags[0];
            4'hb: o_condition_pass = i_flags[3] != i_flags[0];
            4'hc: o_condition_pass = !i_flags[2] && (i_flags[3] == i_flags[0]);
            4'hd: o_condition_pass = i_flags[2] || (i_flags[3] != i_flags[0]);
            4'he: o_condition_pass = 1'b1;
            default: o_condition_pass = 1'b0; // ARMv4 NV never executes.
        endcase
    end
    assign test_op = i_op[3:2] == 2'b10;
    assign o_wait = i_valid && o_condition_pass && |operand_wait;
    assign o_execute = i_valid && o_condition_pass && !o_wait;
    assign o_write_result = o_execute && !test_op;
    assign o_write_flags = o_execute && (i_set_flags || test_op);
    assign o_flags = o_write_flags ? flags : i_flags;
    assign o_branch_target = i_pc8 + i_branch_offset;
    assign o_store_data = operand[3];
endmodule
