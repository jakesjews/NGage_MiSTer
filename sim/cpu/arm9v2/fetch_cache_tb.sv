// SPDX-License-Identifier: GPL-3.0-or-later
// Frontend against the real generated short-read I-cache, tag RAM and TLB.
// No CPU execution model: verify raw words/PCs, hot prediction cadence,
// uncached responses, TLB faults, and redirects during an outstanding fill.
module fetch_cache_tb;
    parameter integer LATENCY=0;
    logic clk=0,reset=1,redirect=0,ready=1,mmu=1;
    logic [31:0] target=32'h1000;
    logic update=0;
    logic [31:0] update_pc=0,update_target=0;
    wire [31:0] addr_next,addr_check,addr,data,pc,word_data,pred_target;
    wire request,stall,ack,error,retry,fill_pending,fill_done,fill_fault,valid,fault,predicted;
    wire bus_stb,bus_we;
    wire [31:0] bus_addr;
    logic bus_ack=0;
    logic [31:0] bus_data=0;
    int cycles=0,checks=0,beats=0;
    arm9v2_fetch #(.RESET_VECTOR(32'h1000)) frontend (
        .i_clk(clk),.i_reset(reset),.i_redirect(redirect),.i_redirect_thumb(1'b0),
        .i_redirect_target(target),.i_redirect_pointer(3'd0),.i_redirect_count(4'd0),
        .i_redirect_action(2'd3),.i_redirect_link(32'd0),.i_predictor_clear(1'b0),
        .i_update(update),.i_update_pc(update_pc),.i_update_target(update_target),
        .i_update_thumb(1'b0),.i_update_taken(1'b1),.i_update_hit(1'b0),
        .i_update_state(2'd1),.i_update_kind(2'd0),
        .i_data(data),.i_ack(ack),.i_error(error),.i_retry(retry),
        .i_fill_pending(fill_pending),.i_fill_done(fill_done),.i_fill_fault(fill_fault),
        .o_address_nxt(addr_next),.o_address_check(addr_check),.o_address(addr),
        .o_request(request),.o_stall(stall),.i_ready(ready),.o_valid(valid),
        .o_pc(pc),.o_word(word_data),.o_fault(fault),.o_predicted(predicted),.o_pred_target(pred_target)
    );
    zap_cache #(.CACHE_SIZE(16384),.WAYS(2),.CACHE_LINE(16)) cache (
        .i_clk(clk),.i_reset(reset),.i_stall(stall),.i_address_check(addr_check),
        .i_wr_check(1'b0),.i_rd_check(1'b1),.i_address(addr),.i_address_nxt(addr_next),
        .i_rd(request),.i_wr(1'b0),.i_ben(4'hf),.i_dat(32'd0),.o_dat(data),
        .o_ack(ack),.o_err(error),.o_err2(retry),.o_fill_pending(fill_pending),
        .o_fill_done(fill_done),.o_fill_fault(fill_fault),.i_mmu_en(mmu),.i_cache_en(1'b1),
        .i_cache_inv_req(1'b0),.i_cache_clean_req(1'b0),.i_cpsr(5'b10011),
        .i_sr(2'd0),.i_baddr(32'h4000),.i_dac_reg(32'd1),.i_tlb_inv(1'b0),
        .o_wb_stb(bus_stb),.o_wb_wen(bus_we),
        .o_wb_adr(bus_addr),.i_wb_dat(bus_data),.i_wb_ack(bus_ack),.i_wb_err(1'b0)
    );
    bit busy=0;
    int wait_left=0;
    logic [31:0] held_addr=0;
    task automatic check(input bit ok,input string message);
        checks++;assert(ok)else $fatal(1,"%s cycle=%0d pc=%h addr=%h",message,cycles,pc,addr);
    endtask
    function automatic logic [31:0] memory_word(input logic [31:0] a);
        // VA section zero: AP=3, domain=0, C=B=1, identity mapping.
        if(a==32'h4000)return 32'h00000c0e;
        if(a>=32'h4004&&a<32'h8000)return 0; // all other descriptors fault
        return a ^ 32'h31415926;
    endfunction
    task automatic tick;
        bus_ack=0;
        if(reset)busy=0;
        else if(bus_stb)begin
            check(!bus_we,"instruction bus must read");
            if(!busy)begin busy=1;held_addr=bus_addr;wait_left=LATENCY;end
            check(bus_addr==held_addr,"bus address stable before ACK");
            if(wait_left==0)begin bus_ack=1;bus_data=memory_word(held_addr);busy=0;beats++;end
            else wait_left--;
        end else check(!busy,"outstanding bus request retained");
        #1;clk=1;#1;clk=0;bus_ack=0;#1;cycles++;
    endtask
    task automatic go(input logic [31:0] a);
        redirect=1;target=a;tick();redirect=0;
    endtask
    task automatic linear(input logic [31:0] start,input int n);
        int seen,limit;logic [31:0] want;
        seen=0;limit=0;want=start;
        while(seen<n&&limit<5000)begin
            if(valid&&ready)begin
                check(pc==want&&!fault,"cache PC and permission");
                check(word_data==memory_word(want),"cache data alignment");
                seen++;want+=4;
            end
            tick();limit++;
        end
        check(seen==n,"cache stream makes progress");
    endtask
    initial begin
        int seen,limit,last_cycle;logic [31:0] want;
        tick();reset=0;linear(32'h1000,80);
        go(32'h1000);ready=0;repeat(80)tick();check(stall,"real cache queue saturation");ready=1;linear(32'h1000,40);
        // Train while fetching, then repeat a three-line hot loop.
        update=1;update_pc=32'h1000;update_target=32'h1080;tick();
        update_pc=32'h1080;update_target=32'h10c0;tick();
        update_pc=32'h10c0;update_target=32'h1000;tick();update=0;
        go(32'h1000);seen=0;limit=0;last_cycle=0;want=32'h1000;
        while(seen<100&&limit<2000)begin
            if(valid)begin
                check(pc==want&&predicted&&!fault,"cache trained loop sequence");
                want=pc==32'h1000 ? 32'h1080 : pc==32'h1080 ? 32'h10c0 : 32'h1000;
                check(pred_target==want&&word_data==memory_word(pc),"cache prediction alignment");
                if(seen>10)check(cycles==last_cycle+1,"real cache zero-slot hot branch");
                seen++;last_cycle=cycles;
            end
            tick();limit++;
        end
        check(seen==100,"real cache hot loop progress");
        // Kill a cold lookup after its bus transaction begins.
        go(32'h2000);limit=0;
        while(!bus_stb&&limit<100)begin tick();limit++;end
        check(bus_stb,"cold target starts memory access");go(32'h3000);linear(32'h3000,40);
        // A translated section fault is delivered as a queued instruction fault.
        go(32'h00100000);limit=0;
        while(!valid&&limit<500)begin tick();limit++;end
        check(valid&&pc==32'h00100000&&fault,"TLB permission/translation abort queued");
        // Reset disables prior metadata; MMU-off exercises the uncached response source.
        reset=1;mmu=0;tick();reset=0;linear(32'h1000,16);
        $display("PASS real I-cache frontend latency=%0d: %0d checks, %0d cycles, %0d beats",LATENCY,checks,cycles,beats);
        $finish;
    end
endmodule
