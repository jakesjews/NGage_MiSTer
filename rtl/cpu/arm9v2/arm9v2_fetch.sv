// SPDX-License-Identifier: GPL-3.0-or-later
// ARM9V2 F1/F2 and raw-word queue. The cache/TLB use the retained short-read
// interface. Prediction is attached in F1; only queue push consumes validity
// from the cache. There is no Thumb decoder or response-to-D bypass here.
// THUMB_HALF: a Thumb fetch at pc[1] stores its upper halfword in the low
// half at queue push, so decode's instruction is the queue's word without
// a thumb/pc multiplexer behind the head select.
// Parameter defaults are the core's configuration (arm9v2_core sets each
// explicitly); 0 selects a cut's original form, kept for A/B timing trials.
module arm9v2_fetch #(
    parameter logic [31:0] RESET_VECTOR = 0,
    parameter logic PREDICTOR = 1'b1,
    parameter logic THUMB_HALF = 1'b1,
    parameter logic RAS_TOP_FF = 1'b1,
    parameter logic VALID_BIT = 1'b1
) (
    input logic i_clk, i_reset,
    // Backend redirect, payload and predictor update are registered by owner.
    input logic i_redirect, i_redirect_thumb,
    input logic [31:0] i_redirect_target,
    input logic [2:0] i_redirect_pointer,
    input logic [3:0] i_redirect_count,
    input logic [1:0] i_redirect_action,
    input logic [31:0] i_redirect_link,
    input logic i_predictor_clear, i_update,
    input logic [31:0] i_update_pc, i_update_target,
    input logic i_update_thumb, i_update_taken, i_update_hit,
    input logic [1:0] i_update_state, i_update_kind,
    input logic [31:0] i_data,
    input logic i_ack, i_error, i_retry,
    input logic i_fill_pending, i_fill_done, i_fill_fault,
    output logic [31:0] o_address_nxt, o_address_check, o_address,
    output logic o_request, o_stall,
    output logic [1:0] o_dbg_fetch,
    input logic i_ready,
    output logic o_valid,
    output logic [31:0] o_pc, o_word,
    output logic o_thumb, o_fault, o_predicted, o_pred_hit,
    output logic [31:0] o_pred_target,
    output logic [1:0] o_pred_state, o_pred_kind,
    output logic [2:0] o_ras_pointer,
    output logic [3:0] o_ras_count
);
    typedef struct packed {
        logic valid, thumb;
        logic [1:0] epoch;
        logic [31:0] pc;
    } lookup_t;
    typedef struct packed {
        logic predicted, hit;
        logic [31:0] target;
        logic [1:0] state, kind;
        logic [2:0] pointer;
        logic [3:0] count;
    } prediction_t;
    typedef struct packed {
        logic [31:0] word, pc;
        logic thumb, fault, pending;
        logic [1:0] epoch;
        prediction_t prediction;
    } packet_t;
    (* dont_retime *) lookup_t f1, f2;
    (* dont_retime *) prediction_t f2_prediction;
    (* dont_retime *) logic [31:0] sequential_pc, restart_pc;
    (* dont_retime *) logic sequential_thumb, restart_thumb, killed;
    (* dont_retime *) logic [1:0] epoch;
    (* dont_retime *) logic [2:0] tail;
    (* dont_retime *) logic [7:0] head_select;
    (* dont_retime *) logic [3:0] count;
    packet_t queue [0:7];
    packet_t head_packet;
    prediction_t prediction;
    logic predicted, advance, push, pop, retry, launch_thumb;
    logic [31:0] launch_pc;
    // Redirect is already a backend register. Launch its RAM lookup on the
    // applying edge, rather than first copying it into sequential_pc.
    (* keep *) wire [31:0] redirect_next = {i_redirect_target[31:1],1'b0} +
                                                (i_redirect_thumb ? 32'd2 : 32'd4);
    // Both continuations are independent of the hit decision. Keep the
    // increment off the RAM -> tag -> launch-select path into sequential_pc.
    (* keep *) wire [31:0] predicted_next = {prediction.target[31:1],1'b0} +
                                              (prediction.target[0] ? 32'd2 : 32'd4);
    (* keep *) wire [31:0] sequential_next = sequential_pc +
                                              (sequential_thumb ? 32'd2 : 32'd4);
    logic unused;
    assign unused = &{1'b0, i_redirect_target[0], i_redirect_pointer, i_redirect_count,
        i_redirect_action, i_redirect_link, i_predictor_clear, i_update, i_update_pc,
        i_update_target, i_update_thumb, i_update_taken, i_update_hit,
        i_update_state, i_update_kind};

    assign predicted = PREDICTOR && prediction.predicted && f1.valid &&
                       f1.epoch == epoch && !killed;
    assign launch_pc = i_redirect ? {i_redirect_target[31:1],1'b0} : predicted ? {prediction.target[31:1],1'b0} : sequential_pc;
    assign launch_thumb = i_redirect ? i_redirect_thumb : predicted ? prediction.target[0] : sequential_thumb;
    assign o_address_nxt = launch_pc;
    assign o_address_check = f1.pc;
    assign o_address = f2.pc;
    assign o_request = f2.valid && !killed && !i_redirect;
    // Cache lookup metadata and the cache RAM enable advance together.
    // Queue backpressure ends here; it does not qualify the queue's D output.
    assign o_stall = (count == 8 && !killed) || (f2.valid && !i_ack);
    assign o_dbg_fetch = {f2.valid && !i_ack, count == 8 && !killed};
    assign advance = !o_stall;
    assign retry = f2.valid && i_ack && i_retry && !killed && !i_redirect;
    assign push = f2.valid && i_ack && !i_retry && advance &&
                  !killed && !i_redirect && f2.epoch == epoch;
    // Registered one-hot selection avoids a binary head decoder driving all
    // packet bits. Only stored queue data appears at this boundary.
    always_comb begin
        head_packet=packet_t'(0);
        for (int q=0;q<8;q++)
            head_packet |= queue[q] & {$bits(packet_t){head_select[q]}};
    end
    assign o_valid = count != 0 && !head_packet.pending && head_packet.epoch == epoch;
    assign pop = o_valid && i_ready;
    assign o_pc = head_packet.pc;
    assign o_word = head_packet.word;
    assign o_thumb = head_packet.thumb;
    assign o_fault = head_packet.fault;
    assign o_predicted = head_packet.prediction.predicted;
    assign o_pred_hit = head_packet.prediction.hit;
    assign o_pred_target = head_packet.prediction.target;
    assign o_pred_state = head_packet.prediction.state;
    assign o_pred_kind = head_packet.prediction.kind;
    assign o_ras_pointer = head_packet.prediction.pointer;
    assign o_ras_count = head_packet.prediction.count;

    if (PREDICTOR) begin : g_predictor
        arm9v2_predict #(.RAS_TOP_FF(RAS_TOP_FF), .VALID_BIT(VALID_BIT)) u_predict (
            .i_clk(i_clk), .i_reset(i_reset), .i_clear(i_predictor_clear),
            .i_lookup(advance), .i_pc(launch_pc), .i_thumb(launch_thumb),
            .i_pc_redirect(i_redirect_target), .i_pc_sequential(sequential_pc),
            .i_sel_redirect(i_redirect), .i_sel_predicted(predicted),
            .i_accept(advance && f1.valid && !i_redirect && !retry && !killed),
            .i_update(i_update), .i_update_pc(i_update_pc), .i_update_target(i_update_target),
            .i_update_thumb(i_update_thumb), .i_update_taken(i_update_taken),
            .i_update_hit(i_update_hit), .i_update_state(i_update_state), .i_update_kind(i_update_kind),
            .i_repair(i_redirect || retry),
            .i_repair_pointer(i_redirect ? i_redirect_pointer : f2_prediction.pointer),
            .i_repair_count(i_redirect ? i_redirect_count : f2_prediction.count),
            .i_repair_action(i_redirect ? i_redirect_action : 2'd0),
            .i_repair_link(i_redirect_link),
            .o_hit(prediction.hit), .o_taken(prediction.predicted), .o_target(prediction.target),
            .o_state(prediction.state), .o_kind(prediction.kind),
            .o_pointer(prediction.pointer), .o_count(prediction.count)
        );
    end else begin : g_no_predictor
        assign prediction = prediction_t'(0);
    end

    // Separate entry registers prevent the queue from inferring a synchronous
    // RAM and putting its read address behind the decode backpressure chain.
    for (genvar q=0; q<8; q++) begin : g_queue
        always_ff @(posedge i_clk) begin
            if (push && tail == q) begin
                queue[q].word <= THUMB_HALF && f2.thumb && f2.pc[1] ? {16'd0,i_data[31:16]} : i_data;
                queue[q].pc <= f2.pc;
                queue[q].thumb <= f2.thumb;
                queue[q].epoch <= f2.epoch;
                queue[q].fault <= i_error || (i_fill_pending && i_fill_fault);
                queue[q].pending <= i_fill_pending && !i_fill_done;
                queue[q].prediction <= f2_prediction;
            end else if (i_fill_done) begin
                queue[q].pending <= 0;
                if (queue[q].pending) queue[q].fault <= queue[q].fault || i_fill_fault;
            end
        end
    end
    always_ff @(posedge i_clk) begin
        if (i_reset) begin
            f1 <= lookup_t'(0); f2 <= lookup_t'(0); f2_prediction <= prediction_t'(0);
            sequential_pc <= RESET_VECTOR; sequential_thumb <= 0;
            restart_pc <= RESET_VECTOR; restart_thumb <= 0;
            killed <= 0; epoch <= 0; head_select <= 8'b1; tail <= 0; count <= 0;
        end else begin
            if (pop) head_select <= {head_select[6:0],head_select[7]};
            if (push) tail <= tail + 1'b1;
            case ({push,pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: ;
            endcase
            if (advance) begin
                f1 <= {1'b1,launch_thumb,epoch,launch_pc};
                f2 <= f1;
                f2_prediction <= prediction;
                f2_prediction.predicted <= predicted;
                sequential_pc <= predicted ? predicted_next : sequential_next;
                sequential_thumb <= launch_thumb;
                if (retry || killed) begin
                    f1.valid <= 0;
                    f2.valid <= 0;
                    sequential_pc <= i_redirect ? {i_redirect_target[31:1],1'b0} :
                                     retry ? f2.pc : restart_pc;
                    sequential_thumb <= i_redirect ? i_redirect_thumb :
                                        retry ? f2.thumb : restart_thumb;
                end
                if (i_redirect) begin
                    f1 <= {1'b1,i_redirect_thumb,epoch+2'd1,{i_redirect_target[31:1],1'b0}};
                    f2.valid <= 0;
                    sequential_pc <= redirect_next;
                    sequential_thumb <= i_redirect_thumb;
                end
            end
            if (i_redirect) begin
                epoch <= epoch + 1'b1;
                head_select <= 8'b1; tail <= 0; count <= 0;
                killed <= o_stall;
                restart_pc <= {i_redirect_target[31:1],1'b0};
                restart_thumb <= i_redirect_thumb;
            end else if (retry) begin
                killed <= o_stall;
                restart_pc <= f2.pc; restart_thumb <= f2.thumb;
            end else if (advance && killed) killed <= 0;
        end
    end
endmodule
