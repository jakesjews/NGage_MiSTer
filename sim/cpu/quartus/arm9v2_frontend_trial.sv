// SPDX-License-Identifier: GPL-3.0-or-later
// COMPONENT trial only: real F1/F2, BTB, RAS and queue, registered cache-side
// stimulus and outputs. It excludes the caches, D1..W and their backpressure.
// It cannot establish integrated CPU timing. Ten 32-bit input registers make
// every control/data input variable without exceeding the device's pin count.
module cpu_trial (
    input logic clk,
    input logic [31:0] serial_in,
    output logic [31:0] address_o, word_o, trace_o
);
    (* dont_retime *) logic [319:0] control;
    logic [31:0] address_next, address_check, address, pc, word_data, pred_target;
    logic request, stall, valid, thumb, fault, predicted, pred_hit;
    logic [1:0] pred_state, pred_kind;
    logic [2:0] ras_pointer;
    logic [3:0] ras_count;
    wire unused = &{1'b0,control[319:188]};
    always_ff @(posedge clk) begin
        control <= {control[287:0],serial_in};
        address_o <= address_next;
        word_o <= word_data;
        trace_o <= pc ^ address_check ^ address ^ pred_target ^
            {13'd0,ras_count,ras_pointer,pred_state,pred_kind,
             request,stall,valid,thumb,fault,predicted,pred_hit,1'b0};
    end
    arm9v2_fetch u_frontend (
        .i_clk(clk), .i_reset(control[0]),
        .i_redirect(control[1]), .i_redirect_thumb(control[2]),
        .i_redirect_target(control[34:3]), .i_redirect_pointer(control[37:35]),
        .i_redirect_count(control[41:38]), .i_redirect_action(control[43:42]),
        .i_redirect_link(control[75:44]), .i_predictor_clear(control[76]),
        .i_update(control[77]), .i_update_pc(control[109:78]), .i_update_target(control[141:110]),
        .i_update_thumb(control[142]), .i_update_taken(control[143]), .i_update_hit(control[144]),
        .i_update_state(control[146:145]), .i_update_kind(control[148:147]),
        .i_data(control[180:149]), .i_ack(control[181]), .i_error(control[182]), .i_retry(control[183]),
        .i_fill_pending(control[184]), .i_fill_done(control[185]), .i_fill_fault(control[186]),
        .i_ready(control[187]),
        .o_address_nxt(address_next), .o_address_check(address_check), .o_address(address),
        .o_request(request), .o_stall(stall), .o_valid(valid), .o_pc(pc), .o_word(word_data),
        .o_thumb(thumb), .o_fault(fault), .o_predicted(predicted), .o_pred_hit(pred_hit),
        .o_pred_target(pred_target), .o_pred_state(pred_state), .o_pred_kind(pred_kind),
        .o_ras_pointer(ras_pointer), .o_ras_count(ras_count)
    );
endmodule
