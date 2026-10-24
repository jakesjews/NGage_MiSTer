// SPDX-License-Identifier: GPL-3.0-or-later
// S/A component. Inputs are the registered S-entry from D2. The output is
// A's registered producer/record; M and W producers must also be registers.
// i_ready is REGISTERED downstream capacity, never a cache ACK/hit/err2.
// Pending S operands are stalled in D2. Unshifted operands can carry a late
// token into A, selecting the just-completed REGISTERED A result there.
module arm9v2_execute (
    input logic i_clk,i_reset,i_flush,i_admit,
    input logic [31:0] i_cpsr,
    input logic i_valid,
    output logic o_ready,
    input logic [31:0] i_pc,i_instruction,i_pc_base,i_next_pc,
    input logic i_thumb,i_fault,i_force_align,i_reg_shift,i_first,i_last,
    input logic [3:0] i_kind,i_condition,
    input logic [3:0][5:0] i_tag,
    input logic [3:0] i_used,
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
    output logic [3:0] o_flags,
    output logic o_redirect,o_redirect_thumb,
    output logic [31:0] o_redirect_target,o_redirect_link,
    output logic [2:0] o_redirect_pointer,
    output logic [3:0] o_redirect_count,
    output logic [1:0] o_redirect_action,
    // Registered pending A slot, for the eventual D2 load/multiply scoreboard.
    output logic o_btb_update,o_btb_taken,o_btb_hit,
    output logic [31:0] o_btb_target,
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
        logic [2:0][1:0] late;
        logic signed [7:0] wb_offset;
    } a_t;
    (* dont_retime *) a_t a;
    (* dont_retime *) logic a_valid,prepared,holding,multiply_accumulate,multiply_product_ready;
    (* dont_retime *) logic [3:0] flags;
    (* dont_retime *) logic [3:0][31:0] held;
    (* dont_retime *) logic [7:0] held_amount;
    (* dont_retime *) logic [31:0] block_base;
    (* dont_retime *) logic signed [33:0] ll,lh,hl,hh;
    (* dont_retime *) logic [63:0] product_saved,accumulator;
    logic [2:0][1:0][31:0] producer_value;
    logic [2:0][1:0][5:0] producer_tag;
    logic [2:0][1:0] producer_valid;
    logic [3:0][31:0] forwarded,operand;
    logic [31:0] shift_input,shifted;
    logic [7:0] shift_amount;
    logic [1:0] shift_type;
    logic shift_register,shift_carry,carry_preserve,rrx;
    logic [31:0] left_a,right_a,store_a,alu_result;
    logic [3:0] alu_flags,next_flags;
    logic condition_pass,finish,accept,space,product_phase,mac_phase,will_write_flags;
    logic [1:0] planned_writes;
    logic [63:0] product,mac_result,mult_result;
    logic [31:0] actual_target;
    logic actual_thumb,wrong_prediction;
    wire unused=&{1'b0,i_cpsr[27:0],CP,UND,SWI,actual_target[0],lh[33:32],hl[33:32],hh[33:32]};
    assign producer_value={i_mw_value,o_result};
    assign producer_tag={i_mw_tag,o_dest};
    // o_write is already registered with condition/fault/PC qualification,
    // and is cleared whenever o_valid is cleared. Keep this bounded mask
    // at the producer boundary rather than rebuilding validity inside S.
    assign producer_valid={i_mw_valid,o_write};
    arm9v2_forward u_forward(.i_value(holding?held:i_value),.i_tag(i_tag),.i_used(i_used),
        .i_producer_value(producer_value),.i_producer_tag(producer_tag),
        .i_producer_valid(producer_valid),.o_value(forwarded));
    always_comb begin
        operand=forwarded;
        for(int s=0;s<4;s++)begin
            if(i_tag[s]==15)begin
                operand[s]=i_pc_base;
                if((i_reg_shift&&s<2)||(s==3&&!i_thumb))operand[s]=i_pc_base+32'd4;
                if(s==0&&i_force_align)operand[s]={i_pc_base[31:2],2'b0};
            end
            if(i_tag[s]==17)operand[s]={flags,i_cpsr[27:0]};
        end
        shift_input=operand[1];shift_type=i_instruction[6:5];
        shift_amount=prepared?held_amount:{3'd0,i_instruction[11:7]};
        shift_register=i_reg_shift;
        if((i_kind==DP||i_kind==MSR)&&i_instruction[25])begin
            shift_input={24'd0,i_instruction[7:0]};shift_type=3;
            shift_amount={3'd0,i_instruction[11:8],1'b0};shift_register=1;
        end
        // MEM/SWP/block offsets bypass the rotator when immediate/unshifted.
        if(i_kind==MEM&&i_instruction[27:26]==0)begin
            shift_type=0;shift_amount=0;shift_register=1;
        end
        if(i_kind!=DP&&i_kind!=MSR&&i_kind!=MEM)begin
            shift_type=0;shift_amount=0;shift_register=1;
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
    arm9v2_rotate u_rotate(.i_value(shift_input),.i_amount(shift_amount),.i_type(shift_type),
        .i_register(shift_register),.i_carry(1'b0),.o_value(shifted),
        .o_carry(shift_carry),.o_preserve(carry_preserve),.o_rrx(rrx));
    // Tokens are captured in S. No tags or producer readiness enter this mux.
    always_comb begin
        left_a=a.left;right_a=a.right;store_a=a.store_data;
        for(int lane=0;lane<2;lane++)if(o_valid&&o_write[lane])begin
            if(a.late[0][lane])left_a=o_result[lane];
            if(a.late[1][lane])right_a=o_result[lane];
            if(a.late[2][lane])store_a=o_result[lane];
        end
        if(a.rrx)right_a[31]=flags[1];
    end
    arm9_alu u_alu(.i_a(left_a),.i_b(right_a),.i_op(a.op),.i_flags(flags),
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
    assign mac_result=product_saved+accumulator;
    assign mult_result=a.ins[21]?mac_result:product;
    assign product_phase=a_valid&&(a.kind==MUL||a.kind==MULL)&&!multiply_product_ready;
    assign mac_phase=a_valid&&(a.kind==MUL||a.kind==MULL)&&multiply_product_ready&&a.ins[21]&&!multiply_accumulate;
    assign space=!a_valid||finish;
    assign o_shift_wait=i_valid&&i_reg_shift&&!prepared;
    assign o_multiply_wait=product_phase||mac_phase;
    assign o_ready=i_admit&&space&&!o_shift_wait&&!i_flush&&!o_redirect;
    assign accept=i_valid&&o_ready;
    assign finish=a_valid&&!product_phase&&!mac_phase&&(!o_valid||i_ready)&&!i_flush&&!o_redirect;
    assign o_a_valid=a_valid;
    assign o_a_can_finish=finish;
    assign o_s_write=planned_writes&{2{i_valid}};
    assign o_a_dest=a.dest;
    assign o_a_write=a.writes;
    assign o_a_load=a_valid&&!a.fault&&((a.kind==MEM||a.kind==BLOCK)?a.ins[20]:a.kind==SWP);
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
    always_ff @(posedge i_clk)begin
        if(i_reset||i_flush)begin
            a_valid<=0;holding<=0;prepared<=0;multiply_accumulate<=0;multiply_product_ready<=0;
            o_valid<=0;o_write<=0;o_write_flags<=0;o_redirect<=0;
            o_btb_update<=0;o_btb_taken<=0;o_btb_hit<=0;o_btb_target<=0;o_btb_state<=0;o_btb_kind<=0;
            flags<=i_cpsr[31:28];a<=a_t'(0);held<=0;held_amount<=0;block_base<=0;
            ll<=0;lh<=0;hl<=0;hh<=0;product_saved<=0;accumulator<=0;
            o_pc<=0;o_instruction<=0;o_cpsr<=0;o_cpsr_next<=0;o_kind<=0;
            o_thumb<=0;o_fault<=0;o_first<=0;o_last<=0;o_condition_pass<=0;
            o_dest<=0;o_result<=0;o_pc_write<=0;o_memory<=0;o_store<=0;
            o_address<=0;o_store_data<=0;o_redirect_thumb<=0;o_redirect_target<=0;
            o_redirect_link<=0;o_redirect_pointer<=0;o_redirect_count<=0;o_redirect_action<=0;
        end else begin
            o_redirect<=0;o_btb_update<=0;
            if(i_ready)begin o_valid<=0;o_write<=0;o_write_flags<=0;end
            if(i_valid&&!accept)begin holding<=1;held<=operand;end
            if(i_valid&&i_admit&&space&&i_reg_shift&&!prepared)begin prepared<=1;held_amount<=operand[2][7:0];end
            if(a_valid)begin a.left<=left_a;a.right<=right_a;a.store_data<=store_a;a.late<=0;end
            if(product_phase)begin
                ll<=$signed({1'b0,a.right[15:0]})*$signed({1'b0,a.special[15:0]});
                lh<=$signed({1'b0,a.right[15:0]})*$signed({a.kind==MULL&&a.ins[22]&&a.special[31],a.special[31:16]});
                hl<=$signed({a.kind==MULL&&a.ins[22]&&a.right[31],a.right[31:16]})*$signed({1'b0,a.special[15:0]});
                hh<=$signed({a.kind==MULL&&a.ins[22]&&a.right[31],a.right[31:16]})*$signed({a.kind==MULL&&a.ins[22]&&a.special[31],a.special[31:16]});
                multiply_product_ready<=1;
            end
            if(mac_phase)begin product_saved<=product;multiply_accumulate<=1;end
            if(finish)begin
                a_valid<=0;o_valid<=1;o_pc<=a.pc;o_instruction<=a.ins;o_kind<=a.kind;
                o_thumb<=a.thumb;o_fault<=a.fault;o_first<=a.first;o_last<=a.last;
                o_condition_pass<=condition_pass&&!a.fault;o_dest<=a.dest;
                o_psr_source<=right_a;o_saved_psr<=a.kind==DP?store_a:a.special;
                o_original_base<=left_a;o_spsr_tag<=a.spsr_tag;
                o_next_pc<=a.next_pc;o_predicted<=a.predicted;o_prediction_target<=a.pred_target;
                o_cpsr<={flags,a.cpsr_low};o_cpsr_next<={next_flags,a.cpsr_low};
                flags<=next_flags;o_write_flags<=will_write_flags;
                o_write<=a.writes&{2{condition_pass&&!a.fault}};
                o_result[0]<=alu_result;o_result[1]<=0;
                o_address<=alu_result;o_store_data<=store_a;
                o_memory<=(a.kind==MEM||a.kind==BLOCK||a.kind==SWP)&&condition_pass&&!a.fault;
                o_store<=(a.kind==SWP||((a.kind==MEM||a.kind==BLOCK)&&!a.ins[20]))&&condition_pass&&!a.fault;
                o_pc_write<=((a.writes[0]&&a.dest[0]==15)||(a.kind==SUFFIX&&!a.direct))&&condition_pass&&!a.fault;
                for(int lane=0;lane<2;lane++)if(a.dest[lane]==15)o_write[lane]<=0;
                case(a.kind)
                    MRS:o_result[0]<=a.cpsr_read?{flags,a.special[27:0]}:a.special;
                    BR,SUFFIX:o_result[0]<={a.next_pc[31:1],a.thumb};
                    PREFIX:o_result[0]<=a.target;
                    MUL:o_result[0]<=mult_result[31:0];
                    MULL:begin o_result[0]<=mult_result[31:0];o_result[1]<=mult_result[63:32];end
                    MEM:begin o_address<=a.ins[24]?alu_result:left_a;o_result[1]<=alu_result;end
                    BLOCK:o_result[1]<=left_a+{{24{a.wb_offset[7]}},a.wb_offset};
                    SWP:begin o_address<=left_a;o_store_data<=right_a;end
                    default:;
                endcase
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
                a_valid<=1;holding<=0;prepared<=0;multiply_accumulate<=0;multiply_product_ready<=0;
                a.pc<=i_pc;a.ins<=i_instruction;a.next_pc<=i_next_pc;a.target<=i_branch_target;
                a.pred_target<=i_pred_target;a.cpsr_low<=i_cpsr[27:0];a.kind<=i_kind;a.condition<=i_condition;
                a.thumb<=i_thumb;a.fault<=i_fault;a.first<=i_first;a.last<=i_last;
                a.direct<=i_direct;a.predicted<=i_predicted;a.match_taken<=i_match_taken;
                a.match_fallthrough<=i_match_fallthrough;a.pred_hit<=i_pred_hit;a.pred_state<=i_pred_state;a.ras_pointer<=i_ras_pointer;a.ras_count<=i_ras_count;
                a.spsr_tag<=i_tag[2];a.dest<=i_dest;a.writes<=planned_writes;a.left<=operand[0];a.right<=shifted;
                a.store_data<=operand[3];a.special<=operand[2];a.cpsr_read<=i_tag[2]==17;
                a.op<=i_instruction[24:21];a.set_flags<=i_instruction[20]||(i_kind==DP&&i_instruction[24:23]==2'b10);
                a.shift_carry<=shift_carry;a.carry_preserve<=carry_preserve;a.rrx<=rrx;a.wb_offset<=i_writeback_offset;
                a.late<=0;
                for(int lane=0;lane<2;lane++)if(a_valid&&a.writes[lane]&&a.dest[lane]!=15)begin
                    if(i_used[0]&&i_tag[0]==a.dest[lane]&&i_tag[0]!=17)a.late[0][lane]<=1;
                    if(i_used[1]&&i_tag[1]==a.dest[lane]&&i_tag[1]!=17&&
                       (i_kind==BX||i_kind==SWP||(i_kind==DP&&!i_instruction[25]&&i_instruction[11:4]==0)))a.late[1][lane]<=1;
                    if(i_used[3]&&i_tag[3]==a.dest[lane]&&i_tag[3]!=17)a.late[2][lane]<=1;
                end
                if(i_kind==MEM)begin
                    a.op<=i_instruction[23]?4'd4:4'd2;a.rrx<=rrx;
                    if(i_instruction[27:26]==1&&!i_instruction[25])begin a.right<={20'd0,i_instruction[11:0]};a.rrx<=0;end
                    if(i_instruction[27:26]==0&&i_instruction[22])begin a.right<={24'd0,i_instruction[11:8],i_instruction[3:0]};a.rrx<=0;end
                end
                if(i_kind==BLOCK)begin
                    a.op<=4;a.left<=i_first?operand[0]:block_base;a.right<={{24{i_offset[7]}},i_offset};a.rrx<=0;
                    if(i_first)block_base<=operand[0];
                end
                if(i_kind==BX||i_kind==SWP)begin a.right<=operand[1];a.rrx<=0;end
                if(i_kind==SUFFIX)begin a.op<=4;a.right<={20'd0,i_instruction[10:0],1'b0};a.rrx<=0;end
                if(i_kind==MUL||i_kind==MULL)begin
                    accumulator<=i_kind==MULL?{operand[0],operand[3]}:{32'd0,operand[3]};
                end
            end
            if(o_redirect)begin a_valid<=0;holding<=0;prepared<=0;end
        end
    end
endmodule
