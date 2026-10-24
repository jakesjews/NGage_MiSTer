module destination_miter(input [31:0] ins, input [4:0] raw_class,mode,nregs,
input thumb,und, input [3:0] first, input list_pc, output ok);
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
    function automatic [5:0] destination0(input packet_t p);
        logic valid_class,half_link,block,multiply,branch,spsr;
        logic unused_packet;
        logic [4:0] block_mode;
        unused_packet=&{1'b0,p};
        valid_class=!p.und&&(p.thumb||p.ins[31:28]!=4'hf)&&
            !(p.thumb&&p.raw[15:11]==5'b11101);
        half_link=p.thumb&&(p.raw[15:11]==5'b11110||p.raw[15:11]==5'b11111);
        block=valid_class&&!half_link&&p.ins[27:25]==3'b100&&p.nregs!=0;
        multiply=valid_class&&!half_link&&(p.ins&32'h0fc000f0)==32'h00000090;
        branch=valid_class&&(half_link||p.ins[27:25]==3'b101);
        spsr=valid_class&&!half_link&&p.ins[22]&&p.mode!=5'h10&&p.mode!=5'h1f&&
            ((p.ins&32'h0fb0fff0)==32'h0120f000||(p.ins&32'h0fb0f000)==32'h0320f000);
        block_mode=p.ins[22]&&!(p.ins[20]&&p.list[15])?5'h10:p.mode;
        return (bank({1'b0,p.ins[15:12]},p.mode)&{6{!(block||multiply||branch||spsr)}})|
            (bank({1'b0,p.first},block_mode)&{6{block}})|
            (bank({1'b0,p.ins[19:16]},p.mode)&{6{multiply}})|
            (bank(5'd14,p.mode)&{6{branch}})|(bank(5'd27,p.mode)&{6{spsr}});
    endfunction
packet_t p;
logic [5:0] reference;
logic [3:0] kind;
always_comb begin
p='0;p.ins=ins;p.raw[15:11]=raw_class;p.mode=mode;p.nregs=nregs;
p.thumb=thumb;p.und=und;p.first=first;p.list[15]=list_pc;
kind=classify(ins,raw_class,thumb,und,mode==5'h10,nregs==0);
reference=bank({1'b0,ins[15:12]},mode);
case(kind)
K_BLOCK:reference=bank({1'b0,first},ins[22]&&!(ins[20]&&list_pc)?5'h10:mode);
K_MUL:reference=bank({1'b0,ins[19:16]},mode);
K_BRANCH,K_BL_PREFIX,K_BL_SUFFIX:reference=bank(5'd14,mode);
K_MSR:if(ins[22]&&mode!=5'h10&&mode!=5'h1f)reference=bank(5'd27,mode);
default:;
endcase
end
assign ok=reference==destination0(p);
endmodule
