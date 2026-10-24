// SPDX-License-Identifier: GPL-3.0-or-later
// Real F1/F2/D1/D2/S/A, register file and three registered A/M/W producers.
// The M/W harness returns arithmetic results only; caches and precise memory
// retirement are not included. All external inputs/outputs are registered.
module cpu_trial(input logic clk,input logic [31:0] serial_in,
    output logic [31:0] address_o,data_o,observe_o);
    (* dont_retime *) logic [159:0] stimulus;
    logic i_clk;
    logic i_reset;
    logic i_flush;
    logic i_ready;
    logic [31:0] i_cpsr;
    logic [31:0] i_backend_target;
    logic i_backend_thumb;
    logic i_predictor_clear;
    logic [39:0] i_locked;
    logic [31:0] i_data;
    logic i_ack;
    logic i_error;
    logic i_retry;
    logic i_fill_pending;
    logic i_fill_done;
    logic i_fill_fault;
    logic o_execute_ready;
    logic o_valid;
    logic [31:0] o_pc;
    logic [31:0] o_instruction;
    logic [31:0] o_cpsr;
    logic [31:0] o_cpsr_next;
    logic [3:0] o_kind;
    logic o_thumb;
    logic o_fault;
    logic o_first;
    logic o_last;
    logic o_condition_pass;
    logic [1:0][5:0] o_dest;
    logic [1:0][31:0] o_result;
    logic [1:0] o_write;
    logic o_write_flags;
    logic o_pc_write;
    logic o_memory;
    logic o_store;
    logic [31:0] o_data_address;
    logic [31:0] o_store_data;
    logic [3:0] o_flags;
    logic o_redirect;
    logic o_redirect_thumb;
    logic [31:0] o_redirect_target;
    logic [31:0] o_redirect_link;
    logic [2:0] o_redirect_pointer;
    logic [3:0] o_redirect_count;
    logic [1:0] o_redirect_action;
    logic o_btb_update;
    logic o_btb_taken;
    logic o_btb_hit;
    logic [31:0] o_btb_target;
    logic [1:0] o_btb_state;
    logic [1:0] o_btb_kind;
    logic o_a_valid;
    logic o_a_can_finish;
    logic [1:0] o_s_write;
    logic [1:0][5:0] o_a_dest;
    logic [1:0] o_a_write;
    logic o_shift_wait;
    logic o_multiply_wait;
    logic [31:0] o_address_nxt;
    logic [31:0] o_address_check;
    logic [31:0] o_address;
    logic [31:0] o_retire_pc;
    logic [31:0] o_retire_instruction;
    logic [31:0] o_retire_value;
    logic o_request;
    logic o_stall;
    logic o_retire_valid;
    assign i_clk=clk;
    assign i_reset=stimulus[0:0];
    assign i_flush=stimulus[1:1];
    assign i_ready=stimulus[2:2];
    assign i_cpsr=stimulus[34:3];
    assign i_backend_target=stimulus[66:35];
    assign i_backend_thumb=stimulus[67:67];
    assign i_predictor_clear=stimulus[68:68];
    assign i_locked=stimulus[108:69];
    assign i_data=stimulus[140:109];
    assign i_ack=stimulus[141:141];
    assign i_error=stimulus[142:142];
    assign i_retry=stimulus[143:143];
    assign i_fill_pending=stimulus[144:144];
    assign i_fill_done=stimulus[145:145];
    assign i_fill_fault=stimulus[146:146];
    wire unused=&{1'b0,stimulus[159:147]};
    wire [63:0] flat_o_result=o_result;
    always_ff @(posedge clk)begin
        stimulus<={stimulus[127:0],serial_in};
        address_o<=o_address_nxt;data_o<=o_data_address;
        observe_o<=32'(o_execute_ready) ^
            32'(o_valid) ^
            32'(o_pc) ^
            32'(o_instruction) ^
            32'(o_cpsr) ^
            32'(o_cpsr_next) ^
            32'(o_kind) ^
            32'(o_thumb) ^
            32'(o_fault) ^
            32'(o_first) ^
            32'(o_last) ^
            32'(o_condition_pass) ^
            32'(o_dest) ^
            32'(flat_o_result[31:0]) ^
            32'(flat_o_result[63:32]) ^
            32'(o_write) ^
            32'(o_write_flags) ^
            32'(o_pc_write) ^
            32'(o_memory) ^
            32'(o_store) ^
            32'(o_data_address) ^
            32'(o_store_data) ^
            32'(o_flags) ^
            32'(o_redirect) ^
            32'(o_redirect_thumb) ^
            32'(o_redirect_target) ^
            32'(o_redirect_link) ^
            32'(o_redirect_pointer) ^
            32'(o_redirect_count) ^
            32'(o_redirect_action) ^
            32'(o_btb_update) ^
            32'(o_btb_taken) ^
            32'(o_btb_hit) ^
            32'(o_btb_target) ^
            32'(o_btb_state) ^
            32'(o_btb_kind) ^
            32'(o_a_valid) ^
            32'(o_a_can_finish) ^
            32'(o_s_write) ^
            32'(o_a_dest) ^
            32'(o_a_write) ^
            32'(o_shift_wait) ^
            32'(o_multiply_wait) ^
            32'(o_address_nxt) ^
            32'(o_address_check) ^
            32'(o_address) ^
            32'(o_retire_pc) ^
            32'(o_retire_instruction) ^
            32'(o_retire_value) ^
            32'(o_request) ^
            32'(o_stall) ^
            32'(o_retire_valid);
    end
    arm9v2_front_execute u_front_execute(.*);
endmodule
