// SPDX-License-Identifier: GPL-3.0-or-later
// Integration harness shared by the component bench and Quartus trial.
// Older backend redirects have priority over the registered D2 redirect.
module arm9v2_front_decode #(
    parameter logic PREDICTOR=1'b1,
    parameter logic EXTERNAL_RF=0,
    parameter logic [31:0] RESET_VECTOR=0
) (
    input logic i_clk, i_reset, i_flush,
    output logic o_ready,
    input logic [4:0] i_mode,
    input logic i_wen,
    input logic [39:0] i_wr_addr_a, i_wr_addr_b, i_wr_addr_c, i_locked,
    input logic [3:0][5:0] i_early_tag,
    input logic [3:0] i_early_valid,
    input logic [31:0] i_wr_data_a, i_wr_data_b, i_wr_data_c,
    input logic [3:0][31:0] i_rf_value,
    output logic [3:0][5:0] o_rf_tag,
    input logic [5:0][5:0] i_load_tag,
    input logic [5:0] i_load_valid,
    input logic i_ready,
    output logic o_valid,
    output logic [31:0] o_pc, o_instruction, o_pc_base, o_next_pc,
    output logic [15:0] o_raw,
    output logic [4:0] o_mode,
    output logic o_thumb, o_fault, o_force_align, o_reg_shift,
    output logic [3:0] o_kind, o_condition,
    output logic [3:0][5:0] o_tag,
    output logic [3:0] o_used,
    output logic [3:0][31:0] o_value,
    output logic [1:0][5:0] o_dest,
    output logic o_first, o_last,
    output logic [4:0] o_reg_count,
    output logic signed [7:0] o_offset, o_writeback_offset,
    output logic [3:0] o_transfer_reg,
    output logic [31:0] o_branch_target,
    output logic o_direct, o_match_taken, o_match_fallthrough,
    output logic o_predicted, o_pred_hit,
    output logic [31:0] o_pred_target,
    output logic [1:0] o_pred_state, o_pred_kind,
    output logic [2:0] o_ras_pointer,
    output logic [3:0] o_ras_count,
    output logic o_hazard,
    output logic o_redirect, o_redirect_thumb,
    output logic [31:0] o_redirect_target, o_redirect_link,
    output logic [2:0] o_redirect_pointer,
    output logic [3:0] o_redirect_count,
    output logic [1:0] o_redirect_action,
    input logic [31:0] i_backend_target, i_backend_link,
    input logic i_backend_thumb,
    input logic [2:0] i_backend_pointer,
    input logic [3:0] i_backend_count,
    input logic [1:0] i_backend_action,
    input logic i_predictor_clear, i_update,
    input logic [31:0] i_update_pc, i_update_target,
    input logic i_update_thumb, i_update_taken, i_update_hit,
    input logic [1:0] i_update_state, i_update_kind,
    input logic [31:0] i_data,
    input logic i_ack, i_error, i_retry, i_fill_pending, i_fill_done, i_fill_fault,
    output logic [31:0] o_address_nxt, o_address_check, o_address,
    output logic o_request, o_stall
);
    logic f_valid,f_thumb,f_fault,f_predicted,f_hit;
    logic [31:0] f_pc,f_word,f_target;
    logic [1:0] f_state,f_kind;
    logic [2:0] f_pointer;
    logic [3:0] f_count;
    arm9v2_fetch #(.RESET_VECTOR(RESET_VECTOR),.PREDICTOR(PREDICTOR)) u_fetch (
        .i_clk(i_clk),.i_reset(i_reset),.i_redirect(i_flush||o_redirect),
        .i_redirect_target(i_flush?i_backend_target:o_redirect_target),
        .i_redirect_thumb(i_flush?i_backend_thumb:o_redirect_thumb),
        .i_redirect_pointer(i_flush?i_backend_pointer:o_redirect_pointer),
        .i_redirect_count(i_flush?i_backend_count:o_redirect_count),
        .i_redirect_action(i_flush?i_backend_action:o_redirect_action),
        .i_redirect_link(i_flush?i_backend_link:o_redirect_link),
        .i_predictor_clear(i_predictor_clear),.i_update(i_update),
        .i_update_pc(i_update_pc),.i_update_target(i_update_target),
        .i_update_thumb(i_update_thumb),.i_update_taken(i_update_taken),
        .i_update_hit(i_update_hit),.i_update_state(i_update_state),.i_update_kind(i_update_kind),
        .i_data(i_data),.i_ack(i_ack),.i_error(i_error),.i_retry(i_retry),
        .i_fill_pending(i_fill_pending),.i_fill_done(i_fill_done),.i_fill_fault(i_fill_fault),
        .o_address_nxt(o_address_nxt),.o_address_check(o_address_check),.o_address(o_address),
        .o_request(o_request),.o_stall(o_stall),.i_ready(o_ready),
        .o_valid(f_valid),.o_pc(f_pc),.o_word(f_word),.o_thumb(f_thumb),.o_fault(f_fault),
        .o_predicted(f_predicted),.o_pred_hit(f_hit),.o_pred_target(f_target),
        .o_pred_state(f_state),.o_pred_kind(f_kind),.o_ras_pointer(f_pointer),.o_ras_count(f_count)
    );
    arm9v2_decode #(.EXTERNAL_RF(EXTERNAL_RF)) u_decode (
        .i_valid(f_valid),.i_pc(f_pc),.i_word(f_word),.i_thumb(f_thumb),.i_fault(f_fault),
        .i_predicted(f_predicted),.i_pred_hit(f_hit),.i_pred_target(f_target),
        .i_pred_state(f_state),.i_pred_kind(f_kind),.i_ras_pointer(f_pointer),.i_ras_count(f_count),
        .*
    );
endmodule
