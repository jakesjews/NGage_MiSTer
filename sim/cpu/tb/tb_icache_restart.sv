// SPDX-License-Identifier: GPL-3.0-or-later
// Cycle-level checks complementary to tests/icache_restart.S: prove the
// response precedes burst completion and exercise the FIFO commit boundary.
module tb_icache_restart;
    logic clk = 0, reset = 1;
    logic [31:0] addr = 0, next_addr = 0, bus_data = 0, data;
    logic rd = 0, bus_ack = 0, bus_err = 0, force_stall = 0;
    wire ack, err, replay, pending, done, fault, bus_stb, tag_write;
    wire [31:0] bus_addr;
    wire [127:0] line_data;
    wire stall = force_stall || !ack;

    zap_cache_fsm #(.CACHE_SIZE(16384), .CACHE_LINE(16), .WAYS(2)) cache (
        .i_clk(clk), .i_reset(reset), .i_address(addr), .i_address_check(next_addr),
        .i_stall(stall), .i_rd(rd), .i_wr(1'b0), .i_din(32'd0), .i_ben(4'hf),
        .o_dat(data), .o_ack(ack), .o_err(err), .o_err2(replay),
        .o_fill_pending(pending), .o_fill_done(done), .o_fill_fault(fault),
        .i_cache_en(1'b1), .i_cache_inv(1'b0), .i_cache_clean(1'b0),
        .i_cache_line(128'd0), .i_cache_words(64'd0), .i_cache_word_sel(1'b0),
        .i_cache_tag_dirty(1'b0), .i_cache_tag('0), .i_cache_tag_valid(1'b0),
        .i_cache_hit(1'b0), .i_cache_way(1'b0), .o_cache_tag_wr_en(tag_write),
        .o_cache_line(line_data), .i_cache_clean_done(1'b0), .i_cache_inv_done(1'b0),
        .i_phy_addr(addr), .i_fsr(8'd0), .i_far(32'd0), .i_fault(1'b0),
        .i_cacheable(1'b1), .i_busy(1'b0), .o_wb_stb_ff(bus_stb),
        .o_wb_adr_ff(bus_addr), .i_wb_ack(bus_ack), .i_wb_err(bus_err), .i_wb_dat(bus_data),
        .i_pf_hit(1'b0), .i_pf_inv(1'b0), .i_wb_busy(1'b0), .o_pf_addr()
    );

    logic q_write = 0, q_stall = 1, q_clear = 0, q_pending = 0;
    logic q_done = 0, q_fault = 0;
    logic [31:0] q_in = 0;
    wire [31:0] q_out;
    wire q_valid, q_full, q_abort;
    zap_fifo #(.WDT(32), .DEPTH(4)) fifo (
        .i_clk(clk), .i_reset(reset), .i_write_inhibit(1'b0),
        .i_clear_from_writeback(1'b0), .i_data_stall(1'b0),
        .i_clear_from_alu(q_clear), .i_stall_from_shifter(1'b0),
        .i_stall_from_issue(q_stall), .i_stall_from_decode(1'b0),
        .i_clear_from_decode(1'b0), .i_instr(q_in), .i_valid(q_write),
        .i_fill_pending(q_pending), .i_fill_done(q_done), .i_fill_fault(q_fault),
        .o_fill_fault(q_abort), .o_full(q_full), .o_instr(q_out), .o_valid(q_valid)
    );

    task automatic tick;
        #1; clk = 1; #1; clk = 0; #1;
    endtask
    task automatic restart(input logic [31:0] a);
        reset = 1; rd = 0; bus_ack = 0; bus_err = 0; force_stall = 0;
        tick(); reset = 0; addr = a; next_addr = a; rd = 1;
        tick(); tick();
        assert (pending && bus_stb && bus_addr == (a & ~32'hf) && !ack)
            else $fatal(1, "linear fill did not start at word zero");
    endtask
    task automatic beat(input int n, input bit error_beat = 0);
        assert (bus_stb && bus_addr == (addr & ~32'hf) + 32'(4*n))
            else $fatal(1, "wrong beat address");
        bus_ack = !error_beat; bus_err = error_beat; bus_data = 32'h12340000 + 32'(n);
        tick(); bus_ack = 0; bus_err = 0; #1;
    endtask
    task automatic push(input int value, input bit provisional);
        q_in = 32'(value); q_pending = provisional; q_write = 1;
        assert (!q_full) else $fatal(1, "unexpected full FIFO");
        tick(); q_write = 0;
    endtask
    task automatic expect_word(input int value, input bit aborted);
        assert (q_valid && q_out == 32'(value) && q_abort == aborted)
            else $fatal(1, "FIFO got valid=%b data=%d abort=%b; expected %d/%b", q_valid, q_out, q_abort, value, aborted);
    endtask

    initial begin
        // Each requested offset becomes available exactly after its beat,
        // before the last beat when possible. Unreturned words never ACK.
        for (int word_idx = 0; word_idx < 4; word_idx++) begin
            restart(32'h100 + 32'(4*word_idx));
            for (int n = 0; n < 4; n++) begin
                beat(n);
                assert (ack == (n >= word_idx)) else $fatal(1, "early response validity");
                if (ack) assert (data == 32'h12340000 + 32'(word_idx)) else $fatal(1, "wrong requested word");
                if (n < 3) assert (pending && !done && !tag_write) else $fatal(1, "premature commit");
            end
            assert (done && !fault && tag_write && line_data == 128'h12340003123400021234000112340000)
                else $fatal(1, "line installation");
        end
        // Following sequential fetches wait for their own beats.
        restart(32'h200);
        for (int n = 0; n < 4; n++) begin
            beat(n);
            assert (ack && data == 32'h12340000 + 32'(n)) else $fatal(1, "sequential fill response");
            if (n < 3) begin
                next_addr = addr + 4; tick(); addr = next_addr; #1;
                assert (!ack) else $fatal(1, "ACK before next beat");
            end
        end
        // FIFO full cannot stop the bus; a late error survives until done.
        restart(32'h300);
        beat(0); force_stall = 1;
        beat(1); beat(2, 1); beat(3);
        assert (done && fault && err && !tag_write) else $fatal(1, "late fault lost");
        // A different-line redirect is replayed, not faulted with this fill.
        addr = 32'h400; next_addr = addr; #1;
        assert (!err && replay && fault) else $fatal(1, "redirect inherited fault");
        reset = 1; rd = 0; tick(); reset = 0;
        assert (!pending && !done) else $fatal(1, "reset did not cancel fill");

        // Older validated entries drain, but a provisional head does not.
        push(1, 0); push(2, 1); push(3, 1); push(4, 0);
        q_stall = 0; tick(); expect_word(1, 0);
        tick(); assert (!q_valid) else $fatal(1, "provisional instruction escaped");
        q_done = 1; q_fault = 1; tick(); expect_word(2, 1);
        q_done = 0; q_fault = 0; tick(); expect_word(3, 1);
        tick(); expect_word(4, 0); tick();

        // A second fill's failure cannot poison the completed first fill.
        q_stall = 1; push(5, 1);
        q_done = 1; tick(); q_done = 0;
        push(6, 1); q_done = 1; q_fault = 1; tick();
        q_done = 0; q_fault = 0; q_stall = 0;
        tick(); expect_word(5, 0); tick(); expect_word(6, 1); tick();

        // A word queued in the completion cycle gets the same resolution.
        q_stall = 1; q_done = 1; q_fault = 1; push(7, 1);
        q_done = 0; q_fault = 0; q_stall = 0; tick(); expect_word(7, 1); tick();
        // Redirect priority discards both queued words and their poison.
        q_stall = 1; push(8, 1); q_clear = 1; q_done = 1; q_fault = 1; tick();
        q_clear = 0; q_done = 0; q_fault = 0; q_stall = 0; tick();
        assert (!q_valid) else $fatal(1, "redirect did not flush");
        for (int n = 9; n < 18; n++) begin
            push(n, 0); tick(); expect_word(n, 0); tick();
        end
        $display("PASS: I-cache early beats, sequential waits, late fault, redirect, reset, FIFO resolution and wrap");
        $finish;
    end
endmodule
