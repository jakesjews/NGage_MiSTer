// SPDX-License-Identifier: GPL-3.0-or-later
// Fetch-address contract: a trained taken branch keeps every older slot,
// discards exactly one younger slot, and carries its own target/state to
// fetch. Run with tools/test_btb.sh; no cache or instruction decoder model.
module tb_btb;
    bit clk = 0;
    always #5 clk = ~clk;
    logic reset, stall, clear_btb, confirm, clear_alu, clear_decode, retry;
    logic thumb;
    logic [31:0] source, target, decode_target;
    logic [1:0] state;
    wire [31:0] pc, pc_check, pc_next;
    wire [32:0] pred;
    wire [1:0] taken;
    wire valid, shelve;

    zap_writeback #(.BP_ENTRIES(512)) dut (
        .i_clk(clk), .i_reset(reset), .i_code_stall(stall),
        .i_clear_btb(clear_btb), .i_confirm_from_alu(confirm),
        .i_clear_from_alu(clear_alu), .i_alu_pc_ff(source),
        .i_pc_from_alu(target), .i_taken(state),
        .i_clear_from_decode(clear_decode), .i_pc_from_decode(decode_target),
        .i_clear_from_icache(retry), .i_mode16(thumb),
        .o_pc(pc), .o_pc_check(pc_check), .o_pc_nxt(pc_next),
        .o_pred(pred), .o_taken(taken), .o_wb_stb(valid), .o_shelve(shelve),
        .i_decompile('0), .i_decompile_valid(1'b0), .i_uop_last(1'b0),
        .i_cpu_pid(7'd0), .i_l4_enable(1'b1), .i_hivecs(1'b0),
        .i_valid(1'b0), .i_rd_index_0(6'd0), .i_rd_index_1(6'd0),
        .i_rd_index_2(6'd0), .i_rd_index_3(6'd0), .i_mem_load_ff(1'b0),
        .i_wr_index(6'd0), .i_wr_data(32'd0), .i_flags(32'd0),
        .i_wr_index_1(6'd0), .i_wr_data_1(32'd0),
        .i_wr_index_2(46'd0), .i_wr_data_2(32'd0),
        .i_irq(1'b0), .i_fiq(1'b0), .i_instr_abt(1'b0), .i_data_abt(2'd0),
        .i_swi(1'b0), .i_und(1'b0), .i_pc_plus_8_buf_ff(32'd0),
        .i_copro_reg_en(1'b0), .i_copro_reg_wr_index(6'd0),
        .i_copro_reg_rd_index(6'd0), .i_copro_reg_wr_data(32'd0),
        .o_decompile(), .o_copro_reg_rd_data_ff(), .o_rd_data_0(),
        .o_rd_data_1(), .o_rd_data_2(), .o_rd_data_3(), .o_cpsr_nxt(),
        .o_dbg_cpsr_ff(), .o_clear_from_writeback(), .o_wb_cyc(),
        .o_trace(), .o_trace_valid(), .o_trace_uop_last()
    );

    task automatic tick;
        @(posedge clk); #1;
    endtask

    task automatic init;
        reset = 1; stall = 0; clear_btb = 0; confirm = 0;
        clear_alu = 0; clear_decode = 0; retry = 0; thumb = 0;
        source = 0; target = 0; decode_target = 0; state = 3;
        tick(); reset = 0;
    endtask

    task automatic train(input logic [31:0] src, dst);
        source = src; target = dst; state = 3; confirm = 1;
        tick(); confirm = 0;
    endtask

    task automatic jump(input logic [31:0] dst);
        decode_target = dst; clear_decode = 1;
        tick(); clear_decode = 0;
    endtask

    task automatic first_slot;
        for (int n = 0; n < 8; n++) begin
            if (valid) return;
            tick();
        end
        $fatal(1, "fetch failed to restart");
    endtask

    task automatic hold_slot;
        logic [132:0] snapshot;
        snapshot = {valid, pc, pc_check, pred, taken, shelve, pc_next};
        stall = 1;
        repeat (3) begin
            tick();
            if ({valid, pc, pc_check, pred, taken, shelve, pc_next} !== snapshot)
                $fatal(1, "address/metadata changed during stall");
        end
        stall = 0;
    endtask

    task automatic slot(input logic [31:0] address,
                        input bit predicted = 0,
                        input logic [31:0] destination = 0);
        if (!valid || pc != address || pred[32] != predicted)
            $fatal(1, "slot: expected %x pred=%b, got valid=%b pc=%x pred=%x",
                   address, predicted, valid, pc, pred);
        if (predicted && (pred[31:0] != destination || taken != 3))
            $fatal(1, "prediction/state belong to another instruction at %x", pc);
        tick();
    endtask

    task automatic bubble;
        if (valid) $fatal(1, "wrong-path slot escaped: %x", pc);
        tick();
    endtask

    initial begin
        logic [31:0] chain_target;
        // Stalls at every phase, including the RAM read, decision, branch
        // delivery and bubble. The target itself is another taken branch.
        for (int mode = 0; mode < 2; mode++) begin
            chain_target = mode ? 32'h182 : 32'h180;
            for (int phase = 0; phase < 10; phase++) begin
                init(); thumb = (mode != 0);
                train(32'h100 + (mode ? 6 : 12), chain_target);
                train(chain_target, 32'h200);
                // A trained younger sequential branch must be discarded.
                train(32'h100 + (mode ? 8 : 16), 32'hbad0);
                jump(32'h100);
                for (int n = 0; n < 3; n++) begin
                    if (phase == n) hold_slot();
                    bubble();
                end
                if (phase == 3) hold_slot();
                slot(32'h100);
                if (phase == 4) hold_slot();
                slot(32'h100 + (mode ? 2 : 4));
                if (phase == 5) hold_slot();
                slot(32'h100 + (mode ? 4 : 8));
                if (phase == 6) hold_slot();
                slot(32'h100 + (mode ? 6 : 12), 1, chain_target);
                if (phase == 7) hold_slot();
                bubble();
                if (phase == 8) hold_slot();
                slot(chain_target, 1, 32'h200);
                if (phase == 9) hold_slot();
                bubble();
                slot(32'h200);
            end
        end

        // Invalidation must cancel an unconsumed decision, including when
        // it arrives under stall. Already accepted redirects keep metadata.
        init(); train(32'h100, 32'h180); jump(32'h100);
        tick(); // branch in pc_del, registered decision ready
        stall = 1; clear_btb = 1; tick(); clear_btb = 0; tick(); stall = 0;
        first_slot(); slot(32'h100); slot(32'h104);

        init(); train(32'h100, 32'h180); jump(32'h100);
        tick(); tick(); // redirect accepted, branch in pc_del2
        clear_btb = 1; tick(); clear_btb = 0;
        slot(32'h100, 1, 32'h180); bubble(); slot(32'h180);

        // Both front-end recovery sources beat a simultaneous prediction.
        // A recovery under stall waits for the old fetch to complete.
        for (int kind = 0; kind < 2; kind++) begin
            for (int blocked = 0; blocked < 2; blocked++) begin
                init(); train(32'h100, 32'h180); jump(32'h100); tick();
                stall = (blocked != 0);
                if (kind == 0) begin
                    clear_alu = 1; target = 32'h300;
                end else begin
                    clear_decode = 1; decode_target = 32'h300;
                end
                tick(); clear_alu = 0; clear_decode = 0;
                if (blocked) begin
                    if (!shelve) $fatal(1, "recovery was not shelved");
                    tick(); stall = 0; tick();
                end
                first_slot(); slot(32'h300); slot(32'h304);
            end
        end

        // An older cache retry cancels speculative younger predictions.
        init(); train(32'h10c, 32'h180); jump(32'h100); first_slot();
        tick(); tick(); // 108 at fetch, branch 10c already redirected
        retry = 1; tick(); retry = 0;
        first_slot(); slot(32'h108); slot(32'h10c, 1, 32'h180);
        bubble(); slot(32'h180);

        // Same index, different tag must never supply a predicted target.
        init(); train(32'h500, 32'h180); jump(32'h100);
        first_slot(); slot(32'h100); slot(32'h104);
        $display("PASS: BTB one-slot redirects, ARM/Thumb, stalls, clear, recovery, retry, alias");
        $finish;
    end
endmodule
