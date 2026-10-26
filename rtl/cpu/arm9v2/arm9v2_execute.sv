// SPDX-License-Identifier: GPL-3.0-or-later
// S/A component. Inputs are the registered S-entry from D2. The output is
// A's combinational record; the consumer captures it in the A/M register.
// i_ready is REGISTERED downstream capacity, never a cache ACK/hit/err2.
// D2 interlocks early operands; a registered S wait preserves their
// separation through backend holds. Late A operands select registered M/W.
// S_AGU: the effective address is summed in S from S's registered-producer
// operands and registered into A (a.agu); A drives the D-cache/TLB lookup
// from that register instead of through its late bypass and ALU. Decode
// makes the base and a register offset early sources. A scaled register
// offset takes one prepared S clock (the rotated offset is registered
// before the sum). A base whose writer is the scalar MEM in A (its
// writeback is that record's registered S-AGU sum) is taken from A.
// FREE_SELECT: S's forward grant and A's late bypass select data as if W's
// load hit and M's load word existed. A source whose producer is a load
// without an accepted hit waits (s_wait/a_wait, unchanged), so the word it
// selected is never consumed: S holds it as pending, A as a.pending, until
// the producer's hit, a newer producer or the return replaces it. The hit
// and the trust then reach only the waits, not the 32-bit selects.
// FAST_Z: the ALU's carry-free zero (arm9_alu).
// W_ROTATE: W's load word, the forward network's last-arriving input, has
// a rotator of its own in S with the record's shift controls; the main
// rotator's input excludes that lane, and the grant selects the finished
// value. The operand multiplexer is no longer between the cache and the
// shifter.
module arm9v2_execute #(parameter logic S_AGU=0, parameter logic FREE_SELECT=0, parameter logic FAST_Z=0,
    parameter logic W_ROTATE=0, parameter logic SHIFT_PRE=0, parameter logic PAYLOAD_FREE=0,
    parameter logic DSP_PRODUCT=0) (
    input logic i_clk,i_reset,i_flush,i_admit,i_load_wait,
    input logic i_flags_refresh,
    output logic o_serial_continue,
    input logic [3:0] i_pending,
    input logic [1:0] i_load_owner,i_next_load_owner,
    input logic i_load_hit,
    // i_load_trust: the cache accepts W's short hit now (not a departing
    // line, not the fill-end clock). i_self_dep: the S record writes a
    // register it reads; only such a writer needs the accepted hit.
    input logic i_load_trust,i_self_dep,
    input logic [63:0] i_return_select, // Registered background port C.
    input logic i_return_next_valid,i_return_ready,
    input logic [5:0] i_return_next_tag,
    input logic [3:0] i_return_s_match,
    input logic [1:0][31:0] i_return_data,
    input logic [31:0] i_cpsr,
    input logic i_valid,
    output logic o_ready,
    output logic o_ready_payload,   // o_ready without the flush and A's redirect (decode's payload enables)
    input logic [31:0] i_pc,i_instruction,i_pc_base,i_next_pc,
    input logic i_thumb,i_fault,i_force_align,i_reg_shift,i_first,i_last,
    input logic [15:0] i_shift_pre,   // SHIFT_PRE: {type, amount, rotate amount, register}
    input logic [3:0] i_kind,i_condition,
    input logic [3:0][5:0] i_tag,
    input logic [3:0] i_used,i_early,
    input logic [3:0][1:0][1:0] i_forward_match,
    input logic [1:0][3:0][4:0] i_forward_grant,
    input logic [1:0][1:0][5:0] i_next_tag, i_advance_tag,
    input logic i_next_advance,
    input logic [1:0][1:0] i_next_write,
    input logic [3:0][31:0] i_value,
    input logic [1:0][5:0] i_dest,
    input logic signed [7:0] i_offset,i_writeback_offset,
    input logic [31:0] i_branch_target,i_pred_target,
    input logic i_direct,i_predicted,i_match_taken,i_match_fallthrough,i_pred_hit,
    input logic [1:0] i_pred_state,
    input logic [2:0] i_ras_pointer,
    input logic [3:0] i_ras_count,
    input logic [1:0][1:0][31:0] i_mw_value,
    input logic [1:0][1:0][5:0] i_mw_tag,
    input logic [1:0][1:0] i_mw_valid,
    input logic i_ready,
    output logic o_valid,
    output logic [31:0] o_pc,o_instruction,o_cpsr,o_cpsr_next,
    output logic [3:0] o_kind,
    output logic o_thumb,o_fault,o_first,o_last,o_condition_pass,
    output logic [1:0][5:0] o_dest,
    output logic [1:0][31:0] o_result,
    (* dont_retime *) output logic [1:0] o_write,
    output logic o_write_flags,o_pc_write,o_memory,o_store,
    output logic [31:0] o_address,o_store_data,
    output logic [31:0] o_alu_address,   // A's ALU result (a Thumb BL suffix's target)
    output logic [3:0] o_flags,
    output logic o_redirect,o_redirect_thumb,
    output logic [31:0] o_redirect_target,o_redirect_link,
    output logic [2:0] o_redirect_pointer,
    output logic [3:0] o_redirect_count,
    output logic [1:0] o_redirect_action,
    // Registered pending A slot, for the eventual D2 load/multiply scoreboard.
    output logic o_btb_update,o_btb_taken,o_btb_hit,
    output logic [31:0] o_btb_target,o_btb_pc,
    output logic o_btb_thumb,
    output logic [2:0] o_record_pointer,
    output logic [3:0] o_record_count,
    output logic o_record_pred_hit,o_record_thumb,
    output logic [1:0] o_record_pred_state,
    output logic [1:0] o_btb_state,o_btb_kind,
    output logic o_a_valid,o_a_can_finish,
    output logic [1:0] o_s_write,
    output logic [1:0][5:0] o_a_dest,
    output logic [1:0] o_a_write,
    output logic o_shift_wait,o_multiply_wait,
    output logic o_a_load,
    output logic [31:0] o_psr_source,o_saved_psr,o_original_base,o_next_pc,o_prediction_target,
    output logic [5:0] o_spsr_tag,
    output logic o_predicted
);
    localparam logic [3:0] DP=0,MRS=1,MSR=2,BR=3,BX=4,MEM=5,BLOCK=6,
        CP=7,UND=8,SWI=9,PREFIX=10,SUFFIX=11,SWP=12,MUL=13,MULL=14;
    typedef struct packed {
        logic [31:0] pc,ins,next_pc,target,pred_target;
        logic [27:0] cpsr_low;
        logic [3:0] kind,condition;
        logic thumb,fault,first,last,direct,predicted,match_taken,match_fallthrough,pred_hit;
        logic [1:0] pred_state;
        logic [2:0] ras_pointer;
        logic [3:0] ras_count;
        logic [1:0][5:0] dest;
        logic [5:0] spsr_tag;
        logic [1:0] writes;
        logic [31:0] left,right,store_data,special;
        logic [3:0] op;
        logic set_flags,shift_carry,carry_preserve,rrx,cpsr_read;
        logic [3:0][1:0][1:0] late;
        logic [3:0][5:0] tag;
        logic [3:0] late_used,pending;
        logic self_dep;
        logic signed [7:0] wb_offset;
        logic [31:0] agu,agu_sum;          // S_AGU: registered address and writeback sum
        logic [3:0][5:0] take;             // FREE_SELECT: one-hot late selects (take_of)
    } a_t;
    (* dont_retime *) a_t a;
    (* dont_retime *) logic a_valid,prepared,holding,multiply_accumulate,multiply_product_ready;
    (* dont_retime *) logic [3:0] flags;
    // I/F follows executed same-mode MSRs, independently of retirement.
    // Real bank/mode changes remain fenced until the W recovery.
    (* dont_retime *) logic [1:0] interrupt_mask;
    logic [1:0] next_interrupt_mask;
    logic msr_same_mode;
    assign msr_same_mode=!condition_pass||a.cpsr_low[4:0]==5'h10||right_a[4:0]==a.cpsr_low[4:0];
    assign next_interrupt_mask=finish&&a.kind==MSR&&!a.ins[22]&&a.ins[16]&&
        condition_pass&&!a.fault&&a.cpsr_low[4:0]!=5'h10&&msr_same_mode?right_a[7:6]:interrupt_mask;
    (* dont_retime *) logic [3:0][31:0] held;
    (* dont_retime *) logic [7:0] held_amount;
    (* dont_retime *) logic [4:0] held_rot;      // SHIFT_PRE: held_amount's rotate amount
    (* dont_retime *) logic [31:0] held_offset;   // S_AGU: a scaled offset, rotated on the prepared clock
    (* dont_retime *) logic [31:0] block_base;
    // DSP_PRODUCT: the partial products have no reset (they are read only
    // after product_phase writes them), so Quartus keeps them in the DSP
    // blocks' output registers, which take only an asynchronous clear.
    // No dont_retime here: it protects the registers from exactly that move.
    logic signed [33:0] ll,lh,hl,hh;
    (* dont_retime *) logic [63:0] product_saved;
    logic [3:0][31:0] forwarded,operand;
    (* dont_retime *) logic [3:0] s_pending;
    logic [3:0] s_wait,a_wait;
    (* dont_retime *) logic [3:0] return_a_match;
    logic [3:0][1:0] s_return_match,a_return_match;
    // A writer of a register it reads passes D2 behind an older pending
    // load of that register only because it waits for that load's data.
    // It must not take a short-hit word the cache has not accepted: that
    // load can still miss, and its background return would then overwrite
    // this younger writer. Other readers may take the word (the departing
    // line's current data); the return rewrites the same value.
    wire s_load_hit=i_load_hit&&(!i_self_dep||i_load_trust);
    wire a_load_hit=i_load_hit&&(!a.self_dep||i_load_trust);
    // The return data and these bounded matches take the same edge. A's
    // owner is the accepted S record or its existing held record. Producer
    // age/pending checks remain at consumption, just as for background C.
    always_ff @(posedge i_clk) begin
        if(i_reset||i_flush||o_redirect)return_a_match<=0;
        else for(int src=0;src<4;src++)
            return_a_match[src]<=i_return_next_valid&&i_return_next_tag==
                (accept?i_tag[src]:a.tag[src]);
    end
    always_comb for(int src=0;src<4;src++) begin
        s_return_match[src]={i_return_select[{26'd0,i_tag[src]}],i_return_ready&&i_return_s_match[src]};
        a_return_match[src]={i_return_select[{26'd0,a.tag[src]}],i_return_ready&&return_a_match[src]};
    end

    // Matches are already registered at D2/S and S/A. A short hit is itself
    // a registered permission-qualified response. No ACK drives admission.
    always_comb begin
        s_wait=holding?s_pending:i_pending;a_wait=a.pending;
        // Resolve readiness in exactly the data network's age order. A
        // newer ready ALU writer cancels an older load's pending token;
        // a newer unresolved load shadows an older hit/return.
        for(int src=0;src<4;src++)for(int prod=1;prod>=0;prod--)begin
            if(|i_forward_match[src][prod])
                s_wait[src]=i_forward_match[src][prod][0]&&
                    i_load_owner[prod]&&(prod==0||!s_load_hit);
            if(|a.late[src][prod])
                a_wait[src]=a.late[src][prod][0]&&
                    i_load_owner[prod]&&(prod==0||!a_load_hit);
        end
    end
    logic [31:0] shift_input,shifted;
    logic [7:0] shift_amount;
    logic [1:0] shift_type,ref_type;
    logic [7:0] ref_amount;
    logic [4:0] shift_rot;
    logic ref_register;
    logic shift_register,shift_carry,carry_preserve,rrx;
    logic [31:0] left_a,right_a,store_a,special_a,alu_result;
    logic [3:0] alu_flags,next_flags;
    logic condition_pass,finish,accept,space,product_phase,mac_phase,will_write_flags;
    logic [1:0] planned_writes;
    logic [63:0] product,mac_result,mult_result;
    logic [31:0] actual_target;
    logic actual_thumb,wrong_prediction;
    wire unused=&{1'b0,i_cpsr[27:0],i_used[2],i_mw_tag,i_mw_valid,CP,UND,SWI,actual_target[0],lh[33:32],hl[33:32],hh[33:32]};
    wire s_grant_hit=FREE_SELECT||s_load_hit;
    arm9v2_forward u_forward(.i_value(holding?held:i_value),.i_grant(i_forward_grant[s_grant_hit]),
        .i_producer_value(i_mw_value),.o_value(forwarded));
`ifndef SYNTHESIS
    // Prove every selected data source is ready, and that the precomputed
    // grants preserve the old selector (including its RF/held fallback),
    // for both hit alternatives.
    always_ff @(posedge i_clk) if(!i_reset&&!i_flush&&i_valid) begin
        for(int hit=0;hit<2;hit++)for(int src=0;src<4;src++)begin
            logic seen,eligible;
            seen=0;
            for(int rank=0;rank<4;rank++)begin
                eligible=i_forward_match[src][rank/2][1-rank%2]&&
                    !(rank%2==1&&i_load_owner[rank/2]&&(rank/2==0||hit==0));
                assert(i_forward_grant[hit][src][rank]==(eligible&&!seen))
                    else $fatal(1,"S grant age/readiness hit=%0d src=%0d rank=%0d",hit,src,rank);
                seen|=eligible;
            end
            assert(i_forward_grant[hit][src][4]==!seen);
            assert($onehot(i_forward_grant[hit][src]));
        end
    end
    // FREE_SELECT: a source that does not wait selects the old word. The
    // old producer word had W's load lane zeroed without a short hit (the
    // core's gate); any such word is unhit here, so its readers wait.
    logic [1:0][1:0][31:0] mw_ref;
    always_comb begin
        mw_ref=i_mw_value;
        if(i_load_owner[1]&&!i_load_hit)mw_ref[1][0]=0;
    end
    logic [3:0][31:0] forwarded_ref;
    arm9v2_forward u_forward_ref(.i_value(holding?held:i_value),.i_grant(i_forward_grant[s_load_hit]),
        .i_producer_value(mw_ref),.o_value(forwarded_ref));
    always_ff @(posedge i_clk) if(!i_reset&&!i_flush&&i_valid)
        for(int src=0;src<4;src++)
            if(i_used[src]&&!s_wait[src]&&i_tag[src]!=15&&i_tag[src]!=17)
                assert(forwarded[src]==forwarded_ref[src])
                    else $fatal(1,"S free select src=%0d",src);
`endif
    always_comb begin
        operand=forwarded;
        for(int s=0;s<4;s++)begin
            if(i_tag[s]==15)begin
                operand[s]=i_pc_base;
                if((i_reg_shift&&s<2)||(s==3&&!i_thumb))operand[s]=i_pc_base+32'd4;
                if(s==0&&i_force_align)operand[s]={i_pc_base[31:2],2'b0};
            end
            if(i_tag[s]==17)operand[s]={flags,i_cpsr[27:8],interrupt_mask,i_cpsr[5:0]};
        end
        shift_input=operand[1];ref_type=i_instruction[6:5];
        ref_amount=prepared&&i_reg_shift?held_amount:{3'd0,i_instruction[11:7]};
        ref_register=i_reg_shift;
        if((i_kind==DP||i_kind==MSR)&&i_instruction[25])begin
            shift_input={24'd0,i_instruction[7:0]};ref_type=3;
            ref_amount={3'd0,i_instruction[11:8],1'b0};ref_register=1;
        end
        // MEM/SWP/block offsets bypass the rotator when immediate/unshifted.
        if(i_kind==MEM&&i_instruction[27:26]==0)begin
            ref_type=0;ref_amount=0;ref_register=1;
        end
        if(i_kind!=DP&&i_kind!=MSR&&i_kind!=MEM)begin
            ref_type=0;ref_amount=0;ref_register=1;
        end
        // SHIFT_PRE: the same controls from decode's registers; a prepared
        // register shift takes the amount held on its prepare clock.
        if(SHIFT_PRE)begin
            shift_type=i_shift_pre[15:14];shift_register=i_shift_pre[0];
            shift_amount=prepared&&i_reg_shift?held_amount:i_shift_pre[13:6];
            shift_rot=prepared&&i_reg_shift?held_rot:i_shift_pre[5:1];
        end else begin
            shift_type=ref_type;shift_amount=ref_amount;shift_register=ref_register;
            shift_rot=ref_type==0?5'(-ref_amount[4:0]):ref_amount[4:0];
        end
        planned_writes=0;
        case(i_kind)
            DP:planned_writes[0]=i_instruction[24:23]!=2'b10;
            MRS,MUL,PREFIX:planned_writes[0]=1;
            MULL:planned_writes=3;
            BR:planned_writes[0]=i_instruction[24];
            SUFFIX:planned_writes[0]=1;
            MEM:planned_writes[1]=i_instruction[21]||!i_instruction[24];
            BLOCK:planned_writes[1]=i_last&&i_instruction[21]&&!(i_instruction[20]&&i_instruction[{1'b0,i_instruction[19:16]}]);
            default:;
        endcase
        if(i_fault)planned_writes=0;
    end
    // W_ROTATE: src 1's forwarded word without W's load lane (rank 3), and
    // the shifter input built from it exactly as shift_input is.
    logic [31:0] operand1_nw,shift_input_nw;
    wire [4:0] grant1=i_forward_grant[s_grant_hit][1];
    wire w_take=W_ROTATE&&grant1[3]&&i_tag[1]!=15&&i_tag[1]!=17&&!((i_kind==DP||i_kind==MSR)&&i_instruction[25]);
    always_comb begin
        operand1_nw=(i_mw_value[0][1]&{32{grant1[0]}})|(i_mw_value[0][0]&{32{grant1[1]}})|
            (i_mw_value[1][1]&{32{grant1[2]}})|((holding?held[1]:i_value[1])&{32{grant1[4]}});
        if(i_tag[1]==15)operand1_nw=i_reg_shift?i_pc_base+32'd4:i_pc_base;
        if(i_tag[1]==17)operand1_nw={flags,i_cpsr[27:8],interrupt_mask,i_cpsr[5:0]};
        shift_input_nw=operand1_nw;
        if((i_kind==DP||i_kind==MSR)&&i_instruction[25])shift_input_nw={24'd0,i_instruction[7:0]};
    end
    logic [31:0] shifted_main,shifted_w;
    logic carry_main,preserve_main,rrx_main,carry_w,preserve_w,rrx_w;
    arm9v2_rotate #(.PRE_ROT(SHIFT_PRE)) u_rotate(.i_value(W_ROTATE?shift_input_nw:shift_input),.i_amount(shift_amount),.i_type(shift_type),.i_rot(shift_rot),
        .i_register(shift_register),.i_carry(1'b0),.o_value(shifted_main),
        .o_carry(carry_main),.o_preserve(preserve_main),.o_rrx(rrx_main));
    arm9v2_rotate #(.PRE_ROT(SHIFT_PRE)) u_rotate_w(.i_value(i_mw_value[1][0]),.i_amount(shift_amount),.i_type(shift_type),.i_rot(shift_rot),
        .i_register(shift_register),.i_carry(1'b0),.o_value(shifted_w),
        .o_carry(carry_w),.o_preserve(preserve_w),.o_rrx(rrx_w));
    assign shifted=w_take?shifted_w:shifted_main;
    assign shift_carry=w_take?carry_w:carry_main;
    assign carry_preserve=w_take?preserve_w:preserve_main;
    assign rrx=w_take?rrx_w:rrx_main;
`ifndef SYNTHESIS
    logic [31:0] shifted_ref;
    logic carry_ref,preserve_ref,rrx_ref;
    arm9v2_rotate u_rotate_ref(.i_value(shift_input),.i_amount(ref_amount),.i_type(ref_type),.i_rot(5'd0),
        .i_register(ref_register),.i_carry(1'b0),.o_value(shifted_ref),
        .o_carry(carry_ref),.o_preserve(preserve_ref),.o_rrx(rrx_ref));
    always_ff @(posedge i_clk) if(!i_reset&&!i_flush&&i_valid)
        assert({shifted,shift_carry,carry_preserve,rrx}=={shifted_ref,carry_ref,preserve_ref,rrx_ref})
            else $fatal(1,"S W-lane rotator");
    // SHIFT_PRE: decode's registered controls equal the in-stage formulas.
    always_ff @(posedge i_clk) if(!i_reset&&SHIFT_PRE&&i_valid)
        assert({shift_type,shift_amount,shift_register,shift_rot}==
            {ref_type,ref_amount,ref_register,ref_type==0?5'(-ref_amount[4:0]):ref_amount[4:0]})
            else $fatal(1,"S shifter controls");
`endif
    // S_AGU: the address adder. Inputs are S's selected operands (registered
    // producers or the RF), never A's ALU. A scaled register offset uses
    // held_offset from the prepared clock, so no rotator precedes the sum.
    wire agu_scaled=S_AGU&&i_kind==MEM&&i_instruction[27:26]==1&&i_instruction[25]&&i_instruction[11:4]!=0;
    logic agu_forward,agu_sub,agu_pre;
    logic [31:0] agu_base,agu_offset,agu_sum,agu_address,s_base;
    always_comb begin
        // The scalar MEM in A writes this base (its writeback lane, condition
        // passed): its registered sum is the newest value; S's network still
        // holds the older one. Decode let this record pass D2 on that basis.
        agu_forward=S_AGU&&(i_kind==MEM||i_kind==SWP||(i_kind==BLOCK&&i_first))&&
            a_valid&&a.kind==MEM&&a.writes[1]&&condition_pass&&!a.fault&&
            !(a.ins[20]&&a.dest[0]==a.dest[1])&&a.dest[1]==i_tag[0]&&i_tag[0]!=15;
        s_base=agu_forward?a.agu_sum:operand[0];
        agu_base=s_base;agu_sub=!i_instruction[23];agu_pre=i_instruction[24];
        agu_offset={20'd0,i_instruction[11:0]};
        if(i_instruction[27:26]==0)
            agu_offset=i_instruction[22]?{24'd0,i_instruction[11:8],i_instruction[3:0]}:operand[1];
        else if(i_instruction[25])agu_offset=i_instruction[11:4]!=0?held_offset:operand[1];
        if(i_kind==BLOCK)begin
            agu_base=i_first?s_base:(a_valid&&a.kind==BLOCK&&a.first)?a.left:block_base;
            agu_offset={{24{i_offset[7]}},i_offset};agu_sub=0;agu_pre=1;
        end
        if(i_kind==SWP)begin agu_offset=0;agu_sub=0;agu_pre=1;end
        agu_sum=agu_sub?agu_base-agu_offset:agu_base+agu_offset;
        agu_address=agu_pre?agu_sum:agu_base;
    end
    // Late data bypass: tag comparisons were captured at S/A, and are
    // refreshed each held edge. Only registered M/W words enter A.
    // FREE_SELECT: the selects no longer depend on the hit, so they are
    // registered one-hot beside a.late (a.take, refreshed on the same edges):
    // the bypass is a two-level AND-OR of the record's operand, the four M/W
    // words and, for a later block transfer's base, block_base.
    function automatic logic [5:0] take_of(input logic [1:0][1:0] late,input logic block);
        take_of=0;
        if(block)take_of[5]=1;
        else if(late[0][1])take_of[3]=1;   // M lane 1, the newest
        else if(late[0][0])take_of[2]=1;   // M lane 0
        else if(late[1][1])take_of[1]=1;   // W lane 1
        else if(late[1][0])take_of[0]=1;   // W lane 0
        else take_of[4]=1;                 // the record's own operand
    endfunction
    logic [3:0][31:0] late_own,late_value;
    always_comb begin
        late_own={a.store_data,a.special,a.right,a.left};
        for(int src=0;src<4;src++)
            late_value[src]=({32{a.take[src][4]}}&late_own[src])|({32{a.take[src][0]}}&i_mw_value[1][0])|
                ({32{a.take[src][1]}}&i_mw_value[1][1])|({32{a.take[src][2]}}&i_mw_value[0][0])|
                ({32{a.take[src][3]}}&i_mw_value[0][1])|({32{a.take[src][5]}}&block_base);
    end
    always_comb begin
        left_a=a.left;right_a=a.right;store_a=a.store_data;special_a=a.special;
        if(FREE_SELECT)begin
            left_a=late_value[0];right_a=late_value[1];special_a=late_value[2];store_a=late_value[3];
        end else begin
            for(int prod=1;prod>=0;prod--)for(int lane=0;lane<2;lane++)begin
                if(!(lane==0&&i_load_owner[prod]&&(prod==0||!a_load_hit)))begin
                if(a.late[0][prod][lane])left_a=i_mw_value[prod][lane];
                if(a.late[1][prod][lane])right_a=i_mw_value[prod][lane];
                if(a.late[2][prod][lane])special_a=i_mw_value[prod][lane];
                if(a.late[3][prod][lane])store_a=i_mw_value[prod][lane];
                end
            end
            if(a.kind==BLOCK&&!a.first)left_a=block_base;
        end
        if(a.rrx)right_a[31]=flags[1];
    end
`ifndef SYNTHESIS
    // FREE_SELECT: an operand that does not wait is the old selector's word.
    logic [3:0][31:0] late_ref;
    always_comb begin
        late_ref={a.store_data,a.special,a.right,a.left};
        for(int prod=1;prod>=0;prod--)for(int lane=0;lane<2;lane++)
            if(!(lane==0&&i_load_owner[prod]&&(prod==0||!a_load_hit)))
                for(int src=0;src<4;src++)if(a.late[src][prod][lane])late_ref[src]=mw_ref[prod][lane];
        if(a.kind==BLOCK&&!a.first)late_ref[0]=block_base;
        if(a.rrx)late_ref[1][31]=flags[1];
    end
    always_ff @(posedge i_clk) if(!i_reset&&!i_flush&&a_valid)
        for(int src=0;src<4;src++)begin
            if(!a_wait[src])
                assert(late_ref[src]==(src==0?left_a:src==1?right_a:src==2?special_a:store_a))
                    else $fatal(1,"A free select src=%0d",src);
            if(FREE_SELECT)assert(a.take[src]==take_of(a.late[src],src==0&&a.kind==BLOCK&&!a.first))
                else $fatal(1,"A one-hot late select src=%0d",src);
        end
`endif
    arm9_alu #(.FAST_Z(FAST_Z)) u_alu(.i_a(left_a),.i_b(right_a),.i_op(a.op),.i_flags(flags),
        .i_shift_carry(a.carry_preserve?flags[1]:a.shift_carry),.o_result(alu_result),.o_flags(alu_flags));
    // S/A captures multiplier operands. A private first clock registers four
    // half-products from those registers; forwarding never precedes a DSP.
    // Two carry-save layers and one final sum finish on the next clock.
    wire [63:0] pp0={{30{ll[33]}},ll};
    wire [63:0] pp1={{14{lh[33]}},lh,16'd0};
    wire [63:0] pp2={{14{hl[33]}},hl,16'd0};
    wire [63:0] pp3={hh[31:0],32'd0};
    wire [63:0] ones0=pp0^pp1^pp2;
    wire [63:0] twos0=((pp0&pp1)|(pp1&pp2)|(pp0&pp2))<<1;
    wire [63:0] ones1=ones0^twos0^pp3;
    wire [63:0] twos1=((ones0&twos0)|(ones0&pp3)|(twos0&pp3))<<1;
    assign product=ones1+twos1;
    assign mac_result=product_saved+(a.kind==MULL?{left_a,store_a}:{32'd0,store_a});
    assign mult_result=a.ins[21]?mac_result:product;
    assign product_phase=a_valid&&(a.kind==MUL||a.kind==MULL)&&!multiply_product_ready;
    assign mac_phase=a_valid&&(a.kind==MUL||a.kind==MULL)&&multiply_product_ready&&a.ins[21]&&!multiply_accumulate;
    assign space=!a_valid||finish;
    assign o_shift_wait=i_valid&&(i_reg_shift||agu_scaled)&&!prepared;
    assign o_multiply_wait=product_phase||mac_phase;
    assign o_ready_payload=i_admit&&space&&!i_load_wait&&!(|(s_wait&i_early))&&!o_shift_wait;
    assign o_ready=o_ready_payload&&!i_flush&&!o_redirect;
    assign accept=i_valid&&o_ready;
    assign o_valid=a_valid&&!(|a_wait)&&!product_phase&&!mac_phase&&!i_flush&&!o_redirect;
    assign finish=o_valid&&i_ready;
    assign o_a_valid=a_valid;
    assign o_a_can_finish=finish;
    assign o_s_write=planned_writes&{2{i_valid}};
    assign o_a_dest=a.dest;
    assign o_a_write=a.writes;
    assign o_a_load=a_valid&&!a.fault&&((a.kind==MEM||a.kind==BLOCK)?a.ins[20]:a.kind==SWP||(a.kind==CP&&a.ins[20]&&a.dest[0]!=15));
    assign o_flags=flags;
    always_comb begin
        case(a.condition)
            0:condition_pass=flags[2];1:condition_pass=!flags[2];
            2:condition_pass=flags[1];3:condition_pass=!flags[1];
            4:condition_pass=flags[3];5:condition_pass=!flags[3];
            6:condition_pass=flags[0];7:condition_pass=!flags[0];
            8:condition_pass=flags[1]&&!flags[2];9:condition_pass=!flags[1]||flags[2];
            10:condition_pass=flags[3]==flags[0];11:condition_pass=flags[3]!=flags[0];
            12:condition_pass=!flags[2]&&(flags[3]==flags[0]);
            13:condition_pass=flags[2]||(flags[3]!=flags[0]);
            14:condition_pass=1;default:condition_pass=0;
        endcase
        next_flags=flags;will_write_flags=0;
        if(condition_pass&&!a.fault)case(a.kind)
            DP:if(a.set_flags&&(!a.writes[0]||a.dest[0]!=15))begin next_flags=alu_flags;will_write_flags=1;end
            MUL:if(a.set_flags)begin next_flags={mult_result[31],mult_result[31:0]==0,flags[1:0]};will_write_flags=1;end
            MULL:if(a.set_flags)begin next_flags={mult_result[63],mult_result==0,flags[1:0]};will_write_flags=1;end
            MSR:if(!a.ins[22]&&a.ins[19])begin next_flags=right_a[31:28];will_write_flags=1;end
            default:;
        endcase
        actual_target=a.next_pc;actual_thumb=a.thumb;
        if(a.kind==BR&&condition_pass)actual_target=a.target;
        wrong_prediction=a.last&&a.predicted&&!a.match_fallthrough;
        if(a.kind==BR)wrong_prediction=a.direct?1'b0:
            (a.predicted?(condition_pass?!a.match_taken:!a.match_fallthrough):condition_pass);
        if(a.kind==SUFFIX)wrong_prediction=0;
        if(a.kind==BX&&condition_pass)begin
            actual_thumb=right_a[0];
            actual_target={right_a[31:2],right_a[1]&right_a[0],1'b0};
            wrong_prediction=!a.predicted||a.pred_target!={right_a[31:2],right_a[1]&right_a[0],right_a[0]};
        end
        // ALU/load PC writes are validated by M/W; never put an ALU adder
        // through target equality and into the front-end clear network.
        if(condition_pass&&a.dest[0]==15&&
           (a.writes[0]||((a.kind==MEM||a.kind==BLOCK)&&a.ins[20])))
            wrong_prediction=0;
        if(a.fault)wrong_prediction=0;
    end
    always_comb begin
                o_pc=a.pc;o_instruction=a.ins;o_kind=a.kind;
                o_thumb=a.thumb;o_fault=a.fault;o_first=a.first;o_last=a.last;
                o_condition_pass=condition_pass&&!a.fault;o_dest=a.dest;
                o_psr_source=right_a;o_saved_psr=a.kind==DP?store_a:special_a;
                o_original_base=left_a;o_spsr_tag=a.spsr_tag;
                o_next_pc=a.next_pc;o_predicted=a.predicted;o_prediction_target=a.pred_target;
                o_cpsr={flags,a.cpsr_low};o_cpsr_next={next_flags,a.cpsr_low};
                o_write_flags=will_write_flags;
                o_write=a.writes&{2{condition_pass&&!a.fault}};
                o_result[0]=alu_result;o_result[1]=0;
                o_address=S_AGU?a.agu:alu_result;o_store_data=store_a;o_alu_address=alu_result;
                o_memory=(a.kind==MEM||a.kind==BLOCK||a.kind==SWP)&&condition_pass&&!a.fault;
                o_store=(a.kind==SWP||((a.kind==MEM||a.kind==BLOCK)&&!a.ins[20]))&&condition_pass&&!a.fault;
                o_pc_write=((a.writes[0]&&a.dest[0]==15)||(a.kind==SUFFIX&&!a.direct))&&condition_pass&&!a.fault;
                for(int lane=0;lane<2;lane++)if(a.dest[lane]==15)o_write[lane]=0;
                case(a.kind)
                    MRS:o_result[0]=a.cpsr_read?{flags,special_a[27:0]}:special_a;
                    BR,SUFFIX:o_result[0]={a.next_pc[31:1],a.thumb};
                    PREFIX:o_result[0]=a.target;
                    MUL:o_result[0]=mult_result[31:0];
                    MULL:begin o_result[0]=mult_result[31:0];o_result[1]=mult_result[63:32];end
                    MEM:begin if(!S_AGU)o_address=a.ins[24]?alu_result:left_a;o_result[1]=alu_result;end
                    BLOCK:o_result[1]=left_a+{{24{a.wb_offset[7]}},a.wb_offset};
                    SWP:begin if(!S_AGU)o_address=left_a;o_store_data=right_a;end
                    default:;
                endcase
                o_record_pointer=a.ras_pointer;o_record_count=a.ras_count;
                o_record_pred_hit=a.pred_hit;o_record_pred_state=a.pred_state;
                o_record_thumb=a.kind==BX?right_a[0]:a.thumb;
    end
    (* keep *) logic [1:0][3:0][1:0][1:0] s_candidate_match, a_candidate_match;
    // a.late's next value on a held edge and on acceptance.
    logic [3:0][1:0][1:0] late_hold,late_accept;
    always_comb for(int src=0;src<4;src++)for(int prod=0;prod<2;prod++)for(int lane=0;lane<2;lane++)begin
        late_hold[src][prod][lane]=a.late_used[src]&&i_next_write[prod][lane]&&a_candidate_match[i_next_advance][src][prod][lane];
        late_accept[src][prod][lane]=i_used[src]&&!i_early[src]&&i_tag[src]!=15&&i_tag[src]!=17&&
            i_next_write[prod][lane]&&s_candidate_match[i_next_advance][src][prod][lane];
    end
    always_comb for(int src=0;src<4;src++)for(int prod=0;prod<2;prod++)for(int lane=0;lane<2;lane++)begin
        s_candidate_match[0][src][prod][lane]=i_tag[src]==i_next_tag[prod][lane];
        // Current M becomes W on advance. Its match is already registered
        // at D2/S, and is refreshed there throughout a hold.
        s_candidate_match[1][src][prod][lane]=prod==1?i_forward_match[src][0][lane]:
            i_tag[src]==i_advance_tag[prod][lane];
        a_candidate_match[0][src][prod][lane]=a.tag[src]==i_next_tag[prod][lane];
        a_candidate_match[1][src][prod][lane]=a.tag[src]==i_advance_tag[prod][lane];
    end
`ifndef SYNTHESIS
    always_ff @(posedge i_clk) if(!i_reset&&!i_flush&&i_valid)
        for(int src=0;src<4;src++)for(int prod=0;prod<2;prod++)for(int lane=0;lane<2;lane++)begin
            assert((i_used[src]&&i_next_write[prod][lane]&&s_candidate_match[i_next_advance][src][prod][lane])==
                (i_used[src]&&i_next_write[prod][lane]&&i_tag[src]==(i_next_advance?i_advance_tag[prod][lane]:i_next_tag[prod][lane])))
                else $fatal(1,"next producer match/age");
        end
`endif
    // PAYLOAD_FREE: a flush resets the control and valid state only (the
    // block below); the payload (A's record, the held operands, the
    // multiplier partials, the redirect/BTB fields) loads as it would
    // without the flush, and every reader of it is gated by a valid bit.
    always_ff @(posedge i_clk)begin
        if(i_reset||(!PAYLOAD_FREE&&i_flush))begin
            a_valid<=0;holding<=0;prepared<=0;s_pending<=0;multiply_accumulate<=0;multiply_product_ready<=0;
            o_redirect<=0;o_btb_pc<=0;o_btb_thumb<=0;
            o_btb_update<=0;o_btb_taken<=0;o_btb_hit<=0;o_btb_target<=0;o_btb_state<=0;o_btb_kind<=0;
            flags<=i_cpsr[31:28];interrupt_mask<=i_cpsr[7:6];o_serial_continue<=0;a<=a_t'(0);held<=0;held_amount<=0;held_rot<=0;held_offset<=0;block_base<=0;
            if(!DSP_PRODUCT)begin ll<=0;lh<=0;hl<=0;hh<=0;end
            product_saved<=0;
            o_redirect_thumb<=0;o_redirect_target<=0;
            o_redirect_link<=0;o_redirect_pointer<=0;o_redirect_count<=0;o_redirect_action<=0;
        end else begin
            o_redirect<=0;o_btb_update<=0;o_serial_continue<=0;
            interrupt_mask<=next_interrupt_mask;
            if(i_flags_refresh)flags<=i_cpsr[31:28];
            if(i_valid&&!accept)begin
                holding<=1;held<=operand;s_pending<=s_wait;
                // A retired return is older than every live M/W match. It
                // may repair only an operand whose live producer has left.
                for(int src=0;src<4;src++)for(int port=0;port<2;port++)
                    if(s_wait[src]&&!(|i_forward_match[src])&&s_return_match[src][port])begin
                        held[src]<=i_return_data[port];s_pending[src]<=0;
                    end
            end
            if(i_valid&&i_admit&&space&&!i_load_wait&&!(|(s_wait&i_early))&&(i_reg_shift||agu_scaled)&&!prepared)begin
                prepared<=1;if(i_reg_shift)begin held_amount<=operand[2][7:0];held_rot<=shift_type==0?5'(-operand[2][4:0]):operand[2][4:0];end
                if(agu_scaled)held_offset<=shifted;
            end
            if(a_valid)begin
                a.left<=left_a;a.right<=right_a;a.store_data<=store_a;a.special<=special_a;
                a.pending<=a_wait;
                for(int src=0;src<4;src++)for(int port=0;port<2;port++)
                    if(a_wait[src]&&!(|a.late[src])&&a_return_match[src][port])begin
                        case(src)
                            0:a.left<=i_return_data[port];1:a.right<=i_return_data[port];
                            2:a.special<=i_return_data[port];3:a.store_data<=i_return_data[port];
                        endcase
                        a.pending[src]<=0;
                    end
                for(int src=0;src<4;src++)for(int prod=0;prod<2;prod++)for(int lane=0;lane<2;lane++)
                    a.late[src][prod][lane]<=late_hold[src][prod][lane];
                for(int src=0;src<4;src++)a.take[src]<=take_of(late_hold[src],src==0&&a.kind==BLOCK&&!a.first);
            end
            if(product_phase)begin
                ll<=$signed({1'b0,a.right[15:0]})*$signed({1'b0,a.special[15:0]});
                lh<=$signed({1'b0,a.right[15:0]})*$signed({a.kind==MULL&&a.ins[22]&&a.special[31],a.special[31:16]});
                hl<=$signed({a.kind==MULL&&a.ins[22]&&a.right[31],a.right[31:16]})*$signed({1'b0,a.special[15:0]});
                hh<=$signed({a.kind==MULL&&a.ins[22]&&a.right[31],a.right[31:16]})*$signed({a.kind==MULL&&a.ins[22]&&a.special[31],a.special[31:16]});
                multiply_product_ready<=1;
            end
            if(mac_phase)begin product_saved<=product;multiply_accumulate<=1;end
            if(finish)begin
`ifndef SYNTHESIS
                // D2's control-MSR fence is released by the registered A
                // result. No next S record can capture I/F on this edge.
                if(a.kind==MSR&&a.ins[16]&&!a.ins[22])assert(!accept);
`endif
                a_valid<=0;flags<=next_flags;
                o_serial_continue<=a.kind==MSR&&!a.ins[22]&&a.ins[16]&&msr_same_mode&&!a.fault;
                if(a.kind==BLOCK&&a.first)block_base<=left_a;
                o_btb_pc<=a.pc;o_btb_thumb<=a.thumb;
                o_btb_update<=(a.kind==BR||a.kind==BX||(a.kind==SUFFIX&&a.direct))&&!a.fault;
                o_btb_taken<=condition_pass;o_btb_hit<=a.pred_hit;o_btb_state<=a.pred_state;
                o_btb_target<=a.kind==BX?{right_a[31:2],right_a[1]&right_a[0],right_a[0]}:{a.target[31:1],a.thumb};
                o_btb_kind<=a.kind==SUFFIX||(a.kind==BR&&a.ins[24])?2'd1:
                    a.kind==BX&&a.ins[3:0]==14?2'd2:2'd0;
                o_redirect<=wrong_prediction;
                o_redirect_target<={actual_target[31:1],1'b0};o_redirect_thumb<=actual_thumb;
                o_redirect_link<={a.next_pc[31:1],a.thumb};
                o_redirect_pointer<=a.ras_pointer;o_redirect_count<=a.ras_count;
                o_redirect_action<=condition_pass&&a.kind==BR&&a.ins[24]?2'd1:
                    condition_pass&&a.kind==BX&&a.ins[3:0]==14?2'd2:2'd0;
            end
            if(accept)begin
                a_valid<=1;holding<=0;prepared<=0;s_pending<=0;multiply_accumulate<=0;multiply_product_ready<=0;
                a.pc<=i_pc;a.ins<=i_instruction;a.next_pc<=i_next_pc;a.target<=i_branch_target;
                a.pred_target<=i_pred_target;a.cpsr_low<={i_cpsr[27:8],interrupt_mask,i_cpsr[5:0]};a.kind<=i_kind;a.condition<=i_condition;
                a.thumb<=i_thumb;a.fault<=i_fault;a.first<=i_first;a.last<=i_last;
                a.direct<=i_direct;a.predicted<=i_predicted;a.match_taken<=i_match_taken;
                a.match_fallthrough<=i_match_fallthrough;a.pred_hit<=i_pred_hit;a.pred_state<=i_pred_state;a.ras_pointer<=i_ras_pointer;a.ras_count<=i_ras_count;
                a.spsr_tag<=i_tag[2];a.self_dep<=i_self_dep;a.dest<=i_dest;a.writes<=planned_writes;a.left<=S_AGU?s_base:operand[0];a.right<=shifted;
                a.agu<=agu_address;a.agu_sum<=agu_sum;
                a.store_data<=operand[3];a.special<=operand[2];a.cpsr_read<=i_tag[2]==17;
                a.op<=i_instruction[24:21];a.set_flags<=i_instruction[20]||(i_kind==DP&&i_instruction[24:23]==2'b10);
                a.shift_carry<=shift_carry;a.carry_preserve<=carry_preserve;a.rrx<=rrx;a.wb_offset<=i_writeback_offset;
                a.tag<=i_tag;
                for(int src=0;src<4;src++)begin
                    a.pending[src]<=i_used[src]&&!i_early[src]&&s_wait[src];
                    for(int prod=0;prod<2;prod++)
                        if(i_used[src]&&!i_early[src]&&i_next_load_owner[prod]&&s_candidate_match[i_next_advance][src][prod][0])
                            a.pending[src]<=1;
                    a.late_used[src]<=i_used[src]&&!i_early[src]&&i_tag[src]!=15&&i_tag[src]!=17;
                    for(int prod=0;prod<2;prod++)for(int lane=0;lane<2;lane++)
                        a.late[src][prod][lane]<=late_accept[src][prod][lane];
                    a.take[src]<=take_of(late_accept[src],src==0&&i_kind==BLOCK&&!i_first);
                end
                if(i_kind==MEM)begin
                    a.op<=i_instruction[23]?4'd4:4'd2;a.rrx<=rrx;
                    if(i_instruction[27:26]==1&&!i_instruction[25])begin a.right<={20'd0,i_instruction[11:0]};a.rrx<=0;end
                    if(i_instruction[27:26]==0&&i_instruction[22])begin a.right<={24'd0,i_instruction[11:8],i_instruction[3:0]};a.rrx<=0;end
                end
                if(i_kind==BLOCK)begin
                    a.op<=4;a.left<=S_AGU?s_base:operand[0];a.right<={{24{i_offset[7]}},i_offset};a.rrx<=0;
                end
                if(i_kind==BX||i_kind==SWP)begin a.right<=operand[1];a.rrx<=0;end
                if(i_kind==SUFFIX)begin a.op<=4;a.right<={20'd0,i_instruction[10:0],1'b0};a.rrx<=0;end
                // Completion wins over class-specific raw operand captures
                // (BX/SWP Rm and the first block base) on this same edge.
                for(int src=0;src<4;src++)begin
                    for(int port=0;port<2;port++)
                        if(i_used[src]&&!i_early[src]&&s_wait[src]&&!(|i_forward_match[src])&&s_return_match[src][port])begin
                            case(src)
                                0:a.left<=i_return_data[port];1:a.right<=i_return_data[port];
                                2:a.special<=i_return_data[port];3:a.store_data<=i_return_data[port];
                            endcase
                            a.pending[src]<=0;
                        end
                end
            end
            if(o_redirect)begin a_valid<=0;holding<=0;prepared<=0;end
            if(PAYLOAD_FREE&&i_flush)begin
                a_valid<=0;holding<=0;prepared<=0;s_pending<=0;multiply_accumulate<=0;multiply_product_ready<=0;
                o_redirect<=0;o_btb_update<=0;o_serial_continue<=0;
                flags<=i_cpsr[31:28];interrupt_mask<=i_cpsr[7:6];
            end
        end
    end
endmodule
