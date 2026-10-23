// SPDX-License-Identifier: GPL-3.0-or-later
// ARM9V2 fetch-cycle predictor. Independently implemented for this project.
// The synchronous entry read and source PC are captured on the SAME edge;
// the resulting decision chooses the following fetch without another stage.
module arm9v2_predict #(
    parameter integer ENTRIES = 256,
    localparam integer INDEX_W = $clog2(ENTRIES),
    localparam integer TAG_W = 31 - INDEX_W
) (
    input logic i_clk, i_reset, i_clear,
    input logic i_lookup,
    input logic [31:0] i_pc,
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
    logic [1:0] update_state;
    wire write_enable = i_update && !i_reset && !i_clear;
    wire [INDEX_W-1:0] rd_index = i_pc[INDEX_W:1];
    wire [INDEX_W-1:0] wr_index = i_update_pc[INDEX_W:1];
    wire unused = &{1'b0, i_pc[0], i_update_pc[0]};

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
        if (write_enable) valid_next[wr_index] = 1'b1;
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
    assign o_hit = read_valid[read_pc[INDEX_W:1]] && read_entry.tag == read_pc[31:INDEX_W+1] &&
                   read_entry.thumb == read_thumb;
    assign o_taken = o_hit && read_entry.state[1];
    assign o_target = read_entry.kind == RETURN && count != 0 ?
                      stack[3'(pointer - 1'b1)] : read_entry.target;
    assign o_state = o_hit ? read_entry.state : 2'b01;
    assign o_kind = read_entry.kind;
    assign o_pointer = pointer;
    assign o_count = count;

    // Repair has priority over speculative prediction. Depth/pointer are
    // restored, not contents: corruption of speculative history can only
    // cause another checked prediction miss, never an architectural write.
    always_ff @(posedge i_clk) begin
        if (i_reset || i_clear) begin
            pointer <= 0;
            count <= 0;
        end else if (i_repair) begin
            pointer <= i_repair_pointer;
            count <= i_repair_count;
            case (i_repair_action)
                CALL: begin
                    stack[i_repair_pointer] <= i_repair_link;
                    pointer <= i_repair_pointer + 1'b1;
                    count <= i_repair_count == 8 ? 4'd8 : i_repair_count + 1'b1;
                end
                RETURN: if (i_repair_count != 0) begin
                    pointer <= i_repair_pointer - 1'b1;
                    count <= i_repair_count - 1'b1;
                end
                2'd3: begin pointer <= 0; count <= 0; end
                default: ;
            endcase
        end else if (i_accept && o_taken) begin
            case (read_entry.kind)
                CALL: begin
                    stack[pointer] <= (read_pc + (read_thumb ? 32'd2 : 32'd4)) |
                                      {31'd0,read_thumb};
                    pointer <= pointer + 1'b1;
                    if (count != 8) count <= count + 1'b1;
                end
                RETURN: if (count != 0) begin
                    pointer <= pointer - 1'b1;
                    count <= count - 1'b1;
                end
                default: ;
            endcase
        end
    end
endmodule
