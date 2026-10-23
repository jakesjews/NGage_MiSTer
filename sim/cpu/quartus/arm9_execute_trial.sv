// SPDX-License-Identifier: GPL-3.0-or-later
// Timing harness, not an instruction-executing core. Serial stimulus provides
// independently controllable registered data/control without exhausting pins.
// Includes the unchanged 40x32 FF register file, D operand capture, three
// registered forwarding producers, flags feedback and observable E results.
module cpu_trial (
    input logic clk,
    input logic reset_in,
    input logic advance_in,
    input logic [31:0] stimulus,
    output logic [31:0] result_out,
    output logic [31:0] store_out,
    output logic [31:0] branch_out,
    output logic [7:0] status_out
);
`ifdef ARM9_TRIAL_SPLIT
    localparam bit SPLIT_SHIFT = 1'b1;
`else
    localparam bit SPLIT_SHIFT = 1'b0;
`endif
    logic reset, advance;
    logic [191:0] control;
    logic [3:0][31:0] rf_value, d_value;
    logic [3:0][5:0] d_tag;
    logic [3:0] d_used;
    logic [2:0][31:0] write_value;
    logic [2:0][5:0] write_tag;
    logic [2:0] write_valid;
    logic [3:0] flags_q, flags;
    logic [3:0] d_op, d_condition;
    logic d_valid, d_s, d_shift_reg, d_immediate, d_carry;
    logic [1:0] d_shift_type;
    logic [4:0] d_amount;
    logic [5:0] d_dest;
    logic [31:0] d_pc8, d_offset, result, store_data, branch_target;
    logic cond_pass, waiting, executing, write_result, write_flags;
    logic [39:0] background_write;
    logic [31:0] decoded_shift;
    logic decoded_carry, decoded_wait;
    wire unused = &{1'b0, control[191:185], control[175:166], control[159:153]};

    assign background_write = control[184] ? (40'b1 << control[183:178]) : 40'b0;
    zap_register_file u_rf (
        .i_clk(clk), .i_reset(reset), .i_wen(write_valid[2] && advance),
        .i_wr_addr_a(write_tag[2]), .i_wr_addr_b(control[165:160]),
        .i_wr_addr_c(background_write),
        .i_wr_data_a(write_value[2]), .i_wr_data_b(control[127:96]),
        .i_wr_data_c(control[95:64]),
        .i_rd_addr_a(control[5:0]), .i_rd_addr_b(control[11:6]),
        .i_rd_addr_c(control[17:12]), .i_rd_addr_d(control[23:18]),
        .o_rd_data_a(rf_value[0]), .o_rd_data_b(rf_value[1]),
        .o_rd_data_c(rf_value[2]), .o_rd_data_d(rf_value[3])
    );
    if (SPLIT_SHIFT) begin : g_decode_shift
        logic [1:0][31:0] operands;
        logic [1:0] pending;
        logic [31:0] shifted;
        logic carry;
        // Include the real E-to-D dependency path in timing. Using only
        // registered M values would hide an extra stall on shifted consumers.
        arm9_forward #(.SOURCES(2), .PRODUCERS(4)) u_forward (
            .i_value(rf_value[2:1]), .i_tag(control[17:6]), .i_used(control[26:25]),
            .i_write_value({write_value, result}),
            .i_write_tag({write_tag, d_dest}),
            .i_write_valid({write_valid, write_result}),
            .i_write_ready({control[177:176], 2'b11}),
            .o_value(operands), .o_wait(pending)
        );
        arm9_shift u_shift (
            .i_value(operands[0]),
            .i_amount(control[44] ? operands[1][7:0] : {3'd0, control[43:39]}),
            .i_type(control[38:37]), .i_register(control[44]), .i_carry(flags[1]),
            .o_value(shifted), .o_carry(carry)
        );
        assign decoded_shift = control[45] ? operands[0] : shifted;
        assign decoded_carry = control[45] ? control[46] : carry;
        assign decoded_wait = |pending;
        wire unused_amount = &{1'b0, operands[1][31:8]};
    end else begin : g_execute_shift
        assign decoded_shift = rf_value[1];
        assign decoded_carry = control[46];
        assign decoded_wait = 1'b0;
    end
    arm9_execute #(.PRE_SHIFTED(SPLIT_SHIFT)) u_execute (
        .i_valid(d_valid), .i_condition(d_condition), .i_op(d_op),
        .i_set_flags(d_s), .i_flags(flags_q), .i_value(d_value),
        .i_tag(d_tag), .i_used(d_used & (SPLIT_SHIFT ? 4'b1001 : 4'b1111)), .i_write_value(write_value),
        .i_write_tag(write_tag), .i_write_valid(write_valid),
        .i_write_ready({control[177:176], 1'b1}),
        .i_shift_type(d_shift_type), .i_shift_amount(d_amount),
        .i_shift_register(d_shift_reg), .i_immediate(d_immediate),
        .i_shift_carry(d_carry), .i_pc8(d_pc8), .i_branch_offset(d_offset),
        .o_result(result), .o_store_data(store_data), .o_branch_target(branch_target),
        .o_flags(flags), .o_condition_pass(cond_pass), .o_wait(waiting),
        .o_execute(executing), .o_write_result(write_result), .o_write_flags(write_flags)
    );
    always_ff @(posedge clk) begin
        reset <= reset_in;
        advance <= advance_in;
        control <= {control[159:0], stimulus};
        if (reset) begin
            d_valid <= 1'b0;
            write_valid <= '0;
            flags_q <= '0;
        end else if (advance) begin
            d_valid <= control[48];
            write_valid <= {write_valid[1:0], write_result};
            if (write_flags) flags_q <= flags;
        end
        if (advance) begin
            d_value <= rf_value;
            d_value[1] <= decoded_shift;
            d_tag <= control[23:0];
            d_used <= control[27:24];
            d_op <= control[31:28];
            d_condition <= control[35:32];
            d_s <= control[36];
            d_shift_type <= control[38:37];
            d_amount <= control[43:39];
            d_shift_reg <= control[44];
            d_immediate <= control[45];
            d_carry <= decoded_carry;
            d_dest <= control[54:49];
            d_pc8 <= control[95:64];
            d_offset <= control[127:96];
            write_value <= {write_value[1:0], result};
            write_tag <= {write_tag[1:0], d_dest};
            result_out <= result;
            store_out <= store_data;
            branch_out <= branch_target;
            status_out <= {flags, cond_pass, waiting | decoded_wait, executing, write_flags};
        end
    end
endmodule
