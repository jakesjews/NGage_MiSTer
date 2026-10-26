// SPDX-License-Identifier: GPL-3.0-or-later
module fetch_tb;
    parameter bit PREDICTOR=1;
    parameter bit RAS_TOP_FF=0, VALID_BIT=0, THUMB_HALF=0;
    logic i_clk=0,i_reset=1,i_redirect=0,i_redirect_thumb=0;
    logic [31:0] i_redirect_target=0,i_redirect_link=0;
    logic [2:0] i_redirect_pointer=0;
    logic [3:0] i_redirect_count=0;
    logic [1:0] i_redirect_action=3;
    logic i_predictor_clear=0,i_update=0,i_update_thumb=0,i_update_taken=1,i_update_hit=0;
    logic [31:0] i_update_pc=0,i_update_target=0;
    logic [1:0] i_update_state=1,i_update_kind=0;
    wire [31:0] i_data=o_address ^ 32'h31415926;
    logic i_ack=1,i_error=0,i_retry=0,i_fill_pending=0,i_fill_done=0,i_fill_fault=0;
    wire [31:0] o_address_nxt,o_address_check,o_address;
    wire o_request,o_stall;
    wire [1:0] o_dbg_fetch;
    logic i_ready=1;
    wire o_valid,o_thumb,o_fault,o_predicted,o_pred_hit;
    wire [31:0] o_pc,o_word,o_pred_target;
    wire [1:0] o_pred_state,o_pred_kind;
    wire [2:0] o_ras_pointer;
    wire [3:0] o_ras_count;
    wire unused = &{1'b0,o_dbg_fetch,o_address_nxt,o_address_check,o_pred_hit,o_pred_state,o_pred_kind,o_ras_pointer,o_ras_count};
    arm9v2_fetch #(.PREDICTOR(PREDICTOR),.RAS_TOP_FF(RAS_TOP_FF),.VALID_BIT(VALID_BIT),.THUMB_HALF(THUMB_HALF)) dut (.*);
    int checks=0,cycle=0;
    task automatic tick;
        #1; i_clk=1; #1; i_clk=0; #1; cycle++;
    endtask
    task automatic check(input bit ok, input string label);
        checks++;
        assert(ok) else $fatal(1,"%s at cycle %0d, check %0d, PC %h",label,cycle,checks,o_pc);
    endtask
    task automatic reset_front;
        i_reset=1; i_redirect=0;i_predictor_clear=0;i_update=0;
        i_ack=1;i_ready=1;i_retry=0;i_fill_pending=0;i_fill_done=0;i_fill_fault=0;i_error=0;
        tick();i_reset=0;
    endtask
    task automatic redirect(input logic [31:0] pc,input logic thumb=0);
        i_redirect=1;i_redirect_target=pc;i_redirect_thumb=thumb; tick();i_redirect=0;
    endtask
    task automatic train(input logic [31:0] pc,target,input logic thumb=0,input logic [1:0] kind=0);
        i_update=1;i_update_pc=pc;i_update_target=target;i_update_thumb=thumb;i_update_kind=kind;
        tick();i_update=0;
    endtask
    task automatic expect_linear(input logic [31:0] first,input int length,input logic thumb=0);
        int received,limit;
        logic [31:0] expected_pc, raw;
        received=0;limit=0;expected_pc=first;
        while(received<length && limit<length+30) begin
            if(o_valid && i_ready) begin
                check(o_pc==expected_pc && o_thumb==thumb,"linear PC and state");
                // THUMB_HALF: a Thumb instruction at pc[1] arrives in the low halfword.
                raw=expected_pc^32'h31415926;
                check(o_word==(THUMB_HALF&&thumb&&expected_pc[1]?{16'd0,raw[31:16]}:raw),"raw word follows metadata");
                check(!o_fault,"no spurious permission fault");
                received++;expected_pc+=thumb?2:4;
            end
            tick();limit++;
        end
        check(received==length,"linear progress");
    endtask
    initial begin
        int received,last_cycle,limit;
        logic [31:0] expected_pc,saved_pc;
        reset_front();expect_linear(0,32);
        // Queue saturation and delayed RAM/transaction advance must retain all words.
        redirect(32'h1000);i_ready=0;repeat(16)tick();check(o_stall,"queue full holds lookup");
        saved_pc=o_pc;repeat(6)begin tick();check(o_pc==saved_pc,"queue head stable under hold");end
        i_ready=1;expect_linear(32'h1000,32);
        // Local retry cancels only the retried lookup and younger F1; older queue stays.
        reset_front();repeat(2)tick();check(o_request,"request available for retry");
        i_retry=1;tick();i_retry=0;expect_linear(0,20);
        // Redirect during an unacknowledged old transaction: drain before reuse.
        reset_front();repeat(2)tick();i_ack=0;tick();saved_pc=o_address;
        redirect(32'h2000);repeat(5)begin tick();check(!o_valid && o_address==saved_pc,"redirect drains held transaction");end
        i_ack=1;expect_linear(32'h2000,20);
        // Repeated redirects wrap epoch while the same killed transaction drains.
        reset_front();repeat(2)tick();i_ack=0;
        for(int n=0;n<5;n++)redirect(32'h3000+32'(n*16));
        i_ack=1;expect_linear(32'h3040,12);
        // Early instruction word remains non-consumable until final fill permission resolves.
        reset_front();repeat(2)tick();i_fill_pending=1;tick();i_fill_pending=0;
        check(!o_valid,"pending queue head is not executable");repeat(4)tick();check(!o_valid,"pending head holds younger words");
        i_fill_done=1;i_fill_fault=1;tick();i_fill_done=0;i_fill_fault=0;
        check(o_valid && o_pc==0 && o_fault,"late fill fault belongs to queued instruction");
        // Trained branches target another registered F1 lookup every clock.
        reset_front();train(32'h100,32'h180);train(32'h180,32'h1c0);train(32'h1c0,32'h100);
        redirect(32'h100);received=0;last_cycle=0;limit=0;expected_pc=32'h100;
        while(received<60 && limit<100)begin
            if(o_valid)begin
                check(o_pc==expected_pc,"predicted target sequence");
                if(PREDICTOR)begin
                    check(o_predicted,"trained branch metadata");
                    if(received!=0)check(cycle==last_cycle+1,"zero lost fetch slots");
                    expected_pc = o_pc == 32'h100 ? 32'h180 : o_pc == 32'h180 ? 32'h1c0 : 32'h100;
                    check(o_pred_target==expected_pc,"predicted target travels with word");
                end else expected_pc+=4;
                last_cycle=cycle;received++;
            end
            tick();limit++;
        end
        check(received==60,"trained loop progress");
        // Deterministic random backpressure/memory waits preserve stream order.
        reset_front();redirect(32'h8000);received=0;expected_pc=32'h8000;
        for(int n=0;n<500;n++)begin
            i_ready=(n%7!=0)&&(n%11!=0);i_ack=(n%13>2);#1;
            if(o_valid&&i_ready)begin
                check(o_pc==expected_pc,"held stream order");
                expected_pc+=4;received++;
            end
            tick();
        end
        check(received>200,"held stream throughput");
        // Thumb state/halfword PC is metadata; raw word is not expanded here.
        i_ready=1;i_ack=1;redirect(32'h9002,1);expect_linear(32'h9002,30,1);
        $display("PASS fetch predictor=%0d: %0d checks",PREDICTOR,checks);$finish;
    end
endmodule
