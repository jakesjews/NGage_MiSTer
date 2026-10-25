// SPDX-License-Identifier: GPL-3.0-or-later
// Component integration harness: real F1/F2/D1/D2/S/A and RF, plus registered
// M/W arithmetic producer records. No D-cache, memory completion or precise
// exception retirement exists here. i_ready is registered downstream capacity.
module arm9v2_front_execute #(
    parameter logic PREDICTOR=1'b1,
    parameter logic [31:0] RESET_VECTOR=0
) (
    input logic i_clk,i_reset,i_flush,i_ready,
    input logic [31:0] i_cpsr,i_backend_target,
    input logic i_backend_thumb,i_predictor_clear,
    input logic [39:0] i_locked,
    input logic [31:0] i_data,
    input logic i_ack,i_error,i_retry,i_fill_pending,i_fill_done,i_fill_fault,
    output logic o_execute_ready,
    output logic o_valid,
    output logic [31:0] o_pc,
    output logic [31:0] o_instruction,
    output logic [31:0] o_cpsr,
    output logic [31:0] o_cpsr_next,
    output logic [3:0] o_kind,
    output logic o_thumb,
    output logic o_fault,
    output logic o_first,
    output logic o_last,
    output logic o_condition_pass,
    output logic [1:0][5:0] o_dest,
    output logic [1:0][31:0] o_result,
    output logic [1:0] o_write,
    output logic o_write_flags,
    output logic o_pc_write,
    output logic o_memory,
    output logic o_store,
    output logic [31:0] o_data_address,
    output logic [31:0] o_store_data,
    output logic [3:0] o_flags,
    output logic o_redirect,
    output logic o_redirect_thumb,
    output logic [31:0] o_redirect_target,
    output logic [31:0] o_redirect_link,
    output logic [2:0] o_redirect_pointer,
    output logic [3:0] o_redirect_count,
    output logic [1:0] o_redirect_action,
    output logic o_btb_update,
    output logic o_btb_taken,
    output logic o_btb_hit,
    output logic [31:0] o_btb_target,
    output logic [1:0] o_btb_state,
    output logic [1:0] o_btb_kind,
    output logic o_a_valid,
    output logic o_a_can_finish,
    output logic [1:0] o_s_write,
    output logic [1:0][5:0] o_a_dest,
    output logic [1:0] o_a_write,
    output logic o_shift_wait,
    output logic o_multiply_wait,
    output logic [31:0] o_address_nxt,
    output logic [31:0] o_address_check,
    output logic [31:0] o_address,
    output logic [31:0] o_retire_pc,
    output logic [31:0] o_retire_instruction,
    output logic [31:0] o_retire_value,
    output logic o_request,
    output logic o_stall,
    output logic o_retire_valid
);
    logic d_ready;
    logic d_valid;
    logic [31:0] d_pc;
    logic [31:0] d_instruction;
    logic [31:0] d_pc_base;
    logic [31:0] d_next_pc;
    logic [15:0] d_raw;
    logic [4:0] d_mode;
    logic d_thumb;
    logic d_fault;
    logic d_force_align;
    logic d_reg_shift;
    logic [3:0] d_kind;
    logic [3:0] d_condition;
    logic [3:0][5:0] d_tag;
    logic [3:0] d_used;
    logic [3:0][1:0][1:0] d_forward_match;
    logic [1:0][3:0][4:0] d_forward_grant;
    logic [1:0][1:0][5:0] forward_tag;
    logic [1:0][1:0] forward_write;
    logic [3:0] d_early;
    logic [31:0] btb_pc;
    logic btb_thumb;

    logic [3:0][31:0] d_value;
    logic [1:0][5:0] d_dest;
    logic d_first;
    logic d_last;
    logic [4:0] d_reg_count;
    logic signed [7:0] d_offset;
    logic signed [7:0] d_writeback_offset;
    logic [3:0] d_transfer_reg;
    logic [31:0] d_branch_target;
    logic d_direct;
    logic d_match_taken;
    logic d_match_fallthrough;
    logic d_predicted;
    logic d_pred_hit;
    logic [31:0] d_pred_target;
    logic [1:0] d_pred_state;
    logic [1:0] d_pred_kind;
    logic [2:0] d_ras_pointer;
    logic [3:0] d_ras_count;
    logic d_hazard;
    logic d_redirect;
    logic d_redirect_thumb;
    logic [31:0] d_redirect_target;
    logic [31:0] d_redirect_link;
    logic [2:0] d_redirect_pointer;
    logic [3:0] d_redirect_count;
    logic [1:0] d_redirect_action;
    (* dont_retime *) logic [1:0][1:0][31:0] mw_value;
    (* dont_retime *) logic [1:0][1:0][5:0] mw_tag;
    (* dont_retime *) logic [1:0][1:0] mw_write;
    (* dont_retime *) logic [1:0] mw_valid,mw_flags;
    (* dont_retime *) logic [1:0][31:0] mw_pc,mw_ins,mw_cpsr;
    logic [39:0] wa,wb,wc;
    logic [3:0][5:0] early_tag;
    logic [3:0] early_valid;
    assign forward_tag={i_ready?mw_tag[0]:mw_tag[1],i_ready?o_dest:mw_tag[0]};
    assign forward_write=(i_reset||i_flush)?4'd0:
        {i_ready?(mw_write[0]&{2{mw_valid[0]}}):(mw_write[1]&{2{mw_valid[1]}}),
         i_ready?(o_write&{2{o_valid}}):(mw_write[0]&{2{mw_valid[0]}})};
    assign wa=(mw_write[1][0]&&mw_valid[1]) ? 40'd1<<mw_tag[1][0] : 40'd0;
    assign wb=(mw_write[1][1]&&mw_valid[1]) ? 40'd1<<mw_tag[1][1] : 40'd0;
    assign wc=(mw_flags[1]&&mw_valid[1]) ? 40'd1<<17 : 40'd0;
    assign early_tag={o_a_dest,d_dest};
    assign early_valid={o_a_write&{2{o_a_valid&&!o_a_can_finish}},o_s_write}&
        {early_tag[3]!=15,early_tag[2]!=15,early_tag[1]!=15,early_tag[0]!=15};
    always_ff @(posedge i_clk)begin
        if(i_reset||i_flush)begin
            mw_valid<=0;mw_write<=0;mw_flags<=0;mw_value<=0;mw_tag<=0;mw_pc<=0;mw_ins<=0;mw_cpsr<=0;
        end else if(i_ready)begin
            mw_valid<={mw_valid[0],o_valid};mw_write<={mw_write[0],o_write};
            mw_flags<={mw_flags[0],o_write_flags};mw_value<={mw_value[0],o_result};
            mw_tag<={mw_tag[0],o_dest};mw_pc<={mw_pc[0],o_pc};
            mw_ins<={mw_ins[0],o_instruction};mw_cpsr<={mw_cpsr[0],o_cpsr_next};
        end
    end
    assign o_retire_valid=mw_valid[1]&&i_ready&&!i_flush;
    assign o_retire_pc=mw_pc[1];assign o_retire_instruction=mw_ins[1];assign o_retire_value=mw_value[1][0];
    arm9v2_front_decode #(.RESET_VECTOR(RESET_VECTOR),.PREDICTOR(PREDICTOR)) u_front_decode (
        .i_serial_continue(1'b0),.o_dbg_fetch(),
        .i_rf_value('0),.o_rf_tag(),.i_load_tag('0),.i_w_load_hit(1'b0),.o_pending(),.i_load_valid('0),.i_load_speculate('0),.i_next_load_tag('0),.i_next_load_valid('0),.o_load_wait(),
        .o_writes(),.o_early(d_early),.i_forward_tag(forward_tag),.i_advance_tag('0),.i_forward_advance(1'b0),.i_forward_write(forward_write),
        .i_forward_load('0),.o_forward_grant(d_forward_grant),.o_forward_match(d_forward_match),.i_clk(i_clk),
        .i_return_next_valid(1'b0),.i_return_next_tag(6'd0),.o_return_match(),
        .i_reset(i_reset),
        .i_flush(i_flush||o_redirect),
        .i_mode(i_cpsr[4:0]),
        .i_wen(i_ready&&!i_flush),
        .i_wr_tag_a(6'd16),.i_wr_tag_b(6'd16),.i_wr_pair(1'b0),.i_wr_addr_a(wa),
        .i_wr_addr_b(wb),
        .i_wr_addr_c(wc),
        .i_locked(i_locked),
        .i_early_tag(early_tag),
        .i_early_valid(early_valid),
        .i_wr_data_a(mw_value[1][0]),
        .i_wr_data_b(mw_value[1][1]),
        .i_wr_data_c(mw_cpsr[1]),
        .i_ready(o_execute_ready),
        .i_ready_payload(o_execute_ready),
        .i_backend_target(i_flush?i_backend_target:o_redirect_target),
        .i_backend_link(o_redirect_link),
        .i_backend_thumb(i_flush?i_backend_thumb:o_redirect_thumb),
        .i_backend_pointer(i_flush?3'd0:o_redirect_pointer),
        .i_backend_count(i_flush?4'd0:o_redirect_count),
        .i_backend_action(i_flush?2'd3:o_redirect_action),
        .i_predictor_clear(i_predictor_clear),
        .i_update(o_btb_update),
        .i_update_pc(btb_pc),
        .i_update_target(o_btb_target),
        .i_update_thumb(btb_thumb),
        .i_update_taken(o_btb_taken),
        .i_update_hit(o_btb_hit),
        .i_update_state(o_btb_state),
        .i_update_kind(o_btb_kind),
        .i_data(i_data),
        .i_ack(i_ack),
        .i_error(i_error),
        .i_retry(i_retry),
        .i_fill_pending(i_fill_pending),
        .i_fill_done(i_fill_done),
        .i_fill_fault(i_fill_fault),
        .o_ready(d_ready),
        .o_valid(d_valid),
        .o_pc(d_pc),
        .o_instruction(d_instruction),
        .o_pc_base(d_pc_base),
        .o_next_pc(d_next_pc),
        .o_raw(d_raw),
        .o_mode(d_mode),
        .o_thumb(d_thumb),
        .o_fault(d_fault),
        .o_force_align(d_force_align),
        .o_reg_shift(d_reg_shift),
        .o_kind(d_kind),
        .o_condition(d_condition),
        .o_tag(d_tag),
        .o_used(d_used),
        .o_value(d_value),
        .o_dest(d_dest),
        .o_first(d_first),
        .o_last(d_last),
        .o_reg_count(d_reg_count),
        .o_offset(d_offset),
        .o_writeback_offset(d_writeback_offset),
        .o_transfer_reg(d_transfer_reg),
        .o_branch_target(d_branch_target),
        .o_direct(d_direct),
        .o_match_taken(d_match_taken),
        .o_match_fallthrough(d_match_fallthrough),
        .o_predicted(d_predicted),
        .o_pred_hit(d_pred_hit),
        .o_pred_target(d_pred_target),
        .o_pred_state(d_pred_state),
        .o_pred_kind(d_pred_kind),
        .o_ras_pointer(d_ras_pointer),
        .o_ras_count(d_ras_count),
        .o_hazard(d_hazard),
        .o_redirect(d_redirect),
        .o_redirect_thumb(d_redirect_thumb),
        .o_redirect_target(d_redirect_target),
        .o_redirect_link(d_redirect_link),
        .o_redirect_pointer(d_redirect_pointer),
        .o_redirect_count(d_redirect_count),
        .o_redirect_action(d_redirect_action),
        .o_address_nxt(o_address_nxt),
        .o_address_check(o_address_check),
        .o_address(o_address),
        .o_request(o_request),
        .o_stall(o_stall)
    );
    arm9v2_execute u_execute (
        .i_flags_refresh(1'b0),.o_serial_continue(),.i_pending(4'd0),.i_load_owner(2'd0),.i_next_load_owner(2'd0),.i_load_hit(1'b0),.i_return_select(64'd0),.i_return_next_valid(1'b0),.i_return_next_tag(6'd0),.i_return_ready(1'b0),.i_return_s_match(4'd0),.i_return_data(64'd0),
        .i_admit(1'b1),.i_load_wait(1'b0),.i_forward_grant(d_forward_grant),.i_forward_match(d_forward_match),.i_next_tag(forward_tag),.i_advance_tag('0),.i_next_advance(1'b0),.i_next_write(forward_write),.i_early(d_early),
        .o_btb_pc(btb_pc),.o_btb_thumb(btb_thumb),.o_record_pointer(),.o_record_count(),
        .o_record_pred_hit(),.o_record_pred_state(),.o_record_thumb(),
        .o_a_load(),.o_psr_source(),.o_saved_psr(),.o_original_base(),.o_next_pc(),.o_prediction_target(),.o_spsr_tag(),.o_predicted(),
        .i_clk(i_clk),
        .i_reset(i_reset),
        .i_flush(i_flush),
        .i_cpsr(i_cpsr),
        .i_valid(d_valid),
        .i_pc(d_pc),
        .i_instruction(d_instruction),
        .i_pc_base(d_pc_base),
        .i_next_pc(d_next_pc),
        .i_thumb(d_thumb),
        .i_fault(d_fault),
        .i_force_align(d_force_align),
        .i_reg_shift(d_reg_shift),
        .i_first(d_first),
        .i_last(d_last),
        .i_kind(d_kind),
        .i_condition(d_condition),
        .i_tag(d_tag),
        .i_used(d_used),
        .i_value(d_value),
        .i_dest(d_dest),
        .i_offset(d_offset),
        .i_writeback_offset(d_writeback_offset),
        .i_branch_target(d_branch_target),
        .i_pred_target(d_pred_target),
        .i_direct(d_direct),
        .i_predicted(d_predicted),
        .i_match_taken(d_match_taken),
        .i_match_fallthrough(d_match_fallthrough),
        .i_pred_hit(d_pred_hit),
        .i_pred_state(d_pred_state),
        .i_ras_pointer(d_ras_pointer),
        .i_ras_count(d_ras_count),
        .i_mw_value(mw_value),
        .i_mw_tag(mw_tag),
        .i_mw_valid(mw_write&{{2{mw_valid[1]}},{2{mw_valid[0]}}}),
        .i_ready(i_ready),
        .o_ready(o_execute_ready),
        .o_valid(o_valid),
        .o_pc(o_pc),
        .o_instruction(o_instruction),
        .o_cpsr(o_cpsr),
        .o_cpsr_next(o_cpsr_next),
        .o_kind(o_kind),
        .o_thumb(o_thumb),
        .o_fault(o_fault),
        .o_first(o_first),
        .o_last(o_last),
        .o_condition_pass(o_condition_pass),
        .o_dest(o_dest),
        .o_result(o_result),
        .o_write(o_write),
        .o_write_flags(o_write_flags),
        .o_pc_write(o_pc_write),
        .o_memory(o_memory),
        .o_store(o_store),
        .o_address(o_data_address),
        .o_store_data(o_store_data),
        .o_flags(o_flags),
        .o_redirect(o_redirect),
        .o_redirect_thumb(o_redirect_thumb),
        .o_redirect_target(o_redirect_target),
        .o_redirect_link(o_redirect_link),
        .o_redirect_pointer(o_redirect_pointer),
        .o_redirect_count(o_redirect_count),
        .o_redirect_action(o_redirect_action),
        .o_btb_update(o_btb_update),
        .o_btb_taken(o_btb_taken),
        .o_btb_hit(o_btb_hit),
        .o_btb_target(o_btb_target),
        .o_btb_state(o_btb_state),
        .o_btb_kind(o_btb_kind),
        .o_a_valid(o_a_valid),
        .o_a_can_finish(o_a_can_finish),
        .o_s_write(o_s_write),
        .o_a_dest(o_a_dest),
        .o_a_write(o_a_write),
        .o_shift_wait(o_shift_wait),
        .o_multiply_wait(o_multiply_wait)
    );
    wire unused=&{1'b0,d_ready,d_raw,d_mode,d_reg_count,d_transfer_reg,d_pred_kind,d_hazard,d_redirect,d_redirect_thumb,d_redirect_target,d_redirect_link,d_redirect_pointer,d_redirect_count,d_redirect_action};
endmodule
