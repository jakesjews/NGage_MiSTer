// SPDX-License-Identifier: GPL-3.0-or-later
module execute_leaf_tb;
    logic [31:0] x,y,reference_value;
    logic [7:0] amount;
    logic [1:0] kind;
    logic reg_amount,carry,out_carry,preserve,rrx,reference_carry;
    logic [3:0][31:0] value,forwarded;
    logic [3:0][5:0] tag;
    logic [3:0] used;
    logic [2:0][1:0][31:0] pv;
    logic [2:0][1:0][5:0] pt;
    logic [2:0][1:0] valid;
    arm9v2_rotate rotate(.i_value(x),.i_amount(amount),.i_type(kind),.i_register(reg_amount),
        .i_carry(carry),.o_value(y),.o_carry(out_carry),.o_preserve(preserve),.o_rrx(rrx));
    arm9v2_forward forward(.i_value(value),.i_tag(tag),.i_used(used),
        .i_producer_value(pv),.i_producer_tag(pt),.i_producer_valid(valid),.o_value(forwarded));
    // Independently exercised legacy ARM shifter is the shift oracle, not
    // another copy of the new rotator/mask implementation.
    arm9_shift reference(.i_value(x),.i_amount(amount),.i_type(kind),.i_register(reg_amount),
        .i_carry(carry),.o_value(reference_value),.o_carry(reference_carry));
    int checks=0;
    task automatic check(input bit ok,input string message);
        checks++;assert(ok)else $fatal(1,"%s check=%0d x=%h n=%0d kind=%0d reg=%0d C=%0d got=%h/%0d want=%h/%0d",message,checks,x,amount,kind,reg_amount,carry,y,out_carry,reference_value,reference_carry);
    endtask
    initial begin
        logic [31:0] state;
        state=32'hd91353a7;x=0;amount=0;kind=0;reg_amount=0;carry=0;
        value=0;tag=0;used=0;pv=0;pt=0;valid=0;
        for(int sample=0;sample<128;sample++)begin
            state=state^(state<<13);state=state^(state>>17);state=state^(state<<5);
            case(sample)0:x=0;1:x='1;2:x=32'h80000000;3:x=1;default:x=state;endcase
            for(int mode=0;mode<2;mode++)for(int c=0;c<2;c++)
                for(int k=0;k<4;k++)for(int n=0;n<(mode==0?32:256);n++)begin
                    kind=2'(k);amount=8'(n);reg_amount=1'(mode);carry=1'(c);#1;
                    check(y==reference_value&&out_carry==reference_carry,"single rotator matches ARM shift semantics");
                    check(preserve==(n==0&&(mode!=0||k==0)),"carry preserve token");
                    check(rrx==(mode==0&&k==3&&n==0),"RRX token");
                end
        end
        // All six producer lanes can collide. Invalid (condition-failed)
        // younger writers must expose the newest older valid value.
        for(int s=0;s<4;s++)begin value[s]=32'h100+32'(s);tag[s]=6'(s);end
        for(int p=0;p<3;p++)for(int lane=0;lane<2;lane++)pv[p][lane]=32'h200+32'(p*2+lane);
        for(int source=0;source<4;source++)for(int mask=0;mask<64;mask++)begin
            logic [31:0] expected;
            used='1;valid=6'(mask);pt='0;
            for(int p=0;p<3;p++)for(int lane=0;lane<2;lane++)pt[p][lane]=6'(source);
            expected=value[source];
            for(int p=2;p>=0;p--)for(int lane=0;lane<2;lane++)if(valid[p][lane])expected=pv[p][lane];
            #1;check(forwarded[source]==expected,"A/M/W age and lane priority");
            for(int s=0;s<4;s++)if(s!=source)check(forwarded[s]==value[s],"nonmatching physical tag");
            used=0;#1;check(forwarded==value,"unused sources ignore producers");
        end
        $display("PASS S/A leaves: %0d checks",checks);$finish;
    end
endmodule
