// SPDX-License-Identifier: GPL-3.0-or-later
module predict_tb;
    logic i_clk=0, i_reset=1, i_clear=0, i_lookup=0, i_thumb=0, i_accept=0;
    logic [31:0] i_pc=0, i_update_pc=0, i_update_target=0, i_repair_link=0;
    logic i_update=0, i_update_thumb=0, i_update_taken=1, i_update_hit=0, i_repair=0;
    logic [1:0] i_update_state=0, i_update_kind=0, i_repair_action=0;
    logic [2:0] i_repair_pointer=0;
    logic [3:0] i_repair_count=0;
    // VALID_BIT: the bench looks up i_pc itself, as a redirect candidate.
    parameter bit RAS_TOP_FF=0, VALID_BIT=0;
    wire [31:0] i_pc_redirect=i_pc, i_pc_sequential=32'd0;
    wire i_sel_redirect=1'b1, i_sel_predicted=1'b0;
    wire o_hit,o_taken;
    wire [31:0] o_target;
    wire [1:0] o_state,o_kind;
    wire [2:0] o_pointer;
    wire [3:0] o_count;
    arm9v2_predict #(.RAS_TOP_FF(RAS_TOP_FF),.VALID_BIT(VALID_BIT)) dut (.*);
    int checks=0;
    task automatic tick;
        #1; i_clk=1; #1; i_clk=0; #1;
    endtask
    task automatic check(input bit ok, input string label);
        checks++;
        assert(ok) else $fatal(1,"%s at check %0d",label,checks);
    endtask
    task automatic train(input logic [31:0] pc, target, input logic thumb=0,
                         input logic [1:0] kind=0);
        i_update=1; i_update_pc=pc; i_update_target=target;
        i_update_thumb=thumb; i_update_taken=1; i_update_hit=0; i_update_kind=kind;
        tick(); i_update=0;
    endtask
    task automatic lookup(input logic [31:0] pc, input logic thumb=0);
        i_pc=pc; i_thumb=thumb; i_lookup=1; tick(); i_lookup=0;
    endtask
    initial begin
        tick(); i_reset=0;
        lookup(32'h100); check(!o_hit && !o_taken,"reset miss");
        train(32'h100,32'h180);
        lookup(32'h100); check(o_hit && o_taken && o_target==32'h180 && o_state==2,"one-edge lookup");
        lookup(32'h300); check(!o_hit,"full source tag rejects index alias");
        lookup(32'h100,1); check(!o_hit,"source instruction state is tagged");
        // Same-edge write-first read must survive a disabled read clock.
        i_pc=32'h100; i_thumb=0; i_lookup=1;
        i_update=1; i_update_pc=32'h100; i_update_target=32'h1c0;
        tick(); i_lookup=0; i_update=0;
        check(o_taken && o_target==32'h1c0,"same-edge write-first");
        repeat(5) begin tick(); check(o_taken && o_target==32'h1c0,"collision output holds"); end
        train(32'h300,32'h400);
        check(o_taken && o_target==32'h1c0,"held output unaffected by later alias write");
        lookup(32'h100); check(!o_hit,"replacement observed on next lookup");
        // All counter transitions; payload and state are one coherent record.
        for (int state_n=0;state_n<4;state_n++) begin
            for(int taken_n=0;taken_n<2;taken_n++) begin
                i_update=1; i_update_pc=32'h100; i_update_target=32'h200;
                i_update_hit=1; i_update_state=2'(state_n); i_update_taken=1'(taken_n);
                tick(); i_update=0; lookup(32'h100);
                check(o_state==2'(taken_n != 0 ? (state_n==3?3:state_n+1) : (state_n==0?0:state_n-1)),"counter saturation");
                check(o_taken==o_state[1],"counter direction");
            end
        end
        // Exercise all indexes and high address bits independently of source code.
        for(int n=0;n<256;n++) train(32'hfe000000+32'(n*2),32'h20000000+32'(n*4),1'(n%2));
        for(int n=0;n<256;n++) begin
            lookup(32'hfe000000+32'(n*2),1'(n%2));
            check(o_taken && o_target==32'h20000000+32'(n*4),"all 256 entries");
        end
        i_clear=1; tick(); i_clear=0;
        check(!o_hit && o_count==0,"clear invalidates held entry and RAS");
        lookup(32'hfe000000);
        train(32'hfe000000,32'h9000);
        check(!o_hit,"held miss cannot become valid on later feedback");
        lookup(32'hfe000000);
        check(o_hit && o_target==32'h9000,"fresh lookup sees feedback after held miss");
        train(32'h400,32'h888,0,2);
        lookup(32'h400); check(o_taken && o_kind==2 && o_target==32'h888,"empty RAS uses checked BTB fallback");
        for(int n=0;n<10;n++) begin
            train(32'h100+32'(n*4),32'h800,0,1);
            lookup(32'h100+32'(n*4)); i_accept=1; tick(); i_accept=0;
            check(o_count==4'(n<8?n+1:8),"RAS bounded depth");
        end
        for(int n=9;n>=2;n--) begin
            lookup(32'h400);
            check(o_target==32'h104+32'(n*4),"RAS newest first after wrap");
            i_accept=1; tick(); i_accept=0;
        end
        check(o_count==0 && o_pointer==2,"RAS underflow guard");
        lookup(32'h400); i_accept=1; tick(); i_accept=0;
        check(o_count==0 && o_pointer==2,"empty return holds pointer");
        i_repair=1; i_repair_pointer=3; i_repair_count=2; i_repair_action=1; i_repair_link=32'h1235;
        // A cold direct redirect now launches its target on this repair edge.
        i_lookup=1;i_pc=32'h400;i_thumb=0;
        tick(); i_repair=0;i_lookup=0;
        check(o_taken&&o_target==32'h1235&&o_pointer==4&&o_count==3,
              "target lookup concurrent with call repair sees new RAS top");
        lookup(32'h400); check(o_target==32'h1235 && o_count==3 && o_pointer==4,"repair and actual call");
        i_repair=1; i_repair_pointer=4; i_repair_count=3; i_repair_action=2;
        tick(); i_repair=0; check(o_count==2 && o_pointer==3,"repair and actual return");
        train(32'h102,32'h801,1,1);
        lookup(32'h102,1); i_accept=1; tick(); i_accept=0;
        lookup(32'h400); check(o_target==32'h105,"Thumb link keeps state and halfword PC");
        i_clear=1; i_update=1; tick(); i_clear=0; i_update=0;
        lookup(32'h102,1); check(!o_hit && o_count==0,"clear wins simultaneous feedback");
        // BTB invalidation can accompany W recovery (CP15/MSR). The
        // checkpoint repair wins for the RAS, and its own action occurs once.
        i_clear=1;i_repair=1;i_repair_pointer=2;i_repair_count=2;
        i_repair_action=1;i_repair_link=32'h4567;i_accept=1;
        tick();i_clear=0;i_repair=0;i_accept=0;
        check(!o_hit&&o_pointer==3&&o_count==3,"clear plus call repair restores checkpoint once");
        train(32'h400,32'h888,0,2);lookup(32'h400);
        check(o_target==32'h4567,"call repair preserves its link across BTB invalidation");
        i_clear=1;i_repair=1;i_repair_pointer=3;i_repair_count=3;i_repair_action=2;i_accept=1;
        tick();i_clear=0;i_repair=0;i_accept=0;
        check(!o_hit&&o_pointer==2&&o_count==2,"clear plus return repair pops once");
        i_clear=1;i_repair=1;i_repair_pointer=5;i_repair_count=4;i_repair_action=0;
        tick();i_clear=0;i_repair=0;
        check(o_pointer==5&&o_count==4,"serial recovery preserves pre-instruction checkpoint");
        $display("PASS predictor: %0d checks",checks); $finish;
    end
endmodule
