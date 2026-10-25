//
// (C)2016-2024 Revanth Kamaraj (krevanth) <revanth91kamaraj@gmail.com>
//
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
// This is the top level cache module that contains the MMU and cache.
// This is the data cache.
//

module zap_dcache #(

parameter logic SHORT_READ = 1'b0, // ARM9: RAM edge then caller's compare/capture edge.
parameter logic [31:0] CACHE_SIZE             = 32'd1024,
parameter logic [31:0] SPAGE_TLB_ENTRIES      = 32'd8,
parameter logic [31:0] LPAGE_TLB_ENTRIES      = 32'd8,
parameter logic [31:0] SECTION_TLB_ENTRIES    = 32'd8,
parameter logic [31:0] FPAGE_TLB_ENTRIES      = 32'd8,
parameter logic [31:0] CACHE_LINE             = 32'd8,
parameter logic        BE_32_ENABLE           = 1'd0,
parameter logic [3:0]  EXT_ABORT_FS           = 4'b0010, // ARM925T: see zap_dcache_fsm.
parameter logic [31:0] WAYS                   = 32'd1,   // ARM925T: 1 or 2 (zap_cache_tag_ram).
parameter logic [31:0] CPSR_MODE              = 32'd4

)
(

// Clock and reset.
input   logic            i_clk,
input   logic            i_reset,

// RAM stall.
input   logic            i_stall,
output  logic            o_fill_busy,

// Signals to check (Provide 1 cycle before TLB+cache access).
input   logic   [31:0]   i_address_check,
input   logic            i_wr_check,
input   logic            i_rd_check,

// Address of TLB+Cache access
input   logic    [31:0]  i_address,

// Address of RAM read.
input   logic    [31:0]  i_address_nxt,

// Other control signals from/to processor.
input   logic            i_rd,
input   logic            i_wr,
input   logic [3:0]      i_ben,
input   logic [31:0]     i_dat,
input   logic            i_align_fault,  // ARM925T: alignment fault (see zap_core).
input   logic [31:0]     i_va,           // ARM925T: full address, for the FAR.
input   logic [5:0]      i_ldfmt,        // ARM925T: load format (see zap_core).
input logic [5:0] i_ldfmt_check,
// ARM9V2: the short-port response registers, before the FSM response mux.
// Permission and hit are registered on the same check edge as the word.
output logic [31:0] o_short_data,
output logic o_short_hit,
// ARM9V2: the FSM can acknowledge a hit in this clock (IDLE or a background-
// hit slot), registered. A short hit outside it is not accepted now.
output logic o_short_live,
output logic  [31:0]     o_dat,
output  logic            o_ack,
output  logic            o_writeback_busy, // ARM925T: CP15 drain fence
output  logic            o_err,
output  logic [7:0]      o_fsr,
output  logic [31:0]     o_far,
output  logic            o_err2,
output  logic [3:0]      o_dbg_dcache, // ARM925T: per-transaction debug events
output  logic            o_dbg_tlb,    // accepted D-TLB walk beat (ACK or ERR)
input   logic [63:0]     i_reg_idx,
input   logic [5:0]      i_reg_idx_bin,
output  logic [63:0]     o_lock,
input logic [5:0] i_lock_owner_hold, i_lock_owner_advance,
input logic i_lock_owner_move,
output  logic           o_lock_any, o_lock_owner,
output  logic [31:0]     o_reg_dat,
output  logic [63:0]     o_reg_idx,

// MMU controls from/to processor.
input   logic            i_mmu_en,
input   logic            i_cache_en,
input   logic            i_cache_inv_req,
input   logic            i_cache_clean_req,
output logic             o_cache_inv_done,
output  logic            o_cache_clean_done,

// ARM925T: single-line clean/invalidate (zap_cache_tag_ram).
input   logic            i_line_req,
input   logic [1:0]      i_line_op,
input   logic            i_line_va,
input   logic [31:0]     i_line_addr,
input   logic            i_line_way,     // ARM925T: of an operation by index
output  logic            o_line_done,

input   logic [CPSR_MODE:0]    i_cpsr,
input   logic [1:0]            i_sr,
input   logic [31:0]           i_baddr,
input   logic [31:0]           i_dac_reg,
input  logic                   i_tlb_inv,

// Wishbone. Signals from all 4 modules are ORed.
output logic              o_wb_stb, o_wb_stb_nxt,
output logic              o_wb_cyc, o_wb_cyc_nxt,
output logic              o_wb_wen, o_wb_wen_nxt,
output logic  [3:0]       o_wb_sel, o_wb_sel_nxt,
output logic  [31:0]      o_wb_dat, o_wb_dat_nxt,
output logic  [31:0]      o_wb_adr, o_wb_adr_nxt,
output logic  [2:0]       o_wb_cti, o_wb_cti_nxt,
output logic  [1:0]       o_wb_bte, o_wb_bte_nxt, // ARM925T: fill burst order
input  logic [31:0]       i_wb_dat,
input  logic              i_wb_ack,
input  logic              i_wb_err

);

`include "zap_defines.svh"
`include "zap_localparams.svh"

localparam [2:0] SELECT_CCH = 3'b001;
localparam [2:0] SELECT_TAG = 3'b010;
localparam [2:0] SELECT_TLB = 3'b100;

logic [2:0]                      wb_stb;
logic [2:0]                      wb_cyc;
logic [2:0]                      wb_wen;
logic [3:0]                      wb_sel [2:0];
logic [31:0]                     wb_dat [2:0];
logic [31:0]                     wb_adr [2:0];
logic [2:0]                      wb_cti [2:0];
logic [1:0]                      fill_bte;
logic [31:0]                     tlb_phy_addr;
logic [7:0]                      tlb_fsr;
logic [31:0]                     tlb_far;
logic                            tlb_fault;
logic                            tlb_cacheable;
logic                            tlb_wt;        // ARM925T
logic                            tlb_busy, tlb_hit_ok;
logic [CACHE_LINE*8-1:0]         tr_cache_line;
logic [WAYS-1:0][31:0]           tr_cache_words;   // ARM925T
logic                            tr_cache_word_sel; // ARM925T
logic [CACHE_LINE*8-1:0]         cf_cache_line;
logic [CACHE_LINE-1:0]           cf_cache_line_ben;
logic                            cf_cache_tag_wr_en;
logic [`ZAP_CACHE_TAG_WDT-1:0]   tr_cache_tag, cf_cache_tag;
logic                            tr_cache_tag_valid;
logic                            tr_cache_hit_early;
logic                            tr_cache_hit, tr_cache_hit_dirty; // ARM925T
logic [(WAYS > 1 ? $clog2(WAYS) : 1)-1:0] tr_cache_way, cf_cache_way; // ARM925T
logic                            tr_cache_tag_dirty, cf_cache_tag_dirty;
logic [CACHE_LINE*8-1:0] raw_cache_line, merged_line;
logic [WAYS-1:0][31:0] raw_cache_words;
logic raw_cache_word_sel, raw_cache_tag_valid, raw_cache_hit, raw_cache_tag_dirty, raw_cache_hit_dirty;
logic [`ZAP_CACHE_TAG_WDT-1:0] raw_cache_tag;
logic [(WAYS > 1 ? $clog2(WAYS) : 1)-1:0] raw_cache_way;
logic [(WAYS > 1 ? $clog2(WAYS) : 1)-1:0] cache_write_way;
logic ram_write, forward_store, forward_victim;
logic [31:0] compare_address;
logic                            cf_cache_clean_req, cf_cache_inv_req;
logic                            cf_line_req, tr_line_done;   // ARM925T
logic                            tr_cache_inv_done, tr_cache_clean_done;
logic [2:0]                      wb_ack;
logic [2:0]                      state_ff, state_nxt;
logic [31:0]                     cache_address;
logic                            hold;
logic                            idle, live_lookup;
logic [2:0]                      relookup;
logic                            fill_busy;
logic [3:0]                      cf_dbg_dcache;
logic                            clean_line_event;
assign o_fill_busy = fill_busy;
assign o_short_data = SHORT_READ ? tr_cache_words[0] : 32'd0;
assign o_short_hit = SHORT_READ && tr_cache_hit && tlb_hit_ok;
// ARM9V2: during a fill, the line it evicts keeps its tag until UNLOCK_REG
// and still gives a short hit, but its lookups are unsafe: the FSM withholds
// the ACK, and after installation the access misses. live_lookup is
// state_ff[IDLE] || hum_slot_ff, the only states with a hit ACK.
assign o_short_live = SHORT_READ && live_lookup;
localparam integer SET_W = $clog2(CACHE_SIZE / WAYS / CACHE_LINE);
localparam integer LINE_W = $clog2(CACHE_LINE);
logic [SET_W-1:0]                lookup_s0, lookup_s1;
logic [31:0]                     lookup_address;

// ARM925T: track the two younger cache set indices with the CPU's
// post-ALU stages. A fill stall must not overwrite them with the ALU's
// stationary address. Only these indices, not cache data, need saving.
always_ff @ (posedge i_clk)
begin
        if ( i_reset )
        begin
                lookup_s0 <= '0;
                lookup_s1 <= '0;
        end
        else if ( !i_stall && !((i_rd || i_wr) && !o_ack) )
        begin
                lookup_s0 <= i_address_nxt[LINE_W +: SET_W];
                lookup_s1 <= lookup_s0;
        end
end

// Reload the held lookup, then the two younger ones. At the end of the
// sequence all three RAM stages again align with the CPU. The mux is before
// the RAM's first register; the shared tag RAM's hit path is untouched.
// ARM9: restore the held request during the FSM reload; ordinary reads
// launch from E in parallel with the TLB and capture their compare next.
always_comb
begin
        lookup_address = i_address_nxt;
        if      ( SHORT_READ && (|relookup) ) lookup_address = i_address;
        else if ( relookup[0] ) lookup_address[LINE_W +: SET_W] = i_address[LINE_W +: SET_W];
        else if ( relookup[1] ) lookup_address[LINE_W +: SET_W] = lookup_s1;
        else if ( relookup[2] ) lookup_address[LINE_W +: SET_W] = lookup_s0;
end
logic  [2:0]                     wb_err;
logic                            unused;

// Selection 2 of Wishbone CTI[2x3] is always on all CPU supported modes.
assign wb_cti[2] = CTI_EOB;

// wb_err[1] is unused.
assign unused = |{wb_err[1]};

// Basic cache FSM - serves as manager 0.
zap_dcache_fsm #(.CACHE_SIZE(CACHE_SIZE), .CACHE_LINE(CACHE_LINE), .BE_32_ENABLE(BE_32_ENABLE),
                 .EXT_ABORT_FS(EXT_ABORT_FS), .WAYS(WAYS), .HIT_FORMATTED(SHORT_READ)) u_zap_cache_fsm (
        .i_clk                  (i_clk),
        .i_reset                (i_reset),
        .i_address              (i_address),
        .i_address_check        (i_address_check),
        .i_hit_ok               (tlb_hit_ok),
        .i_cache_hit_early      (tr_cache_hit_early),
        .i_rd                   (i_rd),
        .i_wr                   (i_wr),
        .i_din                  (i_dat),
        .i_align_fault          (i_align_fault),
        .i_va                   (i_va),
        .i_ldfmt                (i_ldfmt),
        .o_idle                 (idle),
        .o_live_lookup          (live_lookup),
        .o_relookup             (relookup),
        .o_fill_busy            (fill_busy),
        .o_writeback_busy       (o_writeback_busy),
        .i_ben                  (i_ben),
        .o_dat                  (o_dat),
        .o_ack                  (o_ack),
        .o_err                  (o_err),
        .o_fsr                  (o_fsr),
        .o_far                  (o_far),
        .i_cache_en             (i_cache_en),
        .i_cache_inv            (i_cache_inv_req),
        .i_cache_clean          (i_cache_clean_req),
        .o_cache_inv_done       (o_cache_inv_done),
        .o_cache_clean_done     (o_cache_clean_done),
        .i_line_req             (i_line_req),
        .o_line_done            (o_line_done),
        .o_line_req             (cf_line_req),
        .i_line_done_tr         (tr_line_done),
        .i_cache_line           (tr_cache_line),
        .i_cache_words          (tr_cache_words),
        .i_cache_word_sel       (tr_cache_word_sel),
        .i_cache_tag_dirty      (tr_cache_tag_dirty),
        .i_cache_tag            (tr_cache_tag),
        .i_cache_tag_valid      (tr_cache_tag_valid),
        .i_cache_hit            (tr_cache_hit),
        .i_cache_hit_dirty      (tr_cache_hit_dirty),
        .i_cache_way            (tr_cache_way),
        .o_cache_way            (cf_cache_way),
        .o_cache_tag            (cf_cache_tag),
        .o_cache_tag_dirty      (cf_cache_tag_dirty),
        .o_cache_tag_wr_en      (cf_cache_tag_wr_en),
        .o_cache_line           (cf_cache_line),
        .o_cache_line_ben       (cf_cache_line_ben),
        .o_cache_clean_req      (cf_cache_clean_req),
        .i_cache_clean_done     (tr_cache_clean_done),
        .o_cache_inv_req        (cf_cache_inv_req),
        .i_cache_inv_done       (tr_cache_inv_done),
        .i_phy_addr             (tlb_phy_addr),
        .i_fsr                  (tlb_fsr),
        .i_far                  (tlb_far),
        .i_fault                (tlb_fault),
        .i_cacheable            (tlb_cacheable),
        .i_wt                   (tlb_wt),
        .i_busy                 (tlb_busy),
        .o_err2                 (o_err2),
        .o_dbg_dcache           (cf_dbg_dcache),
        .o_address              (cache_address),
        .o_wb_cyc_nxt           (wb_cyc[0]),
        .o_hold                 (hold),
        .i_reg_idx              (i_reg_idx),
        .i_reg_idx_bin          (i_reg_idx_bin),
        .o_lock                 (o_lock),
        .i_lock_owner_hold(i_lock_owner_hold),
        .i_lock_owner_advance(i_lock_owner_advance),
        .i_lock_owner_move(i_lock_owner_move),
        .o_lock_any             (o_lock_any),
        .o_lock_owner           (o_lock_owner),
        .o_reg_dat              (o_reg_dat),
        .o_reg_idx              (o_reg_idx),

        /* verilator lint_off PINCONNECTEMPTY */
        .o_wb_cyc_ff            (),
        .o_wb_stb_ff            (),
        .o_wb_adr_ff            (),
        .o_wb_dat_ff            (),
        .o_wb_sel_ff            (),
        .o_wb_wen_ff            (),
        .o_wb_cti_ff            (),
        /* verilator lint_on PINCONNECTEMPTY */

        .o_wb_stb_nxt           (wb_stb[0]),
        .o_wb_adr_nxt           (wb_adr[0]),
        .o_wb_dat_nxt           (wb_dat[0]),
        .o_wb_sel_nxt           (wb_sel[0]),
        .o_wb_wen_nxt           (wb_wen[0]),
        .o_wb_cti_nxt           (wb_cti[0]),
        .o_wb_bte_nxt           (fill_bte),
        .i_wb_dat               (i_wb_dat),
        .i_wb_ack               (wb_ack[0]),
        .i_wb_err               (wb_err[0])
);

// Cache Tag RAM - As a manager - this performs cache clean - manager 1.
// ARM925T: enlarged two-way D-caches retain the reported 8 KB geometry
// for index maintenance. The tag manager visits all physical set colours.
zap_cache_tag_ram #(.CACHE_SIZE(CACHE_SIZE), .CACHE_LINE(CACHE_LINE), .WAYS(WAYS), .SHORT_READ(SHORT_READ),
                   .ACCEPTED_HIT_UPDATE(SHORT_READ),
                   .INDEX_SIZE((WAYS == 2 && CACHE_SIZE > 8192) ? 32'd8192 : CACHE_SIZE)) u_zap_cache_tag_ram (
        .i_clk                  (i_clk),
        .i_reset                (i_reset),
        .i_address_nxt          (lookup_address),
        .i_address              (cache_address),
        .i_lookup_address       (SHORT_READ ? compare_address : i_address),            // ARM925T
        .i_lookup_check_address (i_address_check),
        .i_lookup_stall         ((i_rd || i_wr) && !o_ack),
        .o_cache_hit_early      (tr_cache_hit_early),
        // Held/stale lookups must not update replacement state.
        .i_access               (SHORT_READ ? (i_rd_check || i_wr_check) && idle : (i_rd || i_wr) && (idle || (live_lookup && o_ack))),
        // ARM9: only the accepted response updates LRU, including HUM. Its
        // way is registered; a younger check probe may be held or replayed.
        .i_accepted_hit         ((i_rd || i_wr) && o_ack && !o_err && !o_err2 && live_lookup && tr_cache_hit),
        .i_accepted_address     (i_address),
        .i_accepted_way         (tr_cache_way),
        .i_idle                 (SHORT_READ ? 1'b0 : live_lookup),
        .o_cache_hit            (raw_cache_hit),
        .o_cache_hit_dirty      (raw_cache_hit_dirty),
        .o_cache_way            (raw_cache_way),
        .i_cache_way            (cache_write_way),
        .i_hold                 (hold || i_stall),
        .i_cache_en             (i_cache_en),
        .i_cache_line           (cf_cache_line),
        .o_cache_line           (raw_cache_line),
        .o_cache_words          (raw_cache_words),
        .o_cache_word_sel       (raw_cache_word_sel),
        .i_cache_line_ben       (cf_cache_line_ben & {CACHE_LINE{ram_write}}),
        .i_cache_tag_wr_en      (cf_cache_tag_wr_en && ram_write),
        .i_cache_tag            (cf_cache_tag),
        .i_cache_tag_dirty      (cf_cache_tag_dirty),
        .o_cache_tag            (raw_cache_tag),
        .o_cache_tag_valid      (raw_cache_tag_valid),
        .o_cache_tag_dirty      (raw_cache_tag_dirty),
        .i_cache_inv_req        (cf_cache_inv_req),
        .o_cache_inv_done       (tr_cache_inv_done),
        .i_cache_clean_req      (cf_cache_clean_req),
        .o_cache_clean_done     (tr_cache_clean_done),
        .i_line_req             (cf_line_req),
        .i_line_op              (i_line_op),
        .i_line_va              (i_line_va),
        .i_line_addr            (i_line_addr),
        .i_line_way             (i_line_way),
        .o_line_done            (tr_line_done),

        /* verilator lint_off PINCONNECTEMPTY */
        .o_wb_cyc_ff            (),
        .o_wb_stb_ff            (),
        .o_wb_adr_ff            (),
        .o_wb_dat_ff            (),
        .o_wb_sel_ff            (),
        .o_wb_wen_ff            (),
        .o_wb_cti_ff            (),
        /* verilator lint_on PINCONNECTEMPTY */

        .o_wb_cyc_nxt           (wb_cyc[1]),
        .o_wb_stb_nxt           (wb_stb[1]),
        .o_wb_adr_nxt           (wb_adr[1]),
        .o_wb_dat_nxt           (wb_dat[1]),
        .o_wb_sel_nxt           (wb_sel[1]),
        .o_wb_wen_nxt           (wb_wen[1]),
        .o_wb_cti_nxt           (wb_cti[1]),
        .i_wb_dat               (i_wb_dat),
        .i_wb_ack               (wb_ack[1]),
        .i_pf_addr      (32'd0),
        .o_pf_hit       ()
);

// ARM9: compare the E-launched RAM result in M1, then capture M2.
// The FSM still classifies the ordered request after the registered TLB
// permission check. A store writes its registered way, never the younger
// probe's hit way. On a miss no speculative store write reaches the RAM.
assign compare_address = (|relookup) ? i_address : i_address_check;
// The FSM exposes its saved victim way. SHORT_READ stores use the
// registered live hit way; ZAP selects the live way inside the tag RAM.
assign cache_write_way = SHORT_READ && live_lookup ? tr_cache_way : cf_cache_way;
assign ram_write = !SHORT_READ || !live_lookup || tr_cache_hit;
assign forward_store = live_lookup && cf_cache_tag_wr_en && tr_cache_hit &&
                       compare_address[LINE_W +: SET_W] == cache_address[LINE_W +: SET_W];
assign forward_victim = forward_store &&
                       raw_cache_tag[`ZAP_CACHE_TAG__TAG] == cf_cache_tag[`ZAP_CACHE_TAG__TAG];
// The RAM's collision register covers the E lookup sampled on this write
// edge. This merge covers the older M1 lookup already outside the RAM.
always_comb begin
    merged_line = raw_cache_line;
    for (int b=0; b<CACHE_LINE; b++) begin
        if (forward_victim && cf_cache_line_ben[b])
            merged_line[8*b +: 8] = cf_cache_line[8*b +: 8];
    end
end
`include "zap_load_format.svh"
generate if (SHORT_READ) begin : g_short_response
    logic [31:0] hit_word, store_word, formatted;
    logic store_collision;
    // ARM9: W already owns registered store data, byte enables and way.
    // Build the possible word result independently of the FSM's full-line
    // write enables. Permission/acceptance selects the finished result;
    // it no longer traverses byte merge and load formatting in series.
    assign hit_word = raw_cache_words[raw_cache_word_sel ? ((WAYS > 1) ? 1 : 0) : 0];
    always_comb begin
        store_word = hit_word;
        for (int b=0; b<4; b++)
            if (i_ben[b]) store_word[8*b +: 8] = i_dat[8*b +: 8];
    end
    assign store_collision = forward_store &&
        compare_address[LINE_W-1:2] == i_address[LINE_W-1:2] &&
        cache_write_way == ((WAYS > 1) ? raw_cache_word_sel : 1'b0);
    assign formatted = store_collision ? ld_transform(store_word, i_ldfmt_check) :
                                         ld_transform(hit_word, i_ldfmt_check);
`ifndef SYNTHESIS
    // A live lookup cannot own a fill/saved write. These assertions protect
    // the factoring above if the FSM's ownership states change later.
    always_ff @(posedge i_clk) if (!i_reset && forward_store && !hold && !i_stall) begin
        assert (cf_cache_line == {(CACHE_LINE/4){i_dat}});
        for (int b=0; b<4; b++)
            assert (cf_cache_line_ben[4*i_address[LINE_W-1:2]+b] == i_ben[b]);
    end
`endif
    always_ff @(posedge i_clk) begin
        if (!hold && !i_stall) begin
            tr_cache_line <= merged_line;
            tr_cache_tag <= raw_cache_tag;
            tr_cache_tag_valid <= raw_cache_tag_valid;
            tr_cache_tag_dirty <= raw_cache_tag_dirty || forward_victim;
            tr_cache_hit <= raw_cache_hit;
            tr_cache_way <= raw_cache_way;
            tr_cache_hit_dirty <= raw_cache_hit_dirty ||
                (forward_store && raw_cache_hit && raw_cache_way == cache_write_way);
            tr_cache_word_sel <= 0;
            for (int w=0; w<WAYS; w++) tr_cache_words[w] <= formatted;
        end
    end
end else begin : g_original_response
    assign tr_cache_line = raw_cache_line;
    assign tr_cache_words = raw_cache_words;
    assign tr_cache_word_sel = raw_cache_word_sel;
    assign tr_cache_tag = raw_cache_tag;
    assign tr_cache_tag_valid = raw_cache_tag_valid;
    assign tr_cache_hit = raw_cache_hit;
    assign tr_cache_hit_dirty = raw_cache_hit_dirty;
    assign tr_cache_way = raw_cache_way;
    assign tr_cache_tag_dirty = raw_cache_tag_dirty;
end endgenerate

// ZAP TLB control module. Includes TLB RAM inside - Manager 2.
zap_tlb #(
        .SHORT_READ            (SHORT_READ),
        .CHECK_WALK            (SHORT_READ),
        .LPAGE_TLB_ENTRIES      (LPAGE_TLB_ENTRIES),
        .SPAGE_TLB_ENTRIES      (SPAGE_TLB_ENTRIES),
        .SECTION_TLB_ENTRIES    (SECTION_TLB_ENTRIES),
        .FPAGE_TLB_ENTRIES      (FPAGE_TLB_ENTRIES)
)
u_zap_tlb (
        .i_clk          (i_clk),
        .i_reset        (i_reset),
        .i_address      (i_address),
        .i_address_nxt  (i_address_nxt),
        .i_address_check(i_address_check),
        .i_idle         (idle),
        .i_wr_check     (i_wr_check),
        .i_rd_check     (i_rd_check),
        // Preserve all TLB reads and the permission-check result while
        // the CPU waits for a fill. Cache RAMs must still accept writes.
        .i_hold         (hold || i_stall || (fill_busy && (i_rd || i_wr) && !o_ack)),
        .i_cpsr         (i_cpsr),
        .i_sr           (i_sr),
        .i_dac_reg      (i_dac_reg),
        .i_baddr        (i_baddr),
        .i_mmu_en       (i_mmu_en),
        .i_inv          (i_tlb_inv),
        .o_phy_addr     (tlb_phy_addr),
        .o_fsr          (tlb_fsr),
        .o_far          (tlb_far),
        .o_fault        (tlb_fault),
        .o_cacheable    (tlb_cacheable),
        .o_wt           (tlb_wt),
        .o_busy         (tlb_busy),
        .o_hit_ok       (tlb_hit_ok),
        .o_wb_stb_nxt   (wb_stb[2]),
        .o_wb_cyc_nxt   (wb_cyc[2]),
        .o_wb_adr_nxt   (wb_adr[2]),
        .o_wb_wen_nxt   (wb_wen[2]),
        .o_wb_sel_nxt   (wb_sel[2]),
        .o_wb_dat_nxt   (wb_dat[2]),
        .i_wb_dat       (i_wb_dat),
        .i_wb_ack       (wb_ack[2]),
        .i_wb_err       (wb_err[2])
);

// Sequential Block
// ARM925T: explicit whole-cache and line cleaning use the tag manager,
// while evictions use the cache FSM. Count each line at its last beat.
always_ff @(posedge i_clk)
        if (i_reset)
                clean_line_event <= 1'b0;
        else
                clean_line_event <= state_ff == SELECT_TAG && o_wb_stb &&
                    o_wb_wen && o_wb_cti == CTI_EOB && (i_wb_ack || i_wb_err);

assign o_dbg_dcache = cf_dbg_dcache | {1'b0, clean_line_event, 2'b0};
assign o_dbg_tlb = state_ff == SELECT_TLB && o_wb_cyc && o_wb_stb && (i_wb_ack || i_wb_err);

always_ff @ ( posedge i_clk )
begin
        if ( i_reset )
        begin
                state_ff <= SELECT_CCH;
                o_wb_stb <= 1'd0;
                o_wb_cyc <= 1'd0;
                o_wb_adr <= 'x;
                o_wb_cti <= CTI_EOB;
                o_wb_bte <= 2'b00;
                o_wb_sel <= 'x;
                o_wb_dat <= 'x;
                o_wb_wen <= 'x;
        end
        else
        begin
                state_ff <= state_nxt;
                o_wb_stb <= o_wb_stb_nxt;
                o_wb_cyc <= o_wb_cyc_nxt;
                o_wb_adr <= o_wb_adr_nxt;
                o_wb_cti <= o_wb_cti_nxt;
                o_wb_bte <= o_wb_bte_nxt;
                o_wb_sel <= o_wb_sel_nxt;
                o_wb_dat <= o_wb_dat_nxt;
                o_wb_wen <= o_wb_wen_nxt;
        end
end

// Next state logic.
always_comb
begin
        // Change state only if strobe is inactive or strobe has just completed.
        if ( !o_wb_stb || (o_wb_stb && (i_wb_ack || i_wb_err)) )
        begin
                casez({wb_cyc[2],wb_cyc[1],wb_cyc[0]})
                3'b1?? : state_nxt = SELECT_TLB; // TLB.
                3'b01? : state_nxt = SELECT_TAG; // Tag.
                3'b001 : state_nxt = SELECT_CCH; // Cache.
                default: state_nxt = state_ff;
                endcase
        end
        else
        begin
            state_nxt = state_ff;
        end
end

// Route ACKs to respective managers.
always_comb
begin
        case(state_ff)
        SELECT_CCH      : {wb_err, wb_ack} = {2'd0, i_wb_err, 2'd0, i_wb_ack};
        SELECT_TAG      : {wb_err, wb_ack} = {1'd0, i_wb_err, 2'd0, i_wb_ack, 1'd0};
        SELECT_TLB      : {wb_err, wb_ack} = {i_wb_err, 2'd0, i_wb_ack, 2'd0};
        default         : {wb_err, wb_ack } = {6{1'dx}};
        endcase
end

//
// ARM925T: the next CYC is any manager's when the bus may change hands
// (the condition the state machine uses), else the current manager's: the
// value the mux below would give, since the manager the priority select
// chooses has CYC whenever any has; one level after the acknowledge
// instead of through the select (timing).
//
assign o_wb_cyc_nxt = ( !o_wb_stb || (o_wb_stb && (i_wb_ack || i_wb_err)) ) ? (|wb_cyc) : (|(state_ff & wb_cyc));

// ARM925T: compute the selected strobe directly, alongside arbitration.
// The hold case still uses the current owner; a new request retains the
// TLB > tag > cache priority even if a manager's CYC and STB differ.
assign o_wb_stb_nxt = ((!o_wb_stb || (o_wb_stb && (i_wb_ack || i_wb_err))) && (|wb_cyc)) ?
        ((wb_cyc[2] && wb_stb[2]) ||
         (!wb_cyc[2] && wb_cyc[1] && wb_stb[1]) ||
         (!wb_cyc[2] && !wb_cyc[1] && wb_cyc[0] && wb_stb[0])) :
        (|(state_ff & wb_stb));

// Combo signals for external MUXing.
always_comb
begin
        case(state_nxt)
        SELECT_CCH:
        begin
                o_wb_adr_nxt = wb_adr[0];
                o_wb_dat_nxt = wb_dat[0];
                o_wb_cti_nxt = wb_cti[0];
                o_wb_bte_nxt = fill_bte;
                o_wb_sel_nxt = wb_sel[0];
                o_wb_wen_nxt = wb_wen[0];
        end
        SELECT_TAG:
        begin
                o_wb_adr_nxt = wb_adr[1];
                o_wb_dat_nxt = wb_dat[1];
                o_wb_cti_nxt = wb_cti[1];
                o_wb_bte_nxt = 2'b00;
                o_wb_sel_nxt = wb_sel[1];
                o_wb_wen_nxt = wb_wen[1];
        end
        SELECT_TLB:
        begin
                o_wb_adr_nxt = wb_adr[2];
                o_wb_dat_nxt = wb_dat[2];
                o_wb_cti_nxt = wb_cti[2];
                o_wb_bte_nxt = 2'b00;
                o_wb_sel_nxt = wb_sel[2];
                o_wb_wen_nxt = wb_wen[2];
        end
        default:
        begin
                o_wb_adr_nxt = 'x;
                o_wb_dat_nxt = 'x;
                o_wb_cti_nxt = 'x;
                o_wb_bte_nxt = 'x;
                o_wb_sel_nxt = 'x;
                o_wb_wen_nxt = 'x;
        end
        endcase
end

endmodule : zap_dcache

// ----------------------------------------------------------------------------
// END OF FILE
// ----------------------------------------------------------------------------
