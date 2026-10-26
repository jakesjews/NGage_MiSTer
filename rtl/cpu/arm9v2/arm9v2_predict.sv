// SPDX-License-Identifier: GPL-3.0-or-later
// ARM9V2 fetch-cycle predictor. Independently implemented for this project.
// The synchronous entry read and source PC are captured on the SAME edge;
// the resulting decision chooses the following fetch without another stage.
// RAS_TOP_FF: the return stack's top, stack[pointer-1], is a register of its
// own, loaded on every edge that changes the stack or the pointer, so a
// return's predicted target (and the next fetch's I-TLB lookup) starts at a
// flop instead of the pointer's decrement and an 8:1 stack read.
// Parameter defaults are the core's configuration (arm9v2_core sets each
// explicitly); 0 selects a cut's original form, kept for A/B timing trials.
module arm9v2_predict #(
    parameter integer ENTRIES = 256,
    parameter logic RAS_TOP_FF = 1'b1,
    // VALID_BIT: the looked-up entry's valid bit as one register, loaded
    // from the valid bit of each launch candidate (redirect, predicted
    // target, sequential) selected as fetch selects the launch PC, so
    // o_hit does not read the bitmap through read_pc (a 256:1 mux).
    parameter logic VALID_BIT = 1'b1,
    // CLEAR_LATE: the next valid bitmap sets the updated entry without the
    // reset/clear terms (every register built from it is cleared outright
    // on those clocks), so the clear reaches the valid registers only as
    // their clear, not through the bitmap and the lookup select.
    parameter logic CLEAR_LATE = 1'b1,
    localparam integer INDEX_W = $clog2(ENTRIES),
    localparam integer TAG_W = 31 - INDEX_W
) (
    input logic i_clk, i_reset, i_clear,
    input logic i_lookup,
    input logic [31:0] i_pc,
    // VALID_BIT: i_pc's candidates and its selects (arm9v2_fetch launch_pc).
    input logic [31:0] i_pc_redirect, i_pc_sequential,
    input logic i_sel_redirect, i_sel_predicted,
    input logic i_thumb,
    input logic i_accept,
    input logic i_update,
    input logic [31:0] i_update_pc, i_update_target,
    input logic i_update_thumb, i_update_taken, i_update_hit,
    input logic [1:0] i_update_state, i_update_kind,
    input logic i_repair,
    input logic [2:0] i_repair_pointer,
    input logic [3:0] i_repair_count,
    input logic [1:0] i_repair_action, // 0 restore, 1 call, 2 return, 3 clear
    input logic [31:0] i_repair_link,
    output logic o_hit, o_taken,
    output logic [31:0] o_target,
    output logic [1:0] o_state, o_kind,
    output logic [2:0] o_pointer,
    output logic [3:0] o_count
);
    localparam logic [1:0] CALL = 1, RETURN = 2;
    typedef struct packed {
        logic [TAG_W-1:0] tag;
        logic thumb;
        logic [31:0] target; // bit 0 is target instruction state
        logic [1:0] state, kind;
    } entry_t;
    entry_t write_entry, read_entry;
    logic [ENTRIES-1:0] valid;
    // Snapshot the bitmap, not valid[late_next_pc]. Selection from read_pc
    // runs beside the RAM tag check, never after the predicted launch mux.
    (* dont_retime *) logic [ENTRIES-1:0] read_valid;
    logic [ENTRIES-1:0] valid_next;
    (* dont_retime *) logic read_thumb;
    (* dont_retime *) logic [31:0] read_pc;
    (* dont_retime *) logic [2:0] pointer;
    (* dont_retime *) logic [3:0] count;
    logic [31:0] stack [0:7];
    (* dont_retime *) logic [31:0] ras_top;   // RAS_TOP_FF: stack[pointer - 1]
    wire [31:0] call_link = (read_pc + (read_thumb ? 32'd2 : 32'd4)) | {31'd0,read_thumb};
    logic [1:0] update_state;
    wire write_enable = i_update && !i_reset && !i_clear;
    wire [INDEX_W-1:0] rd_index = i_pc[INDEX_W:1];
    wire [INDEX_W-1:0] wr_index = i_update_pc[INDEX_W:1];
    wire unused = &{1'b0, i_pc[0], i_update_pc[0], i_pc_redirect[31:INDEX_W+1], i_pc_redirect[0],
                    i_pc_sequential[31:INDEX_W+1], i_pc_sequential[0]};

    always_comb begin
        update_state = i_update_hit ? i_update_state : 2'b01;
        if (i_update_taken) begin
            if (update_state != 2'b11) update_state = update_state + 1'b1;
        end else if (update_state != 2'b00) update_state = update_state - 1'b1;
        write_entry = {i_update_pc[31:INDEX_W+1], i_update_thumb,
                       i_update_target, update_state, i_update_kind};
    end
    zap_ram_simple_nopipe #(.WIDTH($bits(entry_t)), .DEPTH(ENTRIES),
        .HOLD_READ(1'b1), .REGISTER_COLLISION(1'b1)) u_entries (
        .i_clk(i_clk), .i_wr_en(write_enable), .i_rd_en(i_lookup),
        .i_wr_data(write_entry), .i_wr_addr(wr_index), .i_rd_addr(rd_index),
        .o_rd_data(read_entry)
    );
    always_comb begin
        valid_next = valid;
        if (CLEAR_LATE ? i_update : write_enable) valid_next[wr_index] = 1'b1;
    end
    always_ff @(posedge i_clk) begin
        if (i_reset || i_clear) begin
            valid <= {ENTRIES{1'b0}};
            read_valid <= {ENTRIES{1'b0}};
        end else begin
            valid <= valid_next;
            if (i_lookup) read_valid <= valid_next;
        end
        if (i_lookup) begin
            read_pc <= i_pc;
            read_thumb <= i_thumb;
        end
    end
    (* dont_retime *) logic read_valid_bit;
    wire valid_redirect = valid_next[i_pc_redirect[INDEX_W:1]];
    wire valid_predicted = valid_next[o_target[INDEX_W:1]];
    wire valid_sequential = valid_next[i_pc_sequential[INDEX_W:1]];
    wire valid_launch = i_sel_redirect ? valid_redirect : i_sel_predicted ? valid_predicted : valid_sequential;
    always_ff @(posedge i_clk)
        if (i_reset || i_clear) read_valid_bit <= 1'b0;
        else if (i_lookup) read_valid_bit <= valid_launch;
`ifndef SYNTHESIS
    always_ff @(posedge i_clk) if (!i_reset && VALID_BIT) begin
        if (i_lookup) assert (valid_launch == valid_next[rd_index]) else $fatal(1, "predictor launch valid");
        assert (read_valid_bit == read_valid[read_pc[INDEX_W:1]]) else $fatal(1, "predictor valid bit");
    end
`endif
    assign o_hit = (VALID_BIT ? read_valid_bit : read_valid[read_pc[INDEX_W:1]]) && read_entry.tag == read_pc[31:INDEX_W+1] &&
                   read_entry.thumb == read_thumb;
    assign o_taken = o_hit && read_entry.state[1];
    assign o_target = read_entry.kind == RETURN && count != 0 ?
                      (RAS_TOP_FF ? ras_top : stack[3'(pointer - 1'b1)]) : read_entry.target;
`ifndef SYNTHESIS
    // Only a non-empty stack's top is ever used.
    always_ff @(posedge i_clk) if (!i_reset && RAS_TOP_FF && count != 0)
        assert (ras_top == stack[3'(pointer - 1'b1)]) else $fatal(1, "RAS top register");
`endif
    assign o_state = o_hit ? read_entry.state : 2'b01;
    assign o_kind = read_entry.kind;
    assign o_pointer = pointer;
    assign o_count = count;

    // Repair has priority over speculative prediction. Depth/pointer are
    // restored, not contents: corruption of speculative history can only
    // cause another checked prediction miss, never an architectural write.
    always_ff @(posedge i_clk) begin
        if (i_reset) begin
            pointer <= 0;
            count <= 0;
        end else if (i_repair) begin
            pointer <= i_repair_pointer;
            count <= i_repair_count;
            ras_top <= stack[3'(i_repair_pointer - 1'b1)];
            case (i_repair_action)
                CALL: begin
                    stack[i_repair_pointer] <= i_repair_link;
                    ras_top <= i_repair_link;
                    pointer <= i_repair_pointer + 1'b1;
                    count <= i_repair_count == 8 ? 4'd8 : i_repair_count + 1'b1;
                end
                RETURN: if (i_repair_count != 0) begin
                    ras_top <= stack[3'(i_repair_pointer - 2'd2)];
                    pointer <= i_repair_pointer - 1'b1;
                    count <= i_repair_count - 1'b1;
                end
                2'd3: begin pointer <= 0; count <= 0; end
                default: ;
            endcase
        end else if (i_clear) begin
            pointer <= 0; count <= 0;
        end else if (i_accept && o_taken) begin
            case (read_entry.kind)
                CALL: begin
                    stack[pointer] <= call_link;
                    ras_top <= call_link;
                    pointer <= pointer + 1'b1;
                    if (count != 8) count <= count + 1'b1;
                end
                RETURN: if (count != 0) begin
                    ras_top <= stack[3'(pointer - 2'd2)];
                    pointer <= pointer - 1'b1;
                    count <= count - 1'b1;
                end
                default: ;
            endcase
        end
    end
endmodule
