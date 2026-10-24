// SPDX-License-Identifier: GPL-3.0-or-later
`include "zap_defines.svh"
module tb_cache_metadata #(
    parameter integer CACHE_SIZE = 8192,
    parameter bit SHORT_READ = 0,
    parameter bit PREFETCH = 0
);
    localparam integer CACHE_LINE = 16, WAYS = 2;
    localparam integer SETS = CACHE_SIZE / WAYS / CACHE_LINE;
    localparam integer WAY_BYTES = CACHE_SIZE / WAYS;
    logic clk=0, reset=1, hold=0, enabled=1, idle=0, access_en=0;
    logic accepted=0, accepted_way=0;
    logic [31:0] accepted_address=0;
    logic [31:0] address=0, lookup=0, next_address=0;
    logic tag_we=0, dirty=0, way=0;
    logic [`ZAP_CACHE_TAG_WDT-1:0] tag_data=0, tag_out;
    logic [127:0] line_data=0;
    logic [15:0] ben=0;
    logic hit, hit_dirty, victim_valid, victim_dirty, selected;
    logic pf_hit;
    logic inv=0, inv_done, clean=0, clean_done;
    logic line_req=0, line_done, line_va=1, line_way=0;
    logic [1:0] line_op=0;
    logic [31:0] line_addr=0;
    logic bus_req;
    logic [31:0] bus_addr, bus_data;
    logic [2:0] bus_cti;
    int beats=0;
    zap_cache_tag_ram #(.CACHE_SIZE(CACHE_SIZE), .CACHE_LINE(CACHE_LINE), .WAYS(WAYS),
        .SHORT_READ(SHORT_READ), .ACCEPTED_HIT_UPDATE(SHORT_READ), .PREFETCH(PREFETCH)) dut (
        .i_clk(clk), .i_reset(reset), .i_hold(hold), .i_cache_en(enabled),
        .i_address_nxt(next_address), .i_address(address), .i_lookup_address(lookup),
        .i_lookup_check_address(lookup), .i_lookup_stall(1'b1),
        .i_access(access_en), .i_idle(idle), .i_accepted_hit(accepted),
        .i_accepted_address(accepted_address), .i_accepted_way(accepted_way),
        .i_cache_tag_wr_en(tag_we), .i_cache_tag(tag_data), .i_cache_tag_dirty(dirty),
        .i_cache_way(way), .i_cache_line(line_data), .i_cache_line_ben(ben),
        .o_cache_hit(hit), .o_cache_hit_dirty(hit_dirty), .o_cache_way(selected),
        .o_cache_tag(tag_out), .o_cache_tag_valid(victim_valid), .o_cache_tag_dirty(victim_dirty),
        .i_cache_inv_req(inv), .o_cache_inv_done(inv_done),
        .i_cache_clean_req(clean), .o_cache_clean_done(clean_done),
        .i_line_req(line_req), .i_line_op(line_op), .i_line_va(line_va),
        .i_line_addr(line_addr), .i_line_way(line_way), .o_line_done(line_done),
        .i_pf_addr(next_address), .o_pf_hit(pf_hit), .i_wb_dat(32'd0), .i_wb_ack(bus_req),
        .o_wb_stb_ff(bus_req), .o_wb_adr_ff(bus_addr), .o_wb_dat_ff(bus_data), .o_wb_cti_ff(bus_cti)
    );
    task automatic tick;
        #1;
        if (bus_req) begin
            assert (bus_data == (32'hcafe0000 | (bus_addr & 32'hf))) else
                $fatal(1, "maintenance wrote wrong data %h at %h", bus_data,bus_addr);
            beats++;
        end
        clk=1; #1; clk=0; #1;
    endtask
    task automatic settle(input logic[31:0] a);
        next_address=a; lookup=a;
        repeat(SHORT_READ ? 1 : 3) tick();
    endtask
    task automatic install(input logic[31:0] a, input bit w, input bit d);
        address=a; way=w; dirty=d; idle=0; tag_we=1; ben='1;
        tag_data[`ZAP_CACHE_TAG__TAG]=a[`ZAP_VA__CACHE_TAG];
        tag_data[`ZAP_CACHE_TAG__PA]=a[31:4];
        line_data={32'hcafe000c,32'hcafe0008,32'hcafe0004,32'hcafe0000};
        tick(); tag_we=0; ben=0;
    endtask
    task automatic touch(input logic[31:0] a, input bit w);
        if (SHORT_READ) begin
            // Accepted HUM response is independent of a younger held probe.
            next_address=a+16; lookup=a+16; tick();
            hold=1; accepted_address=a; accepted_way=w; accepted=1;
            tick(); accepted=0; hold=0;
        end else begin
            settle(a); access_en=1; tick(); access_en=0;
        end
    endtask
    task automatic line_operation(input logic[31:0] a, input logic[1:0] op);
        line_addr=a; line_op=op; line_req=1;
        for(int n=0;n<64;n++) begin
            tick(); if(line_done) break;
            assert(n<63) else $fatal(1,"line maintenance timeout");
        end
        line_req=0; tick();
    endtask
    initial begin
        tick(); reset=0;
        tick();
        settle(32'h10000); assert(!hit) else $fatal(1,"reset valid");
        // Same-edge install/read, then immediate hit and dirty forwarding.
        next_address=32'h10000; lookup=32'h10000;
        install(32'h10000,0,1);
        repeat(SHORT_READ ? 0 : 2) tick();
        assert(hit && hit_dirty && selected==0) else $fatal(1,"immediate dirty install hit");
        install(32'h10000+WAY_BYTES,1,0);
        settle(32'h10000+2*WAY_BYTES);
        assert(!hit && victim_valid && selected==0 && victim_dirty) else $fatal(1,"dirty eviction metadata");
        // Accepted way-zero hit must make way one the victim even when the
        // short RAM probe addresses a different set and the port is held.
        touch(32'h10000,0);
        settle(32'h10000+2*WAY_BYTES);
        assert(selected==1 && !victim_dirty) else $fatal(1,"accepted-hit LRU update lost");
        // Consecutive clean/dirty tag updates model WT then WB stores.
        // The very next eviction query must see the new dirty bit and LRU.
        settle(32'h10000); address=32'h10000; idle=1; tag_we=1;
        tag_data[`ZAP_CACHE_TAG__TAG]=address[`ZAP_VA__CACHE_TAG];
        tag_data[`ZAP_CACHE_TAG__PA]=address[31:4];
        dirty=0; tick(); dirty=1; tick(); tag_we=0; idle=0;
        settle(32'h10000+2*WAY_BYTES);
        assert(selected==1 && !victim_dirty) else $fatal(1,"dirty mark changed wrong victim");
        touch(32'h10000+WAY_BYTES,1);
        settle(32'h10000+2*WAY_BYTES);
        assert(selected==0 && victim_dirty) else $fatal(1,"dirty mark lost before eviction");
        if (SHORT_READ) begin
            install(32'h10020+WAY_BYTES,1,0); settle(32'h10020);
            accepted=1; accepted_address=32'h10000; accepted_way=0;
            install(32'h10020,0,0);
            repeat(3) tick();
            settle(32'h10020+2*WAY_BYTES);
            assert(selected==1) else $fatal(1,"coincident fill/accepted-hit LRU lost");
            accepted=0; repeat(3) tick();
            assert(selected==1) else $fatal(1,"deferred LRU drain changed victim");
        end
        // The first dirty update in a group must not dirty its neighbours.
        for(int n=1;n<17;n++) begin
            install(32'h10000+32'(16*n),0,n==16);
        end
        settle(32'h10010); assert(hit && !hit_dirty) else $fatal(1,"dirty bank initialization");
        if(PREFETCH) assert(pf_hit) else $fatal(1,"prefetch valid copy missed install");
        settle(32'h10100); assert(hit && hit_dirty) else $fatal(1,"second dirty group");
        // Line clean keeps valid; line invalidate clears valid and dirty.
        beats=0; line_operation(32'h10000,2'b01);
        assert(beats==4) else $fatal(1,"single clean beat count %0d",beats);
        settle(32'h10000); assert(hit && !hit_dirty) else $fatal(1,"single clean metadata");
        line_operation(32'h10000,2'b10);
        settle(32'h10000); assert(!hit) else $fatal(1,"single invalidate metadata");
        beats=0; clean=1;
        for(int n=0;n<4*SETS;n++) begin
            tick(); if(clean_done) break;
            assert(n<4*SETS-1) else $fatal(1,"whole clean timeout");
        end
        clean=0; tick();
        assert(beats==4) else $fatal(1,"whole clean beat count %0d",beats);
        settle(32'h10100); assert(hit && !hit_dirty) else $fatal(1,"whole clean metadata");
        // Whole invalidate retains its single-cycle completion. The next
        // install must not revive any of the old bits in its group.
        inv=1; tick();
        assert(inv_done) else $fatal(1,"invalidate completion delayed");
        tick();
        inv=0; settle(32'h10000+WAY_BYTES);
        assert(!hit) else $fatal(1,"lookup immediately after invalidate hit");
        settle(32'h10100); assert(!hit) else $fatal(1,"invalidate missed another set");
        install(32'h10020,0,0); settle(32'h10020);
        assert(hit) else $fatal(1,"first install after invalidate");
        settle(32'h10010); assert(!hit) else $fatal(1,"dead group neighbour revived");
        for(int round=0;round<6;round++) begin
            inv=1; tick(); tick(); inv=0;
            install(32'h10000+32'(16*(round%4)),0,0);
            settle(32'h10000+32'(16*(round%4)));
            assert(hit) else $fatal(1,"group reinitialization lost install");
            settle(32'h10000+32'(16*((round+1)%4)));
            assert(!hit) else $fatal(1,"stale group bit resurrected");
            if(PREFETCH) assert(!pf_hit) else $fatal(1,"stale prefetch group bit");
        end
        // Disable/re-enable also removes old lines; soft reset reinitializes
        // dirty groups without relying on power-up RAM contents.
        install(32'h10000,0,1); settle(32'h10000);
        enabled=0; tick(); enabled=1;
        settle(32'h10000); assert(!hit) else $fatal(1,"disable retained valid");
        reset=1; tick(); reset=0; tick();
        install(32'h10010,0,0); settle(32'h10010);
        assert(hit && !hit_dirty) else $fatal(1,"reset dirty group stale");
        reset=1; tick(); reset=0;
        repeat(4) begin
            tick(); assert(!hit) else $fatal(1,"soft reset revived a live lookup");
        end
        install(32'h10010,0,1); hold=1; reset=1; tick(); reset=0; hold=0;
        repeat(4) begin
            tick(); assert(!hit) else $fatal(1,"held-port reset revived a lookup");
        end
        $display("PASS metadata size=%0d short=%0d",CACHE_SIZE,SHORT_READ);
        $finish;
    end
endmodule
