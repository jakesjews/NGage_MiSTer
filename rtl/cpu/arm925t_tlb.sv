//
// (C)2016-2024 Revanth Kamaraj (krevanth) <revanth91kamaraj@gmail.com>
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation; either version 3
// of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
// 02110-1301, USA.
//
// Part of the N-Gage QD core's ARM925T (rtl/cpu). Derived from ZAP's
// zap_tlb.sv; the changes made for this core are marked "ARM925T:"
// and are listed in rtl/cpu/NOTICE and docs/CPU.md.
//
// TLB management unit. The TLB units use single cycle
// clearing memories since TLBs are shallow.
//

module arm925t_tlb #(

parameter logic [31:0] LPAGE_TLB_ENTRIES   = 32'd32,
parameter logic [31:0] SPAGE_TLB_ENTRIES   = 32'd256,
parameter logic [31:0] SECTION_TLB_ENTRIES = 32'd64,
parameter logic [31:0] FPAGE_TLB_ENTRIES   = 32'd64,
parameter logic [31:0] CPSR_MODE           = 32'd4,
// ARM925T: the small-page TLB is SPAGE_TLB_WAYS-way set-associative (1, 2
// or 4 ways of SPAGE_TLB_ENTRIES sets each, indexed by VA[19:12] upward as
// before). The ARM925T's TLBs are fully associative, so two pages never
// evict each other there; in one way, two pages with the same index do at
// every access in turn, a two-level walk each time. EKA1 puts every chunk
// on a megabyte boundary, so pages at the same offset in two chunks (a
// bitmap and a stack, two heaps) have the same index; the phone's 2D
// drawing ran at 60 to 85 % of the phone's rate, by where its buffers lay
// (docs/PROGRESS-LOG.md, 2026-11-15). The victim of a set is its ways in
// turn (a pointer per set), so a set keeps the last SPAGE_TLB_WAYS pages
// installed in it, and after an invalidation every way is used before any
// is replaced.
parameter logic [31:0] SPAGE_TLB_WAYS      = 32'd2,
// ARM925T, the pipeline's D side (its check address is the next request's, not the
// cache's i_address, and it looks up speculatively every clock):
//  * the TLB RAMs read through holds, so the first check after a hold
//    sees the lookup address's entry, not the read made before the hold;
//  * a walk is for the address whose check missed (o_walk_va), not for
//    i_address (W's address, possibly a non-memory instruction's);
//  * after an install, no walk starts until the check has registered
//    again (the check registered in the install clock used older data);
//    the TLB stays busy meanwhile.
parameter logic CHECK_WALK = 1'b0,
parameter logic        MMU_OFF_CACHEABLE   = 1'd0     // ARM925T: see arm925t_tlb_check

) (

// Clock and reset.
input   logic            i_clk,
input   logic            i_reset,

// From cache FSM (processor)
input   logic    [31:0]  i_address,
input   logic    [31:0]  i_address_check,
input   logic            i_wr_check,
input   logic            i_rd_check,
input   logic    [31:0]  i_address_nxt,

// Hold input
input   logic            i_hold,

// CPSR, SR, DAC register.
input   logic    [CPSR_MODE:0] i_cpsr,
input   logic    [1:0]   i_sr,
input   logic    [31:0]  i_dac_reg,
input   logic    [31:0]  i_baddr,

// From CP15.
input   logic            i_mmu_en,
input   logic            i_inv,

// To cache FSM.
output  logic    [31:0]  o_phy_addr,
output  logic    [7:0]   o_fsr,
output  logic    [31:0]  o_far,
output  logic            o_fault,
output  logic            o_cacheable,
output  logic            o_bufferable,
output  logic            o_wt,          // ARM925T: write-through page (C=1 B=0).
output  logic            o_busy,
output logic             o_hit_ready,
output  logic            o_hit_ok,      // ARM925T: registered check, independent of walker IDLE.
output  logic            o_hit_ok_short, // ARM925T: o_hit_ok's unretimed copy (arm925t_tlb_check)
input   logic            i_idle,
input   logic            i_access_done,
input   logic            i_access,

// Wishbone memory interface - Needs to go through some OR gates.
output logic             o_wb_stb_nxt,
output logic             o_wb_cyc_nxt,
output logic [31:0]      o_wb_adr_nxt,
output logic             o_wb_wen_nxt,
output logic [3:0]       o_wb_sel_nxt,
input  logic [31:0]      i_wb_dat,
output logic [31:0]      o_wb_dat_nxt,
input  logic             i_wb_ack,
input  logic             i_wb_err

);

// ----------------------------------------------------------------------------

assign o_wb_dat_nxt = 32'd0;

`include "arm925t_localparams.svh"
`include "arm925t_defines.svh"

logic [`ARM925T_SECTION_TLB_WDT-1:0]     setlb_wdata, setlb_rdata, setlb_rdata_pre;
logic [`ARM925T_LPAGE_TLB_WDT-1:0]       lptlb_wdata, lptlb_rdata, lptlb_rdata_pre;
logic [`ARM925T_SPAGE_TLB_WDT-1:0]       sptlb_wdata;
logic [SPAGE_TLB_WAYS-1:0][`ARM925T_SPAGE_TLB_WDT-1:0] sptlb_rdata, sptlb_rdata_pre;
logic [`ARM925T_FPAGE_TLB_WDT-1:0]       fptlb_wdata, fptlb_rdata, fptlb_rdata_pre;

logic                            sptlb_wen, lptlb_wen, setlb_wen;
logic                            lptlb_ren, setlb_ren;
logic                            lptlb_ren_pre, setlb_ren_pre;
logic [SPAGE_TLB_WAYS-1:0]       sptlb_ren, sptlb_ren_pre, sptlb_wen_way;
logic                            fptlb_ren, fptlb_ren_pre, fptlb_wen;
logic                            walk;
logic [31:0]                     walk_va;
logic                            fsm_busy, check_stale;
logic [7:0]                      fsr;
logic [31:0]                     far;
logic                            cacheable;
logic                            wt;           // ARM925T
logic [31:0]                     phy_addr;
logic [31:0]                     tlb_address;
logic                            u0, u1, u2, u3, u4, u5;
logic                            unused;

// ----------------------------------------------------------------------------

function automatic [31:0] max ( input [31:0] a, b, c, d );
             if ( a >= b && a >= c && a >= d )                max = a;
        else if ( b >= a && b >= c && b >= d )                max = b;
        else if ( c >= a && c >= b && c >= d )                max = c;
        else                                                  max = d;
endfunction

// U0 generation.
if      ( 10+$clog2(FPAGE_TLB_ENTRIES) == 11 )
begin: l_two_fp
        assign u0 = i_address_nxt[11];
end
else
begin: l_more_than_two_fp
        assign u0 = 1'd0;
end

// U1 generation.
if      ( 12+$clog2(SPAGE_TLB_ENTRIES) == 13 )
begin: l_two_sp
        assign u1 = |i_address_nxt[15:13];
end
else if ( 12+$clog2(SPAGE_TLB_ENTRIES) == 14 )
begin: l_four_sp
        assign u1 = |i_address_nxt[15:14];
end
else if ( 12+$clog2(SPAGE_TLB_ENTRIES) == 15 )
begin: l_eight_sp
        assign u1 = i_address_nxt[15];
end
else
begin: l_more_than_eight_sp
        assign u1 = 1'd0;
end

// U2 generation
if      ( 16+$clog2(LPAGE_TLB_ENTRIES) == 17 )
begin: l_two_lp
        assign u2 = |i_address_nxt[19:17];
end
else if ( 16+$clog2(LPAGE_TLB_ENTRIES) == 18 )
begin: l_four_lp
        assign u2 = |i_address_nxt[19:18];
end
else if ( 16+$clog2(LPAGE_TLB_ENTRIES) == 19 )
begin: l_eight_lp
        assign u2 = i_address_nxt[19];
end
else
begin: l_more_than_eight_lp
        assign u2 = 1'd0;
end

///////////////////////////////////////////////////////////////////////////////

// U3 generation.
if      ( 10+$clog2(FPAGE_TLB_ENTRIES) == 11 )
begin: l_two_fp_tlb
        assign u3 = tlb_address[11];
end
else
begin: l_more_than_two_fp_tlb
        assign u3 = 1'd0;
end

// U4 generation
if      ( 12+$clog2(SPAGE_TLB_ENTRIES) == 13 )
begin: l_two_sp_tlb
        assign u4 = |tlb_address[15:13];
end
else if ( 12+$clog2(SPAGE_TLB_ENTRIES) == 14 )
begin: l_four_sp_tlb
        assign u4 = |tlb_address[15:14];
end
else if ( 12+$clog2(SPAGE_TLB_ENTRIES) == 15 )
begin: l_eight_sp_tlb
        assign u4 = tlb_address[15];
end
else
begin: l_more_than_eight_sp_tlb
        assign u4 = 1'd0;
end

// U5 generation.
if      ( 16+$clog2(LPAGE_TLB_ENTRIES) == 17 )
begin: l_two_lp_tlb
        assign u5 = |tlb_address[19:17];
end
else if ( 16+$clog2(LPAGE_TLB_ENTRIES) == 18 )
begin: l_four_lp_tlb
        assign u5 = |tlb_address[19:18];
end
else if ( 16+$clog2(LPAGE_TLB_ENTRIES) == 19 )
begin: l_eight_lp_tlb
        assign u5 = tlb_address[19];
end
else
begin: l_more_than_eight_lp_tlb
        assign u5 = 1'd0;
end

// -----------------------------------------------------------------------------

localparam [31:0] W = max (
        20+$clog2(SECTION_TLB_ENTRIES),
        16+$clog2(LPAGE_TLB_ENTRIES),
        12+$clog2(SPAGE_TLB_ENTRIES),
        10+$clog2(FPAGE_TLB_ENTRIES)
);

assign unused = |{i_address_nxt[9:0], tlb_address[9:0], i_address_nxt[31:W],
                       tlb_address[31:W], u0, u1, u2, u3, u4, u5,
                       setlb_rdata, sptlb_rdata, lptlb_rdata, fptlb_rdata,
                       setlb_ren, sptlb_ren, lptlb_ren, fptlb_ren
                       };

// ----------------------------------------------------------------------------

arm925t_tlb_buffer #(.WIDTH(`ARM925T_SECTION_TLB_WDT), .DEPTH(SECTION_TLB_ENTRIES), .READ_THROUGH(CHECK_WALK))
u_section_tlb (
.i_clk          (i_clk),
.i_reset        (i_reset),
.i_clken        (!i_hold),

.i_wdata        (setlb_wdata),
.i_wen          (setlb_wen),

.i_inv          (i_inv | !i_mmu_en),

.i_raddr        (i_address_nxt[`ARM925T_VA__SECTION_INDEX]),
.i_waddr        (tlb_address[`ARM925T_VA__SECTION_INDEX]),

.o_rdata        (setlb_rdata),
.o_rdav         (setlb_ren),

.o_rdata_pre    (setlb_rdata_pre),
.o_rdav_pre     (setlb_ren_pre)
);

// ----------------------------------------------------------------------------

arm925t_tlb_buffer #(.WIDTH(`ARM925T_LPAGE_TLB_WDT), .DEPTH(LPAGE_TLB_ENTRIES), .READ_THROUGH(CHECK_WALK))
u_lpage_tlb   (
.i_clk          (i_clk),
.i_reset        (i_reset),
.i_clken        (!i_hold),

.i_wdata        (lptlb_wdata),
.i_wen          (lptlb_wen),

.i_inv          (i_inv | !i_mmu_en),

.i_raddr        (i_address_nxt[`ARM925T_VA__LPAGE_INDEX]),
.i_waddr        (tlb_address[`ARM925T_VA__LPAGE_INDEX]),

.o_rdata        (lptlb_rdata),
.o_rdav         (lptlb_ren),

.o_rdata_pre    (lptlb_rdata_pre),
.o_rdav_pre     (lptlb_ren_pre)
);

// ----------------------------------------------------------------------------

// ARM925T: the small-page ways. The way an install goes to is the set's
// pointer, read into a register while the walk runs (the walker's address
// is fixed from the walk's start, clocks before the install) and stepped
// by the install.
// The pointer is two bits a set, in two vectors (no multiply in the index).
//
// A page walked again while it is in the set goes back to the way it has:
// the instruction side walks a page twice in a row (its next fetch address
// was checked in the clock of the install, against the entry before it),
// and a second copy in the next way would put out the other page of the
// set. So the last page installed and its way are kept, and a walk of that
// page again uses that way and leaves the pointer.
logic [SPAGE_TLB_ENTRIES-1:0] sp_victim_lo, sp_victim_hi;
logic [1:0]                   sp_way;
logic                         sp_again;

if ( SPAGE_TLB_WAYS > 1 )
begin: l_sp_ways
        logic [31:12] sp_last_page;
        logic [1:0]   sp_last_way;
        logic         sp_last_valid;

        // The walker's address a clock late (it does not change during a
        // walk): the compare and the pointer read load this copy, not the
        // register the walker's bus address is made from.
        (* preserve, dont_retime *) logic [31:12] sp_page;

        wire sp_again_nxt = sp_last_valid && (sp_page == sp_last_page);

        always_ff @ ( posedge i_clk )
        begin
                sp_page  <= tlb_address[31:12];
                sp_again <= sp_again_nxt;
                sp_way   <= sp_again_nxt ? sp_last_way :
                            {sp_victim_hi[sp_page[`ARM925T_VA__SPAGE_INDEX]],
                             sp_victim_lo[sp_page[`ARM925T_VA__SPAGE_INDEX]]};

                if ( sptlb_wen )
                begin
                        sp_last_page  <= tlb_address[31:12];
                        sp_last_way   <= sp_way;
                        sp_last_valid <= 1'd1;

                        if ( !sp_again )
                        begin
                                sp_victim_lo[tlb_address[`ARM925T_VA__SPAGE_INDEX]] <= !sp_way[0];
                                sp_victim_hi[tlb_address[`ARM925T_VA__SPAGE_INDEX]] <=
                                        (SPAGE_TLB_WAYS > 2) && (sp_way[1] ^ sp_way[0]);
                        end
                end

                if ( i_reset || i_inv || !i_mmu_en )
                begin
                        sp_last_valid <= 1'd0;
                end

                if ( i_reset )
                begin
                        sp_victim_lo <= '0;
                        sp_victim_hi <= '0;
                        sp_way       <= '0;
                        sp_again     <= 1'd0;
                end
        end
end
else
begin: l_sp_one_way
        assign sp_victim_lo = '0;
        assign sp_victim_hi = '0;
        assign sp_way       = '0;
        assign sp_again     = 1'd0;
end

for (genvar w = 0; w < SPAGE_TLB_WAYS; w++)
begin: l_spage_way

assign sptlb_wen_way[w] = sptlb_wen && (sp_way == w);

arm925t_tlb_buffer #(.WIDTH(`ARM925T_SPAGE_TLB_WDT), .DEPTH(SPAGE_TLB_ENTRIES), .READ_THROUGH(CHECK_WALK))
u_spage_tlb   (
.i_clk          (i_clk),
.i_reset        (i_reset),
.i_clken        (!i_hold),

.i_wdata        (sptlb_wdata),
.i_wen          (sptlb_wen_way[w]),

.i_inv          (i_inv | !i_mmu_en),

.i_raddr        (i_address_nxt[`ARM925T_VA__SPAGE_INDEX]),
.i_waddr        (tlb_address[`ARM925T_VA__SPAGE_INDEX]),

.o_rdata        (sptlb_rdata[w]),
.o_rdav         (sptlb_ren[w]),

.o_rdata_pre    (sptlb_rdata_pre[w]),
.o_rdav_pre     (sptlb_ren_pre[w])
);

end: l_spage_way

// ----------------------------------------------------------------------------

arm925t_tlb_buffer #(.WIDTH(`ARM925T_FPAGE_TLB_WDT), .DEPTH(FPAGE_TLB_ENTRIES), .READ_THROUGH(CHECK_WALK))
u_fpage_tlb (
.i_clk          (i_clk),
.i_reset        (i_reset),
.i_clken        (!i_hold),

.i_wdata        (fptlb_wdata),
.i_wen          (fptlb_wen),

.i_inv          (i_inv | !i_mmu_en),

.i_raddr        (i_address_nxt[`ARM925T_VA__FPAGE_INDEX]),
.i_waddr        (tlb_address[`ARM925T_VA__FPAGE_INDEX]),

.o_rdata        (fptlb_rdata),
.o_rdav         (fptlb_ren),

.o_rdata_pre    (fptlb_rdata_pre),
.o_rdav_pre     (fptlb_ren_pre)
);

// ----------------------------------------------------------------------------

arm925t_tlb_check #(
.LPAGE_TLB_ENTRIES(LPAGE_TLB_ENTRIES),
.SPAGE_TLB_ENTRIES(SPAGE_TLB_ENTRIES),
.SECTION_TLB_ENTRIES(SECTION_TLB_ENTRIES),
.FPAGE_TLB_ENTRIES(FPAGE_TLB_ENTRIES),
.SPAGE_TLB_WAYS(SPAGE_TLB_WAYS),
.CPSR_MODE(ARM925T_CPSR_MODE),
.MMU_OFF_CACHEABLE(MMU_OFF_CACHEABLE)
)
u_tlb_check (
.i_clk          (i_clk),
.i_clkena       (!i_hold),

.i_mmu_en       (i_mmu_en),
.i_va           (i_address_check),
.i_rd           (i_rd_check),
.i_wr           (i_wr_check),

.i_cpsr         (i_cpsr),
.i_sr           (i_sr),
.i_dac_reg      (i_dac_reg),

.i_sptlb_rdata  (sptlb_rdata_pre),
.i_sptlb_rdav   (sptlb_ren_pre),

.i_lptlb_rdata  (lptlb_rdata_pre),
.i_lptlb_rdav   (lptlb_ren_pre),

.i_setlb_rdata  (setlb_rdata_pre),
.i_setlb_rdav   (setlb_ren_pre),

.i_fptlb_rdata  (fptlb_rdata_pre),
.i_fptlb_rdav   (fptlb_ren_pre),

.o_walk         (walk),
.o_walk_va      (walk_va),
.o_hit_ok       (o_hit_ok),
.o_hit_ok_short (o_hit_ok_short),
.o_fsr          (fsr),
.o_far          (far),
.o_cacheable    (cacheable),
.o_wt           (wt),
.o_bufferable   (o_bufferable),
.o_phy_addr     (phy_addr)

);

// ----------------------------------------------------------------------------

arm925t_tlb_fsm #(
.LPAGE_TLB_ENTRIES      (LPAGE_TLB_ENTRIES),
.SPAGE_TLB_ENTRIES      (SPAGE_TLB_ENTRIES),
.SECTION_TLB_ENTRIES    (SECTION_TLB_ENTRIES),
.FPAGE_TLB_ENTRIES      (FPAGE_TLB_ENTRIES)
) u_tlb_fsm (
.i_clk          (i_clk),
.i_reset        (i_reset),
.i_mmu_en       (i_mmu_en),
.i_baddr        (i_baddr),
.i_address      (CHECK_WALK ? walk_va : i_address),
.i_walk         (walk && !check_stale),
.i_fsr          (fsr),
.i_far          (far),
.i_cacheable    (cacheable),
.i_phy_addr     (phy_addr),

.i_idle         (i_idle),
.i_access_done  (i_access_done),
.i_access       (i_access),
.i_inv          (i_inv),
.o_fsr          (o_fsr),
.o_far          (o_far),
.o_fault        (o_fault),
.o_phy_addr     (o_phy_addr),
.o_cacheable    (o_cacheable),
.o_busy         (fsm_busy),
.o_hit_ready    (o_hit_ready),

.o_setlb_wdata  (setlb_wdata),
.o_setlb_wen    (setlb_wen),

.o_sptlb_wdata  (sptlb_wdata),
.o_sptlb_wen    (sptlb_wen),

.o_lptlb_wdata  (lptlb_wdata),
.o_lptlb_wen    (lptlb_wen),

.o_fptlb_wdata  (fptlb_wdata),
.o_fptlb_wen    (fptlb_wen),

.o_address      (tlb_address),
.o_wb_wen       (o_wb_wen_nxt),

/* verilator lint_off PINCONNECTEMPTY */
.o_wb_cyc       (),
.o_wb_stb       (),
.o_wb_sel       (),
.o_wb_adr       (),
/* verilator lint_on PINCONNECTEMPTY */

.i_wb_dat       (i_wb_dat),
.i_wb_ack       (i_wb_ack),
.i_wb_err       (i_wb_err),

.o_wb_sel_nxt   (o_wb_sel_nxt),
.o_wb_cyc_nxt   (o_wb_cyc_nxt),
.o_wb_stb_nxt   (o_wb_stb_nxt),
.o_wb_adr_nxt   (o_wb_adr_nxt)
);

// ----------------------------------------------------------------------------

// ARM925T: passed straight on, like o_cacheable through arm925t_tlb_fsm.
assign o_wt = wt;

// ARM925T, CHECK_WALK: an install or consumed fault makes the registered
// check stale until it registers again (at the next edge without i_hold).
// In particular, a consumed abort must not restart its old miss check.
always_ff @(posedge i_clk)
        if (i_reset || !CHECK_WALK) check_stale <= 1'b0;
        else if (setlb_wen || sptlb_wen || lptlb_wen || fptlb_wen || (o_fault && i_access_done)) check_stale <= 1'b1;
        else if (!i_hold) check_stale <= 1'b0;

assign o_busy = fsm_busy || (check_stale && walk && i_mmu_en);

endmodule : arm925t_tlb

// ----------------------------------------------------------------------------
// END OF FILE
// ----------------------------------------------------------------------------

