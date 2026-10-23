// SPDX-License-Identifier: GPL-3.0-or-later
// Parallel cache/TLB read, then registered compare/Thumb translation.
// F2 hits may enter D directly; an eight-entry queue decouples backend stalls.
// The cache owns an untagged outstanding bus transaction. A redirect kills its
// epoch immediately, but drains that transaction before reusing the lookup pipe.
module arm9_fetch #(
    parameter logic [31:0] RESET_VECTOR = 0,
    parameter logic PREDICTOR = 1'b1,
    parameter logic [31:0] BP_ENTRIES = 512
) (
    input logic i_clk, i_reset,
    input logic i_redirect,
    input logic i_predictor_clear, i_fb_valid, i_fb_wrong,
    input logic [31:0] i_fb_pc, i_fb_target,
    input logic [1:0] i_fb_state,
    output logic o_predicted,
    output logic [31:0] o_pred_target,
    output logic [1:0] o_pred_state,
    input logic [31:0] i_target,
    input logic i_thumb,
    input logic [31:0] i_data, i_data_early,
    input logic i_hit,
    input logic i_ack, i_error, i_retry,
    input logic i_fill_pending, i_fill_done, i_fill_fault,
    output logic [31:0] o_address_nxt, o_address_check, o_address,
    output logic o_request, o_stall,
    output logic o_valid,
    output logic [31:0] o_pc, o_instruction,
    output logic o_abort,
    output logic [34:0] o_decoded,
    output logic o_thumb_und, o_thumb_align,
    input logic i_ready
);
    typedef struct packed {
        logic valid;
        logic [1:0] epoch;
        logic thumb;
        logic [31:0] pc;
    } lookup_t;
    typedef struct packed {
        logic [1:0] epoch;
        logic predicted;
        logic [31:0] pred_target;
        logic [1:0] pred_state;
        logic fault;
        logic pending;
        logic [34:0] decoded;
        logic thumb_und, thumb_align;
        logic [31:0] pc, instruction;
    } entry_t;
    lookup_t f1, f2;
    entry_t queue [0:7];
    logic [2:0] head, tail;
    logic [3:0] count;
    logic [31:0] launch_pc, target;
    logic launch_thumb, target_thumb, killed;
    logic [1:0] epoch;
    logic push, pop, retry, response, bypass;
    logic btb_taken, prediction;
    logic [31:0] btb_target;
    logic [1:0] btb_state;
    // Both alternatives and the BTB decision are registers. Neither the
    // RAM address nor the BTB lookup depends on the next-PC incrementer.
    assign prediction = PREDICTOR && btb_taken && f2.valid &&
                        f2.epoch == epoch && !killed;
    if (PREDICTOR) begin : g_predictor
        zap_btb #(.BP_ENTRIES(BP_ENTRIES)) u_btb (
            .i_clk(i_clk), .i_reset(i_reset), .i_stall(o_stall),
            .i_clear(i_predictor_clear), .i_fb_ok(i_fb_valid && !i_fb_wrong),
            .i_fb_nok(i_fb_valid && i_fb_wrong), .i_fb_branch_src_address(i_fb_pc),
            .i_fb_branch_dest_address(i_fb_target), .i_fb_current_branch_state(i_fb_state),
            .i_rd_addr(o_address_nxt), .i_rd_addr_del(f1.pc),
            .o_clear_from_btb(btb_taken), .o_pc_from_btb(btb_target), .o_branch_state(btb_state)
        );
    end else begin : g_no_predictor
        assign btb_taken = 0;
        assign btb_target = 0;
        assign btb_state = 0;
    end
    entry_t early_packet, selected_packet;
    logic [31:0] early_incoming;
    logic [34:0] early_decoded;
    logic early_und, early_align;
    logic [31:0] incoming;
    logic [34:0] decoded;
    logic thumb_und, thumb_align;
    assign incoming = f2.thumb && f2.pc[1] ? {16'd0,i_data[31:16]} : i_data;
    // Translate before the existing FIFO register. This moves the Thumb
    // decode off the D register-read/forwarding cone without adding a stage.
    zap_mode16_decoder #(.V4T(1'b1)) u_thumb (
        .i_instruction(incoming), .i_instruction_valid(1'b1), .i_offset(11'd0),
        .i_prev_prefix(1'b0), .i_irq(1'b0), .i_fiq(1'b0), .i_cpsr_ff_t(f2.thumb),
        .o_instruction(decoded), .o_instruction_valid(), .o_und(thumb_und),
        .o_force32_align(thumb_align), .o_irq(), .o_fiq()
    );

    assign early_incoming = f1.thumb && f1.pc[1] ? {16'd0,i_data_early[31:16]} : i_data_early;
    zap_mode16_decoder #(.V4T(1'b1)) u_thumb_early (
        .i_instruction(early_incoming), .i_instruction_valid(1'b1), .i_offset(11'd0),
        .i_prev_prefix(1'b0), .i_irq(1'b0), .i_fiq(1'b0), .i_cpsr_ff_t(f1.thumb),
        .o_instruction(early_decoded), .o_instruction_valid(), .o_und(early_und),
        .o_force32_align(early_align), .o_irq(), .o_fiq()
    );
    // F2 is already a data register. Empty-queue hits can enter D directly;
    // queued entries retain priority and misses use the ordinary capture.
    always_comb begin
        selected_packet = early_packet;
        if (!i_hit) begin
            selected_packet.pc = f2.pc;
            selected_packet.epoch = f2.epoch;
            selected_packet.instruction = incoming;
            selected_packet.decoded = f2.thumb ? decoded : {3'd0,incoming};
            selected_packet.thumb_und = thumb_und;
            selected_packet.thumb_align = thumb_align;
        end
        selected_packet.predicted = prediction;
        selected_packet.pred_target = btb_target;
        // An absent/non-taken entry starts weakly not-taken; the BTB has no
        // tag-valid output for its raw state. A taken entry has a valid state.
        selected_packet.pred_state = prediction ? btb_state : 2'b01;
        selected_packet.fault = i_error || (i_fill_pending && i_fill_fault);
        selected_packet.pending = i_fill_pending && !i_fill_done;
    end
    assign o_address_nxt = prediction ? btb_target : launch_pc;
    assign o_address_check = f1.pc;
    assign o_address = f2.pc;
    // Cancel an unstarted wrong-path request on the redirect edge. An
    // existing cache transaction drains through its own FSM even with rd low.
    assign o_request = f2.valid && !i_redirect && !killed;
    // Like the retained cache's original caller, hold RAMs and all lookup
    // metadata together. Pending queue entries resolve even while held.
    assign o_stall = (count == 8 && !killed) || (f2.valid && !i_ack);
    assign retry = f2.valid && i_ack && i_retry && !killed && !i_redirect;
    assign response = f2.valid && i_ack && !i_retry && !o_stall &&
                  !killed && !i_redirect && f2.epoch == epoch;
    // Uncached ARM words also arrive from the FSM's response register. They
    // can enter D directly without another enqueue edge. Thumb miss responses
    // still register translation before the operand-read path.
    assign bypass = count == 0 && response && (i_hit || !f2.thumb) && !selected_packet.pending;
    assign push = response && !(bypass && i_ready);
    assign o_valid = bypass || (count != 0 && !queue[head].pending &&
                     queue[head].epoch == epoch && !i_redirect);
    assign o_pc = bypass ? selected_packet.pc : queue[head].pc;
    assign o_instruction = bypass ? selected_packet.instruction : queue[head].instruction;
    assign o_abort = bypass ? selected_packet.fault : queue[head].fault;
    assign o_decoded = bypass ? (i_hit ? early_packet.decoded : {3'd0,incoming}) : queue[head].decoded;
    assign o_thumb_und = bypass ? (i_hit && early_packet.thumb_und) : queue[head].thumb_und;
    assign o_thumb_align = bypass ? (i_hit && early_packet.thumb_align) : queue[head].thumb_align;
    assign o_predicted = bypass ? selected_packet.predicted : queue[head].predicted;
    assign o_pred_target = bypass ? selected_packet.pred_target : queue[head].pred_target;
    assign o_pred_state = bypass ? selected_packet.pred_state : queue[head].pred_state;
    assign pop = o_valid && i_ready && !bypass;

    always_ff @(posedge i_clk) begin
        if (i_reset) begin
            f1 <= '0; f2 <= '0; early_packet <= '0;
            launch_pc <= RESET_VECTOR;
            launch_thumb <= 0;
            target <= RESET_VECTOR; target_thumb <= 0;
            killed <= 0; epoch <= 0;
            head <= 0; tail <= 0; count <= 0;
            for (int n=0; n<8; n++) queue[n] <= '0;
        end else begin
            if (!o_stall) begin
                early_packet.epoch <= f1.epoch;
                early_packet.pc <= f1.pc;
                early_packet.instruction <= early_incoming;
                early_packet.decoded <= early_decoded;
                early_packet.thumb_und <= early_und;
                early_packet.thumb_align <= early_align;
            end
            if (i_fill_done) begin
                for (int n=0; n<8; n++) begin
                    if (queue[n].pending) begin
                        queue[n].pending <= 0;
                        queue[n].fault <= queue[n].fault || i_fill_fault;
                    end
                end
            end
            if (push) begin
                queue[tail] <= selected_packet;
                tail <= tail + 1'b1;
            end
            if (pop) head <= head + 1'b1;
            case ({push,pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: ;
            endcase
            // A clear must advance invalid metadata whenever the RAMs advance.
            // Freezing just these registers for the clear edge mislabels a
            // later same-tag/different-set hit.
            if ((i_redirect || retry || killed) && !o_stall) begin
                f1 <= {1'b0,epoch,launch_thumb,o_address_nxt};
                f2 <= {1'b0,f1.epoch,f1.thumb,f1.pc};
                launch_pc <= i_redirect ? i_target : retry ? f2.pc : target;
                launch_thumb <= i_redirect ? i_thumb : retry ? f2.thumb : target_thumb;
            end
            if (i_redirect) begin
                epoch <= epoch + 1'b1;
                head <= 0; tail <= 0; count <= 0;
                killed <= o_stall;
                target <= i_target;
                target_thumb <= i_thumb;
            end else if (retry) begin
                // Retain older queue entries; only this lookup and younger
                // addresses need replay after a TLB walk or fill installation.
                killed <= o_stall;
                target <= f2.pc;
                target_thumb <= f2.thumb;
            end else if (!o_stall) begin
                if (killed) begin
                    killed <= 0;
                end else begin
                    f1 <= {1'b1,epoch,launch_thumb,o_address_nxt};
                    f2 <= f1;
                    if (prediction) f2.valid <= 0;
                    launch_pc <= o_address_nxt + (launch_thumb ? 32'd2 : 32'd4);
                end
            end
        end
    end
endmodule
