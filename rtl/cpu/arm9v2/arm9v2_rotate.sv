// SPDX-License-Identifier: GPL-3.0-or-later
// One 32-bit ROR network, with parallel masks/fill/carry for all ARM shifts.
// o_preserve lets A use its ordered flags instead of sending A flags through S.
// o_rrx lets A insert its latest C into bit 31 after the S/A boundary.
module arm9v2_rotate (
    input logic [31:0] i_value,
    input logic [7:0] i_amount,
    input logic [1:0] i_type,
    input logic i_register, i_carry,
    output logic [31:0] o_value,
    output logic o_carry, o_preserve, o_rrx
);
    wire [4:0] amount=i_type==0 ? -i_amount[4:0] : i_amount[4:0];
    wire [31:0] stage[0:5];
    assign stage[0]=i_value;
    for(genvar sa_rot_stage=0;sa_rot_stage<5;sa_rot_stage++)begin:g_rotate
        for(genvar sa_rot_bit=0;sa_rot_bit<32;sa_rot_bit++)begin:g_bit
            assign stage[sa_rot_stage+1][sa_rot_bit]=amount[sa_rot_stage]?stage[sa_rot_stage][(sa_rot_bit+(1<<sa_rot_stage))%32]:stage[sa_rot_stage][sa_rot_bit];
        end
    end
    wire [31:0] left_mask=32'hffffffff<<i_amount[4:0];
    wire [31:0] right_mask=32'hffffffff>>i_amount[4:0];
    always_comb begin
        o_preserve=0;o_rrx=0;
        case(i_type)
            0:begin o_value=stage[5]&left_mask;o_carry=stage[5][0];end
            1:begin o_value=stage[5]&right_mask;o_carry=stage[5][31];end
            2:begin o_value=(stage[5]&right_mask)|({32{i_value[31]}}&~right_mask);o_carry=stage[5][31];end
            default:begin o_value=stage[5];o_carry=stage[5][31];end
        endcase
        if(i_amount==0)begin
            o_value=i_value;o_carry=i_carry;o_preserve=1;
            if(!i_register)case(i_type)
                1:begin o_value=0;o_carry=i_value[31];o_preserve=0;end
                2:begin o_value={32{i_value[31]}};o_carry=i_value[31];o_preserve=0;end
                3:begin o_value={i_carry,i_value[31:1]};o_carry=i_value[0];o_preserve=0;o_rrx=1;end
                default:;
            endcase
        end else if(i_type!=3&&|i_amount[7:5])begin
            o_value=i_type==2 ? {32{i_value[31]}} : 32'd0;
            o_carry=i_type==2 ? i_value[31] : i_amount==32 ?
                    (i_type==0 ? i_value[0] : i_value[31]) : 1'b0;
        end
    end
endmodule
