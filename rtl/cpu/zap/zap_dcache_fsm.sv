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
// This is the core state machine for the memory subsystem. Talks to both
// processor and the TLB controller. Cache uploads and downloads are done
// using an incrementing burst on the Wishbone bus for maximum efficiency
//

`include "zap_defines.svh"

module zap_dcache_fsm   #(
        parameter logic [31:0] CACHE_SIZE    = 32'd1024,  // Bytes.
        parameter logic [31:0] CACHE_LINE    = 32'd8,
        parameter logic        BE_32_ENABLE  = 1'd0,
        // ARM925T: FSR status for an external abort on an uncached access:
        // upstream's "terminal exception" 0b0010, or the ARM925T's 0b1000
        // (external abort on a non-cacheable access, section).
        parameter logic [3:0]  EXT_ABORT_FS  = 4'b0010,
        parameter logic [31:0] WAYS          = 32'd1      // ARM925T: ways (zap_cache_tag_ram).
)

// ----------------------------------------------
//  Port List
// ----------------------------------------------

(

// Clock and reset
input   logic                      i_clk,
input   logic                      i_reset,

// From/to processor
input   logic    [31:0]            i_address,
input   logic    [31:0]            i_address_check, // ARM925T: next pipeline access.
input   logic                      i_cache_hit_early, // ARM925T: registered tag compare for HUM.
input   logic                      i_hit_ok, // ARM925T: registered TLB hit eligibility.
input   logic                      i_rd,
input   logic                      i_wr,
input   logic    [31:0]            i_din,
input   logic    [3:0]             i_ben,
input   logic                      i_align_fault, // ARM925T: alignment fault.
input   logic    [31:0]            i_va,          // ARM925T: full address.
input   logic    [5:0]             i_ldfmt,       // ARM925T: load format (zap_core).
input   logic    [63:0]            i_reg_idx,
input   logic    [5:0]             i_reg_idx_bin,
output  logic     [63:0]           o_lock,
output  logic [31:0]               o_reg_dat,
(* dont_retime *) output logic [63:0] o_reg_idx,
output  logic     [31:0]           o_dat,
output  logic                      o_ack,
output  logic                      o_err,
output  logic     [7:0]            o_fsr,
output  logic     [31:0]           o_far,
output  logic                      o_err2,
// ARM925T: registered event pulses: load fill, store fill, victim
// write-back, uncached data access. One event per completed transaction.
output  logic [3:0]                 o_dbg_dcache,

// From/To CP15 unit
input   logic                      i_cache_en,
input   logic                      i_cache_inv,
input   logic                      i_cache_clean,

output  logic                       o_cache_inv_done,
output  logic                       o_cache_clean_done,

// ARM925T: single-line operation from CP15 (see zap_cache_tag_ram).
input   logic                       i_line_req,
output  logic                       o_line_done,
output  logic                       o_line_req,       // to the tag RAM
input   logic                       i_line_done_tr,   // from the tag RAM

// From/to cache.
input   logic    [CACHE_LINE*8-1:0]     i_cache_line,       // the victim's line
input   logic    [WAYS-1:0][31:0]       i_cache_words,      // ARM925T: each way's word at i_address
input   logic                           i_cache_word_sel,   // ARM925T: the hit way's is [1]

input   logic                           i_cache_tag_dirty,
input   logic  [`ZAP_CACHE_TAG_WDT-1:0] i_cache_tag,
input   logic                           i_cache_tag_valid,
// ARM925T: the tag RAM's hit and way of interest for i_address; the way a
// tag or line write goes to (the lookup's way, kept across a fill).
input   logic                           i_cache_hit,
input   logic                           i_cache_hit_dirty,   // the hit way's dirty bit
input   logic  [(WAYS > 1 ? $clog2(WAYS) : 1)-1:0] i_cache_way,
output  logic  [(WAYS > 1 ? $clog2(WAYS) : 1)-1:0] o_cache_way,

output  logic   [`ZAP_CACHE_TAG_WDT-1:0] o_cache_tag,
output  logic                            o_cache_tag_dirty,
output  logic                            o_cache_tag_wr_en,

output  logic     [CACHE_LINE*8-1:0] o_cache_line,
output  logic     [CACHE_LINE-1:0]   o_cache_line_ben,

output  logic                       o_cache_clean_req,
input   logic                       i_cache_clean_done,

output  logic                       o_cache_inv_req,
input   logic                       i_cache_inv_done,

output logic [31:0]                 o_address,

// From/to TLB unit
input   logic    [31:0]            i_phy_addr,
input   logic    [7:0]             i_fsr,
input   logic    [31:0]            i_far,
input   logic                      i_fault,
input   logic                      i_cacheable,
input   logic                      i_wt,          // ARM925T: write-through page.
input   logic                      i_busy,
output  logic                      o_hold,

// Cache state
(* dont_retime *) output logic      o_idle,
(* dont_retime *) output logic      o_live_lookup, // ARM925T: IDLE or background hit-way selection.
// ARM925T: rebuild the three in-flight cache lookups after holding a fill.
(* dont_retime *) output logic [2:0] o_relookup,
(* dont_retime *) output logic      o_fill_busy,
// ARM925T: the saved dirty victim has not yet reached memory. CP15 drain
// observes this register; normal ACK/lookup logic does not consume it.
(* dont_retime *) output logic      o_writeback_busy,

// Bus access ports, both NXT and FF.
output  logic             o_wb_cyc_ff, o_wb_cyc_nxt,
output  logic             o_wb_stb_ff, o_wb_stb_nxt,
output  logic     [31:0]  o_wb_adr_ff, o_wb_adr_nxt,
output  logic     [31:0]  o_wb_dat_ff, o_wb_dat_nxt,
output  logic     [3:0]   o_wb_sel_ff, o_wb_sel_nxt,
output  logic             o_wb_wen_ff, o_wb_wen_nxt,
output  logic     [2:0]   o_wb_cti_ff, o_wb_cti_nxt,
output  logic     [1:0]   o_wb_bte_nxt, // ARM925T: wrap-four line fills
input   logic             i_wb_ack,
input   logic    [31:0]   i_wb_dat,
input   logic             i_wb_err

);

// ----------------------------------------------------------------------------
// Includes and Localparams
// ----------------------------------------------------------------------------

`include "zap_localparams.svh"
`include "zap_defines.svh"
`include "zap_functions.svh"

// States. FSM is 1-hot.
localparam [2:0] IDLE                 = 3'd0; // Resting state.
localparam [2:0] UNCACHEABLE          = 3'd1; // Uncacheable access.
localparam [2:0] UNCACHEABLE_PREPARE  = 3'd2; // Prepare uncacheable access.
localparam [2:0] CLEAN_SINGLE         = 3'd3; // Ultimately cleans up cache line. Parent state
localparam [2:0] FETCH_SINGLE         = 3'd4; // Ultimately validates cache line. Parent state
localparam [2:0] INVALIDATE           = 3'd5; // Cache invalidate parent state
localparam [2:0] CLEAN                = 3'd6; // Cache clean parent state
localparam [2:0] UNLOCK_REG           = 3'd7; // ARM925T: install the buffered line/tag.
localparam [3:0] LINEOP               = 4'd8; // ARM925T: single-line operation
localparam [3:0] UNC_DONE             = 4'd9; // ARM925T: uncacheable access completes
localparam [3:0] UNLOCK_WR            = 4'd10; // ARM925T: load fill completion
localparam [3:0] RELOOKUP0            = 4'd11;
localparam [3:0] RELOOKUP1            = 4'd12;
localparam [3:0] RELOOKUP2            = 4'd13;
localparam [31:0] NUMBER_OF_STATES    = 32'd14;

localparam [31:0] ADR_PAD              =  32'd32 - $clog2(CACHE_LINE/4) - 32'd1;
localparam [31:0] ADR_PAD_MINUS_2      =  ADR_PAD - 32'd2;

// ----------------------------------------------------------------------------
// Variables
// ----------------------------------------------------------------------------

logic                                     cache_dirty;
logic                                     defer_writeback;
logic                                     victim_alias;

// ARM925T: keep the one-hot control boundary. Retiming these bits through
// the output muxes reconnects cache writes to the whole next-state tree.
(* dont_retime *) logic [NUMBER_OF_STATES-1:0] state_ff;
logic [NUMBER_OF_STATES-1:0] state_nxt;
logic [31:0]                              buf_ff [(CACHE_LINE/4)-1:0];
logic [31:0]                              buf_nxt[(CACHE_LINE/4)-1:0];
logic                                     cache_clean_req_nxt,
                                          cache_clean_req_ff;
logic                                     cache_inv_req_nxt,
                                          cache_inv_req_ff;
logic                                     line_req_nxt, line_req_ff; // ARM925T
logic [$clog2(CACHE_LINE/4):0]            adr_ctr_ff, adr_ctr_nxt; // Needs to take on 0,1,2,3, ... CACHE_LINE/4

// From/to processor
logic    [31:0]                           address;
logic                                     wr;
logic    [31:0]                           din;
logic    [3:0]                            ben; // Valid only for writes.
logic    [CACHE_LINE*8-1:0]               cache_line;
logic  [`ZAP_CACHE_TAG_WDT-1:0]           cache_tag; // Tag
logic    [31:0]                           phy_addr;

// ARM925T: a burst's next beat is chosen by the acknowledge between two
// candidates formed from registers, the current beat's and the next's,
// instead of being computed after it (timing).
logic                                     take;
logic [$clog2(CACHE_LINE/4):0]            adr_ctr_inc;
logic                                     beat_cur_ok, beat_inc_ok;
logic [2:0]                               cti_cur, cti_inc;
logic [31:0]                              wb_adr_cur, wb_adr_inc;       // the write-back's beats
logic [31:0]                              fetch_adr_cur, fetch_adr_inc; // the fill's beats
// ARM925T: count beats independently of their word positions. Only the
// 16-byte ARM925T line uses wrap-four; other geometries retain linear fills.
logic [$clog2(CACHE_LINE/4)-1:0]           fetch_word_cur, fetch_word_inc;

assign take          = o_wb_stb_ff && (i_wb_ack | i_wb_err);
assign adr_ctr_inc   = adr_ctr_ff + {{$clog2(CACHE_LINE/4){1'd0}}, 1'd1};
assign beat_cur_ok   = {{ADR_PAD{1'd0}}, adr_ctr_ff}  <= ((CACHE_LINE/4) - 1);
assign beat_inc_ok   = {{ADR_PAD{1'd0}}, adr_ctr_inc} <= ((CACHE_LINE/4) - 1);
assign cti_cur       = ({{ADR_PAD{1'd0}}, adr_ctr_ff}  != ((CACHE_LINE/4) - 1)) ? CTI_BURST : CTI_EOB;
assign cti_inc       = ({{ADR_PAD{1'd0}}, adr_ctr_inc} != ((CACHE_LINE/4) - 1)) ? CTI_BURST : CTI_EOB;
assign wb_adr_cur    = {cache_tag[`ZAP_CACHE_TAG__PA], {$clog2(CACHE_LINE){1'd0}}} + ({{ADR_PAD_MINUS_2{1'd0}}, adr_ctr_ff,  2'd0});
assign wb_adr_inc    = {cache_tag[`ZAP_CACHE_TAG__PA], {$clog2(CACHE_LINE){1'd0}}} + ({{ADR_PAD_MINUS_2{1'd0}}, adr_ctr_inc, 2'd0});
assign fetch_word_cur = adr_ctr_ff[$clog2(CACHE_LINE/4)-1:0] +
                        ((CACHE_LINE == 16) ? address[$clog2(CACHE_LINE)-1:2] : '0);
assign fetch_word_inc = adr_ctr_inc[$clog2(CACHE_LINE/4)-1:0] +
                        ((CACHE_LINE == 16) ? address[$clog2(CACHE_LINE)-1:2] : '0);
assign fetch_adr_cur = {phy_addr[31:$clog2(CACHE_LINE)], fetch_word_cur, 2'b00};
assign fetch_adr_inc = {phy_addr[31:$clog2(CACHE_LINE)], fetch_word_inc, 2'b00};
assign o_wb_bte_nxt = (state_ff[FETCH_SINGLE] && CACHE_LINE == 16) ? 2'b01 : 2'b00;
logic  [(WAYS > 1 ? $clog2(WAYS) : 1)-1:0] way;       // ARM925T: the line's way
logic    [63:0]                           reg_idx;
logic    [63:0]                           lock_nxt, lock_ff;
logic                                     victim_valid;
logic                                     wt_hit, wt_dirty; // ARM925T: write-through store.
logic    [5:0]                            ldfmt;            // ARM925T: format of a background load.
logic    [31:0]                           unc_dat_ff;       // ARM925T: registered bus response
(* dont_retime *) logic [31:0]             reg_dat_ff;       // ARM925T: background load value
logic                                     critical_take;
logic                                     unc_err_ff;       // ARM925T
logic                                     uncached_ff;      // excludes write-through stores

logic                                     unused;

// ----------------------------------------------------------------------------
// Logic
// ----------------------------------------------------------------------------

// Unused
assign      unused = |{phy_addr[$clog2(CACHE_LINE)-1:0]};

//
// ARM925T: the memory stage's load transform (zap_memory_main), for a load
// that misses and is written to its register when the line arrives. f is
// {address[1:0], signed byte, unsigned byte, signed halfword, unsigned
// halfword}; a word is rotated by the address (ARMv4 unaligned LDR).
//
function automatic [31:0] ld_transform ( input [31:0] d, input [5:0] f );
        logic [7:0]  b;
        logic [15:0] h;

        case ( f[5:4] )
        2'd0:    b = d[7:0];
        2'd1:    b = d[15:8];
        2'd2:    b = d[23:16];
        default: b = d[31:24];
        endcase

        h = f[5] ? d[31:16] : d[15:0];

        if      ( f[2] ) ld_transform = {24'd0, b};
        else if ( f[3] ) ld_transform = {{24{b[7]}}, b};
        else if ( f[1] ) ld_transform = {{16{h[15]}}, h};
        else if ( f[0] ) ld_transform = {16'd0, h};
        else
        case ( f[5:4] )
        2'd0:    ld_transform = d;
        2'd1:    ld_transform = {d[7:0],  d[31:8]};
        2'd2:    ld_transform = {d[15:0], d[31:16]};
        default: ld_transform = {d[23:0], d[31:24]};
        endcase
endfunction

// Tie flops to the output
// ARM925T: register the background write mask with the data. The mask
// alone qualifies the payload, so no completion gate remains in the data.
assign o_reg_dat = reg_dat_ff;
assign o_line_done = state_ff[LINEOP] && i_line_done_tr;

assign o_cache_clean_req = cache_clean_req_ff; // Tie req flop to output.
assign o_cache_inv_req   = cache_inv_req_ff;   // Tie inv flop to output.
assign o_line_req        = line_req_ff;        // ARM925T

// Alias (ARM925T: the tag compare is in the tag RAM, i_cache_hit)
assign cache_dirty = i_cache_tag_dirty;
// A VIVT synonym that replaces the same physical line must read the dirty
// bytes after cleaning them. Retain the old order in that exceptional case.
assign victim_alias = i_phy_addr[31:$clog2(CACHE_LINE)] == i_cache_tag[`ZAP_CACHE_TAG__PA];
always_ff @(posedge i_clk)
        if (state_ff[IDLE]) defer_writeback <= !victim_alias;

// cache_line/cache_tag already form a complete write-back buffer captured
// on acceptance. Keep ownership until the final write beat; later misses,
// uncached requests, TLB walks and maintenance cannot enter before IDLE.
always_ff @(posedge i_clk)
        if (i_reset) o_writeback_busy <= 1'b0;
        else if (state_ff[IDLE])
                o_writeback_busy <= (state_nxt[FETCH_SINGLE] || state_nxt[CLEAN_SINGLE]) &&
                                    i_cache_tag_valid && cache_dirty;
        else if (state_ff[CLEAN_SINGLE] && take && o_wb_cti_ff == CTI_EOB)
                o_writeback_busy <= 1'b0;

// Buffers
always_ff @ ( posedge i_clk )
begin
        if ( state_ff[IDLE] )
        begin
                address         <= i_address ;
                wr              <= i_wr;
                din             <= i_din;
                ben             <= i_ben;
        end
end

always_ff @ ( posedge i_clk )
begin
        if ( state_ff [IDLE] )
        begin
                cache_line      <= i_cache_line;
        end
end

//
// ARM925T: the bus response of an uncacheable access is registered and
// passed on in UNC_DONE, a cycle later, so that the bus acknowledge and
// error are not in the same cycle as the pipeline's stall (timing).
//
// ARM925T: select the requested beat before registering the load transform.
// The beat already is the word that adapt_cache_data selected from the
// assembled line. No cache-line mux or live bus path reaches the register file.
// Preserve the existing cacheable-error contract: ERR completes a beat and
// its returned data is consumed, without a data abort. In particular, a later
// ERR neither retracts nor repeats an early write. Uncached errors still use
// UNC_DONE. Precise cacheable aborts require a separate architectural change.
assign critical_take = state_ff[FETCH_SINGLE] && !wr && take &&
                       fetch_word_cur == address[$clog2(CACHE_LINE)-1:2];

always_ff @ ( posedge i_clk )
begin
        if ( i_reset )
                o_reg_idx <= 64'b0;
        else
                o_reg_idx <= critical_take ? reg_idx : 64'b0;

        if ( critical_take )
        begin
                reg_dat_ff <= ld_transform(i_wb_dat, ldfmt);
        end
end

always_ff @ ( posedge i_clk )
begin
        if ( state_ff[UNCACHEABLE] && (i_wb_ack || i_wb_err) )
        begin
                unc_dat_ff <= BE_32_ENABLE ? be_32(i_wb_dat, o_wb_sel_ff) : i_wb_dat;
                unc_err_ff <= i_wb_err;
        end
end

always_ff @ ( posedge i_clk )
begin
        if ( state_ff [IDLE] )
        begin
                cache_tag       <= i_cache_tag;
                victim_valid    <= i_cache_tag_valid;
                phy_addr        <= i_phy_addr;
                way             <= i_cache_way;
                reg_idx         <= i_reg_idx;
                ldfmt           <= i_ldfmt;
                wt_hit          <= i_wr && i_wt && i_cacheable && i_cache_hit;
                wt_dirty        <= i_cache_hit_dirty;
                uncached_ff     <= !i_cache_en || !i_cacheable;
        end
end

// ARM925T: count the final accepted beat, including the existing ERR-as-
// completion behavior. Delays, early load unlocks and hits under the fill
// do not repeat these events. Debug registers never feed pipeline control.
always_ff @(posedge i_clk)
begin
        if (i_reset)
                o_dbg_dcache <= 4'b0;
        else begin
                o_dbg_dcache[0] <= state_ff[FETCH_SINGLE] && take &&
                                  o_wb_cti_ff == CTI_EOB && !wr;
                o_dbg_dcache[1] <= state_ff[FETCH_SINGLE] && take &&
                                  o_wb_cti_ff == CTI_EOB && wr;
                o_dbg_dcache[2] <= state_ff[CLEAN_SINGLE] && take &&
                                  o_wb_cti_ff == CTI_EOB;
                o_dbg_dcache[3] <= state_ff[UNCACHEABLE] && take && uncached_ff;
        end
end

// Sequential Block
always_ff @ ( posedge i_clk )
begin
        if ( i_reset )
        begin
                o_wb_cyc_ff             <= 0;
                o_wb_stb_ff             <= 0;
                o_wb_wen_ff             <= 'x;
                o_wb_sel_ff             <= 'x;
                o_wb_dat_ff             <= 'x;
                o_wb_cti_ff             <= CTI_EOB;
                o_wb_adr_ff             <= 'x;
                cache_clean_req_ff      <= 0;
                cache_inv_req_ff        <= 0;
                line_req_ff             <= 0;
                adr_ctr_ff              <= 0;
                lock_ff                 <= 64'd0;

                // STATE - Drive state to 000...0001.
                state_ff                <= 0;       // Rest of bits
                state_ff[IDLE]          <= 1'd1;    // Override LSB
        end
        else
        begin
                assert($onehot(state_nxt)) else
                $fatal(2, "State is not 1-hot encoded.");

                o_wb_cyc_ff             <= o_wb_cyc_nxt;
                o_wb_stb_ff             <= o_wb_stb_nxt;
                o_wb_wen_ff             <= o_wb_wen_nxt;
                o_wb_sel_ff             <= o_wb_sel_nxt;
                o_wb_dat_ff             <= o_wb_dat_nxt;
                o_wb_cti_ff             <= o_wb_cti_nxt;
                o_wb_adr_ff             <= o_wb_adr_nxt;
                cache_clean_req_ff      <= cache_clean_req_nxt;
                cache_inv_req_ff        <= cache_inv_req_nxt;
                line_req_ff             <= line_req_nxt;
                adr_ctr_ff              <= adr_ctr_nxt;
                lock_ff                 <= lock_nxt;

                // STATE
                state_ff                <= state_nxt;
        end
end

always_ff @ ( posedge i_clk )
begin
        for(int i=0;i<CACHE_LINE/4;i++)
        begin
                buf_ff[i] <= buf_nxt[i];
        end
end

// ARM925T: write each buffer byte directly. Variable indexed updates
// built a read/modify/write mux tree after the wrapped-word adder.
for (genvar k = 0; k < CACHE_LINE/4; k++) begin : g_buffer_word
        for (genvar b = 0; b < 4; b++) begin : g_byte
                assign buf_nxt[k][b*8 +: 8] = !state_ff[FETCH_SINGLE] ? buf_ff[k][b*8 +: 8] :
                        (wr && address[$clog2(CACHE_LINE)-1:2] == k && ben[b]) ? din[b*8 +: 8] :
                        (take && fetch_word_cur == k) ? i_wb_dat[b*8 +: 8] : buf_ff[k][b*8 +: 8];
        end
end

// ARM925T: allow unrelated hits while the single background transaction
// runs. The initiating access has already passed alignment/MMU checks.
// Cacheable burst ERR retains the existing no-late-abort contract above;
// fault-capable uncached/WT accesses and TLB walks never use these slots.
// Register the line exclusions one stage before the access; freeze
// them with the CPU. On the miss-accept edge use the live victim/context.
localparam integer LINE_W = $clog2(CACHE_LINE);
localparam integer SET_W = $clog2(CACHE_SIZE / WAYS / CACHE_LINE);
logic line_safe_ff, line_safe_nxt;
logic victim_safe_ff, victim_safe_nxt;
logic [1:0] install_delay_ff;
logic fill_visible_ff;
// The registered early tag match does not bypass the current RAM write.
// Wait three edges after installation before admitting the new line;
// the existing lookup repair independently handles a held CPU slot.
always_ff @(posedge i_clk)
        if (i_reset || state_ff[IDLE]) begin
                install_delay_ff <= 2'b0;
                fill_visible_ff <= 1'b0;
        end else begin
                install_delay_ff <= {install_delay_ff[0], state_ff[UNLOCK_REG]};
                fill_visible_ff <= fill_visible_ff || install_delay_ff[1];
        end
logic lookup_ready_ff, lookup_ready_nxt;
logic [2:0] repair_ff, repair_nxt;
(* dont_retime *) logic hum_slot_ff;
logic cpu_wait, hum_ack, idle_ack, hum_slot_nxt;
assign cpu_wait = (i_rd || i_wr) && !o_ack;

always_comb begin
        line_safe_nxt = line_safe_ff;
        victim_safe_nxt = victim_safe_ff;
        if (!cpu_wait) begin
                if (o_idle) begin
                        victim_safe_nxt = !i_cache_tag_valid ||
                            i_address_check[31:LINE_W] !=
                            {i_cache_tag[`ZAP_CACHE_TAG__TAG], i_address[LINE_W +: SET_W]};
                        line_safe_nxt = victim_safe_nxt &&
                            i_address_check[31:LINE_W] != i_address[31:LINE_W];
                end else begin
                        victim_safe_nxt = !victim_valid ||
                            i_address_check[31:LINE_W] !=
                            {cache_tag[`ZAP_CACHE_TAG__TAG], address[LINE_W +: SET_W]};
                        line_safe_nxt = victim_safe_nxt &&
                            i_address_check[31:LINE_W] != address[31:LINE_W];
                end
        end

        // Cache RAMs keep running so the fill can write. After a CPU hold,
        // reload the held access followed by its two younger set indices.
        // The original end-of-fill restore takes priority over this repair.
        repair_nxt = {repair_ff[1:0], 1'b0};
        lookup_ready_nxt = lookup_ready_ff;
        if (!o_fill_busy || state_ff[RELOOKUP2]) begin
                repair_nxt = 3'b0;
                lookup_ready_nxt = 1'b1;
        end else if (state_ff[RELOOKUP0] || state_ff[RELOOKUP1]) begin
                repair_nxt = 3'b0;
                lookup_ready_nxt = 1'b0;
        end else if (repair_ff[2])
                lookup_ready_nxt = 1'b1;
        else if (lookup_ready_ff && cpu_wait) begin
                lookup_ready_nxt = 1'b0;
                repair_nxt = 3'b001;
        end
end

always_ff @(posedge i_clk)
        if (i_reset) begin
                line_safe_ff <= 1'b0;
                victim_safe_ff <= 1'b0;
                lookup_ready_ff <= 1'b1;
                repair_ff <= 3'b0;
                hum_slot_ff <= 1'b0;
                o_live_lookup <= 1'b1;
                o_relookup <= 3'b0;
        end else begin
                line_safe_ff <= line_safe_nxt;
                victim_safe_ff <= victim_safe_nxt;
                lookup_ready_ff <= lookup_ready_nxt;
                repair_ff <= repair_nxt;
                hum_slot_ff <= hum_slot_nxt;
                o_live_lookup <= state_nxt[IDLE] || hum_slot_nxt;
                o_relookup <= (state_nxt[RELOOKUP0] || state_nxt[RELOOKUP1] || state_nxt[RELOOKUP2]) ?
                    {state_nxt[RELOOKUP2], state_nxt[RELOOKUP1], state_nxt[RELOOKUP0]} : repair_nxt;
        end

assign hum_slot_nxt = (state_nxt[CLEAN_SINGLE] || state_nxt[FETCH_SINGLE] ||
                       state_nxt[UNLOCK_WR]) && lookup_ready_nxt &&
                      (line_safe_nxt || (state_nxt[CLEAN_SINGLE] &&
                       fill_visible_ff && victim_safe_nxt));
// ARM925T: ACK combines registered predicates, independently of the bus
// FSM's priority decode. In particular the live tag compare cannot feed
// the high-fanout CPU stall through background-hit qualification.
assign hum_ack = hum_slot_ff && i_hit_ok && i_cache_en &&
                 !i_align_fault && i_cache_hit_early;
assign o_ack = idle_ack || hum_ack;
always_ff @(posedge i_clk)
        if (i_reset) o_fill_busy <= 1'b0;
        else o_fill_busy <= state_nxt[CLEAN_SINGLE] || state_nxt[FETCH_SINGLE] ||
                state_nxt[UNLOCK_REG] || state_nxt[UNLOCK_WR] ||
                state_nxt[RELOOKUP0] || state_nxt[RELOOKUP1] || state_nxt[RELOOKUP2];

// ARM925T: RAM write payloads are independent of the write event. Only
// enables need fault/acknowledge qualification; forwarding data registers
// may sample an unused payload when their corresponding valid bit is zero.
// In IDLE the RAM selects the hit way; background writes use the saved way.
logic live_write, fill_write, saved_write;
logic [CACHE_LINE*8-1:0] fill_line;
assign live_write = i_wr && !i_align_fault && i_cache_en &&
                    ((o_idle && !i_fault && !i_busy && i_cacheable && !i_wt) ||
                     (hum_slot_ff && i_hit_ok && i_cache_hit_early));
// ARM925T: one registered state owns the full-line write. The last bus
// beat is already in buf_ff; no bus response arbitrates with a live hit.
// The victim remains inaccessible from miss acceptance until this write,
// so cleaning it need not perform an intermediate dirty-bit RAM write.
assign fill_write = state_ff[UNLOCK_REG];
assign saved_write = state_ff[UNC_DONE] && !unc_err_ff && wt_hit;
assign o_cache_tag_wr_en = live_write || fill_write || saved_write;
assign o_cache_tag_dirty = live_write || (fill_write && wr) ||
                          (saved_write && wt_dirty);
assign o_address = o_live_lookup ? i_address : address;
assign o_cache_way = way;
assign o_cache_tag[`ZAP_CACHE_TAG__TAG] = o_live_lookup ? i_address[`ZAP_VA__CACHE_TAG] :
        address[`ZAP_VA__CACHE_TAG];
assign o_cache_tag[`ZAP_CACHE_TAG__PA] = o_live_lookup ? i_phy_addr[31:$clog2(CACHE_LINE)] :
        phy_addr[31:$clog2(CACHE_LINE)];
for (genvar k = 0; k < CACHE_LINE/4; k++) begin : g_fill_line
        assign fill_line[k*32 +: 32] = buf_ff[k];
end
assign o_cache_line = o_live_lookup ? {(CACHE_LINE/4){i_din}} :
        state_ff[UNLOCK_REG] ? fill_line : {(CACHE_LINE/4){din}};
assign o_cache_line_ben =
        (ben_comp(i_address[$clog2(CACHE_LINE)-1:2], i_ben) & {CACHE_LINE{live_write}}) |
        (ben_comp(address[$clog2(CACHE_LINE)-1:2], ben) & {CACHE_LINE{saved_write}}) |
        {CACHE_LINE{fill_write}};

`ifndef SYNTHESIS
// FETCH exits on the edge that advances beyond the last beat; its
// complete registered buffer is installed in UNLOCK_REG.
always_ff @(posedge i_clk)
        if (!i_reset && state_ff[FETCH_SINGLE])
                assert (beat_cur_ok) else $fatal(2, "Fill counter outside line");
`endif

// Idle indication
always_ff @ ( posedge i_clk )
begin
        o_idle <= state_nxt[IDLE];
end

// ARM925T: only these states can own a bus strobe. All other states
// enter with STB low, an invariant of the FSM. Decode requests in parallel
// so maintenance/relookup state bits do not reach the merger's next owner.
assign o_wb_stb_nxt =
        (state_ff[IDLE] && (i_rd || i_wr) && !i_align_fault && !i_fault && !i_busy && !i_cache_en) ||
        state_ff[UNCACHEABLE_PREPARE] ||
        (state_ff[UNLOCK_REG] && o_writeback_busy) ||
        (state_ff[UNCACHEABLE] && o_wb_stb_ff && !(i_wb_ack || i_wb_err)) ||
        ((state_ff[CLEAN_SINGLE] || state_ff[FETCH_SINGLE]) && (take ? beat_inc_ok : beat_cur_ok));
assign o_wb_cyc_nxt = o_wb_stb_nxt;

// Payload clearing is independent of the parallel request control above.
task automatic kill_bus_payload;
        o_wb_wen_nxt = 1'b0;
        o_wb_adr_nxt = 32'b0;
        o_wb_dat_nxt = 32'b0;
        o_wb_sel_nxt = 4'b0;
        o_wb_cti_nxt = CTI_EOB;
endtask

// STATE MACHINE (Next State Logic)
always_comb
begin:next_state_logic

        // =====================================================
        // Default values section
        // (Done to avoid combo loops/incomplete assignments).
        // =====================================================

        state_nxt               = state_ff;
        adr_ctr_nxt             = adr_ctr_ff;
        o_wb_adr_nxt            = o_wb_adr_ff;
        o_wb_dat_nxt            = o_wb_dat_ff;
        o_wb_cti_nxt            = o_wb_cti_ff;
        // ARM925T: the registered completion mask writes and unlocks on
        // the same edge as the former reg_wr_ff-qualified saved mask.
        lock_nxt                = lock_ff & ~o_reg_idx;
        o_wb_wen_nxt            = o_wb_wen_ff;
        o_wb_sel_nxt            = o_wb_sel_ff;
        cache_clean_req_nxt     = cache_clean_req_ff;
        cache_inv_req_nxt       = cache_clean_req_ff;
        line_req_nxt            = line_req_ff;
        o_lock                  = lock_ff;
        o_fsr                   = 0;
        o_far                   = 0;
        o_cache_inv_done        = 0;
        o_cache_clean_done      = 0;
        o_hold                  = 1'd0;
        idle_ack                = 1'b0;
        o_err                   = 0;
        o_err2                  = 0;

        // ======================================================
        // Generate output data.
        // ======================================================

        //
        // ARM925T: the load's data goes out formatted (rotated, sign or
        // zero extended; ld_transform, the memory stage's transform), each
        // way's word in parallel with the tag compares and the uncached
        // data from its register, so that the hit chooses a finished
        // value and the memory stage registers it as it is
        // (zap_memory_main LOAD_FORMATTED). The live format for a hit,
        // the latched one for the uncached access that began in IDLE.
        //
        if(state_ff[UNC_DONE])
        begin
            o_dat = ld_transform(unc_dat_ff, ldfmt);
        end
        else
        begin
            o_dat = i_cache_word_sel ? ld_transform(i_cache_words[(WAYS > 1) ? 1 : 0], i_ldfmt)
                                     : ld_transform(i_cache_words[0], i_ldfmt);
        end

        // ====================================================
        // FSM Code Section
        // ====================================================

        case(1'd1)

        state_ff[IDLE]:
        begin
                kill_bus_payload();

                if ( !i_rd && !i_wr )
                begin
                        //
                        // ARM925T: maintenance is only looked at when there
                        // is no access (CP15 starts it with the pipeline
                        // empty), and is acknowledged like an idle cycle, so
                        // that the requests from CP15 are not in the path
                        // from o_ack to the pipeline stall (timing).
                        //
                        idle_ack = 1'd1;

                        if ( i_cache_inv )
                        begin
                                state_nxt[IDLE] = 1'd0;
                                state_nxt[INVALIDATE] = 1'd1;
                        end
                        else if ( i_cache_clean )
                        begin
                                state_nxt[IDLE] = 1'd0;
                                state_nxt[CLEAN] = 1'd1;
                        end
                        else if ( i_line_req )
                        begin
                                state_nxt[IDLE] = 1'd0;
                                state_nxt[LINEOP] = 1'd1;
                        end
                end
                else if ( i_align_fault )
                begin
                        // ARM925T: alignment fault, highest priority: FSR
                        // status 0b0001 (no domain), FAR = the address.
                        o_err = 1'd1;
                        idle_ack = 1'd1;
                        o_fsr = 8'b0000_0001;
                        o_far = i_va;
                end
                else if ( i_fault )
                begin
                        // MMU access fault.
                        o_err = 1'd1;
                        idle_ack = 1'd1;
                        o_fsr = i_fsr;
                        o_far = i_far;
                end
                else if ( i_busy )
                begin
                        // Wait it out - this is what err2 is for.
                        o_err2 = 1'd1;
                        idle_ack  = 1'd1;
                end
                else if ( i_rd || i_wr )
                begin
                        if ( !i_cache_en )
                        begin
                                o_hold          = 1'd1;

                                state_nxt[IDLE] = 1'd0;
                                state_nxt[UNCACHEABLE] = 1'd1;

                                idle_ack           = 1'd0; // Wait...
                                // ARM925T: the translated address (the VA with
                                // the MMU off); upstream put the VA on the bus
                                // whenever the D-cache was off, MMU on or not.
                                o_wb_adr_nxt    = i_phy_addr;
                                o_wb_wen_nxt    = i_wr;
                                o_wb_cti_nxt    = CTI_EOB;
                                o_wb_dat_nxt    = i_din;

                                if ( BE_32_ENABLE )
                                begin
                                        o_wb_sel_nxt = be_sel_32(i_ben);
                                end
                                else
                                begin
                                        o_wb_sel_nxt = i_ben;
                                end
                        end
                        else if ( i_cacheable && i_wr && i_wt )
                        begin
                                //
                                // ARM925T: a store to a write-through page (C=1
                                // B=0) goes to memory as an uncached write; on a
                                // hit the line is updated when the write is
                                // acknowledged (UNCACHEABLE). There is no write
                                // allocation. Upstream treated every cacheable
                                // page as write-back.
                                //
                                state_nxt[IDLE] = 1'd0;
                                state_nxt[UNCACHEABLE_PREPARE] = 1'd1;

                                idle_ack           = 1'd0; // Wait...
                                o_hold          = 1'd1;
                        end
                        else if ( i_cacheable )
                        begin
                                //
                                // ARM925T: a store's line and tag write is
                                // presented whatever the compare says: the
                                // tag RAM writes the way that hits, none on
                                // a miss, so the compare gates the write
                                // enables directly instead of through this
                                // state machine (timing).
                                //

                                // ARM925T: the valid bit is the victim's: a
                                // hit is a hit whatever it says.
                                casez ({i_cache_hit,i_cache_tag_valid})

                                2'b1?: // Cache Hit
                                begin
                                        if ( i_rd ) // Read request.
                                        begin
                                                idle_ack   = 1'd1;
                                        end
                                        else if ( i_wr ) // Write request (the write itself is above)
                                        begin
                                                idle_ack        = 1'd1;
                                        end
                                end

                                2'b01: // Unrelated tag, possibly dirty.
                                begin
                                        // Acknowledge current entry. Lock the register.
                                        idle_ack               = 1'd1;

                                        // Lock register on load. ARM925T: upstream also
                                        // raised o_err2 if that register was locked, but
                                        // no register is locked in IDLE (a lock lasts
                                        // until its background write), and the term was in the
                                        // critical tag-compare to pipeline-stall path.
                                        if ( i_rd )
                                        begin
                                                lock_nxt[i_reg_idx_bin] = 1'd1;
                                        end

                                        if ( cache_dirty && victim_alias )
                                        begin
                                                // Set up counter
                                                adr_ctr_nxt = 0;

                                                // A physical synonym must clean before reading.
                                                state_nxt[IDLE] = 1'd0;
                                                state_nxt[CLEAN_SINGLE] = 1'd1;
                                        end
                                        else if ( i_rd | i_wr )
                                        begin
                                                // Set up counter
                                                adr_ctr_nxt = 0;

                                                // Fetch a single cache line
                                                state_nxt[IDLE] = 1'd0;
                                                state_nxt[FETCH_SINGLE] = 1'd1;
                                        end
                                end

                                default: // Need to generate a new tag.
                                begin
                                                // CPU should wait.
                                                idle_ack  = 1'd1;

                                                // Set up counter
                                                adr_ctr_nxt = 0;

                                                // Fetch a single cache line
                                                state_nxt[IDLE] = 1'd0;
                                                state_nxt[FETCH_SINGLE] = 1'd1;

                                                // Lock register on load (see above).
                                                if ( i_rd )
                                                begin
                                                        lock_nxt[i_reg_idx_bin] = 1'd1;
                                                end
                                end
                                endcase
                        end
                        else // Decidedly non cacheable.
                        begin
                                state_nxt[IDLE] = 1'd0;
                                state_nxt[UNCACHEABLE_PREPARE] = 1'd1;

                                idle_ack           = 1'd0; // Wait...
                                o_hold          = 1'd1;
                        end
                end
        end

        state_ff[UNCACHEABLE_PREPARE]:
        begin
                idle_ack           = 1'd0;
                o_hold          = 1'd1;

                state_nxt[UNCACHEABLE_PREPARE] = 1'd0;
                state_nxt[UNCACHEABLE]         = 1'd1;

                o_wb_adr_nxt    = i_phy_addr;
                o_wb_wen_nxt    = i_wr;
                o_wb_cti_nxt    = CTI_EOB;
                o_wb_dat_nxt    = i_din;

                if ( BE_32_ENABLE )
                begin
                        o_wb_sel_nxt = be_sel_32(i_ben);
                end
                else
                begin
                        o_wb_sel_nxt = i_ben;
                end
        end

        state_ff[UNCACHEABLE]: // Uncacheable reads and writes definitely go through this.
        begin
                idle_ack  = 1'd0;
                o_hold = 1'd1;

                if ( i_wb_ack | i_wb_err )
                begin
                        // ARM925T: complete in UNC_DONE (registered response).
                        state_nxt[UNCACHEABLE] = 1'd0;
                        state_nxt[UNC_DONE]    = 1'd1;

                        kill_bus_payload();
                end
        end

        state_ff[UNC_DONE]: // ARM925T: the uncacheable access completes.
        begin
                idle_ack           = 1'd1;
                o_hold          = 1'd0;

                state_nxt[UNC_DONE] = 1'd0;
                state_nxt[IDLE]     = 1'd1;

                begin
                        o_err      = unc_err_ff;

                        // ARM925T: report a fault only for an error. Upstream
                        // set the FSR on every uncached access, so CP15 c5/c6
                        // were overwritten (FAR with 0) after any abort.
                        if ( unc_err_ff )
                        begin
                                o_fsr[3:0] = EXT_ABORT_FS;
                                o_far      = i_va;
                        end
                        // Write-through hit updates are driven by saved_write above.

                        kill_bus_payload();
                end
        end

        state_ff[CLEAN_SINGLE]: // Clean single cache line
        begin

                // Generate address
                adr_ctr_nxt = take ? adr_ctr_inc : adr_ctr_ff;

                if ( take ? beat_inc_ok : beat_cur_ok )
                begin
                        // Sync up with memory. Use PA in cache tag itself.
                        o_wb_wen_nxt = 1'd1;
                        o_wb_dat_nxt = take ? clean_single_d(cache_line, adr_ctr_inc) : clean_single_d(cache_line, adr_ctr_ff);
                        o_wb_adr_nxt = take ? wb_adr_inc : wb_adr_cur;
                       o_wb_cti_nxt = take ? cti_inc : cti_cur;
                       o_wb_sel_nxt =  4'b1111;
                end
                else
                begin
                        // Move to wait state
                        kill_bus_payload();

                        adr_ctr_nxt = 0;

                        state_nxt[CLEAN_SINGLE] = 1'd0;
                        if (defer_writeback) begin
                                // The new line is already installed. Preserve
                                // aligned lookups when a hit advances the CPU.
                                state_nxt[RELOOKUP0] = (i_rd || i_wr) && !o_ack;
                                state_nxt[IDLE] = !(i_rd || i_wr) || o_ack;
                        end else
                                state_nxt[FETCH_SINGLE] = 1'd1;

                end
        end

        state_ff[FETCH_SINGLE]: // Fetch a single cache line
        begin

                // Generate address
                adr_ctr_nxt = take ? adr_ctr_inc : adr_ctr_ff;

                if ( take ? beat_inc_ok : beat_cur_ok )
                begin

                        // Fetch line from memory
                        o_wb_wen_nxt = 1'b0;
                        o_wb_sel_nxt = 4'b1111;
                        o_wb_adr_nxt = take ? fetch_adr_inc : fetch_adr_cur;
                        o_wb_cti_nxt = take ? cti_inc : cti_cur;
                        o_wb_dat_nxt = 32'b0;
                end
                else
                begin:blk12
                        // Register the final beat before the exclusive RAM write.
                        kill_bus_payload();

                        state_nxt[FETCH_SINGLE] = 1'd0;
                        state_nxt[UNLOCK_REG]   = 1'd1;
                end
        end

        state_ff[UNLOCK_REG]: // ARM925T: exclusive cache RAM installation slot.
        begin

                // ARM925T: loads were written after the critical beat.
                // Install the assembled line and its tag. Younger accesses
                // wait for this exclusive write slot.

                // Back to IDLE (ARM925T: through UNLOCK_WR for a load)
                state_nxt[UNLOCK_REG] = 1'd0;
                if (o_writeback_busy) begin
                        // Fill first, then drain the immutable saved victim.
                        // No cache read or write port is needed by the drain.
                        adr_ctr_nxt = 0;
                        state_nxt[CLEAN_SINGLE] = 1'b1;
                        // Launch beat zero on the installation edge. The
                        // line and PA come from the saved victim registers;
                        // there is no RAM port collision or extra bus bubble.
                        o_wb_wen_nxt = 1'b1;
                        o_wb_dat_nxt = cache_line[31:0];
                        o_wb_adr_nxt = {cache_tag[`ZAP_CACHE_TAG__PA], {$clog2(CACHE_LINE){1'b0}}};
                        o_wb_sel_nxt = 4'b1111;
                        o_wb_cti_nxt = CTI_BURST;
                end else begin
                        state_nxt[UNLOCK_WR]  = !wr;
                        state_nxt[RELOOKUP0]  = wr && (i_rd || i_wr);
                        state_nxt[IDLE]       = wr && !(i_rd || i_wr);
                end
        end

        state_ff[UNLOCK_WR]: // ARM925T: finish the load fill, without a second write.
        begin
                state_nxt[UNLOCK_WR] = 1'd0;
                // A completed hit advanced the CPU: its lookups stay aligned.
                // Start restoration only for an access actually held here.
                state_nxt[RELOOKUP0] = (i_rd || i_wr) && !o_ack;
                state_nxt[IDLE]      = !(i_rd || i_wr) || o_ack;
        end

        // ARM925T: the RAM reads run during fills, even when the CPU is
        // stalled. Restore the held access and the two younger lookups in
        // order (zap_dcache), after all fill/store writes. Keep the live
        // hit-way selection and acknowledgements disabled through this restore.
        state_ff[RELOOKUP0]:
        begin
                state_nxt[RELOOKUP0] = 1'd0;
                state_nxt[RELOOKUP1] = 1'd1;
        end

        state_ff[RELOOKUP1]:
        begin
                state_nxt[RELOOKUP1] = 1'd0;
                state_nxt[RELOOKUP2] = 1'd1;
        end

        state_ff[RELOOKUP2]:
        begin
                state_nxt[RELOOKUP2] = 1'd0;
                state_nxt[IDLE]      = 1'd1;
        end

        state_ff[INVALIDATE]: // Invalidate the cache - Almost Single Cycle
        begin
                cache_inv_req_nxt = 1'd1;
                cache_clean_req_nxt = 1'd0;

                if ( i_cache_inv_done )
                begin
                        cache_inv_req_nxt    = 1'd0;

                        state_nxt[INVALIDATE] = 1'd0;
                        state_nxt[IDLE]       = 1'd1;

                        o_cache_inv_done     = 1'd1;
                end
        end

        state_ff[LINEOP]: // ARM925T: let the tag RAM do one line
        begin
                line_req_nxt        = 1'd1;
                cache_clean_req_nxt = 1'd0;
                cache_inv_req_nxt   = 1'd0;

                if ( i_line_done_tr )
                begin
                        line_req_nxt          = 1'd0;
                        state_nxt[LINEOP]     = 1'd0;
                        state_nxt[IDLE]       = 1'd1;
                end
        end

        state_ff[CLEAN]:  // Force cache to clean itself
        begin
                cache_clean_req_nxt = 1'd1;
                cache_inv_req_nxt   = 1'd0;

                if ( i_cache_clean_done )
                begin
                        cache_clean_req_nxt  = 1'd0;

                        state_nxt[CLEAN]     = 1'd0;
                        state_nxt[IDLE]      = 1'd1;

                        o_cache_clean_done   = 1'd1;
                end
        end

        // ==========================================
        // Default Section (To simplify synth)
        // ==========================================

        default:
        begin
                state_nxt               = 'x;
                adr_ctr_nxt             = 'x;
                o_wb_adr_nxt            = 'x;
                o_wb_dat_nxt            = 'x;
                o_wb_cti_nxt            = 'x;
                lock_nxt                = 'x;
                o_wb_wen_nxt            = 'x;
                o_wb_sel_nxt            = 'x;
                cache_clean_req_nxt     = 'x;
                cache_inv_req_nxt       = 'x;
                line_req_nxt            = 'x;
                o_lock                  = 'x;
                o_fsr                   = 'x;
                o_far                   = 'x;
                o_cache_inv_done        = 'x;
                o_cache_clean_done      = 'x;
                o_hold                  = 'x;
                idle_ack                   = 'x;
                o_err                   = 'x;
                o_err2                  = 'x;
        end
        endcase
end : next_state_logic

// ----------------------------------------------------------------------------
// Tasks and functions.
// ----------------------------------------------------------------------------

function automatic [CACHE_LINE-1:0] ben_comp (
        input [$clog2(CACHE_LINE) - 3:0] shift,
        input [3:0]                      bv
);

        localparam [31:0] W = $clog2(CACHE_LINE);
        logic [W-1:0] shamt;

        shamt    = {shift, 2'd0};
        ben_comp = {{(CACHE_LINE - 32'd4){1'd0}}, bv} << shamt;

endfunction : ben_comp

function automatic [31:0] clean_single_d (
        input [CACHE_LINE*8-1:0]        cl,
        input [$clog2(CACHE_LINE/4):0]  sh
);
        logic [$clog2(CACHE_LINE/4) + 5:0] shamt;

        /* verilator lint_off UNUSEDSIGNAL */
        logic [CACHE_LINE*8-32-1:0] dummy;
        /* verilator lint_on UNUSEDSIGNAL */

        shamt                   = {sh, 5'd0};
        {dummy, clean_single_d} = cl >> shamt; // Select specific 32-bit.

endfunction : clean_single_d

endmodule : zap_dcache_fsm

// ----------------------------------------------------------------------------
// END OF FILE
// ----------------------------------------------------------------------------
