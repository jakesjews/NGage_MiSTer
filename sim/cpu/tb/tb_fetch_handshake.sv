// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise the production zap_core fetch/FIFO wiring and consumed bit. Only
// the cache response, redirect decisions and downstream backpressure are
// driven here; the fetch register, FIFO and marker are never substituted.
module tb_fetch_handshake;
    logic clk = 0, reset = 1;
    logic response = 0, block_fifo = 1, block_data = 0;
    logic clear_alu = 0, clear_decode = 0, clear_wb = 0;
    logic pending = 0, done = 0, fault = 0, abort_fetch = 0, thumb = 0;
    logic [31:0] addr = 0, word_in = 0;

    zap_core #(.FIFO_DEPTH(4)) dut (
        .i_clk(clk), .i_reset(reset),
        .i_instr_wb_ack(response), .i_instr_wb_dat(word_in), .i_instr_wb_err(abort_fetch),
        .i_icache_fill_pending(pending), .i_icache_fill_done(done), .i_icache_fill_fault(fault),
        .i_icache_err2(1'b0), .i_data_wb_ack(1'b1), .i_data_wb_err(1'b0),
        .i_data_wb_dat(32'd0), .i_irq(1'b0), .i_fiq(1'b0),
        .i_dc_reg_idx(64'd0), .i_dc_reg_dat(32'd0), .i_dc_lock(64'd0)
    );
    initial begin
        // The real code_stall calculation still uses FIFO full and response.
        force dut.o_instr_wb_cyc = 1'b1;
        force dut.o_instr_wb_stb = 1'b1;
        force dut.o_instr_wb_adr = addr;
        force dut.shelve = 1'b0;
        force dut.clear_from_alu = clear_alu;
        force dut.clear_from_decode = clear_decode;
        force dut.clear_from_writeback = clear_wb;
        force dut.alu_flags_ff = thumb ? 32'hf3 : 32'hd3;
        force dut.wb_taken = 2'b00;
        force dut.wb_pred = 33'd0;
        force dut.U_ZAP_FIFO.i_data_stall = block_data;
        force dut.U_ZAP_FIFO.i_stall_from_shifter = 1'b0;
        force dut.U_ZAP_FIFO.i_stall_from_decode = 1'b0;
        force dut.U_ZAP_FIFO.i_stall_from_issue = block_fifo;
    end

    task automatic tick;
        #1; clk = 1; #1; clk = 0; #1;
    endtask
    task automatic restart;
        reset = 1; response = 0; block_fifo = 1; block_data = 0;
        clear_alu = 0; clear_decode = 0; clear_wb = 0;
        pending = 0; done = 0; fault = 0; abort_fetch = 0; thumb = 0;
        tick(); reset = 0;
        assert (!dut.fetch_consumed_ff && !dut.fetch_valid && !dut.fifo_valid)
            else $fatal(1, "reset retained a held/consumed word");
    endtask
    task automatic capture(input logic [31:0] pc, input logic [31:0] instruction);
        addr = pc; word_in = instruction; response = 1; tick(); response = 0;
    endtask
    task automatic expect_word(input logic [31:0] pc, input logic [31:0] instruction,
                               input bit aborted = 0);
        assert (dut.fifo_valid && dut.fifo_pc_plus_8 == pc + (thumb ? 4 : 8) &&
                dut.fifo_instruction == instruction && dut.fifo_instr_abort == aborted)
            else $fatal(1, "FIFO valid=%b pc8=%h word=%h abort=%b, wanted pc=%h word=%h abort=%b",
                        dut.fifo_valid, dut.fifo_pc_plus_8, dut.fifo_instruction,
                        dut.fifo_instr_abort, pc, instruction, aborted);
    endtask
    task automatic empty_next;
        tick(); assert (!dut.fifo_valid) else $fatal(1, "held word duplicated");
    endtask

    initial begin
        // A held word drains without the next ACK and is not repeated.
        restart(); capture(32'h100, 32'he1a00000); tick();
        assert (dut.fetch_consumed_ff) else $fatal(1, "held word was not consumed");
        repeat (4) tick(); block_fifo = 0; tick();
        expect_word(32'h100, 32'he1a00000); empty_next(); empty_next();

        // Back-to-back replacement can enqueue the old word and capture the
        // new one on the same edge. Fill the FIFO with one further word held.
        restart();
        for (int n = 0; n < 5; n++) capture(32'h200 + 32'(4*n), 32'he3a00000 + 32'(n));
        assert (dut.fifo_full && !dut.fetch_consumed_ff)
            else $fatal(1, "full FIFO lost the unconsumed replacement");
        repeat (4) begin
            tick(); assert (!dut.fetch_consumed_ff) else $fatal(1, "full FIFO consumed held word");
        end
        block_fifo = 0;
        for (int n = 0; n < 5; n++) begin
            tick(); expect_word(32'h200 + 32'(4*n), 32'he3a00000 + 32'(n));
        end
        empty_next(); empty_next();

        // Replacing an already consumed held word must not write it twice.
        restart(); capture(32'h300, 32'he3a00001); tick();
        capture(32'h304, 32'he3a00002); tick(); block_fifo = 0;
        tick(); expect_word(32'h300, 32'he3a00001);
        tick(); expect_word(32'h304, 32'he3a00002); empty_next();

        // Both resolved branch directions while the next response is absent.
        // Exercise a consumed held word and an unconsumed held word for each.
        for (int direction = 0; direction < 2; direction++) begin
            for (int consumed = 0; consumed < 2; consumed++) begin
                restart(); capture(32'h400, 32'he3a00003);
                if (consumed != 0) tick();
                clear_alu = 1; tick(); clear_alu = 0;
                assert (!dut.fetch_consumed_ff && !dut.fetch_valid && dut.code_stall)
                    else $fatal(1, "held redirect retained fetch state");
                capture(direction == 0 ? 32'h800 : 32'h408, 32'he3a00005);
                tick(); block_fifo = 0; tick();
                expect_word(direction == 0 ? 32'h800 : 32'h408, 32'he3a00005); empty_next();
            end
        end
        // A cache response coincident with the redirect must also be discarded.
        restart(); capture(32'h400, 32'he3a00003); tick();
        clear_alu = 1; capture(32'h404, 32'he3a00004); clear_alu = 0;
        capture(32'h800, 32'he3a00005); tick(); block_fifo = 0; tick();
        expect_word(32'h800, 32'he3a00005); empty_next();
        // Decode redirects and writeback exceptions have the same ownership.
        for (int kind = 0; kind < 2; kind++) begin
            restart(); capture(32'h500, 32'he3a00006); tick();
            block_fifo = 0; // decode clears are accepted only without issue backpressure
            clear_decode = kind == 0; clear_wb = kind == 1; tick();
            clear_decode = 0; clear_wb = 0;
            capture(32'h900, 32'he3a00007); tick(); block_fifo = 0; tick();
            expect_word(32'h900, 32'he3a00007); empty_next();
        end

        // Clear priority is unchanged: a stalled redirect remains asserted
        // until accepted. Its queued word must not escape on the release edge.
        for (int kind = 0; kind < 2; kind++) begin
            restart(); capture(32'h600, 32'he3a00008); tick();
            block_data = kind == 0; clear_alu = kind == 0; clear_decode = kind == 1;
            repeat (3) tick();
            assert (!dut.fetch_valid && !dut.fetch_consumed_ff && !dut.fifo_valid)
                else $fatal(1, "stalled redirect leaked a held word");
            block_data = 0; block_fifo = 0; tick();
            clear_alu = 0; clear_decode = 0;
            capture(32'h980, 32'he3a00009); tick(); tick();
            expect_word(32'h980, 32'he3a00009); empty_next();
        end

        // Translation/permission faults arrive as an abort-marked fetch,
        // independent of another cache response. Sleep must not repeat it.
        for (int fault_kind = 0; fault_kind < 2; fault_kind++) begin
            restart(); abort_fetch = 1;
            capture(32'ha00 + 32'(4*fault_kind), 32'he1a00000); tick();
            assert (dut.fetch_consumed_ff) else $fatal(1, "abort word was not queued");
            block_fifo = 0; tick();
            expect_word(32'ha00 + 32'(4*fault_kind), 32'he1a00000, 1);
            empty_next(); response = 1; abort_fetch = 0; tick(); response = 0;
            empty_next();
        end

        // A late error must poison the queued provisional word even though
        // its held fetch copy has already been consumed. Test every late beat.
        for (int bad = 1; bad < 4; bad++) begin
            restart(); pending = 1; capture(32'hb00, 32'he2877001); tick();
            assert (dut.fetch_consumed_ff) else $fatal(1, "provisional marker not set");
            block_fifo = 0;
            for (int beat = 1; beat < 4; beat++) begin
                tick(); assert (!dut.fifo_valid) else $fatal(1, "provisional instruction escaped");
                if (beat == bad) fault = 1;
            end
            done = 1; tick(); expect_word(32'hb00, 32'he2877001, 1);
            done = 0; fault = 0; pending = 0; empty_next(); empty_next();
        end

        // Thumb alignment/payload remains attached to each consumed word.
        for (int half = 0; half < 8; half++) begin
            restart(); thumb = 1;
            capture(32'hc00 + 32'(2*half), 32'h37023701); tick();
            block_fifo = 0; tick();
            expect_word(32'hc00 + 32'(2*half), half[0] ? 32'h00003702 : 32'h37023701);
            empty_next();
        end
        // Reset while the marker is set, then reuse the same address.
        restart(); capture(32'hd00, 32'he3a00008); tick(); restart();
        capture(32'hd00, 32'he3a00009); tick(); block_fifo = 0; tick();
        expect_word(32'hd00, 32'he3a00009); empty_next();
        $display("PASS: production fetch handshake: once-only, full, replacement, clears, aborts, late errors, Thumb, reset");
        $finish;
    end
endmodule
