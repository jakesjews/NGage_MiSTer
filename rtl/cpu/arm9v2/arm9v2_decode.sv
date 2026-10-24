// SPDX-License-Identifier: GPL-3.0-or-later
// ARM9V2 D1/D2, including the registers at the S entrance. ARMv4T class and
// physical register mapping follow this project's GPL arm9_core/zap_functions
// (ZAP copyright 2016-2024 Revanth Kamaraj). No execution or forwarding here.
module arm9v2_decode (
    input logic i_clk, i_reset, i_flush,
    input logic i_valid,
    output logic o_ready,
    input logic [31:0] i_pc, i_word,
    input logic i_thumb, i_fault,
    input logic [4:0] i_mode,
    input logic i_predicted, i_pred_hit,
    input logic [31:0] i_pred_target,
    input logic [1:0] i_pred_state, i_pred_kind,
    input logic [2:0] i_ras_pointer,
    input logic [3:0] i_ras_count,
    // These are registered W/scoreboard producers, not live cache responses.
    input logic i_wen,
    input logic [39:0] i_wr_addr_a, i_wr_addr_b, i_wr_addr_c, i_locked,
    input logic [31:0] i_wr_data_a, i_wr_data_b, i_wr_data_c,
    input logic i_ready,
    output logic o_valid,
    output logic [31:0] o_pc, o_instruction, o_pc_base, o_next_pc,
    output logic [15:0] o_raw,
    output logic [4:0] o_mode,
    output logic o_thumb, o_fault, o_force_align, o_reg_shift,
    output logic [3:0] o_kind, o_condition,
    output logic [3:0][5:0] o_tag,
    output logic [3:0] o_used,
    output logic [3:0][31:0] o_value,
    output logic [1:0][5:0] o_dest,
    output logic o_first, o_last,
    output logic [4:0] o_reg_count,
    output logic signed [7:0] o_offset, o_writeback_offset,
    output logic [3:0] o_transfer_reg,
    output logic [31:0] o_branch_target,
    output logic o_direct, o_match_taken, o_match_fallthrough,
    output logic o_predicted, o_pred_hit,
    output logic [31:0] o_pred_target,
    output logic [1:0] o_pred_state, o_pred_kind,
    output logic [2:0] o_ras_pointer,
    output logic [3:0] o_ras_count,
    output logic o_hazard,
    // All redirect fields are registers at the D2/S edge. Older i_flush wins.
    output logic o_redirect, o_redirect_thumb,
    output logic [31:0] o_redirect_target, o_redirect_link,
    output logic [2:0] o_redirect_pointer,
    output logic [3:0] o_redirect_count,
    output logic [1:0] o_redirect_action
);
    localparam logic [3:0] K_DP=0, K_MRS=1, K_MSR=2, K_BRANCH=3,
        K_BX=4, K_MEM=5, K_BLOCK=6, K_CP=7, K_UND=8, K_SWI=9,
        K_BL_PREFIX=10, K_BL_SUFFIX=11, K_SWP=12, K_MUL=13, K_MULL=14;
    typedef struct packed {
        logic [31:0] pc, ins, pc_base, next_pc, pred_target;
        logic [15:0] raw, list, rest;
        logic [4:0] mode, nregs;
        logic [3:0] first;
        logic thumb, fault, und, align_pc, half_branch, paired;
        logic predicted, pred_hit;
        logic [1:0] pred_state, pred_kind;
        logic [2:0] ras_pointer;
        logic [3:0] ras_count;
    } packet_t;
    typedef struct packed {
        packet_t p;
        logic [3:0] kind, condition;
        logic [3:0][5:0] tag;
        logic [3:0] used;
        logic [1:0][5:0] dest;
        logic [31:0] target;
        logic direct, reg_shift, first, last, redirected;
        logic [4:0] left;
        logic [15:0] remaining;
        logic [3:0] transfer_reg;
        logic signed [7:0] offset, wb_offset;
    } decoded_t;
    typedef struct packed {
        logic valid, thumb;
        logic [31:0] target, link;
        logic [2:0] pointer;
        logic [3:0] count;
        logic [1:0] action;
    } redirect_t;
    (* dont_retime *) redirect_t redirect_ff;
    (* dont_retime *) logic redirect_in_d2;
    (* dont_retime, ramstyle = "logic" *) packet_t d1[0:1];
    (* dont_retime *) logic head, tail;
    (* dont_retime *) logic [1:0] count;
    (* dont_retime *) logic d2_valid, out_valid;
    (* dont_retime *) decoded_t d2, issued;
    (* dont_retime *) logic [3:0][31:0] values;
    (* dont_retime *) logic matches_taken, matches_fallthrough;
    (* dont_retime *) logic previous_prefix, prefix_valid;
    (* dont_retime *) logic [31:0] previous_next_pc, prefix_target;
    packet_t incoming, front;
    decoded_t decoded, fast_branch, admitted;
    logic [31:0] raw_word;
    logic [34:0] expanded;
    logic thumb_und, thumb_align;
    logic [15:0] reg_list, next_remaining;
    logic [3:0] next_register;
    logic [31:0] suffix_base;
    logic [4:0] transfer_mode;
    logic [3:0][31:0] raw_values, read_values;
    logic push, pop, accept, shortcut, fast_select, new_d2, late_redirect, step, kill_younger, taken_match, fallthrough_match;
    logic unused;
    assign unused = &{1'b0, expanded[33:32], issued.left, issued.remaining, issued.redirected, fast_arm_twos[31], fast_thumb_twos[31]};

    // Three small truth tables and a carry-save reduction avoid four serial
    // carry-propagating population-count additions after the queue mux.
    function automatic [2:0] count6(input logic [5:0] v);
        case (v)
            6'd0:count6=3'd0;
            6'd1:count6=3'd1;
            6'd2:count6=3'd1;
            6'd3:count6=3'd2;
            6'd4:count6=3'd1;
            6'd5:count6=3'd2;
            6'd6:count6=3'd2;
            6'd7:count6=3'd3;
            6'd8:count6=3'd1;
            6'd9:count6=3'd2;
            6'd10:count6=3'd2;
            6'd11:count6=3'd3;
            6'd12:count6=3'd2;
            6'd13:count6=3'd3;
            6'd14:count6=3'd3;
            6'd15:count6=3'd4;
            6'd16:count6=3'd1;
            6'd17:count6=3'd2;
            6'd18:count6=3'd2;
            6'd19:count6=3'd3;
            6'd20:count6=3'd2;
            6'd21:count6=3'd3;
            6'd22:count6=3'd3;
            6'd23:count6=3'd4;
            6'd24:count6=3'd2;
            6'd25:count6=3'd3;
            6'd26:count6=3'd3;
            6'd27:count6=3'd4;
            6'd28:count6=3'd3;
            6'd29:count6=3'd4;
            6'd30:count6=3'd4;
            6'd31:count6=3'd5;
            6'd32:count6=3'd1;
            6'd33:count6=3'd2;
            6'd34:count6=3'd2;
            6'd35:count6=3'd3;
            6'd36:count6=3'd2;
            6'd37:count6=3'd3;
            6'd38:count6=3'd3;
            6'd39:count6=3'd4;
            6'd40:count6=3'd2;
            6'd41:count6=3'd3;
            6'd42:count6=3'd3;
            6'd43:count6=3'd4;
            6'd44:count6=3'd3;
            6'd45:count6=3'd4;
            6'd46:count6=3'd4;
            6'd47:count6=3'd5;
            6'd48:count6=3'd2;
            6'd49:count6=3'd3;
            6'd50:count6=3'd3;
            6'd51:count6=3'd4;
            6'd52:count6=3'd3;
            6'd53:count6=3'd4;
            6'd54:count6=3'd4;
            6'd55:count6=3'd5;
            6'd56:count6=3'd3;
            6'd57:count6=3'd4;
            6'd58:count6=3'd4;
            6'd59:count6=3'd5;
            6'd60:count6=3'd4;
            6'd61:count6=3'd5;
            6'd62:count6=3'd5;
            6'd63:count6=3'd6;
        endcase
    endfunction
    function automatic [4:0] popcount16(input logic [15:0] v);
        logic [2:0] a,b,c,ones,twos;
        a=count6(v[5:0]);b=count6(v[11:6]);c=count6({2'b0,v[15:12]});
        ones=a^b^c;twos=(a&b)|(a&c)|(b&c);
        return {2'b0,ones}+{1'b0,twos,1'b0};
    endfunction
    function automatic [15:0] clear_first(input logic [15:0] v);
        logic [15:0] result;
        for (int n=0;n<16;n++) result[n]=v[n] && |(v & (16'hffff >> (16-n)));
        return result;
    endfunction
    // Bit 15 is implied when the lower fifteen are zero. Empty lists are
    // classified as undefined before this index can name a transfer.
    function automatic [3:0] first16(input logic [14:0] v);
        logic [3:0] r; logic [6:0] b; logic [2:0] q;
        r[3]=!(|v[7:0]); b=r[3]?v[14:8]:v[6:0];
        r[2]=!(|b[3:0]); q=r[2]?b[6:4]:b[2:0];
        r[1]=!(|q[1:0]);
        r[0]=!(r[1]?q[2]:q[0]); return r;
    endfunction
    function automatic [5:0] bank(input logic [4:0] r, mode);
        logic [5:0] result;
        result={1'b0,r};
        if (r==27) begin
            case (mode)
                5'h11:result=35; 5'h12:result=36; 5'h13:result=37;
                5'h1b:result=38; 5'h17:result=39; default:result=17;
            endcase
        end else if (r>=8 && r<=14 && mode==5'h11) result={1'b0,r}+6'd10;
        else if (r==13 || r==14) begin
            case (mode)
                5'h12:result={1'b0,r}+6'd12; 5'h13:result={1'b0,r}+6'd14;
                5'h1b:result={1'b0,r}+6'd16; 5'h17:result={1'b0,r}+6'd18;
                default:;
            endcase
        end
        return result;
    endfunction
    function automatic [3:0] classify(input logic [31:0] ins,
        input logic [4:0] raw_class, input logic thumb, und, user_mode, empty_list);
        logic [3:0] k;
        k=K_UND;
        if (ins[27:24]==4'hf) k=K_SWI;
        else if (ins[27:25]==3'b101) k=K_BRANCH;
        else if (ins[27:25]==3'b100) k=K_BLOCK;
        else if (ins[27:26]==2'b01 && !(ins[25]&&ins[4])) k=K_MEM;
        else if ((ins&32'h0fc000f0)==32'h00000090) k=K_MUL;
        else if ((ins&32'h0f8000f0)==32'h00800090) k=K_MULL;
        else if ((ins&32'h0fb00ff0)==32'h01000090) k=K_SWP;
        else if ((ins&32'h0ffffff0)==32'h012fff10) k=K_BX;
        else if ((ins&32'h0fbf0fff)==32'h010f0000) k=K_MRS;
        else if ((ins&32'h0fb0fff0)==32'h0120f000 || (ins&32'h0fb0f000)==32'h0320f000) k=K_MSR;
        else if (ins[27:24]==4'he && ins[4] && ins[11:8]==4'hf) k=user_mode?K_UND:K_CP;
        else if (ins[27:25]==0 && ins[7] && ins[4] && ins[6:5]!=0) k=K_MEM;
        else if (ins[27:26]==0 && !(ins[7]&&ins[4]&&!ins[25]) && !(!ins[20]&&ins[24:23]==2'b10)) k=K_DP;
        if (thumb && raw_class==5'b11110) k=K_BL_PREFIX;
        if (thumb && raw_class==5'b11111) k=K_BL_SUFFIX;
        if (und || (!thumb&&ins[31:28]==4'hf) ||
            (k==K_MEM&&ins[27:26]==0&&!ins[20]&&ins[6]) ||
            (thumb&&raw_class==5'b11101) || (k==K_BLOCK&&empty_list)) k=K_UND;
        return k;
    endfunction

    assign raw_word = i_thumb && i_pc[1] ? {16'd0,i_word[31:16]} : i_word;
    // A suffix is kept as its own architectural record. Paired target
    // optimization uses the dedicated prefix register, not Thumb expansion.
    zap_mode16_decoder #(.V4T(1'b1)) u_thumb (
        .i_instruction(raw_word),.i_instruction_valid(1'b1),.i_offset(11'd0),
        .i_prev_prefix(1'b0),.i_irq(1'b0),.i_fiq(1'b0),.i_cpsr_ff_t(i_thumb),
        .o_instruction(expanded),.o_und(thumb_und),.o_force32_align(thumb_align),
        .o_instruction_valid(),.o_irq(),.o_fiq()
    );
    always_comb begin
        // List extraction is parallel to Thumb expansion, not downstream of it.
        reg_list=i_word[15:0];
        if (i_thumb) begin
            reg_list={8'd0,raw_word[7:0]};
            if ((raw_word[15:0]&16'hf600)==16'hb400 && raw_word[8]) begin
                if (raw_word[11]) reg_list[15]=1; else reg_list[14]=1;
            end
        end
        incoming=packet_t'(0);
        incoming.pc=i_pc; incoming.ins=expanded[31:0]; incoming.raw=raw_word[15:0];
        incoming.pc_base=i_pc+(i_thumb?32'd4:32'd8);
        incoming.next_pc=i_pc+(i_thumb?32'd2:32'd4);
        incoming.mode=i_mode;incoming.thumb=i_thumb;incoming.fault=i_fault;
        incoming.und=thumb_und;incoming.align_pc=thumb_align;incoming.half_branch=expanded[34];
        incoming.list=reg_list;incoming.rest=clear_first(reg_list);
        incoming.nregs=popcount16(reg_list);incoming.first=first16(reg_list[14:0]);
        incoming.paired=previous_prefix && i_thumb && i_pc==previous_next_pc;
        incoming.predicted=i_predicted;incoming.pred_hit=i_pred_hit;incoming.pred_target=i_pred_target;
        incoming.pred_state=i_pred_state;incoming.pred_kind=i_pred_kind;
        incoming.ras_pointer=i_ras_pointer;incoming.ras_count=i_ras_count;
    end
    assign front=d1[head];
    // Complete sums in parallel; instruction classification only selects a
    // finished target and never selects the operands of its carry chain.
    (* keep *) wire [31:0] arm_target=front.pc_base+{{6{front.ins[23]}},front.ins[23:0],2'b0};
    (* keep *) wire [31:0] thumb_target=front.pc_base+{{7{front.ins[23]}},front.ins[23:0],1'b0};
    (* keep *) wire [31:0] prefix_sum=front.pc_base+{{9{front.raw[10]}},front.raw[10:0],12'd0};
    (* keep *) wire [31:0] suffix_sum=suffix_base+{20'd0,front.raw[10:0],1'b0};
    wire [31:0] fast_arm_offset={{6{i_word[23]}},i_word[23:0],2'b0};
    wire [31:0] fast_thumb_offset={{20{raw_word[10]}},raw_word[10:0],1'b0};
    // Include the architectural PC bias with carry-save logic. Writing
    // pc+offset+8/4 inferred TWO serial carry chains on the shortcut path.
    (* keep *) wire [31:0] fast_arm_ones=i_pc^fast_arm_offset^32'd8;
    (* keep *) wire [31:0] fast_arm_twos=(i_pc&fast_arm_offset)|((i_pc|fast_arm_offset)&32'd8);
    (* keep *) wire [31:0] fast_thumb_ones=i_pc^fast_thumb_offset^32'd4;
    (* keep *) wire [31:0] fast_thumb_twos=(i_pc&fast_thumb_offset)|((i_pc|fast_thumb_offset)&32'd4);
    (* keep *) wire [31:0] fast_arm_sum=fast_arm_ones+{fast_arm_twos[30:0],1'b0};
    (* keep *) wire [31:0] fast_thumb_sum=fast_thumb_ones+{fast_thumb_twos[30:0],1'b0};
    always_comb begin
        // Only direct B/BL takes the empty-D1 shortcut. Its controls/indices
        // are trivial and independent of general decode or list arithmetic.
        // The source is the REGISTERED fetch queue, never the cache response.
        fast_branch=decoded_t'(0);
        fast_branch.p=incoming;
        fast_branch.p.ins=i_thumb?{4'he,4'ha,{13{raw_word[10]}},raw_word[10:0]}:i_word;
        fast_branch.p.list=0;fast_branch.p.rest=0;fast_branch.p.nregs=0;fast_branch.p.first=0;
        fast_branch.kind=K_BRANCH;fast_branch.condition=4'he;
        fast_branch.dest[0]=bank(5'd14,i_mode);
        fast_branch.first=1;fast_branch.last=1;fast_branch.direct=1;
        fast_branch.target=i_thumb?fast_thumb_sum:fast_arm_sum;
    end
    always_comb begin
        decoded=decoded_t'(0);decoded.p=front;
        decoded.kind=classify(front.ins,front.raw[15:11],front.thumb,front.und,front.mode==5'h10,front.nregs==0);
        decoded.condition=front.ins[31:28];
        if (decoded.kind==K_BL_PREFIX || decoded.kind==K_BL_SUFFIX ||
            (front.thumb&&decoded.kind==K_UND) || (!front.thumb&&front.ins[31:28]==4'hf)) decoded.condition=4'he;
        decoded.reg_shift=decoded.kind==K_DP&&!front.ins[25]&&front.ins[4];
        decoded.tag[0]=bank({1'b0,front.ins[19:16]},front.mode);
        decoded.tag[1]=bank({1'b0,front.ins[3:0]},front.mode);
        decoded.tag[2]=bank(5'd27,front.mode);
        decoded.tag[3]=bank({1'b0,front.ins[15:12]},front.mode);
        decoded.dest[0]=decoded.tag[3];decoded.dest[1]=decoded.tag[0];
        decoded.first=1;decoded.last=1;
        decoded.left=front.nregs;decoded.remaining=front.rest;decoded.transfer_reg=front.first;
        decoded.wb_offset=front.ins[23] ? $signed({1'b0,front.nregs,2'b0}) : -$signed({1'b0,front.nregs,2'b0});
        decoded.offset=front.ins[23] ? (front.ins[24]?8'sd4:8'sd0) : decoded.wb_offset+(front.ins[24]?8'sd0:8'sd4);
        transfer_mode=front.ins[22]&&!(front.ins[20]&&front.list[15])?5'h10:front.mode;
        case (decoded.kind)
            K_DP: begin
                decoded.used[0]=front.ins[24:21]!=4'd13&&front.ins[24:21]!=4'd15;
                decoded.used[1]=!front.ins[25];decoded.used[2]=decoded.reg_shift;
                if (decoded.reg_shift) decoded.tag[2]=bank({1'b0,front.ins[11:8]},front.mode);
                if (front.ins[20]&&front.ins[15:12]==15) begin decoded.tag[3]=bank(5'd27,front.mode);decoded.used[3]=1;end
            end
            K_MRS:begin decoded.used[2]=1;if(!front.ins[22])decoded.tag[2]=6'd17;end
            K_MSR:begin decoded.used[1]=!front.ins[25];decoded.used[2]=front.ins[22];end
            K_BX:decoded.used[1]=1;
            K_MEM:begin decoded.used[0]=1;decoded.used[1]=front.ins[27:26]==1?front.ins[25]:!front.ins[22];decoded.used[3]=!front.ins[20];end
            K_BLOCK:begin
                decoded.tag[3]=bank({1'b0,front.first},transfer_mode);
                decoded.dest[0]=decoded.tag[3];decoded.used[0]=1;decoded.used[3]=!front.ins[20];
                decoded.last=front.nregs==1;
                decoded.used[2]=front.ins[20]&&front.ins[22]&&decoded.last&&front.first==15;
            end
            K_CP:decoded.used[3]=!front.ins[20];
            K_SWP:decoded.used=4'b0011;
            K_MUL,K_MULL:begin
                decoded.tag[2]=bank({1'b0,front.ins[11:8]},front.mode);
                decoded.used=4'b0110;
                if(front.ins[21])decoded.used=decoded.kind==K_MUL?4'b1110:4'b1111;
                if(decoded.kind==K_MUL)decoded.dest[0]=decoded.tag[0];
            end
            K_BRANCH,K_BL_PREFIX:decoded.dest[0]=bank(5'd14,front.mode);
            K_BL_SUFFIX:begin decoded.tag[0]=bank(5'd14,front.mode);decoded.used[0]=!front.paired;decoded.dest[0]=decoded.tag[0];end
            default:;
        endcase
        decoded.target=front.half_branch?thumb_target:arm_target;
        // Target selection has its own shallow class bits. It must not wait
        // for the complete ISA classifier (multiply, CP15, undefined, etc.).
        if (front.thumb&&front.raw[15:11]==5'b11110)decoded.target=prefix_sum;
        decoded.direct=front.ins[31:25]==7'b1110101&&!front.und;
        suffix_base=prefix_target;
        if (d2_valid && d2.kind==K_BL_PREFIX) suffix_base=d2.target;
        if (front.thumb&&front.raw[15:11]==5'b11111) begin
            decoded.target=suffix_sum;
            decoded.direct=!front.und&&front.paired && (prefix_valid || (d2_valid&&d2.kind==K_BL_PREFIX));
        end
        // A fetch fault is one exception record, independent of the invalid
        // instruction bits. It cannot wait for operands or expand a block.
        if(front.fault)begin decoded.direct=0;decoded.used=0;decoded.last=1;end
    end
    assign next_remaining=clear_first(d2.remaining);
    assign next_register=first16(d2.remaining[14:0]);
    assign taken_match=d2.p.pred_target=={d2.target[31:1],d2.p.thumb};
    assign fallthrough_match=d2.p.pred_target=={d2.p.next_pc[31:1],d2.p.thumb};
    assign kill_younger=i_flush||redirect_ff.valid;
    assign o_ready=count<2&&!kill_younger;
    assign accept=i_valid&&o_ready;
    assign fast_select=count==0&&!i_fault&&
        (i_thumb?raw_word[15:11]==5'b11100:i_word[31:25]==7'b1110101);
    assign shortcut=accept&&fast_select&&(!d2_valid||(step&&d2.last));
    assign push=accept&&!shortcut;
    assign new_d2=pop||shortcut;
    assign admitted=fast_select?fast_branch:decoded;
    assign late_redirect=step&&d2.direct&&!d2.redirected&&(!d2.p.predicted||!taken_match);
    assign o_hazard=d2_valid&&((d2.used[0]&&i_locked[d2.tag[0]]) ||
        (d2.used[1]&&i_locked[d2.tag[1]]) || (d2.used[2]&&i_locked[d2.tag[2]]) || (d2.used[3]&&i_locked[d2.tag[3]]));
    assign step=d2_valid&&(!out_valid||i_ready)&&!o_hazard&&!i_flush&&(!redirect_ff.valid||redirect_in_d2);
    assign pop=count!=0&&(!d2_valid||(step&&d2.last))&&!kill_younger;
    zap_register_file u_registers (
        .i_clk(i_clk),.i_reset(i_reset),.i_wen(i_wen),
        .i_wr_addr_a(i_wr_addr_a),.i_wr_addr_b(i_wr_addr_b),.i_wr_addr_c(i_wr_addr_c),
        .i_wr_data_a(i_wr_data_a),.i_wr_data_b(i_wr_data_b),.i_wr_data_c(i_wr_data_c),
        .i_rd_addr_a(d2.tag[0]),.i_rd_addr_b(d2.tag[1]),.i_rd_addr_c(d2.tag[2]),.i_rd_addr_d(d2.tag[3]),
        .o_rd_data_a(raw_values[0]),.o_rd_data_b(raw_values[1]),.o_rd_data_c(raw_values[2]),.o_rd_data_d(raw_values[3])
    );
    always_comb begin
        read_values=raw_values;
        // Same-edge RF write-through only: priority is C > B > A, as in ZAP.
        // No A/M producer search and no readiness logic in this data path.
        for (int n=0;n<4;n++) begin
            if(i_wen&&i_wr_addr_a[d2.tag[n]])read_values[n]=i_wr_data_a;
            if(i_wen&&i_wr_addr_b[d2.tag[n]])read_values[n]=i_wr_data_b;
            if(i_wr_addr_c[d2.tag[n]])read_values[n]=i_wr_data_c;
        end
    end
    always_ff @(posedge i_clk) begin
        if(i_reset) begin
            count<=0;head<=0;tail<=0;d2_valid<=0;out_valid<=0;redirect_ff.valid<=0;redirect_in_d2<=0;
            previous_prefix<=0;prefix_valid<=0;previous_next_pc<=0;prefix_target<=0;
            d2<=decoded_t'(0);issued<=decoded_t'(0);values<=0;matches_taken<=0;matches_fallthrough<=0;
            redirect_ff.target<=0;redirect_ff.thumb<=0;redirect_ff.link<=0;
            redirect_ff.pointer<=0;redirect_ff.count<=0;redirect_ff.action<=0;
        end else begin
            redirect_ff.valid<=0;redirect_in_d2<=0;
            if(i_ready)out_valid<=0;
            if(push)begin
                d1[tail]<=incoming;tail<=!tail;
            end
            if(accept)begin
                previous_prefix<=i_thumb&&!i_fault&&raw_word[15:11]==5'b11110;
                previous_next_pc<=incoming.next_pc;
            end
            if(pop)head<=!head;
            case({push,pop})2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:;endcase
            if(step)begin
                issued<=d2;values<=read_values;out_valid<=1;
                matches_taken<=taken_match;matches_fallthrough<=fallthrough_match;
                if(d2.kind==K_BL_PREFIX)begin prefix_target<=d2.target;prefix_valid<=!d2.p.fault;end
                else prefix_valid<=0;
                if(d2.last)d2_valid<=0;
                else begin
                    d2.first<=0;d2.left<=d2.left-1'b1;d2.last<=d2.left==2;
                    d2.remaining<=next_remaining;d2.transfer_reg<=next_register;d2.offset<=d2.offset+8'sd4;
                    d2.tag[3]<=bank({1'b0,next_register},d2.p.ins[22]&&!(d2.p.ins[20]&&d2.p.list[15])?5'h10:d2.p.mode);
                    d2.dest[0]<=bank({1'b0,next_register},d2.p.ins[22]&&!(d2.p.ins[20]&&d2.p.list[15])?5'h10:d2.p.mode);
                    d2.used[0]<=0;d2.used[2]<=d2.p.ins[20]&&d2.p.ins[22]&&d2.left==2&&next_register==15;
                end
                if(late_redirect)begin
                    redirect_ff.valid<=1;redirect_ff.target<=d2.target;redirect_ff.thumb<=d2.p.thumb;
                    redirect_ff.link<={d2.p.next_pc[31:1],d2.p.thumb};
                    redirect_ff.pointer<=d2.p.ras_pointer;redirect_ff.count<=d2.p.ras_count;
                    redirect_ff.action<=d2.kind==K_BL_SUFFIX||d2.p.ins[24]?2'd1:2'd0;
                end
            end
            if(new_d2)begin
                d2<=admitted;d2_valid<=1;
                if(admitted.direct&&!admitted.p.predicted&&!late_redirect)begin
                    d2.redirected<=1;redirect_in_d2<=1;
                    redirect_ff.valid<=1;redirect_ff.target<=admitted.target;redirect_ff.thumb<=admitted.p.thumb;
                    redirect_ff.link<={admitted.p.next_pc[31:1],admitted.p.thumb};
                    redirect_ff.pointer<=admitted.p.ras_pointer;redirect_ff.count<=admitted.p.ras_count;
                    redirect_ff.action<=admitted.kind==K_BL_SUFFIX||admitted.p.ins[24]?2'd1:2'd0;
                end
            end
            if(kill_younger)begin
                count<=0;head<=0;tail<=0;previous_prefix<=0;prefix_valid<=0;
                if(i_flush||!redirect_in_d2)d2_valid<=0;
            end
            if(i_flush)begin out_valid<=0;redirect_ff.valid<=0;end
        end
    end
    assign o_valid=out_valid;assign o_pc=issued.p.pc;assign o_instruction=issued.p.ins;
    assign o_mode=issued.p.mode;assign o_raw=issued.p.raw;
    assign o_pc_base=issued.p.pc_base;assign o_next_pc=issued.p.next_pc;
    assign o_thumb=issued.p.thumb;assign o_fault=issued.p.fault;assign o_force_align=issued.p.align_pc;
    assign o_kind=issued.kind;assign o_condition=issued.condition;assign o_reg_shift=issued.reg_shift;
    assign o_tag=issued.tag;assign o_used=issued.used;assign o_value=values;assign o_dest=issued.dest;
    assign o_first=issued.first;assign o_last=issued.last;assign o_reg_count=issued.p.nregs;
    assign o_offset=issued.offset;assign o_writeback_offset=issued.wb_offset;assign o_transfer_reg=issued.transfer_reg;
    assign o_branch_target=issued.target;assign o_direct=issued.direct;
    assign o_match_taken=matches_taken;assign o_match_fallthrough=matches_fallthrough;
    assign o_predicted=issued.p.predicted;assign o_pred_hit=issued.p.pred_hit;assign o_pred_target=issued.p.pred_target;
    assign o_pred_state=issued.p.pred_state;assign o_pred_kind=issued.p.pred_kind;
    assign o_ras_pointer=issued.p.ras_pointer;assign o_ras_count=issued.p.ras_count;
    assign o_redirect=redirect_ff.valid;
    assign o_redirect_thumb=redirect_ff.thumb;
    assign o_redirect_target=redirect_ff.target;
    assign o_redirect_link=redirect_ff.link;
    assign o_redirect_pointer=redirect_ff.pointer;
    assign o_redirect_count=redirect_ff.count;
    assign o_redirect_action=redirect_ff.action;
endmodule
