// SPDX-License-Identifier: GPL-3.0-or-later
module execute_cache_tb;
    parameter integer LATENCY=0;
    logic i_clk,i_reset,i_flush,i_ready;
    logic [31:0] i_cpsr,i_backend_target;
    logic i_backend_thumb,i_predictor_clear;
    logic [39:0] i_locked;
    logic [31:0] i_data;
    logic i_ack,i_error,i_retry,i_fill_pending,i_fill_done,i_fill_fault;
    logic o_execute_ready;
    logic o_valid;
    logic [31:0] o_pc;
    logic [31:0] o_instruction;
    logic [31:0] o_cpsr;
    logic [31:0] o_cpsr_next;
    logic [3:0] o_kind;
    logic o_thumb;
    logic o_fault;
    logic o_first;
    logic o_last;
    logic o_condition_pass;
    logic [1:0][5:0] o_dest;
    logic [1:0][31:0] o_result;
    logic [1:0] o_write;
    logic o_write_flags;
    logic o_pc_write;
    logic o_memory;
    logic o_store;
    logic [31:0] o_data_address;
    logic [31:0] o_store_data;
    logic [3:0] o_flags;
    logic o_redirect;
    logic o_redirect_thumb;
    logic [31:0] o_redirect_target;
    logic [31:0] o_redirect_link;
    logic [2:0] o_redirect_pointer;
    logic [3:0] o_redirect_count;
    logic [1:0] o_redirect_action;
    logic o_btb_update;
    logic o_btb_taken;
    logic o_btb_hit;
    logic [31:0] o_btb_target;
    logic [1:0] o_btb_state;
    logic [1:0] o_btb_kind;
    logic o_a_valid;
    logic o_a_can_finish;
    logic [1:0] o_s_write;
    logic [1:0][5:0] o_a_dest;
    logic [1:0] o_a_write;
    logic o_shift_wait;
    logic o_multiply_wait;
    logic [31:0] o_address_nxt;
    logic [31:0] o_address_check;
    logic [31:0] o_address;
    logic [31:0] o_retire_pc;
    logic [31:0] o_retire_instruction;
    logic [31:0] o_retire_value;
    logic o_request;
    logic o_stall;
    logic o_retire_valid;
    arm9v2_front_execute #(.RESET_VECTOR(32'h1000)) dut(.*);
    wire unused=&{1'b0,o_execute_ready,o_valid,o_pc,o_instruction,o_cpsr,o_cpsr_next,o_kind,o_thumb,o_fault,o_first,o_last,o_condition_pass,o_dest,o_result,o_write,o_write_flags,o_pc_write,o_memory,o_store,o_data_address,o_store_data,o_flags,o_redirect,o_redirect_thumb,o_redirect_target,o_redirect_link,o_redirect_pointer,o_redirect_count,o_redirect_action,o_btb_update,o_btb_taken,o_btb_hit,o_btb_target,o_btb_state,o_btb_kind,o_a_valid,o_a_can_finish,o_s_write,o_a_dest,o_a_write,o_shift_wait,o_multiply_wait,o_address_nxt,o_address_check,o_address,o_retire_pc,o_retire_instruction,o_retire_value,o_request,o_stall,o_retire_valid};
    wire bus_stb,bus_we;
    wire [31:0] bus_addr;
    logic bus_ack=0;
    logic [31:0] bus_data=0;
    zap_cache #(.CACHE_SIZE(16384),.WAYS(2),.CACHE_LINE(16)) cache (
        .i_clk(i_clk),.i_reset(i_reset),.i_stall(o_stall),.i_address_check(o_address_check),
        .i_wr_check(1'b0),.i_rd_check(1'b1),.i_address(o_address),.i_address_nxt(o_address_nxt),
        .i_rd(o_request),.i_wr(1'b0),.i_ben(4'hf),.i_dat(32'd0),.o_dat(i_data),
        .o_ack(i_ack),.o_err(i_error),.o_err2(i_retry),.o_fill_pending(i_fill_pending),
        .o_fill_done(i_fill_done),.o_fill_fault(i_fill_fault),.i_mmu_en(1'b1),.i_cache_en(1'b1),
        .i_cache_inv_req(1'b0),.i_cache_clean_req(1'b0),.i_cpsr(5'b10011),
        .i_sr(2'd0),.i_baddr(32'h4000),.i_dac_reg(32'd1),.i_tlb_inv(1'b0),
        .o_wb_stb(bus_stb),.o_wb_wen(bus_we),
        .o_wb_adr(bus_addr),.i_wb_dat(bus_data),.i_wb_ack(bus_ack),.i_wb_err(1'b0)
    );
    int cycles=0,checks=0,retired=0,loop_count=0,sub_count=0,last_loop=0;
    int shift_waits=0,multiply_waits=0,hazards=0;
    bit busy=0;
    int wait_left=0;
    logic [31:0] held_addr=0;
    function automatic logic [31:0] memory_word(input logic [31:0] a);
        if(a==32'h4000)return 32'h00000c0e;
        if(a>=32'h4004&&a<32'h8000)return 0;
        case(a)
            32'h1000:return 32'he3a00001;
            32'h1004:return 32'he3a01002;
            32'h1008:return 32'he0802001;
            32'h100c:return 32'he0823082;
            32'h1010:return 32'he3a04001;
            32'h1014:return 32'he0835412;
            32'h1018:return 32'he0060395;
            32'h101c:return 32'he0270496;
            32'h1020:return 32'he0898697;
            32'h1024:return 32'he3580000;
            32'h1028:return 32'h03a0a063;
            32'h102c:return 32'he287a001;
            32'h1030:return 32'he08ab009;
            32'h1034:return 32'hea000001;
            32'h1038,32'h103c:return 32'he3a0bb01;
            32'h1040:return 32'he3a0c004;
            32'h1044:return 32'he25cc001;
            32'h1048:return 32'h1afffffd;
            32'h104c:return 32'he3a00a02;
            32'h1050:return 32'he2800001;
            32'h1054:return 32'he12fff10;
            32'h2000:return 32'h21032002;
            32'h2004:return 32'h00431842;
            32'h2008:return 32'h435a1c54;
            32'h200c:return 32'hd1002a14;
            32'h2010:return 32'he7fe46c0;
            default:return 32'he1a00000;
        endcase
    endfunction
    task automatic check(input bit ok,input string message);
        checks++;assert(ok)else $fatal(1,"%s cycle=%0d retired=%0d pc=%h ins=%h value=%h",message,cycles,retired,o_retire_pc,o_retire_instruction,o_retire_value);
    endtask
    task automatic observe;
        logic [31:0] want;
        bit compare;
        if(o_shift_wait)shift_waits++;
        if(o_multiply_wait)multiply_waits++;
        if(dut.d_hazard)hazards++;
        if(o_valid)check(!o_fault&&!o_pc_write&&!o_memory,"component program stays within executed arithmetic/branch classes");
        if(o_retire_valid)begin
            retired++;compare=1;want=0;
            case(o_retire_pc)
                32'h1000:want=1;32'h1004:want=2;32'h1008:want=3;32'h100c:want=9;
                32'h1010:want=1;32'h1014:want=15;32'h1018:want=135;
                32'h101c:want=136;32'h1020:want=18360;32'h1024:want=18360;
                32'h1028:compare=0;32'h102c:want=137;32'h1030:want=137;
                32'h1034:compare=0;32'h1040:want=4;
                32'h1044:begin sub_count++;want=32'(4-sub_count);end
                32'h1048:compare=0;32'h104c:want=32'h2000;32'h1050:want=32'h2001;32'h1054:compare=0;
                32'h2000:want=2;32'h2002:want=3;32'h2004:want=5;32'h2006:want=4;
                32'h2008:want=6;32'h200a:want=20;32'h200c:want=0;32'h200e:compare=0;32'h2010:compare=0;
                32'h2012:begin
                    compare=0;loop_count++;
                    if(loop_count>40&&loop_count<70)check(cycles-last_loop==1,"trained branch sustains one record/clock through S/A and producer registers");
                    last_loop=cycles;
                end
                default:check(0,"no wrong-path record reaches arithmetic W harness");
            endcase
            if(compare)check(o_retire_value==want,"joined ARM/Thumb arithmetic result");
        end
    endtask
    task automatic tick;
        bus_ack=0;
        if(i_reset)busy=0;
        else if(bus_stb)begin
            check(!bus_we,"I-cache bus reads");
            if(!busy)begin busy=1;held_addr=bus_addr;wait_left=LATENCY;end
            check(bus_addr==held_addr,"bus request held through wait");
            if(wait_left==0)begin bus_ack=1;bus_data=memory_word(held_addr);busy=0;end
            else wait_left--;
        end else check(!busy,"outstanding cache bus request retained");
        #1;observe();i_clk=1;#1;i_clk=0;bus_ack=0;#1;cycles++;
    endtask
    initial begin
        i_clk=0;i_reset=1;i_flush=0;i_ready=1;i_cpsr=32'h13;i_backend_target=0;i_backend_thumb=0;
        i_predictor_clear=0;i_locked=0;tick();i_reset=0;
        while(loop_count<70&&cycles<20000)begin
            // Backpressure while the linear/dependent program runs. Keep the
            // final cadence window free of artificial downstream stalls.
            i_ready=loop_count>10||(cycles%11<8);tick();
        end
        check(loop_count==70&&sub_count==4,"program and conditional loop complete");
        check(shift_waits>=1&&multiply_waits>=1&&hazards>=1,"shift/multiply/source interlock exercised");
        i_ready=0;repeat(25)tick();check(o_stall,"bounded downstream hold reaches fetch queue");
        i_ready=1;repeat(40)tick();check(loop_count>90,"held predicted loop restarts without lost/duplicate records");
        $display("PASS S/A/cache latency=%0d: %0d checks, %0d clocks, %0d records, shift=%0d mac=%0d hazard=%0d",LATENCY,checks,cycles,retired,shift_waits,multiply_waits,hazards);$finish;
    end
endmodule
