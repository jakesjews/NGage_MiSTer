// SPDX-License-Identifier: GPL-3.0-or-later
module execute_tb;
    // CUTS: execute's timing cuts (SHIFT_PRE, OP1_PRE, PAYLOAD_FREE,
    // DSP_PRODUCT) off (the original forms) or on (the core's).
    parameter bit CUTS=0;
    logic unused_serial_continue;
    logic i_clk,i_reset,i_flush;
    logic [31:0] i_cpsr;
    logic i_valid,i_admit;
    logic [3:0] i_pending;
    logic manual_producers,i_load_hit;
    logic [1:0] i_load_owner,i_next_load_owner;
    logic [1:0][63:0] i_return_select;
    logic [1:0][31:0] i_return_data;
    logic [63:0] normal_return_select;
    logic [31:0] normal_return_data;
    logic [3:0] normal_s_match;
    logic [5:0] normal_return_tag;
    always_comb begin
        normal_return_tag=0;
        for(int n=0;n<64;n++)if(i_return_select[0][n])normal_return_tag=6'(n);
        for(int src=0;src<4;src++)normal_s_match[src]=normal_return_select[i_tag[src]];
    end
    // Normal completion is registered in the core. Drive its next owner
    // before the edge, then consume its data/matches in the following clock.
    always_ff @(posedge i_clk) begin
        normal_return_select<=i_reset?64'd0:i_return_select[0];
        normal_return_data<=i_return_data[0];
    end
    logic o_ready;
    logic [31:0] i_pc,i_instruction,i_pc_base,i_next_pc;
    logic i_thumb,i_fault,i_force_align,i_reg_shift,i_first,i_last;
    logic [3:0] i_kind,i_condition;
    logic [3:0][5:0] i_tag;
    // Ports added by the timing cuts. i_shift_pre is formed from this
    // record exactly as decode registers it (arm9v2_decode shift_controls,
    // op1_class); execute's own assertions compare it with its formulas.
    wire i_load_trust=1'b1, i_self_dep=1'b0;
    wire o_ready_payload;
    wire [31:0] o_alu_address;
    logic [18:0] i_shift_pre;
    // WRITES_PRE: decode's destination mask for this record (arm9v2_decode
    // decoded.writes, with the block's register list in ins[15:0]).
    logic [1:0] i_writes;
    // TAG_PRE: the PC/PSR classes decode registers beside the tags.
    logic [3:0][1:0] i_tag_class;
    always_comb for(int s=0;s<4;s++)i_tag_class[s]={i_tag[s]==6'd17,i_tag[s]==6'd15};
    always_comb begin
        i_writes=0;
        case(i_kind)
            4'd0:i_writes[0]=i_instruction[24:23]!=2'b10;
            4'd1,4'd10,4'd11,4'd13:i_writes[0]=1;
            4'd14:i_writes=3;
            4'd3:i_writes[0]=i_instruction[24];
            4'd5:i_writes={i_instruction[21]||!i_instruction[24],i_instruction[20]};
            4'd6:i_writes={i_last&&i_instruction[21]&&!(i_instruction[20]&&i_instruction[{1'b0,i_instruction[19:16]}]),i_instruction[20]};
            4'd12:i_writes[0]=1;
            4'd7:i_writes[0]=i_instruction[20]&&i_instruction[15:12]!=15;
            4'd2:i_writes[0]=i_instruction[22];
            default:;
        endcase
        if(i_fault)i_writes=0;
    end
    always_comb begin
        logic [1:0] t; logic [7:0] n; logic g;
        t=i_instruction[6:5]; n={3'd0,i_instruction[11:7]}; g=i_reg_shift;
        if((i_kind==4'd0||i_kind==4'd2)&&i_instruction[25])begin t=3; n={3'd0,i_instruction[11:8],1'b0}; g=1; end
        if(i_kind==4'd5&&i_instruction[27:26]==0)begin t=0; n=0; g=1; end
        if(i_kind!=4'd0&&i_kind!=4'd2&&i_kind!=4'd5)begin t=0; n=0; g=1; end
        i_shift_pre={(i_kind==4'd0||i_kind==4'd2)&&i_instruction[25],i_tag[1]==6'd15,i_tag[1]==6'd17,
                     t,n,(t==0?5'(-n[4:0]):n[4:0]),g};
    end
    logic [3:0] i_used;
    logic [3:0][31:0] i_value;
    logic [1:0][5:0] i_dest;
    logic signed [7:0] i_offset,i_writeback_offset;
    logic [31:0] i_branch_target,i_pred_target;
    logic i_direct,i_predicted,i_match_taken,i_match_fallthrough;
    logic [2:0] i_ras_pointer;
    logic [3:0] i_ras_count;
    logic [1:0][1:0][31:0] i_mw_value;
    logic [1:0][1:0][5:0] i_mw_tag;
    logic [1:0][1:0] i_mw_valid;
    logic i_ready;
    logic o_valid;
    logic [31:0] o_pc,o_instruction,o_cpsr,o_cpsr_next;
    logic [3:0] o_kind;
    logic o_thumb,o_fault,o_first,o_last,o_condition_pass;
    logic [1:0][5:0] o_dest;
    logic [1:0][31:0] o_result;
    logic [1:0] o_write;
    logic o_write_flags,o_pc_write,o_memory,o_store;
    logic [31:0] o_address,o_store_data;
    logic [3:0] o_flags;
    logic o_redirect,o_redirect_thumb;
    logic [31:0] o_redirect_target,o_redirect_link;
    logic [2:0] o_redirect_pointer;
    logic [3:0] o_redirect_count;
    logic [1:0] o_redirect_action;
    logic o_a_valid,o_a_can_finish,o_a_cond_al,o_a_can_finish_nohit;
    logic [1:0] o_s_write;
    logic [1:0][5:0] o_a_dest;
    logic [1:0] o_a_write;
    logic o_shift_wait,o_multiply_wait;
    logic i_pred_hit;
    logic [1:0] i_pred_state;
    logic o_btb_update,o_btb_taken,o_btb_hit;
    logic [31:0] o_btb_target;
    logic [1:0] o_btb_state,o_btb_kind;
    logic o_a_load,o_predicted;
    logic [31:0] o_psr_source,o_saved_psr,o_original_base,o_next_pc,o_prediction_target;
    logic [5:0] o_spsr_tag;
    // Model the real M/W registers outside execute. Observations below are
    // at M, so datapath semantics are checked after the acceptance edge.
    logic [3:0] i_early;
    logic [3:0][1:0][1:0] i_forward_match;
    logic [1:0][3:0][4:0] i_forward_grant;
    logic [1:0][1:0][5:0] i_next_tag,real_tag;
    logic [1:0][1:0] i_next_write,i_next_write_hold,real_write;
    logic [1:0][1:0][31:0] real_value;
    logic [1:0][5:0] w_tag;
    logic [1:0][31:0] w_value;
    logic [1:0] w_write;
    logic o_btb_thumb,o_record_pred_hit,o_record_thumb;
    logic [31:0] o_btb_pc;
    logic [2:0] o_record_pointer;
    logic [3:0] o_record_count;
    logic [1:0] o_record_pred_state;
    logic [$bits(o_valid)-1:0] raw_o_valid;
    logic [$bits(o_pc)-1:0] raw_o_pc;
    logic [$bits(o_instruction)-1:0] raw_o_instruction;
    logic [$bits(o_cpsr)-1:0] raw_o_cpsr;
    logic [$bits(o_cpsr_next)-1:0] raw_o_cpsr_next;
    logic [$bits(o_kind)-1:0] raw_o_kind;
    logic [$bits(o_thumb)-1:0] raw_o_thumb;
    logic [$bits(o_fault)-1:0] raw_o_fault;
    logic [$bits(o_first)-1:0] raw_o_first;
    logic [$bits(o_last)-1:0] raw_o_last;
    logic [$bits(o_condition_pass)-1:0] raw_o_condition_pass;
    logic [$bits(o_dest)-1:0] raw_o_dest;
    logic [$bits(o_result)-1:0] raw_o_result;
    logic [$bits(o_write)-1:0] raw_o_write;
    logic [$bits(o_write_flags)-1:0] raw_o_write_flags;
    logic [$bits(o_pc_write)-1:0] raw_o_pc_write;
    logic [$bits(o_memory)-1:0] raw_o_memory;
    logic [$bits(o_store)-1:0] raw_o_store;
    logic [$bits(o_address)-1:0] raw_o_address;
    logic [$bits(o_store_data)-1:0] raw_o_store_data;
    logic [$bits(o_psr_source)-1:0] raw_o_psr_source;
    logic [$bits(o_saved_psr)-1:0] raw_o_saved_psr;
    logic [$bits(o_original_base)-1:0] raw_o_original_base;
    logic [$bits(o_next_pc)-1:0] raw_o_next_pc;
    logic [$bits(o_prediction_target)-1:0] raw_o_prediction_target;
    logic [$bits(o_spsr_tag)-1:0] raw_o_spsr_tag;
    logic [$bits(o_predicted)-1:0] raw_o_predicted;
    wire ready_m=!o_valid||i_ready;
    assign real_tag=manual_producers?i_mw_tag:{|i_mw_valid?i_mw_tag[0]:w_tag,o_dest};
    assign real_value=manual_producers?i_mw_value:{|i_mw_valid?i_mw_value[0]:w_value,o_result};
    assign real_write=manual_producers?i_mw_valid:{|i_mw_valid?i_mw_valid[0]:w_write,o_write&{2{o_valid}}};
    assign i_next_tag=manual_producers?i_mw_tag:{i_ready?o_dest:real_tag[1],ready_m?raw_o_dest:o_dest};
    assign i_next_write=(i_reset||i_flush)?4'd0:manual_producers?i_mw_valid:
        {i_ready?(o_write&{2{o_valid}}):real_write[1],ready_m?(raw_o_write&{2{raw_o_valid}}):real_write[0]};
    // LATE_HOLD_SPLIT: no W completion here; both entries are the actual values.
    wire [1:0][1:0][1:0] i_next_write_hold_by={2{i_next_write_hold}};
    wire [1:0] i_next_advance_by=2'b00;
    wire i_next_done=1'b0;
    // LATE_HOLD_STATIC: the same with A's record not entering M.
    assign i_next_write_hold=(i_reset||i_flush)?4'd0:manual_producers?i_mw_valid:
        {i_ready?(o_write&{2{o_valid}}):real_write[1],ready_m?2'b00:real_write[0]};
    always_comb begin
        i_early=0;
        if(i_kind==0)begin i_early[1]=i_used[1]&&i_instruction[11:4]!=0;i_early[2]=i_reg_shift;end
        if(i_kind==5)i_early[1]=i_used[1]&&i_instruction[27:26]==1&&i_instruction[11:4]!=0;
        if(i_kind==13||i_kind==14)i_early=6;
        for(int src=0;src<4;src++)for(int prod=0;prod<2;prod++)for(int lane=0;lane<2;lane++)
            i_forward_match[src][prod][lane]=i_used[src]&&real_write[prod][lane]&&i_tag[src]==real_tag[prod][lane];
    end
    always_comb begin
        logic seen;
        i_forward_grant=0;
        for(int hit=0;hit<2;hit++)for(int src=0;src<4;src++)begin
            seen=0;
            for(int rank=0;rank<4;rank++)begin
                i_forward_grant[hit][src][rank]=i_forward_match[src][rank/2][1-rank%2]&&!(rank%2==1&&i_load_owner[rank/2]&&(rank/2==0||hit==0))&&!seen;
                seen|=i_forward_match[src][rank/2][1-rank%2]&&!(rank%2==1&&i_load_owner[rank/2]&&(rank/2==0||hit==0));
            end
            i_forward_grant[hit][src][4]=!seen;
        end
    end
    always_ff @(posedge i_clk)begin
        if(i_reset||i_flush)begin
            w_tag<=0;w_value<=0;w_write<=0;
            o_valid<=0;
            o_pc<=0;
            o_instruction<=0;
            o_cpsr<=0;
            o_cpsr_next<=0;
            o_kind<=0;
            o_thumb<=0;
            o_fault<=0;
            o_first<=0;
            o_last<=0;
            o_condition_pass<=0;
            o_dest<=0;
            o_result<=0;
            o_write<=0;
            o_write_flags<=0;
            o_pc_write<=0;
            o_memory<=0;
            o_store<=0;
            o_address<=0;
            o_store_data<=0;
            o_psr_source<=0;
            o_saved_psr<=0;
            o_original_base<=0;
            o_next_pc<=0;
            o_prediction_target<=0;
            o_spsr_tag<=0;
            o_predicted<=0;
        end else begin
            if(i_ready)begin w_tag<=o_dest;w_value<=o_result;w_write<=o_write&{2{o_valid}};end
            if(ready_m)begin
                o_valid<=raw_o_valid;
                o_pc<=raw_o_pc;
                o_instruction<=raw_o_instruction;
                o_cpsr<=raw_o_cpsr;
                o_cpsr_next<=raw_o_cpsr_next;
                o_kind<=raw_o_kind;
                o_thumb<=raw_o_thumb;
                o_fault<=raw_o_fault;
                o_first<=raw_o_first;
                o_last<=raw_o_last;
                o_condition_pass<=raw_o_condition_pass;
                o_dest<=raw_o_dest;
                o_result<=raw_o_result;
                o_write<=raw_o_write;
                o_write_flags<=raw_o_write_flags;
                o_pc_write<=raw_o_pc_write;
                o_memory<=raw_o_memory;
                o_store<=raw_o_store;
                o_address<=raw_o_address;
                o_store_data<=raw_o_store_data;
                o_psr_source<=raw_o_psr_source;
                o_saved_psr<=raw_o_saved_psr;
                o_original_base<=raw_o_original_base;
                o_next_pc<=raw_o_next_pc;
                o_prediction_target<=raw_o_prediction_target;
                o_spsr_tag<=raw_o_spsr_tag;
                o_predicted<=raw_o_predicted;
            end
        end
    end
    arm9v2_execute #(.SHIFT_PRE(CUTS),.OP1_PRE(CUTS),.PAYLOAD_FREE(CUTS),.DSP_PRODUCT(CUTS)) dut(.i_flags_refresh(1'b0),.o_serial_continue(unused_serial_continue),.i_advance_tag('0),.i_next_advance(1'b0),.i_pending(i_pending),.i_load_owner(i_load_owner),.i_next_load_owner(i_next_load_owner),.i_load_hit(i_load_hit),.i_return_select(i_return_select[1]),.i_return_data({i_return_data[1],normal_return_data}),
        .i_return_next_valid(|i_return_select[0]),.i_return_next_tag(normal_return_tag),
        .i_return_ready(1'b1),.i_return_s_match(normal_s_match),.i_load_wait(1'b0),.i_ready(ready_m),.i_mw_tag(real_tag),.i_mw_value(real_value),.i_mw_valid(real_write),
.o_valid(raw_o_valid),.o_pc(raw_o_pc),.o_instruction(raw_o_instruction),.o_cpsr(raw_o_cpsr),.o_cpsr_next(raw_o_cpsr_next),.o_kind(raw_o_kind),.o_thumb(raw_o_thumb),.o_fault(raw_o_fault),.o_first(raw_o_first),.o_last(raw_o_last),.o_condition_pass(raw_o_condition_pass),.o_dest(raw_o_dest),.o_result(raw_o_result),.o_write(raw_o_write),.o_write_flags(raw_o_write_flags),.o_pc_write(raw_o_pc_write),.o_memory(raw_o_memory),.o_store(raw_o_store),.o_address(raw_o_address),.o_store_data(raw_o_store_data),.o_psr_source(raw_o_psr_source),.o_saved_psr(raw_o_saved_psr),.o_original_base(raw_o_original_base),.o_next_pc(raw_o_next_pc),.o_prediction_target(raw_o_prediction_target),.o_spsr_tag(raw_o_spsr_tag),.o_predicted(raw_o_predicted),.*);
    wire unused=&{1'b0,o_ready_payload,o_alu_address,o_btb_pc,o_btb_thumb,o_record_pointer,o_record_count,o_record_pred_hit,o_record_thumb,o_record_pred_state,i_mw_tag[1],i_mw_value[1],o_a_load,o_predicted,o_psr_source,o_saved_psr,o_original_base,o_next_pc,o_prediction_target,o_spsr_tag,o_btb_update,o_btb_taken,o_btb_hit,o_btb_target,o_btb_state,o_btb_kind,o_a_can_finish,o_a_cond_al,o_a_can_finish_nohit,o_s_write,o_ready,o_valid,o_pc,o_instruction,o_cpsr,o_cpsr_next,o_kind,o_thumb,o_fault,o_first,o_last,o_condition_pass,o_dest,o_result,o_write,o_write_flags,o_pc_write,o_memory,o_store,o_address,o_store_data,o_flags,o_redirect,o_redirect_thumb,o_redirect_target,o_redirect_link,o_redirect_pointer,o_redirect_count,o_redirect_action,o_a_valid,o_a_dest,o_a_write,o_shift_wait,o_multiply_wait};
    int checks=0,cycles=0;
    logic [31:0] random_state=32'h315d97af;
    function automatic logic [31:0] rnd;
        random_state=random_state^(random_state<<13);
        random_state=random_state^(random_state>>17);
        random_state=random_state^(random_state<<5);
        return random_state;
    endfunction
    task automatic tick;
        #1;i_clk=1;#1;i_clk=0;#1;cycles++;
    endtask
    task automatic check(input bit ok,input string message);
        checks++;assert(ok)else $fatal(1,"%s at cycle %0d pc=%h ins=%h result=%h flags=%h",message,cycles,o_pc,o_instruction,o_result,o_flags);
    endtask
    task automatic defaults;
        i_clk='0;
        i_reset='0;
        i_flush='0;
        i_cpsr='0;
        i_valid='0;i_admit=1;
        i_pc='0;
        i_instruction='0;
        i_pc_base='0;
        i_next_pc='0;
        i_thumb='0;
        i_fault='0;
        i_force_align='0;
        i_reg_shift='0;
        i_first='0;
        i_last='0;
        i_kind='0;
        manual_producers=0;i_load_hit=0;i_load_owner=0;i_next_load_owner=0;
        i_condition='0;i_pending=0;i_return_select=0;i_return_data=0;
        i_tag='0;
        i_used='0;
        i_value='0;
        i_dest='0;
        i_offset='0;
        i_writeback_offset='0;
        i_branch_target='0;
        i_pred_target='0;
        i_direct='0;
        i_predicted='0;
        i_match_taken='0;
        i_match_fallthrough='0;
        i_ras_pointer='0;
        i_ras_count='0;
        i_mw_value='0;
        i_mw_tag='0;
        i_mw_valid='0;
        i_ready='0;

        i_pred_hit=0;i_pred_state=0;
        i_ready=1;i_cpsr=32'h13;i_condition=14;i_instruction=32'he0800001;
        i_pc=32'h1000;i_pc_base=32'h1008;i_next_pc=32'h1004;
        i_first=1;i_last=1;i_tag[0]=0;i_tag[1]=1;i_tag[2]=2;i_tag[3]=3;
        i_dest[0]=10;i_dest[1]=11;i_used=3;
    endtask
    task automatic reset_case(input logic [3:0] f=0);
        defaults();i_cpsr={f,28'h13};i_reset=1;tick();i_reset=0;
    endtask
    task automatic send;
        int limit;limit=0;i_valid=1;#1;
        while(!o_ready&&limit<30)begin tick();limit++;end
        check(o_ready,"S progress");tick();i_valid=0;
    endtask
    task automatic receive;
        int limit;limit=0;
        while(!o_valid&&limit<30)begin tick();limit++;end
        check(o_valid,"A output progress");
    endtask
    function automatic bit cond(input logic [3:0] c,f);
        case(c)
            0:return f[2];1:return !f[2];2:return f[1];3:return !f[1];
            4:return f[3];5:return !f[3];6:return f[0];7:return !f[0];
            8:return f[1]&&!f[2];9:return !f[1]||f[2];10:return f[3]==f[0];11:return f[3]!=f[0];
            12:return !f[2]&&f[3]==f[0];13:return f[2]||f[3]!=f[0];14:return 1;default:return 0;
        endcase
    endfunction
    function automatic logic [35:0] arithmetic(input logic [31:0] x,y,input logic [3:0] op,input logic [1:0] f,input logic sc);
        logic signed [63:0] sx,sy,m;
        logic [63:0] ux,uy,u;
        logic [31:0] result;
        logic ar,cy,ov;
        sx={{32{x[31]}},x};sy={{32{y[31]}},y};ux={32'd0,x};uy={32'd0,y};
        m=0;u=0;ar=1;cy=sc;ov=f[0];result=0;
        case(op)
            0,8:begin result=x&y;ar=0;end
            1,9:begin result=x^y;ar=0;end
            2,10:begin m=sx-sy;cy=ux>=uy;end
            3:begin m=sy-sx;cy=uy>=ux;end
            4,11:begin m=sx+sy;u=ux+uy;cy=u>64'hffffffff;end
            5:begin m=sx+sy+64'(f[1]);u=ux+uy+64'(f[1]);cy=u>64'hffffffff;end
            6:begin m=sx-sy-64'(!f[1]);cy=ux>=uy+64'(!f[1]);end
            7:begin m=sy-sx-64'(!f[1]);cy=uy>=ux+64'(!f[1]);end
            12:begin result=x|y;ar=0;end
            13:begin result=y;ar=0;end
            14:begin result=x&~y;ar=0;end
            15:begin result=~y;ar=0;end
            default:;
        endcase
        if(ar)begin result=32'(m);ov=m>64'sd2147483647||m< -64'sd2147483648;end
        return {result[31],result==0,cy,ov,result};
    endfunction
    logic [31:0] ref_shift;
    logic ref_carry;
    arm9_shift shift_reference(.i_value(i_instruction[25]?{24'd0,i_instruction[7:0]}:i_value[1]),
        .i_amount(i_instruction[25]?{3'd0,i_instruction[11:8],1'b0}:i_reg_shift?i_value[2][7:0]:{3'd0,i_instruction[11:7]}),
        .i_type(i_instruction[25]?2'd3:i_instruction[6:5]),.i_register(i_instruction[25]||i_reg_shift),
        .i_carry(i_cpsr[29]),.o_value(ref_shift),.o_carry(ref_carry));
    initial begin
        logic [35:0] expected;
        logic [63:0] product;
        logic signed [63:0] sx,sy;
        logic [3:0] f;
        int start;
        for(int op=0;op<16;op++)for(int flags_n=0;flags_n<16;flags_n++)for(int sample=0;sample<32;sample++)begin
            f=4'(flags_n);reset_case(f);
            i_instruction=32'he010a001|(32'(op)<<21);
            i_value[0]=rnd();i_value[1]=rnd();i_value[2]=rnd();
            if(sample<4)begin i_value[0]=sample==0?0:sample==1?32'h7fffffff:sample==2?32'h80000000:32'hffffffff;i_value[1]=32'(sample);end
            i_instruction[6:5]=2'(sample);i_instruction[11:7]=5'(sample);
            if(sample%4==1)begin i_reg_shift=1;i_used=7;i_instruction[4]=1;i_value[2]=32'(sample*8);end
            if(sample%4==2)begin i_instruction[25]=1;i_instruction[11:0]=12'(rnd());i_used=1;end
            i_condition=4'(sample%16);i_instruction[31:28]=i_condition;
            #1;expected=arithmetic(i_value[0],ref_shift,4'(op),f[1:0],ref_carry);start=cycles;
            send();receive();
            check(cycles-start==2+int'(i_reg_shift),"DP and register-shift occupancy");
            check(o_condition_pass==cond(i_condition,f),"all ARM conditions");
            if(cond(i_condition,f))begin
                check(o_result[0]==expected[31:0],"ALU result");
                check(o_flags==expected[35:32]&&o_write_flags,"ALU NZCV");
                check(o_write==2'(op<8||op>=12),"test operations do not write Rd");
            end else check(o_write==0&&!o_write_flags&&o_flags==f,"failed condition has no writes");
        end
        for(int long_n=0;long_n<2;long_n++)for(int signed_n=0;signed_n<2;signed_n++)
            for(int acc=0;acc<2;acc++)for(int sample=0;sample<256;sample++)begin
                reset_case(4'hb);i_kind=long_n!=0?14:13;
                i_instruction=32'he0100090|(32'(signed_n)<<22)|(32'(acc)<<21);
                i_used=15;i_value[0]=rnd();i_value[1]=rnd();i_value[2]=rnd();i_value[3]=rnd();
                if(sample<4)begin i_value[1]=32'h80000000+32'(sample);i_value[2]=32'hffffffff-32'(sample);end
                sx=(long_n!=0&&signed_n!=0)?{{32{i_value[1][31]}},i_value[1]}:$signed({32'd0,i_value[1]});
                sy=(long_n!=0&&signed_n!=0)?{{32{i_value[2][31]}},i_value[2]}:$signed({32'd0,i_value[2]});
                product=64'(sx*sy);
                if(acc!=0)product+=long_n!=0?{i_value[0],i_value[3]}:{32'd0,i_value[3]};
                start=cycles;send();receive();
                check(cycles-start==3+acc,"multiply private slot occupancy");
                check(o_result[0]==product[31:0],"multiply low word");
                if(long_n!=0)check(o_result[1]==product[63:32],"multiply high word");
                check(o_write==(long_n!=0?3:1),"multiply destination pair");
                f=long_n!=0?{product[63],product==0,2'b11}:{product[31],product[31:0]==0,2'b11};
                check(o_flags==f,"multiply NZ, C/V preserved");
            end
        // Dependent unshifted ALU chain: stale RF operands throughout, yet
        // one completed instruction per clock via registered late pickup.
        reset_case();i_instruction=32'he3a00000;i_used=0;i_dest[0]=0;send();
        for(int n=0;n<32;n++)begin
            i_instruction=32'he2800001;i_used=1;i_tag[0]=0;i_value[0]=0;send();
            check(o_valid&&o_result[0]==32'(n),"one dependent ALU completion per clock");
        end
        tick();check(o_valid&&o_result[0]==32'd32,"dependent chain final result");
        // Independent long multiplies occupy the private A slot for two
        // clocks after the S/A operand capture; older M/W records can drain.
        reset_case();i_kind=14;i_instruction=32'he0800090;i_used=6;i_valid=1;
        for(int n=0;n<32;n++)begin
            i_value[1]=32'h10000+32'(n);i_value[2]=32'hfedcba98-32'(n);#1;
            if(n>0)begin
                check(!o_ready,"multiply private product phase holds S for one clock");tick();
            end
            check(o_ready,"independent multiplier accepts every two clocks");tick();
            if(n>0)begin
                product=(64'h10000+64'(n-1))*(64'hfedcba98-64'(n-1));
                check(o_valid&&o_write==3&&o_result==product,"independent long product stream");
            end
        end
        i_valid=0;tick();tick();product=(64'h10000+31)*(64'hfedcba98-31);
        check(o_valid&&o_result==product,"independent product final record");
        // A private multiply may advance behind a blocked output, but it
        // must retain its completed product and flags until capacity returns.
        for(int acc=0;acc<2;acc++)begin
            reset_case(4'hb);i_ready=0;i_instruction=32'he3a0a007;i_used=0;send();
            i_kind=14;i_instruction=32'he0d00090|(32'(acc)<<21);i_used=15;
            i_value[0]=32'h12345678;i_value[1]=32'h80000003;
            i_value[2]=32'hfffffffd;i_value[3]=32'h76543210;send();
            sx=-64'sd2147483645;sy=-64'sd3;product=64'(sx*sy);
            if(acc!=0)product+=64'h1234567876543210;
            repeat(8)begin tick();check(o_valid&&o_result[0]==7&&o_flags==4'hb,
                "older blocked output stable while multiply computes");end
            check(o_a_valid&&!o_a_can_finish,"completed multiply held for output capacity");
            i_ready=1;tick();check(o_valid&&o_result==product,"held product released once");
            tick();check(!o_valid&&!o_a_valid,"held product not duplicated");
        end
        // A skid/reload can deliver an older accumulator only after the
        // multiplier's private product clocks. Keep that operand late too.
        reset_case();i_ready=0;i_instruction=32'he3a0a007;i_used=0;send();
        i_kind=14;i_instruction=32'he0a00090;i_used=15;
        i_value[0]=0;i_value[1]=3;i_value[2]=4;i_value[3]=1;send();
        repeat(4)tick();
        i_mw_valid[0][0]=1;i_mw_tag[0][0]=3;i_mw_value[0][0]=40;
        repeat(2)tick();
        i_ready=1;tick();check(o_valid&&o_result==52,"late accumulator arrives after held product clocks");
        // Flush at each private multiply phase cancels all younger products.
        for(int phase=0;phase<3;phase++)begin
            reset_case(4'hb);i_kind=14;i_instruction=32'he0f00090;i_used=15;
            i_value[1]=32'h80000003;i_value[2]=32'hfffffffd;send();
            repeat(phase)tick();i_cpsr=32'h60000013;i_flush=1;tick();i_flush=0;
            repeat(5)begin tick();check(!o_valid&&!o_a_valid&&o_flags==6,
                "flush cancels private multiply and restores flags");end
            i_kind=0;i_instruction=32'he3a0a009;i_used=0;send();receive();
            check(o_result[0]==9,"ordinary issue resumes after cancelled multiply");
        end
        // Just-completed A result is selected by a token at A, never sent
        // through S's rotator. Test both Rn and unshifted Rm and a failed writer.
        reset_case();i_instruction=32'he3a00007;i_value=0;i_used=0;i_dest[0]=0;send();
        i_instruction=32'he0801000;i_used=3;i_tag[0]=0;i_tag[1]=0;i_value=0;i_dest[0]=1;send();
        check(o_valid&&o_result[0]==7,"older MOV before late consumer");tick();
        check(o_valid&&o_result[0]==14,"A late Rn/Rm pickup");
        reset_case();i_mw_valid[0][0]=1;i_mw_tag[0][0]=0;i_mw_value[0][0]=19;
        i_condition=0;i_instruction=32'h03a00007;i_used=0;i_dest[0]=0;send();
        i_condition=14;i_instruction=32'he0801000;i_used=3;i_tag[0]=0;i_tag[1]=0;i_dest[0]=1;send();tick();
        check(o_valid&&o_result[0]==38,"failed younger writer exposes captured older fallback");
        // Carry/conditions are A-local: newest flags bypass the S boundary,
        // including RRX's inserted bit and zero-shift preserved carry.
        reset_case();i_instruction=32'he3500000;i_value[0]=0;i_used=1;send(); // CMP #0 => Z,C
        i_instruction=32'he1b01060;i_used=2;i_tag[1]=2;i_value[1]=2;i_dest[0]=1;send();tick();
        check(o_valid&&o_result[0]==32'h80000001&&o_flags==4'h8,"RRX uses preceding CMP carry in A");
        reset_case();i_instruction=32'he3500000;i_value[0]=0;i_used=1;send();
        i_instruction=32'he10f1000;i_kind=1;i_used=4;i_tag[2]=17;i_dest[0]=1;send();tick();
        check(o_valid&&o_result[0]==32'h60000013,"MRS sees latest ordered A flags");
        // Architectural PC overrides any raw/forwarded physical r15 value.
        reset_case();i_instruction=32'he08f100f;i_used=3;i_tag[0]=15;i_tag[1]=15;i_value='1;send();receive();
        check(o_result[0]==32'h2010,"ordinary ARM PC is pc+8");
        reset_case();i_instruction=32'he08f121f;i_used=7;i_tag[0]=15;i_tag[1]=15;i_tag[2]=2;i_reg_shift=1;i_value[2]=0;send();receive();
        check(o_result[0]==32'h2018,"register shift PC is pc+12");
        reset_case();i_kind=5;i_instruction=32'he59f1000;i_thumb=1;i_pc=32'h1002;i_pc_base=32'h1006;i_force_align=1;i_used=1;i_tag[0]=15;send();receive();
        check(o_address==32'h1004,"Thumb literal base aligns architectural PC");
        reset_case();i_kind=5;i_instruction=32'he580f000;i_used=9;i_tag[3]=15;i_value[0]=32'h3000;send();receive();
        check(o_address==32'h3000&&o_store_data==32'h100c&&o_store,"ARM STR PC uses pc+12");
        // A back-end reservation can temporarily hide an older producer.
        // Register-shift preparation must wait for admission, then capture
        // the refreshed amount from the ordinary M producer.
        reset_case();i_instruction=32'he1b22472;i_used=6;i_tag[1]=2;i_tag[2]=4;
        i_reg_shift=1;i_value[1]=32'h12345678;i_value[2]=6;i_valid=1;i_admit=0;
        repeat(3)begin tick();check(!o_ready&&!dut.prepared,"held shift does not prepare a stale amount");end
        i_mw_valid[0][0]=1;i_mw_tag[0][0]=4;i_mw_value[0][0]=4;i_admit=1;
        send();receive();check(o_result[0]==32'h81234567,"shift amount refreshed after reservation recovery");
        // Conditional direct branches use only the registered target-match
        // bits and ordered A flags. Check all conditions and prediction cases.
        for(int cf=0;cf<16;cf++)for(int cc=0;cc<16;cc++)for(int pred=0;pred<4;pred++)begin
            bit taken,wrong;
            reset_case(4'(cf));i_kind=3;i_instruction=32'h0b000123|(32'(cc)<<28);
            i_condition=4'(cc);i_used=0;i_dest[0]=14;i_branch_target=32'h1494;
            i_predicted=pred!=0;i_match_taken=pred==1;i_match_fallthrough=pred==2;
            i_pred_hit=pred!=0;i_pred_state=2'(pred);i_ras_pointer=3;i_ras_count=4;
            taken=cond(4'(cc),4'(cf));wrong=pred==0?taken:taken?pred!=1:pred!=2;
            send();receive();
            check(o_redirect==wrong&&o_redirect_target==(taken?32'h1494:32'h1004),
                "conditional branch direction and registered match selection");
            check(o_btb_update&&o_btb_taken==taken&&o_btb_target==32'h1494&&o_btb_kind==1,
                "registered BL feedback includes actual direction and call kind");
            check(o_write==2'(taken)&&o_result[0]==32'h1004&&o_flags==4'(cf),
                "conditional link write and flags preservation");
            check(o_redirect_pointer==3&&o_redirect_count==4&&o_redirect_action==2'(taken),
                "conditional call checkpoint repair");
        end
        // BX validates the registered operand, including state/alignment and
        // the return-stack checkpoint. An exact predicted target has no kill.
        for(int low=0;low<4;low++)for(int predicted=0;predicted<2;predicted++)begin
            reset_case();i_kind=4;i_instruction=32'he12fff1e;i_used=2;
            i_value[1]=32'h8000+32'(low);i_ras_pointer=5;i_ras_count=6;
            i_pred_target=32'h8000|(32'(low)&(low%2!=0?3:0));i_predicted=1'(predicted);
            send();receive();check(o_redirect==!1'(predicted)&&o_redirect_thumb==1'(low),
                "BX exact prediction and state validation");
            check(o_redirect_target==(i_pred_target&32'hfffffffe)&&o_btb_kind==2&&o_redirect_action==2&&
                o_redirect_pointer==5&&o_redirect_count==6,"BX LR alignment and return checkpoint");
        end
        reset_case(4'ha);i_kind=2;i_instruction=32'he128f001;i_used=2;i_value[1]=32'h50000013;
        send();receive();check(o_flags==5&&o_write_flags&&o_write==0,"flags-only MSR updates A-local NZCV");
        reset_case(4'ha);i_kind=2;i_instruction=32'he168f001;i_used=2;i_value[1]=32'h50000013;
        send();receive();check(o_flags==4'ha&&!o_write_flags,"SPSR MSR does not change A-local CPSR flags");
        // Stale prediction on a nonbranch must refetch fallthrough, not the
        // irrelevant D branch-target field. Event is a registered one-shot.
        reset_case();i_instruction=32'he3a01001;i_used=0;i_dest[0]=1;i_predicted=1;i_pred_target=32'h9000;
        i_branch_target=32'hdead0000;send();receive();
        check(o_redirect&&o_redirect_target==32'h1004,"nonbranch stale BTB repairs fallthrough");
        i_ready=0;tick();check(o_valid&&!o_redirect,"held result does not repeat redirect");
        reset_case();i_instruction=32'h01a0f001;i_condition=0;i_used=2;i_dest[0]=15;
        i_predicted=1;i_pred_target=32'h9000;send();receive();
        check(o_redirect&&o_redirect_target==32'h1004&&!o_pc_write&&o_write==0,
              "condition-failed PC write repairs fallthrough in A");
        // Prediction belongs to the architectural block, not each transfer.
        // LDM PC validation is deferred to M/W; a final STM PC is a store.
        reset_case();i_kind=6;i_instruction=32'he8908003;i_used=1;i_value[0]=32'h3000;
        i_dest[0]=0;i_last=0;i_predicted=1;i_pred_target=32'h6000;send();receive();
        check(!o_redirect&&o_memory&&!o_store,"intermediate LDM does not squash its remaining transfers");tick();
        i_first=0;i_last=1;i_dest[0]=15;i_offset=8;send();receive();
        check(!o_redirect&&o_memory,"LDM PC prediction waits for memory value");tick();
        reset_case();i_kind=6;i_instruction=32'he8808001;i_used=9;i_value[0]=32'h3000;
        i_dest[0]=15;i_predicted=1;i_pred_target=32'h9000;send();receive();
        check(o_redirect&&o_redirect_target==32'h1004&&o_memory&&o_store,
              "STM PC repairs stale branch prediction at final transfer");
        // A held S source survives the disappearance of a ready M producer.
        reset_case();i_ready=0;i_instruction=32'he3a0a001;i_used=0;send();
        i_instruction=32'he3a0b002;i_dest[0]=11;send();
        i_instruction=32'he080c001;i_dest[0]=12;i_used=3;i_value[0]=5;i_value[1]=6;
        i_mw_valid[0][0]=1;i_mw_tag[0][0]=0;i_mw_value[0][0]=100;i_valid=1;tick();
        i_mw_valid=0;repeat(3)tick();i_ready=1;#1;check(o_ready,"release held S");tick();i_valid=0;tick();
        check(o_valid&&o_result[0]==106,"one forwarding network retains held operand");
        // A late consumer waits without retiring or redirecting. Completion
        // repairs its operand register once, even while downstream is held.
        reset_case();i_pending=1;i_value[0]=5;i_value[1]=6;send();
        repeat(4)begin tick();check(o_a_valid&&!raw_o_valid&&!o_redirect,"miss holds late consumer");end
        i_return_select[1]=64'd1;i_return_data[1]=100;i_ready=0;tick();
        i_return_select=0;repeat(3)tick();
        check(o_valid&&o_result[0]==106,"background return retained across hold");i_ready=1;tick();
        reset_case();i_kind=4;i_instruction=32'he12fff11;i_used=2;i_pending=2;i_value[1]=32'h99;
        i_return_select[0]=64'd2;i_return_data[0]=32'h951;tick();i_return_select=0;send();i_return_select=0;receive();
        check(o_redirect&&o_redirect_target==32'h950&&o_redirect_thumb,"BX completion wins raw operand capture");
        // Early shifted input must stay in S, then use the repaired word.
        reset_case();i_instruction=32'he080a081;i_pending=2;i_value[0]=5;i_value[1]=6;i_valid=1;
        repeat(4)begin tick();check(!o_ready&&!o_a_valid,"miss holds early consumer in S");end
        i_return_select[0]=64'd2;i_return_data[0]=100;tick();i_return_select=0;tick();
        #1;check(o_ready,"registered completion releases early consumer");tick();i_valid=0;tick();
        check(o_valid&&o_result[0]==205,"early consumer rotates the returned word");
        // Two successive loads to one register: the older W hit/return must
        // not release the consumer of the younger M load (firmware startup).
        reset_case();manual_producers=1;i_pending=1;
        i_mw_valid=4'b0101;i_mw_tag=0;i_load_owner=3;i_next_load_owner=3;i_load_hit=1;
        i_mw_value[1][0]=32'h80006680;i_value[1]=6;send();
        check(!raw_o_valid,"younger M load shadows older W hit");
        i_return_select[0]=64'd1;i_return_data[0]=32'h80006680;tick();i_return_select=0;tick();
        check(!raw_o_valid,"older W return cannot repair younger load operand");
        i_return_select=0;i_mw_valid=4'b0100;i_next_load_owner=2;
        // Advance the precomputed token before dropping the manually driven
        // M ownership; real M/W registers and this token move on one edge.
        i_mw_value[1][0]=100;tick();i_load_owner=2;receive();
        check(o_result[0]==106,"younger load hit supplies late operand");
        // The youngest writer can also be an ALU result. A stale pending
        // bit from an older load must not deadlock its ready replacement.
        reset_case();manual_producers=1;i_pending=1;
        i_mw_valid=4'b0101;i_mw_tag=0;i_load_owner=2;i_next_load_owner=2;
        i_mw_value[0][0]=100;i_mw_value[1][0]=32'h80006680;i_value[1]=6;send();receive();
        check(o_result[0]==106,"ready M ALU supersedes pending older load");
        // Older exception/restore clears all younger slots and restores flags.
        reset_case();i_instruction=32'he3b0a001;send();i_cpsr=32'h90000013;i_flush=1;tick();i_flush=0;
        check(!o_valid&&!o_a_valid&&o_flags==9&&!o_redirect,"older flush and flag restore");
        $display("PASS S/A execute: %0d checks, %0d clocks",checks,cycles);$finish;
    end
endmodule
