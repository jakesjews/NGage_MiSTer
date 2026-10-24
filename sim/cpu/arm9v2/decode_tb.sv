// SPDX-License-Identifier: GPL-3.0-or-later
module decode_tb;
    logic i_clk, i_reset, i_flush;
    logic i_valid;
    logic o_ready;
    logic [31:0] i_pc, i_word;
    logic i_thumb, i_fault;
    logic [4:0] i_mode;
    logic i_predicted, i_pred_hit;
    logic [31:0] i_pred_target;
    logic [1:0] i_pred_state, i_pred_kind;
    logic [2:0] i_ras_pointer;
    logic [3:0] i_ras_count;
    logic i_wen;
    logic [39:0] i_wr_addr_a, i_wr_addr_b, i_wr_addr_c, i_locked;
    logic [3:0][5:0] i_early_tag;
    logic [3:0] i_early_valid;
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
    arm9v2_decode dut (.*);
    wire unused = &{1'b0,o_ready,o_valid,o_pc,o_instruction,o_pc_base,o_next_pc,o_raw,o_mode,o_thumb,o_fault,o_force_align,o_reg_shift,o_kind,o_condition,o_tag,o_used,o_value,o_dest,o_first,o_last,o_reg_count,o_offset,o_writeback_offset,o_transfer_reg,o_branch_target,o_direct,o_match_taken,o_match_fallthrough,o_predicted,o_pred_hit,o_pred_target,o_pred_state,o_pred_kind,o_ras_pointer,o_ras_count,o_hazard,o_redirect,o_redirect_thumb,o_redirect_target,o_redirect_link,o_redirect_pointer,o_redirect_count,o_redirect_action};
    int checks=0,cycles=0,redirects=0;
    logic [31:0] last_target=0;
    logic last_thumb=0;
    logic [1:0] last_action=0;
    // Events may precede their S record. Observe every registered pulse rather
    // than requiring a pulse at a particular receive() call.

    task automatic tick;
        #1;i_clk=1;#1;i_clk=0;#1;cycles++;
        if(o_redirect&&!i_reset)begin
            redirects++;last_target=o_redirect_target;
            last_thumb=o_redirect_thumb;last_action=o_redirect_action;
        end
    endtask
    task automatic check(input bit ok,input string message);
        checks++;assert(ok)else $fatal(1,"%s cycle=%0d pc=%h ins=%h kind=%0d",message,cycles,o_pc,o_instruction,o_kind);
    endtask
    function automatic logic [31:0] rf(input int r);return 32'hc0de0000|32'(r);endfunction
    function automatic int ref_bank(input int r,input int mode);
        if(mode==17&&r>=8&&r<=14)return r+10;
        if(r==13||r==14)case(mode)18:return r+12;19:return r+14;27:return r+16;23:return r+18;default:;endcase
        return r;
    endfunction
    task automatic seed_rf;
        i_wen=1;
        for(int r=0;r<40;r++)begin i_wr_addr_a=40'd1<<r;i_wr_data_a=rf(r);tick();end
        i_wen=0;i_wr_addr_a=0;
    endtask
    task automatic send(input logic [31:0] ins,input logic [31:0] pc=32'h1000,input bit thumb=0);
        int limit;limit=0;
        while(!o_ready&&limit<30)begin tick();limit++;end
        check(o_ready,"D1 capacity");i_valid=1;i_word=ins;i_pc=pc;i_thumb=thumb;tick();i_valid=0;
    endtask
    task automatic receive;
        int limit;limit=0;
        while(!o_valid&&limit<30)begin tick();limit++;end
        check(o_valid,"D2/S output progress");
    endtask
    task automatic single(input logic [31:0] ins,input logic [3:0] kind);
        int before_redirects;
        before_redirects=redirects;
        send(ins);receive();check(o_kind==kind&&o_instruction==ins,"ARM class and raw instruction");
        check(o_pc==32'h1000&&o_pc_base==32'h1008&&o_next_pc==32'h1004,"registered PC metadata");
        check(o_first&&o_last&&!o_thumb&&o_fault==i_fault,"ordinary single record");
        check(redirects==before_redirects+int'(o_direct&&(!i_predicted||!o_match_taken)),
              "exactly one redirect for a direct miss, none for a hit or nonbranch");
    endtask
    task automatic block_test(input logic [15:0] list,input bit p,u,l,s,input int mode,input int base=4);
        int n,seen,expected_offset,last_cycle,bank_mode,accepted;
        logic [31:0] ins;
        n=0;for(int r=0;r<16;r++)if(list[r])n++;
        ins=32'he8000000|(32'(p)<<24)|(32'(u)<<23)|(32'(s)<<22)|32'h00200000|(32'(l)<<20)|(32'(base)<<16)|{16'd0,list};
        i_mode=5'(mode);send(ins);accepted=cycles;receive();seen=0;last_cycle=cycles;
        check(cycles==accepted+2,"D1 acceptance to first S entry is two edges");
        expected_offset=u?(p?4:0):(-4*n+(p?0:4));
        bank_mode=s&&!(l&&list[15])?16:mode;
        for(int r=0;r<16;r++)if(list[r])begin
            check(o_valid&&o_kind==6&&o_instruction==ins,"streamed block record");
            check(o_transfer_reg==4'(r)&&o_reg_count==5'(n),"block list order/count");
            check(int'($signed(o_offset))==expected_offset+4*seen,"eight-bit block offset");
            check(int'($signed(o_writeback_offset))==(u?4*n:-4*n),"block writeback offset");
            check(o_first==(seen==0)&&o_last==(seen==n-1),"block boundaries");
            check(o_tag[0]==6'(ref_bank(base,mode))&&o_dest[1]==6'(ref_bank(base,mode)),"base bank preserved");
            check(o_tag[3]==6'(ref_bank(r,bank_mode))&&o_dest[0]==o_tag[3],"transfer bank/index");
            check(o_value[3]==rf(ref_bank(r,bank_mode)),"raw RF value for current transfer");
            check(o_used[0]==(seen==0)&&o_used[3]==!l,"block source usage");
            check(o_used[2]==(l&&s&&r==15),"only final LDM PC with S reads SPSR");
            if(seen!=0)check(cycles==last_cycle+1,"one block register per clock");
            last_cycle=cycles;seen++;tick();
        end
        check(!o_valid,"block drains without extra register record");
        check(last_cycle==accepted+n+1,"block has no fixed setup or drain between transfers");
    endtask
    initial begin
        i_clk=0;i_reset=0;i_flush=0;i_valid=0;i_pc=0;i_word=0;i_thumb=0;i_fault=0;i_mode=0;i_predicted=0;i_pred_hit=0;i_pred_target=0;i_pred_state=0;i_pred_kind=0;i_ras_pointer=0;i_ras_count=0;i_wen=0;i_wr_addr_a=0;i_wr_addr_b=0;i_wr_addr_c=0;i_locked=0;i_early_valid=0;i_early_tag=0;i_wr_data_a=0;i_wr_data_b=0;i_wr_data_c=0;i_ready=0;
        i_reset=1;i_ready=1;i_mode=5'h13;tick();i_reset=0;seed_rf();
        single(32'he0812003,0);check(o_used==3&&o_tag[0]==1&&o_tag[1]==3&&o_dest[0]==2,"ADD indices");
        check(o_value[0]==rf(1)&&o_value[1]==rf(3),"raw operands at S boundary");tick();
        single(32'he1a02413,0);check(o_reg_shift&&o_used==6&&o_tag[2]==4,"register shift index");tick();
        single(32'he10f2000,1);check(o_tag[2]==17&&o_used==4,"MRS CPSR");tick();
        single(32'he14f3000,1);check(o_tag[2]==37,"MRS banked SPSR");tick();
        single(32'he591200c,5);check(o_used==1&&o_dest[0]==2,"immediate load indices");tick();
        single(32'he581200c,5);check(o_used==9&&o_tag[3]==2,"store data index");tick();
        single(32'he1d120b2,5);check(o_used==1,"halfword immediate index");tick();
        single(32'he1012093,12);check(o_used==3&&o_dest[0]==2,"SWP indices");tick();
        single(32'he0020391,13);check(o_tag[1]==1&&o_tag[2]==3&&o_dest[0]==2,"multiply indices");tick();
        single(32'he0832190,14);check(o_dest[0]==2&&o_dest[1]==3,"long multiply destinations");tick();
        single(32'he12fff1e,4);check(o_tag[1]==28&&!o_redirect,"BX reads SVC LR and remains late");tick();
        i_mode=5'h10;single(32'hee070f10,8);tick();i_mode=5'h13;
        single(32'hf1a00000,8);check(o_condition==14,"ARMv4 NV undefined is unconditional");tick();
        single(32'he8900000,8);tick();
        // Same-edge writes use the register file's C > B > A priority.
        send(32'he0812003);tick();i_wen=1;i_wr_addr_a=2;i_wr_addr_b=2;i_wr_addr_c=2;
        i_wr_data_a=32'haaaa;i_wr_data_b=32'hbbbb;i_wr_data_c=32'hcccc;tick();
        check(o_valid&&o_value[0]==32'hcccc,"RF same-edge write-through priority");
        i_wen=0;i_wr_addr_a=0;i_wr_addr_b=0;i_wr_addr_c=0;tick();seed_rf();
        // A locked source stalls D2, not a forwarding network or the output.
        i_locked=2;send(32'he0812003);repeat(4)tick();
        check(o_hazard&&!o_valid,"D2 load-use scoreboard stall");i_locked=0;tick();
        check(o_valid&&o_value[0]==rf(1),"registered lock release admits D2");tick();
        i_locked=1;single(32'he1a02003,0);check(!o_hazard,"unused Rn does not stall MOV");i_locked=0;tick();
        // S-only locks hold shifted operands in D2, while plain ALU inputs
        // may enter S and carry a late token into A.
        i_early_valid=1;i_early_tag[0]=1;single(32'he1a02001,0);check(!o_hazard,"unshifted Rm permits late A pickup");tick();
        send(32'he1a02081);repeat(4)tick();
        check(o_hazard&&!o_valid,"shifted Rm waits in D2 for registered producer");
        i_early_valid=0;i_early_tag=0;tick();check(o_valid,"early source unlock admits S");tick();
        i_early_valid=1;i_early_tag[0]=4;send(32'he1a02413);repeat(4)tick();
        check(o_hazard&&!o_valid,"register shift amount waits in D2");
        i_early_valid=0;i_early_tag=0;tick();check(o_valid&&o_reg_shift,"register shift unlock");tick();
        // Direct targets and both equality results are registered with S data.
        single(32'hea000002,3);check(o_direct&&last_target==32'h1010,"unpredicted direct branch");
        check(last_action==0&&!o_match_taken,"B repairs without RAS push");tick();
        single(32'heafffffc,3);check(last_target==32'hff8,"negative branch offset");tick();
        i_predicted=1;i_pred_hit=1;i_pred_target=32'h1010;
        single(32'heb000002,3);check(o_direct&&!o_redirect&&o_match_taken&&!o_match_fallthrough,"correct BL prediction");tick();
        i_pred_target=32'h1004;i_ras_pointer=3;i_ras_count=4;
        single(32'heb000002,3);check(o_redirect&&o_redirect_action==1&&o_redirect_link==32'h1004,"wrong BL prediction repair");
        check(o_match_fallthrough&&o_redirect_pointer==3&&o_redirect_count==4,"comparison and checkpoint alignment");tick();
        i_predicted=0;i_pred_hit=0;i_pred_target=0;
        single(32'h0a000002,3);check(!o_direct&&!o_redirect&&o_condition==0,"conditional branch waits for A flags");tick();
        i_fault=1;single(32'hea000002,3);check(!o_redirect,"fault suppresses speculative direct redirect");i_fault=0;tick();
        i_fault=1;i_locked='1;single(32'he8b4ffff,6);
        check(o_fault&&o_last&&o_used==0&&!o_hazard,"faulted block is one operand-free exception record");
        i_fault=0;i_locked=0;tick();check(!o_valid,"faulted block does not expand");
        // Thumb word lanes, raw expansion and paired/unpaired BL halves.
        send(32'h2001ffff,32'h1002,1);receive();check(o_instruction==32'he3b00001&&o_raw==16'h2001,"Thumb upper halfword expansion");tick();
        send(32'h0000e7fe,32'h2000,1);receive();check(last_target==32'h2000&&last_thumb,"Thumb direct branch target");tick();
        send(32'h0000f001,32'h2000,1);send(32'hf8020000,32'h2002,1);receive();
        check(o_kind==10&&o_branch_target==32'h3004,"Thumb prefix target register");tick();
        check(o_valid&&o_kind==11&&o_direct&&o_redirect_target==32'h3008&&o_redirect_link==32'h2005,"paired suffix bypasses registered prefix sum");tick();
        send(32'hf8020000,32'h4002,1);receive();check(o_kind==11&&!o_direct&&o_used[0]&&o_tag[0]==28,"standalone suffix reads SVC LR later");tick();
        send(32'h0000d0fd,32'h6000,1);receive();
        check(o_kind==3&&o_condition==0&&!o_direct&&o_branch_target==32'h5ffe,"Thumb conditional negative target remains late");tick();
        i_predicted=1;i_pred_target=32'h6000;
        send(32'h0000e7fe,32'h6000,1);receive();
        check(o_redirect&&!o_match_taken&&o_redirect_thumb,"same address with wrong predicted state must repair");tick();
        i_predicted=0;i_pred_target=0;
        send(32'h0000f7ff,32'h7000,1);send(32'hffff0000,32'h7002,1);receive();
        check(o_kind==10&&o_branch_target==32'h6004,"negative Thumb prefix displacement");tick();
        check(o_valid&&o_kind==11&&o_direct&&o_redirect_target==32'h7002,"maximum paired Thumb suffix displacement");tick();
        send(32'h0000de01,32'h4000,1);receive();check(o_kind==8&&o_condition==14,"Thumb reserved condition undefined");tick();
        // Thumb list extraction runs beside expansion: implicit LR/PC and
        // PUSH/POP stack offsets must match the expanded ARM transfer.
        send(32'h0000b503,32'h5000,1);receive();
        check(o_kind==6&&o_reg_count==3&&o_transfer_reg==0&&o_offset==-8'sd12&&o_tag[0]==27,"Thumb PUSH count/base/first");tick();
        check(o_valid&&o_transfer_reg==1&&o_offset==-8'sd8,"Thumb PUSH next");tick();
        check(o_valid&&o_transfer_reg==14&&o_tag[3]==28&&o_last&&o_offset==-8'sd4,"Thumb PUSH implicit banked LR");tick();
        send(32'hbd030000,32'h5002,1);receive();
        check(o_kind==6&&o_reg_count==3&&o_transfer_reg==0&&o_offset==0,"Thumb POP count/first");tick();
        check(o_valid&&o_transfer_reg==1&&o_offset==4,"Thumb POP next");tick();
        check(o_valid&&o_transfer_reg==15&&o_last&&o_offset==8&&!o_direct&&!o_redirect,"Thumb POP PC remains a late return");tick();
        // The early redirect cannot consume its branch while S is occupied.
        i_ready=0;single(32'he1a00000,0);
        begin
            int events;events=redirects;
            send(32'hea000000,32'h9000);
            check(o_redirect&&o_redirect_target==32'h9008,"empty-D1 branch redirects at D2 entrance");
            repeat(5)tick();
            check(o_valid&&o_pc==32'h1000&&redirects==events+1,"early branch owner retained behind held S");
            i_ready=1;tick();
            check(o_valid&&o_pc==32'h9000&&o_direct,"early branch reaches S exactly once after hold");
            tick();check(!o_valid&&redirects==events+1,"no duplicate redirect or branch record");
        end
        // An older wrong-target prediction beats a younger unpredicted branch
        // accepted at the same edge. The younger record must be killed.
        begin
            int events;events=redirects;
            i_predicted=1;i_pred_target=32'hdead0000;
            send(32'hea000000,32'ha000);
            i_predicted=0;i_pred_target=0;
            send(32'hea000000,32'hb000);
            check(o_redirect&&o_redirect_target==32'ha008&&o_pc==32'ha000,
                  "older late redirect wins simultaneous younger early redirect");
            tick();repeat(3)tick();
            check(!o_valid&&redirects==events+1,"wrong-path early branch killed");
        end
        // An older exception flush supersedes an early direct redirect and
        // its held owner, without admitting any target record.
        i_ready=0;single(32'he1a00000,0);send(32'hea000000,32'hc000);
        i_flush=1;tick();i_flush=0;i_ready=1;repeat(3)tick();
        check(!o_valid&&!o_redirect,"older flush cancels held early redirect owner");
        // The shortcut's three-operand PC sum must wrap at 32 bits, with
        // signed offsets and either Thumb word lane. Reference ordinary +.
        begin
            logic [31:0] state,pc,ins,expected;
            logic [15:0] half_ins;
            int events;
            state=32'h8f13627d;
            for(int n=0;n<4096;n++)begin
                state=state^(state<<13);state=state^(state>>17);state=state^(state<<5);
                pc=(n<4 ? 32'hfffffff0+32'(n*4) : state)&32'hfffffffc;
                ins=32'hea000000|{8'd0,state[23:0]};
                expected=pc+32'd8+{{6{ins[23]}},ins[23:0],2'b0};
                events=redirects;send(ins,pc);receive();
                check(o_branch_target==expected&&last_target==expected&&redirects==events+1,
                      "ARM shortcut signed sum and wrap");tick();
                half_ins={5'b11100,state[10:0]};pc=pc|{30'd0,state[11],1'b0};
                expected=pc+32'd4+{{20{half_ins[10]}},half_ins[10:0],1'b0};
                events=redirects;send(pc[1]?{half_ins,16'h46c0}:{16'h46c0,half_ins},pc,1);receive();
                check(o_branch_target==expected&&last_target==expected&&last_thumb&&redirects==events+1,
                      "Thumb shortcut signed sum, lane and wrap");tick();
            end
        end
        // Full-mask/sparse lists across addressing modes and bank selections.
        for(int mode_n=0;mode_n<7;mode_n++)begin
            int mode;case(mode_n)0:mode=16;1:mode=17;2:mode=18;3:mode=19;4:mode=23;5:mode=27;default:mode=31;endcase
            for(int a=0;a<4;a++)begin
                block_test(16'hffff,1'(a&1),1'((a>>1)&1),0,0,mode,13);
                block_test(16'h8103,1'(a&1),1'((a>>1)&1),1,1,mode,13);
                block_test(16'h4103,1'(a&1),1'((a>>1)&1),0,1,mode,13);
            end
        end
        // Every nonempty mask: count/first/next scan; rotate IA/IB/DA/DB.
        for(int mask=1;mask<65536;mask++)block_test(16'(mask),1'(mask&1),1'((mask>>1)&1),1'((mask>>2)&1),0,19);
        // Every pending lane can block a shifted source. An invalid or
        // different destination must not block it; a held S payload must
        // remain intact while the pending hazard changes behind it.
        for(int lane=0;lane<4;lane++)begin
            i_early_tag=0;i_early_tag[lane]=3;i_early_valid=0;
            single(32'he1a02083,0);check(!o_hazard,"invalid pending lane permits shifted Rm");tick();
            i_early_valid=4'(1<<lane);i_early_tag[lane]=4;
            single(32'he1a02083,0);check(!o_hazard,"different pending tag permits shifted Rm");tick();
            i_early_tag[lane]=3;send(32'he1a02083);tick();
            repeat(3)begin tick();check(o_hazard&&!o_valid,"each pending lane holds shifted Rm");end
            i_early_valid=0;tick();check(o_valid&&o_instruction==32'he1a02083,"pending lane release admits once");tick();
        end
        i_early_tag=0;
        // Registered output and two D1 slots absorb a downstream hold.
        i_mode=5'h13;i_ready=0;
        for(int n=0;n<4;n++)send(32'he1a00000,32'h8000+32'(n*4));
        repeat(4)tick();check(!o_ready&&o_valid&&o_pc==32'h8000,"bounded decode capacity");
        begin
            logic [31:0] ins;
            logic [3:0][31:0] values;
            logic [3:0][5:0] tags;
            ins=o_instruction;values=o_value;tags=o_tag;
            repeat(5)begin
                i_early_valid=4'b1111;i_early_tag={6'd3,6'd2,6'd1,6'd0};
                tick();check(o_valid&&o_pc==32'h8000&&o_instruction==ins&&o_value==values&&o_tag==tags,
                             "S payload stable while held and pending tags change");
            end
            i_early_valid=0;i_early_tag=0;
        end
        i_ready=1;
        for(int n=0;n<4;n++)begin receive();check(o_pc==32'h8000+32'(n*4),"decode hold preserves order");tick();end
        i_ready=0;send(32'hea000000,32'h9000);repeat(2)tick();i_flush=1;tick();i_flush=0;#1;
        check(!o_valid&&!o_redirect&&o_ready,"older flush cancels records and local redirect");
        $display("PASS decode: %0d checks, %0d cycles",checks,cycles);$finish;
    end
endmodule
