// SPDX-License-Identifier: GPL-3.0-or-later
module decode_cache_tb;
    parameter integer LATENCY=0;
    logic i_clk, i_reset, i_flush;
    logic o_ready;
    logic [4:0] i_mode;
    logic i_wen;
    logic [39:0] i_wr_addr_a, i_wr_addr_b, i_wr_addr_c, i_locked;
    logic [31:0] i_wr_data_a, i_wr_data_b, i_wr_data_c;
    logic i_ready;
    logic o_valid;
    logic [31:0] o_pc, o_instruction, o_pc_base, o_next_pc;
    logic [15:0] o_raw;
    logic [4:0] o_mode;
    logic o_thumb, o_fault, o_force_align, o_reg_shift;
    logic [3:0] o_kind, o_condition;
    logic [3:0][5:0] o_tag;
    logic [3:0] o_used;
    logic [3:0][31:0] o_value;
    logic [1:0][5:0] o_dest;
    logic o_first, o_last;
    logic [4:0] o_reg_count;
    logic signed [7:0] o_offset, o_writeback_offset;
    logic [3:0] o_transfer_reg;
    logic [31:0] o_branch_target;
    logic o_direct, o_match_taken, o_match_fallthrough;
    logic o_predicted, o_pred_hit;
    logic [31:0] o_pred_target;
    logic [1:0] o_pred_state, o_pred_kind;
    logic [2:0] o_ras_pointer;
    logic [3:0] o_ras_count;
    logic o_hazard;
    logic o_redirect, o_redirect_thumb;
    logic [31:0] o_redirect_target, o_redirect_link;
    logic [2:0] o_redirect_pointer;
    logic [3:0] o_redirect_count;
    logic [1:0] o_redirect_action;
    logic [31:0] i_backend_target, i_backend_link;
    logic i_backend_thumb;
    logic [2:0] i_backend_pointer;
    logic [3:0] i_backend_count;
    logic [1:0] i_backend_action;
    logic i_predictor_clear, i_update;
    logic [31:0] i_update_pc, i_update_target;
    logic i_update_thumb, i_update_taken, i_update_hit;
    logic [1:0] i_update_state, i_update_kind;
    logic [31:0] i_data;
    logic i_ack, i_error, i_retry, i_fill_pending, i_fill_done, i_fill_fault;
    logic [31:0] o_address_nxt, o_address_check, o_address;
    logic o_request, o_stall;
    arm9v2_front_decode #(.RESET_VECTOR(32'h1000)) dut (.*);
    wire unused=&{1'b0,o_ready,o_valid,o_pc,o_instruction,o_pc_base,o_next_pc,o_raw,o_mode,o_thumb,o_fault,o_force_align,o_reg_shift,o_kind,o_condition,o_tag,o_used,o_value,o_dest,o_first,o_last,o_reg_count,o_offset,o_writeback_offset,o_transfer_reg,o_branch_target,o_direct,o_match_taken,o_match_fallthrough,o_predicted,o_pred_hit,o_pred_target,o_pred_state,o_pred_kind,o_ras_pointer,o_ras_count,o_hazard,o_redirect,o_redirect_thumb,o_redirect_target,o_redirect_link,o_redirect_pointer,o_redirect_count,o_redirect_action,o_address_nxt,o_address_check,o_address,o_request,o_stall};
    logic mmu=1;
    wire bus_stb,bus_we;
    wire [31:0] bus_addr;
    logic bus_ack=0;
    logic [31:0] bus_data=0;
    int cycles=0,checks=0,beats=0,redirects=0;
    logic [31:0] last_target=0;
    zap_cache #(.SHORT_READ(1'b1),.CACHE_SIZE(16384),.WAYS(2),.CACHE_LINE(16)) cache (
        .i_clk(i_clk),.i_reset(i_reset),.i_stall(o_stall),.i_address_check(o_address_check),
        .i_wr_check(1'b0),.i_rd_check(1'b1),.i_address(o_address),.i_address_nxt(o_address_nxt),
        .i_rd(o_request),.i_wr(1'b0),.i_ben(4'hf),.i_dat(32'd0),.o_dat(i_data),
        .o_ack(i_ack),.o_err(i_error),.o_err2(i_retry),.o_fill_pending(i_fill_pending),
        .o_fill_done(i_fill_done),.o_fill_fault(i_fill_fault),.i_mmu_en(mmu),.i_cache_en(1'b1),
        .i_cache_inv_req(1'b0),.i_cache_clean_req(1'b0),.i_cpsr(5'b10011),
        .i_sr(2'd0),.i_baddr(32'h4000),.i_dac_reg(32'd1),.i_tlb_inv(1'b0),
        .i_wb_busy(1'b0),.i_pf_inv(1'b0),.o_wb_stb(bus_stb),.o_wb_wen(bus_we),
        .o_wb_adr(bus_addr),.i_wb_dat(bus_data),.i_wb_ack(bus_ack),.i_wb_err(1'b0)
    );
    bit busy=0;
    int wait_left=0;
    logic [31:0] held_addr=0;
    task automatic check(input bit ok,input string message);
        checks++;assert(ok)else $fatal(1,"%s cycle=%0d pc=%h ins=%h",message,cycles,o_pc,o_instruction);
    endtask
    function automatic logic [31:0] memory_word(input logic [31:0] a);
        if(a==32'h4000)return 32'h00000c0e;
        if(a>=32'h4004&&a<32'h8000)return 0;
        if(a>=32'h2000&&a<32'h2100)return 32'h21022001;
        case(a)
            32'h1000:return 32'hea00001e;
            32'h1080:return 32'hea00000e;
            32'h10c0:return 32'heaffffce;
            32'h3000:return 32'he8b4010a;
            32'h3004:return 32'he92d4003;
            // Upper-halfword Thumb direct branches, untrained hot loop.
            32'hb000:return 32'he03e46c0;
            32'hb080:return 32'he01e46c0;
            32'hb0c0:return 32'he79e46c0;
            default:return 32'he1a00000;
        endcase
    endfunction
    function automatic logic [31:0] loop_next(input logic [31:0] pc);
        return pc==32'h1000 ? 32'h1080 : pc==32'h1080 ? 32'h10c0 : 32'h1000;
    endfunction
    task automatic tick;
        bus_ack=0;
        if(i_reset)busy=0;
        else if(bus_stb)begin
            check(!bus_we,"instruction bus must read");
            if(!busy)begin busy=1;held_addr=bus_addr;wait_left=LATENCY;end
            check(bus_addr==held_addr,"bus address stable before ACK");
            if(wait_left==0)begin bus_ack=1;bus_data=memory_word(held_addr);busy=0;beats++;end
            else wait_left--;
        end else check(!busy,"outstanding bus request retained");
        #1;i_clk=1;#1;i_clk=0;bus_ack=0;#1;cycles++;
        if(o_redirect&&!i_reset)begin redirects++;last_target=o_redirect_target;end
    endtask
    task automatic go(input logic [31:0] pc,input bit thumb=0);
        i_flush=1;i_backend_target=pc;i_backend_thumb=thumb;tick();i_flush=0;
    endtask
    task automatic receive;
        int limit;limit=0;
        while(!o_valid&&limit<5000)begin tick();limit++;end
        check(o_valid,"decode makes progress through cache");
    endtask
    task automatic train(input logic [31:0] pc,target);
        i_update=1;i_update_pc=pc;i_update_target=target;tick();i_update=0;
    endtask
    initial begin
        int last_cycle,unpredicted_spacing,limit;
        logic [31:0] want;
        i_clk=0;i_reset=0;i_flush=0;i_mode=0;i_wen=0;i_wr_addr_a=0;i_wr_addr_b=0;i_wr_addr_c=0;i_locked=0;i_wr_data_a=0;i_wr_data_b=0;i_wr_data_c=0;i_ready=0;i_backend_target=0;i_backend_link=0;i_backend_thumb=0;i_backend_pointer=0;i_backend_count=0;i_backend_action=0;i_predictor_clear=0;i_update=0;i_update_pc=0;i_update_target=0;i_update_thumb=0;i_update_taken=0;i_update_hit=0;i_update_state=0;i_update_kind=0;
        i_reset=1;i_mode=5'h13;i_ready=1;i_update_taken=1;i_update_state=1;i_backend_action=3;
        tick();i_reset=0;want=32'h1000;last_cycle=0;unpredicted_spacing=0;
        for(int n=0;n<15;n++)begin
            receive();check(o_pc==want&&o_kind==3&&o_direct&&!o_fault,"unpredicted direct loop sequence");
            check(redirects==n+1&&last_target==loop_next(want)&&o_branch_target==loop_next(want),"registered D2 redirect payload");
            if(n==8)unpredicted_spacing=cycles-last_cycle;
            if(n>8)check(cycles-last_cycle==unpredicted_spacing,"constant hot unpredicted spacing");
            last_cycle=cycles;want=loop_next(want);tick();
        end
        check(unpredicted_spacing==4,"measured unpredicted refill with registered queue and redirect");
        train(32'h1000,32'h1080);train(32'h1080,32'h10c0);train(32'h10c0,32'h1000);
        go(32'h1000);want=32'h1000;last_cycle=0;
        for(int n=0;n<100;n++)begin
            receive();check(o_pc==want&&o_predicted&&o_match_taken&&!o_redirect&&!o_fault,"predicted direct loop sequence");
            check(o_instruction==memory_word(want),"instruction and prediction metadata stay aligned");
            if(n>3)check(cycles==last_cycle+1,"one predicted branch per clock through D1/D2");
            last_cycle=cycles;want=loop_next(want);tick();
        end
        i_ready=0;receive();want=o_pc;repeat(30)tick();
        check(o_stall&&o_pc==want,"frontend and decode bounded backpressure");
        i_ready=1;for(int n=0;n<30;n++)begin receive();check(o_pc==want,"held branch stream order");want=loop_next(want);tick();end
        go(32'hb002,1);want=32'hb002;last_cycle=0;
        for(int n=0;n<15;n++)begin
            receive();
            check(o_pc==want&&o_kind==3&&o_direct&&o_thumb&&!o_fault,
                  "untrained upper-halfword Thumb direct loop");
            want=want==32'hb002 ? 32'hb082 : want==32'hb082 ? 32'hb0c2 : 32'hb002;
            check(last_target==want&&o_branch_target==want,"Thumb redirect payload");
            if(n>8)check(cycles-last_cycle==4,"Thumb cold redirect loses three hot slots");
            last_cycle=cycles;tick();
        end
        go(32'h2002,1);want=32'h2002;
        for(int n=0;n<30;n++)begin
            receive();check(o_pc==want&&o_thumb&&o_kind==0&&!o_fault,"real-cache Thumb stream");
            check(o_instruction==(want[1]?32'he3b11002:32'he3b00001),"one Thumb expansion at either word lane");
            want+=2;tick();
        end
        go(32'h3000);receive();
        check(o_kind==6&&o_transfer_reg==1&&o_offset==0&&o_first,"LDM first transfer");
        i_locked=8;tick();receive();
        check(o_pc==32'h3000&&o_transfer_reg==3&&o_offset==4&&!o_hazard,"load destination is not a source hazard");
        tick();receive();check(o_transfer_reg==8&&o_offset==8&&o_last,"LDM final transfer");i_locked=0;tick();
        receive();check(o_pc==32'h3004&&o_transfer_reg==0&&o_offset==-8'sd12,"STM first transfer");
        i_locked=2;tick();repeat(3)begin check(!o_valid&&o_hazard,"dependent store source held in D2");tick();end
        i_locked=0;tick();
        receive();check(o_pc==32'h3004&&o_transfer_reg==1&&o_offset==-8'sd8,"STM second transfer");tick();
        receive();check(o_pc==32'h3004&&o_transfer_reg==14&&o_tag[3]==28&&o_last&&o_offset==-8'sd4,"STM banked LR transfer");tick();
        go(32'h00100000);receive();check(o_pc==32'h00100000&&o_fault&&!o_redirect,"translation fault retains PC and cannot redirect as instruction");
        go(32'h9000);limit=0;while(!bus_stb&&limit<100)begin tick();limit++;end
        check(bus_stb,"cold fetch starts bus request");go(32'ha000);receive();
        check(o_pc==32'ha000&&!o_fault&&o_instruction==32'he1a00000,"older redirect drains held cache transaction");
        $display("PASS decode/cache latency=%0d: %0d checks, %0d cycles; unpredicted spacing=%0d, predicted spacing=1",LATENCY,checks,cycles,unpredicted_spacing);
        $finish;
    end
endmodule
