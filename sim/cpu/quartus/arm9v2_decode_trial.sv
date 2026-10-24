// SPDX-License-Identifier: GPL-3.0-or-later
// Real F1/F2 + D1/D2 + register file + registered S-entry. Caches and S/A/M/W
// execution are excluded. Every interface input is registered and variable.
module cpu_trial(input logic clk,input logic [31:0] serial_in,
    output logic [31:0] address_o, data_o, observe_o);
    (* dont_retime *) logic [479:0] stimulus;
    logic i_clk, i_reset, i_flush;
    logic o_ready;
    logic [4:0] i_mode;
    logic i_wen;
    logic [39:0] i_wr_addr_a, i_wr_addr_b, i_wr_addr_c, i_locked;
    logic [3:0][5:0] i_early_tag;
    logic [3:0] i_early_valid;
    logic [31:0] i_wr_data_a, i_wr_data_b, i_wr_data_c;
    logic i_ready;
    logic o_valid;
    logic [31:0] o_pc, o_instruction, o_pc_base, o_next_pc;
    logic [15:0] o_raw;
    logic [4:0] o_mode;
    logic o_thumb, o_fault, o_force_align, o_reg_shift;
    logic [3:0] o_kind, o_condition;
    logic [3:0][5:0] o_tag;
    logic [3:0] o_used;
    logic [3:0][31:0] o_value;
    logic [1:0][5:0] o_dest;
    logic o_first, o_last;
    logic [4:0] o_reg_count;
    logic signed [7:0] o_offset, o_writeback_offset;
    logic [3:0] o_transfer_reg;
    logic [31:0] o_branch_target;
    logic o_direct, o_match_taken, o_match_fallthrough;
    logic o_predicted, o_pred_hit;
    logic [31:0] o_pred_target;
    logic [1:0] o_pred_state, o_pred_kind;
    logic [2:0] o_ras_pointer;
    logic [3:0] o_ras_count;
    logic o_hazard;
    logic o_redirect, o_redirect_thumb;
    logic [31:0] o_redirect_target, o_redirect_link;
    logic [2:0] o_redirect_pointer;
    logic [3:0] o_redirect_count;
    logic [1:0] o_redirect_action;
    logic [31:0] i_backend_target, i_backend_link;
    logic i_backend_thumb;
    logic [2:0] i_backend_pointer;
    logic [3:0] i_backend_count;
    logic [1:0] i_backend_action;
    logic i_predictor_clear, i_update;
    logic [31:0] i_update_pc, i_update_target;
    logic i_update_thumb, i_update_taken, i_update_hit;
    logic [1:0] i_update_state, i_update_kind;
    logic [31:0] i_data;
    logic i_ack, i_error, i_retry, i_fill_pending, i_fill_done, i_fill_fault;
    logic [31:0] o_address_nxt, o_address_check, o_address;
    logic o_request, o_stall;
    assign i_early_tag=0;
    assign i_early_valid=0;
    assign i_clk=clk;
    assign i_reset=stimulus[0:0];
    assign i_flush=stimulus[1:1];
    assign i_mode=stimulus[6:2];
    assign i_wen=stimulus[7:7];
    assign i_wr_addr_a=stimulus[47:8];
    assign i_wr_addr_b=stimulus[87:48];
    assign i_wr_addr_c=stimulus[127:88];
    assign i_locked=stimulus[167:128];
    assign i_wr_data_a=stimulus[199:168];
    assign i_wr_data_b=stimulus[231:200];
    assign i_wr_data_c=stimulus[263:232];
    assign i_ready=stimulus[264:264];
    assign i_backend_target=stimulus[296:265];
    assign i_backend_link=stimulus[328:297];
    assign i_backend_thumb=stimulus[329:329];
    assign i_backend_pointer=stimulus[332:330];
    assign i_backend_count=stimulus[336:333];
    assign i_backend_action=stimulus[338:337];
    assign i_predictor_clear=stimulus[339:339];
    assign i_update=stimulus[340:340];
    assign i_update_pc=stimulus[372:341];
    assign i_update_target=stimulus[404:373];
    assign i_update_thumb=stimulus[405:405];
    assign i_update_taken=stimulus[406:406];
    assign i_update_hit=stimulus[407:407];
    assign i_update_state=stimulus[409:408];
    assign i_update_kind=stimulus[411:410];
    assign i_data=stimulus[443:412];
    assign i_ack=stimulus[444:444];
    assign i_error=stimulus[445:445];
    assign i_retry=stimulus[446:446];
    assign i_fill_pending=stimulus[447:447];
    assign i_fill_done=stimulus[448:448];
    assign i_fill_fault=stimulus[449:449];
    wire [127:0] flat_o_value=o_value;
    wire unused = &{1'b0,stimulus[479:450]};
    always_ff @(posedge clk) begin
        stimulus<={stimulus[447:0],serial_in};
        address_o<=o_address_nxt;data_o<=o_instruction;
        observe_o<=32'(o_ready) ^
            32'(o_valid) ^
            32'(o_pc) ^
            32'(o_instruction) ^
            32'(o_pc_base) ^
            32'(o_next_pc) ^
            32'(o_raw) ^
            32'(o_mode) ^
            32'(o_thumb) ^
            32'(o_fault) ^
            32'(o_force_align) ^
            32'(o_reg_shift) ^
            32'(o_kind) ^
            32'(o_condition) ^
            32'(o_tag) ^
            32'(o_used) ^
            32'(flat_o_value[31:0]) ^
            32'(flat_o_value[63:32]) ^
            32'(flat_o_value[95:64]) ^
            32'(flat_o_value[127:96]) ^
            32'(o_dest) ^
            32'(o_first) ^
            32'(o_last) ^
            32'(o_reg_count) ^
            32'(o_offset) ^
            32'(o_writeback_offset) ^
            32'(o_transfer_reg) ^
            32'(o_branch_target) ^
            32'(o_direct) ^
            32'(o_match_taken) ^
            32'(o_match_fallthrough) ^
            32'(o_predicted) ^
            32'(o_pred_hit) ^
            32'(o_pred_target) ^
            32'(o_pred_state) ^
            32'(o_pred_kind) ^
            32'(o_ras_pointer) ^
            32'(o_ras_count) ^
            32'(o_hazard) ^
            32'(o_redirect) ^
            32'(o_redirect_thumb) ^
            32'(o_redirect_target) ^
            32'(o_redirect_link) ^
            32'(o_redirect_pointer) ^
            32'(o_redirect_count) ^
            32'(o_redirect_action) ^
            32'(o_address_nxt) ^
            32'(o_address_check) ^
            32'(o_address) ^
            32'(o_request) ^
            32'(o_stall);
    end
    arm9v2_front_decode u_front_decode (.*);
endmodule
