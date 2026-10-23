// SPDX-License-Identifier: GPL-3.0-or-later
// Three-edge cache lookup, followed by an eight-entry instruction queue.
// The cache owns an untagged outstanding bus transaction. A redirect kills its
// epoch immediately, but drains that transaction before reusing the lookup pipe.
module arm9_fetch #(
    parameter logic [31:0] RESET_VECTOR = 0
) (
    input logic i_clk, i_reset,
    input logic i_redirect,
    input logic [31:0] i_target,
    input logic i_thumb,
    input logic [31:0] i_data,
    input logic i_ack, i_error, i_retry,
    input logic i_fill_pending, i_fill_done, i_fill_fault,
    output logic [31:0] o_address_nxt, o_address_check, o_address,
    output logic o_request, o_stall,
    output logic o_valid,
    output logic [31:0] o_pc, o_instruction,
    output logic o_abort,
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
        logic abort;
        logic pending;
        logic [31:0] pc, instruction;
    } entry_t;
    lookup_t f1, f2, f3;
    entry_t queue [0:7];
    logic [2:0] head, tail;
    logic [3:0] count;
    logic [31:0] launch_pc, target;
    logic launch_thumb, target_thumb, killed;
    logic [1:0] epoch;
    logic push, pop, retry;

    assign o_address_nxt = launch_pc;
    assign o_address_check = f2.pc;
    assign o_address = f3.pc;
    assign o_request = f3.valid;
    // Like the retained cache's original caller, hold RAMs and all lookup
    // metadata together. Pending queue entries resolve even while held.
    assign o_stall = (count == 8 && !killed) || (f3.valid && !i_ack);
    assign retry = f3.valid && i_ack && i_retry && !killed && !i_redirect;
    assign push = f3.valid && i_ack && !i_retry && !o_stall &&
                  !killed && !i_redirect && f3.epoch == epoch;
    assign o_valid = count != 0 && !queue[head].pending &&
                     queue[head].epoch == epoch && !i_redirect;
    assign o_pc = queue[head].pc;
    assign o_instruction = queue[head].instruction;
    assign o_abort = queue[head].abort;
    assign pop = o_valid && i_ready;

    always_ff @(posedge i_clk) begin
        if (i_reset) begin
            f1 <= '0; f2 <= '0; f3 <= '0;
            launch_pc <= RESET_VECTOR;
            launch_thumb <= 0;
            target <= RESET_VECTOR; target_thumb <= 0;
            killed <= 0; epoch <= 0;
            head <= 0; tail <= 0; count <= 0;
            for (int n=0; n<8; n++) queue[n] <= '0;
        end else begin
            if (i_fill_done) begin
                for (int n=0; n<8; n++) begin
                    if (queue[n].pending) begin
                        queue[n].pending <= 0;
                        queue[n].abort <= queue[n].abort || i_fill_fault;
                    end
                end
            end
            if (push) begin
                queue[tail].epoch <= f3.epoch;
                queue[tail].pc <= f3.pc;
                queue[tail].instruction <= f3.thumb && f3.pc[1] ?
                                          {16'd0,i_data[31:16]} : i_data;
                queue[tail].abort <= i_error || (i_fill_pending && i_fill_fault);
                queue[tail].pending <= i_fill_pending && !i_fill_done;
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
                f1 <= {1'b0,epoch,launch_thumb,launch_pc};
                f2 <= {1'b0,f1.epoch,f1.thumb,f1.pc};
                f3 <= {1'b0,f2.epoch,f2.thumb,f2.pc};
                launch_pc <= i_redirect ? i_target : retry ? f3.pc : target;
                launch_thumb <= i_redirect ? i_thumb : retry ? f3.thumb : target_thumb;
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
                target <= f3.pc;
                target_thumb <= f3.thumb;
            end else if (!o_stall) begin
                if (killed) begin
                    killed <= 0;
                end else begin
                    f1 <= {1'b1,epoch,launch_thumb,launch_pc};
                    f2 <= f1; f3 <= f2;
                    launch_pc <= launch_pc + (launch_thumb ? 32'd2 : 32'd4);
                end
            end
        end
    end
endmodule
