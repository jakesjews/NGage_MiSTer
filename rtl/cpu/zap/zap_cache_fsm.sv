//
//  (C)2016-2024 Revanth Kamaraj (krevanth) <revanth91kamaraj@gmail.com>
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 3
//  of the License, or (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program; if not, write to the Free Software
//  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
//  02110-1301, USA.
//
//  This is the core state machine for the memory subsystem. Talks to both
//  processor and the TLB controller. Cache uploads and downloads are done
//  using an incrementing burst on the Wishbone bus for maximum efficiency
//

`include "zap_defines.svh"

module zap_cache_fsm   #(
        parameter logic [31:0] CACHE_SIZE    = 32'd1024,  // Bytes.
        parameter logic [31:0] CACHE_LINE    = 32'd8,
        parameter logic [31:0] WAYS          = 32'd1,     // ARM925T: ways (zap_cache_tag_ram).
        parameter logic        PREFETCH      = 1'd0       // ARM925T: sequential next-line prefetch.
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
input   logic    [31:0]            i_address_check, // ARM925T: next lookup
input   logic                      i_stall,
input   logic                      i_rd,
input   logic                      i_wr,
input   logic    [31:0]            i_din,
input   logic    [3:0]             i_ben,

output  logic     [31:0]            o_dat,
output  logic                       o_ack,
output  logic                       o_err,
output  logic     [7:0]             o_fsr,
output  logic     [31:0]            o_far,
output  logic                       o_err2,
// ARM925T: speculative fetch words must not leave the FIFO until done.
output  logic                       o_fill_pending,
output  logic                       o_fill_done,
output  logic                       o_fill_fault,

// From/To CP15 unit
input   logic                      i_cache_en,
input   logic                      i_cache_inv,
input   logic                      i_cache_clean,

output  logic                       o_cache_inv_done,
output  logic                       o_cache_clean_done,

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
input   logic                      i_busy,
output  logic                      o_hold,

// Cache state
output  logic                      o_idle,

// ARM925T: sequential next-line prefetch interface.
input   logic                      i_pf_hit,
input   logic                      i_pf_inv,
input   logic                      i_wb_busy,
output  logic    [31:0]            o_pf_addr,

// Bus access ports.
output  logic                   o_wb_cyc_ff, o_wb_cyc_nxt,
output  logic                   o_wb_stb_ff, o_wb_stb_nxt,
output  logic     [31:0]        o_wb_adr_ff, o_wb_adr_nxt,
output  logic     [31:0]        o_wb_dat_ff, o_wb_dat_nxt,
output  logic     [3:0]         o_wb_sel_ff, o_wb_sel_nxt,
output  logic                   o_wb_wen_ff, o_wb_wen_nxt,
output  logic     [2:0]         o_wb_cti_ff, o_wb_cti_nxt,
input   logic                   i_wb_ack,
input   logic    [31:0]         i_wb_dat,
input   logic                   i_wb_err

);

// ----------------------------------------------------------------------------
// Includes and Localparams
// ----------------------------------------------------------------------------

`include "zap_localparams.svh"
`include "zap_defines.svh"

// States
localparam [3:0] IDLE                 = 4'd0; // Resting state.
localparam [3:0] UNCACHEABLE          = 4'd1; // Uncacheable access.
localparam [3:0] UNCACHEABLE_PREPARE  = 4'd2; // Prepare uncacheable access.
localparam [3:0] CLEAN_SINGLE         = 4'd3; // Ultimately cleans up cache line. Parent state
localparam [3:0] FETCH_SINGLE         = 4'd4; // Ultimately validates cache line. Parent state
localparam [3:0] INVALIDATE           = 4'd5; // Cache invalidate parent state
localparam [3:0] CLEAN                = 4'd6; // Cache clean parent state
localparam [3:0] UNC_DONE             = 4'd7; // ARM925T: uncacheable access completes

localparam [3:0] FILL_COMPLETE        = 4'd8; // Commit or abort the buffered fetches.

localparam [31:0] NUMBER_OF_STATES    = 32'd9;

localparam [31:0] ADR_PAD              =  32'd32 - $clog2(CACHE_LINE/4) - 32'd1;
localparam [31:0] ADR_PAD_MINUS_2      =  ADR_PAD - 32'd2;
localparam [31:0] LINE_PAD             = (CACHE_LINE * 32'd8) - 32'd32;
localparam [31:0] LINE_ADDR_W          =  32'd32 - $clog2(CACHE_LINE);

// ----------------------------------------------------------------------------
// Variables
// ----------------------------------------------------------------------------

logic                                     cache_dirty;

logic [$clog2(NUMBER_OF_STATES)-1:0]      state_ff, state_nxt;
logic [31:0]                              buf_ff [(CACHE_LINE/4)-1:0];
logic [31:0]                              buf_nxt[(CACHE_LINE/4)-1:0];
logic                                     cache_clean_req_nxt,
                                          cache_clean_req_ff;
logic                                     cache_inv_req_nxt,
                                          cache_inv_req_ff;
logic [$clog2(CACHE_LINE/4):0]            adr_ctr_ff, adr_ctr_nxt; // Needs to take on 0,1,2,3, ... CACHE_LINE/4
logic                                     rhit, whit;              // For debug only.

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

assign take          = o_wb_stb_ff && (i_wb_ack | i_wb_err);
assign adr_ctr_inc   = adr_ctr_ff + {{$clog2(CACHE_LINE/4){1'd0}}, 1'd1};
assign beat_cur_ok   = {{ADR_PAD{1'd0}}, adr_ctr_ff}  <= ((CACHE_LINE/4) - 1);
assign beat_inc_ok   = {{ADR_PAD{1'd0}}, adr_ctr_inc} <= ((CACHE_LINE/4) - 1);
assign cti_cur       = ({{ADR_PAD{1'd0}}, adr_ctr_ff}  != ((CACHE_LINE/4) - 1)) ? CTI_BURST : CTI_EOB;
assign cti_inc       = ({{ADR_PAD{1'd0}}, adr_ctr_inc} != ((CACHE_LINE/4) - 1)) ? CTI_BURST : CTI_EOB;
assign wb_adr_cur    = {cache_tag[`ZAP_CACHE_TAG__PA], {$clog2(CACHE_LINE){1'd0}}} + ({{ADR_PAD_MINUS_2{1'd0}}, adr_ctr_ff,  2'd0});
assign wb_adr_inc    = {cache_tag[`ZAP_CACHE_TAG__PA], {$clog2(CACHE_LINE){1'd0}}} + ({{ADR_PAD_MINUS_2{1'd0}}, adr_ctr_inc, 2'd0});
assign fetch_adr_cur = {phy_addr[31:$clog2(CACHE_LINE)], {$clog2(CACHE_LINE){1'd0}}}  + ({{ADR_PAD_MINUS_2{1'd0}}, adr_ctr_ff,  2'd0});
assign fetch_adr_inc = {phy_addr[31:$clog2(CACHE_LINE)], {$clog2(CACHE_LINE){1'd0}}}  + ({{ADR_PAD_MINUS_2{1'd0}}, adr_ctr_inc, 2'd0});
logic  [(WAYS > 1 ? $clog2(WAYS) : 1)-1:0] way;       // ARM925T: the line's way

// ARM925T: one-line sequential prefetch buffer (PREFETCH = 1).
logic                                     pf_valid_ff, pf_valid_nxt;
logic                                     pf_pend_ff,  pf_pend_nxt;
logic                                     pf_active_ff, pf_active_nxt;
logic                                     pf_drop_ff,  pf_drop_nxt;
logic [31:$clog2(CACHE_LINE)]             pf_va_ff,    pf_va_nxt;
logic [31:$clog2(CACHE_LINE)]             pf_pa_ff,    pf_pa_nxt;
logic [(CACHE_LINE/4)-1:0]                pf_beat_valid_ff, pf_beat_valid_nxt;
logic [31:0]                              pf_buf_ff [(CACHE_LINE/4)-1:0];
logic [31:0]                              pf_buf_nxt[(CACHE_LINE/4)-1:0];
logic [31:0]                              pf_word_ff;
logic [31:0]                              pf_adr_cur, pf_adr_inc;
logic [31:$clog2(CACHE_LINE)]             next_va_line, next_pa_line;
logic                                     pf_clear, pf_va_hit, pf_hit;

assign pf_adr_cur   = {pf_pa_ff, {$clog2(CACHE_LINE){1'd0}}} + ({{ADR_PAD_MINUS_2{1'd0}}, adr_ctr_ff,  2'd0});
assign pf_adr_inc   = {pf_pa_ff, {$clog2(CACHE_LINE){1'd0}}} + ({{ADR_PAD_MINUS_2{1'd0}}, adr_ctr_inc, 2'd0});
assign next_va_line = address[31:$clog2(CACHE_LINE)]  + {{(LINE_ADDR_W-1){1'd0}}, 1'd1};
assign next_pa_line = phy_addr[31:$clog2(CACHE_LINE)] + {{(LINE_ADDR_W-1){1'd0}}, 1'd1};
assign o_pf_addr    = {((state_ff == IDLE) ? i_address[31:$clog2(CACHE_LINE)] : address[31:$clog2(CACHE_LINE)]) +
                       {{(LINE_ADDR_W-1){1'd0}}, 1'd1}, {$clog2(CACHE_LINE){1'd0}}};
assign pf_clear     = !i_cache_en || i_cache_inv || i_cache_clean || i_pf_inv;
assign pf_va_hit    = PREFETCH && pf_valid_ff && (pf_va_ff == i_address[31:$clog2(CACHE_LINE)]);
assign pf_hit       = pf_va_hit && !pf_clear && (pf_pa_ff == i_phy_addr[31:$clog2(CACHE_LINE)]);

// ARM925T: one registered word bypasses the tag/data lookup during a
// linear fill. Select the next lookup when the PC pipeline advances, or
// refresh the held lookup when it stalls (including a just-arrived beat).
// The valid mask belongs to this fill only; never use a previous line's data.
logic [CACHE_LINE/4-1:0] fill_valid_ff, fill_valid_nxt;
logic fill_fault_ff, fill_fault_nxt;
logic [31:0] fill_lookup, response_dat_ff;
logic fill_ready_ff;
assign fill_lookup = i_stall ? i_address : i_address_check;
assign o_fill_pending = state_ff == FETCH_SINGLE;
assign o_fill_done = state_ff == FILL_COMPLETE;
assign o_fill_fault = o_fill_done && fill_fault_ff;

always_ff @(posedge i_clk)
begin
        if (i_reset || state_nxt == IDLE)
        begin
                fill_valid_ff <= '0;
                fill_fault_ff <= 1'd0;
                fill_ready_ff <= 1'd0;
        end
        else
        begin
                fill_valid_ff <= fill_valid_nxt;
                fill_fault_ff <= fill_fault_nxt;
                fill_ready_ff <= fill_valid_nxt[fill_lookup[$clog2(CACHE_LINE)-1:2]] &&
                                 fill_lookup[31:$clog2(CACHE_LINE)] ==
                                 ((state_ff == IDLE) ? i_address[31:$clog2(CACHE_LINE)] : address[31:$clog2(CACHE_LINE)]);
        end
        if (state_ff == UNCACHEABLE && (i_wb_ack || i_wb_err))
                response_dat_ff <= i_wb_dat;
        else if (state_ff != UNC_DONE)
                response_dat_ff <= buf_nxt[fill_lookup[$clog2(CACHE_LINE)-1:2]];
end

always_ff @(posedge i_clk)
begin
        if (i_reset || !PREFETCH)
        begin
                pf_valid_ff      <= 1'd0;
                pf_pend_ff       <= 1'd0;
                pf_active_ff     <= 1'd0;
                pf_drop_ff       <= 1'd0;
                pf_va_ff         <= '0;
                pf_pa_ff         <= '0;
                pf_beat_valid_ff <= '0;
                pf_word_ff       <= '0;
                for (int i=0; i<CACHE_LINE/4; i++)
                begin
                        pf_buf_ff[i] <= '0;
                end
        end
        else
        begin
                pf_valid_ff      <= pf_valid_nxt;
                pf_pend_ff       <= pf_pend_nxt;
                pf_active_ff     <= pf_active_nxt;
                pf_drop_ff       <= pf_drop_nxt;
                pf_va_ff         <= pf_va_nxt;
                pf_pa_ff         <= pf_pa_nxt;
                pf_beat_valid_ff <= pf_beat_valid_nxt;
                pf_word_ff       <= pf_buf_nxt[fill_lookup[$clog2(CACHE_LINE)-1:2]];
                for (int i=0; i<CACHE_LINE/4; i++)
                begin
                        pf_buf_ff[i] <= pf_buf_nxt[i];
                end
        end
end

logic                                     unused;

// ----------------------------------------------------------------------------
// Logic
// ----------------------------------------------------------------------------

// Unused
assign unused = |{rhit, whit, phy_addr[$clog2(CACHE_LINE)-1:0],
                  i_pf_hit, i_pf_inv, i_wb_busy,
                  pf_valid_ff, pf_pend_ff, pf_active_ff, pf_drop_ff,
                  pf_va_ff, pf_pa_ff, pf_beat_valid_ff, pf_word_ff,
                  pf_adr_cur, pf_adr_inc, next_va_line, next_pa_line,
                  pf_clear, pf_va_hit, pf_hit};

// Tie flops to the output
assign o_cache_clean_req = cache_clean_req_ff; // Tie req flop to output.
assign o_cache_inv_req   = cache_inv_req_ff;   // Tie inv flop to output.

// Alias (ARM925T: the tag compare is in the tag RAM, i_cache_hit)
assign cache_dirty = i_cache_tag_dirty;

// Buffers
always_ff @ ( posedge i_clk )
begin
        if ( state_ff == IDLE )
        begin
                address         <= i_address ;
                wr              <= i_wr;
                din             <= i_din;
                ben             <= i_ben;
                cache_line      <= i_cache_line;
                cache_tag       <= i_cache_tag;
                phy_addr        <= i_phy_addr;
                way             <= i_cache_way;
        end
end

// Sequential Block
always_ff @ ( posedge i_clk )
begin
        if ( i_reset )
        begin
                // Things that are assigned to 'x on
                // reset indicates that they do not
                // actually need to be reset.

                o_wb_cyc_ff             <= 0;
                o_wb_stb_ff             <= 0;
                o_wb_wen_ff             <= 'x;
                o_wb_sel_ff             <= 'x;
                o_wb_dat_ff             <= 'x;
                o_wb_cti_ff             <= CTI_EOB;
                o_wb_adr_ff             <= 'x;
                cache_clean_req_ff      <= 0;
                cache_inv_req_ff        <= 0;
                adr_ctr_ff              <= 0;

                // STATE
                state_ff                <= IDLE;
        end
        else
        begin
                o_wb_cyc_ff             <= o_wb_cyc_nxt;
                o_wb_stb_ff             <= o_wb_stb_nxt;
                o_wb_wen_ff             <= o_wb_wen_nxt;
                o_wb_sel_ff             <= o_wb_sel_nxt;
                o_wb_dat_ff             <= o_wb_dat_nxt;
                o_wb_cti_ff             <= o_wb_cti_nxt;
                o_wb_adr_ff             <= o_wb_adr_nxt;
                cache_clean_req_ff      <= cache_clean_req_nxt;
                cache_inv_req_ff        <= cache_inv_req_nxt;
                adr_ctr_ff              <= adr_ctr_nxt;

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

//
// ARM925T: the bus response of an uncacheable access is registered and
// passed on in UNC_DONE, a cycle later, so that the bus acknowledge is not
// in the same cycle as the pipeline's stall (timing).
//
logic        unc_err_ff;

always_ff @ ( posedge i_clk )
begin
        if ( state_ff == UNCACHEABLE && (i_wb_ack || i_wb_err) )
        begin
                unc_err_ff <= i_wb_err;
        end
end

// Idle indication
always_ff @ ( posedge i_clk )
begin
        o_idle <= ~(|state_nxt);
end

// Output data port (ARM925T: the word of the way that hits, selected in
// the tag RAM by the address before the hit; only the hit chooses here).
assign o_dat = (state_ff == UNC_DONE || state_ff == FETCH_SINGLE || state_ff == FILL_COMPLETE) ?
               response_dat_ff :
               pf_va_hit ? pf_word_ff :
               i_cache_word_sel ? i_cache_words[(WAYS > 1) ? 1 : 0] : i_cache_words[0];

// ==========================================================
// STATE MACHINE (Next State Logic)
// ==========================================================

// ARM925T: compute o_ack in a dedicated combinational block that never reads
// i_stall (code_stall depends combinationally on o_ack in zap_core).
always_comb
begin : ack_comb
        o_ack = 1'd0;

        case (state_ff)
        IDLE:
        begin
                if ( i_cache_inv || i_cache_clean )
                        o_ack = 1'd0;
                else if ( !i_rd && !i_wr )
                        o_ack = 1'd1;
                else if ( i_fault || i_busy )
                        o_ack = 1'd1;
                else if ( !i_cache_en || !i_cacheable )
                        o_ack = 1'd0;
                else if ( i_cache_hit )
                        o_ack = i_rd || i_wr;
                else
                        o_ack = PREFETCH && pf_hit && i_rd && !i_wr;
        end

        UNCACHEABLE_PREPARE,
        UNCACHEABLE,
        INVALIDATE,
        CLEAN:
                o_ack = 1'd0;

        UNC_DONE,
        CLEAN_SINGLE,
        FILL_COMPLETE:
                o_ack = 1'd1;

        FETCH_SINGLE:
                o_ack = i_rd && !i_wr && !wr && fill_ready_ff && !fill_fault_ff &&
                        !i_busy && !i_fault && i_cache_en && i_cacheable &&
                        !i_cache_inv && !i_cache_clean;

        default:
                o_ack = 'x;
        endcase
end : ack_comb

always_comb
begin:blk1

       // -----------------------------------------
       // Local Vars Section
       // ----------------------------------------

       logic [$clog2(CACHE_LINE/4)-1:0] tmp;
       logic                            pf_can_start;

        // ---------------------------------------
        // Default Values Section
        // (Done To Avoid Combo Loops/Incomplete Assignments)
        // ---------------------------------------

        tmp                     = {($clog2(CACHE_LINE/4)){1'd0}};
        pf_can_start            = 1'd0;
        state_nxt               = state_ff;
        fill_valid_nxt          = fill_valid_ff;
        fill_fault_nxt          = fill_fault_ff;
        pf_valid_nxt            = pf_valid_ff;
        pf_pend_nxt             = pf_pend_ff;
        pf_active_nxt           = pf_active_ff;
        pf_drop_nxt             = pf_drop_ff;
        pf_va_nxt               = pf_va_ff;
        pf_pa_nxt               = pf_pa_ff;
        pf_beat_valid_nxt       = pf_beat_valid_ff;
        adr_ctr_nxt             = adr_ctr_ff;
        o_wb_cyc_nxt            = o_wb_cyc_ff;
        o_wb_stb_nxt            = o_wb_stb_ff;
        o_wb_adr_nxt            = o_wb_adr_ff;
        o_wb_dat_nxt            = o_wb_dat_ff;
        o_wb_cti_nxt            = o_wb_cti_ff;
        o_wb_wen_nxt            = o_wb_wen_ff;
        o_wb_sel_nxt            = o_wb_sel_ff;
        cache_clean_req_nxt     = cache_clean_req_ff;
        cache_inv_req_nxt       = cache_clean_req_ff;
        o_fsr                   = 0;
        o_far                   = 0;
        o_cache_tag             = 0;
        o_cache_inv_done        = 0;
        o_cache_clean_done      = 0;
        o_cache_tag_dirty       = 0;
        o_cache_tag_wr_en       = 0;
        o_cache_line            = 0;
        o_cache_line_ben        = 0;
        o_hold                  = 1'd0;
        o_err                   = 0;
        o_err2                  = 0;
        o_address               = address;
        o_cache_way             = way;

        for(int i=0;i<CACHE_LINE/4;i++)
        begin
                buf_nxt[i]    = buf_ff[i];
                pf_buf_nxt[i] = pf_buf_ff[i];
        end

        rhit                     = 0;
        whit                     = 0;

        // --------------------------------------
        // FSM Code Section
        // --------------------------------------

        case(state_ff)

        IDLE:
        begin
                `zap_kill_access;

                if ( PREFETCH && pf_clear )
                begin
                        pf_valid_nxt = 1'd0;
                        pf_pend_nxt  = 1'd0;
                        pf_drop_nxt  = 1'd1;
                end

                if ( PREFETCH && pf_active_ff )
                begin
                        adr_ctr_nxt = take ? adr_ctr_inc : adr_ctr_ff;
                        if ( take )
                        begin
                                pf_buf_nxt[adr_ctr_ff[$clog2(CACHE_LINE/4)-1:0]] = i_wb_dat;
                                pf_beat_valid_nxt[adr_ctr_ff[$clog2(CACHE_LINE/4)-1:0]] = 1'd1;
                                if ( i_wb_err )
                                begin
                                        pf_drop_nxt = 1'd1;
                                end
                        end

                        if ( take ? beat_inc_ok : beat_cur_ok )
                        begin
                                `zap_wb_prpr_read(take ? pf_adr_inc : pf_adr_cur, take ? cti_inc : cti_cur);
                        end
                        else
                        begin
                                `zap_kill_access;
                                pf_active_nxt = 1'd0;
                                pf_valid_nxt  = !pf_drop_nxt;
                        end
                end

                if ( i_cache_inv )
                begin
                        pf_pend_nxt = 1'd0;
                        state_nxt   = (PREFETCH && pf_active_nxt) ? IDLE : INVALIDATE;
                end
                else if ( i_cache_clean )
                begin
                        pf_pend_nxt = 1'd0;
                        state_nxt   = (PREFETCH && pf_active_nxt) ? IDLE : CLEAN;
                end
                else if ( !i_rd && !i_wr )
                begin
                        pf_can_start = 1'd1;
                end
                else if ( i_fault )
                begin
                        // MMU access fault.
                        o_err        = 1'd1;
                        o_fsr        = i_fsr;
                        o_far        = i_far;
                        pf_pend_nxt  = 1'd0;
                        if ( PREFETCH && pf_va_hit )
                        begin
                                pf_valid_nxt = 1'd0;
                        end
                end
                else if ( i_busy )
                begin
                        // Wait it out
                        o_err2      = 1'd1;
                        pf_pend_nxt = 1'd0;
                end
                else if ( i_rd || i_wr )
                begin
                        if ( !i_cache_en )
                        begin
                                pf_pend_nxt = 1'd0;
                                if ( !(PREFETCH && pf_active_ff) )
                                begin
                                        state_nxt       = UNCACHEABLE;
                                        o_wb_stb_nxt    = 1'd1;
                                        o_wb_cyc_nxt    = 1'd1;
                                        // ARM925T: translated address, as in zap_dcache_fsm.
                                        o_wb_adr_nxt    = i_phy_addr;
                                        o_wb_dat_nxt    = i_din;
                                        o_wb_wen_nxt    = i_wr;
                                        o_wb_sel_nxt    = i_ben;
                                        o_wb_cti_nxt    = CTI_EOB;
                                end
                        end
                        else if ( i_cacheable )
                        begin
                                // ARM925T: the valid bit is the victim's: a
                                // hit is a hit whatever it says.
                                casez ({i_cache_hit,i_cache_tag_valid})

                                2'b1?: // Cache Hit
                                begin
                                        if ( i_rd ) // Read request.
                                        begin
                                                rhit         = 1'd1;
                                                pf_can_start = 1'd1;
                                                if ( PREFETCH && pf_va_hit )
                                                begin
                                                        pf_valid_nxt = 1'd0;
                                                end
                                        end
                                        else if ( i_wr ) // Write request
                                        begin
                                                whit         = 1'd1;

                                                o_cache_line =
                                                {(CACHE_LINE/4){i_din}};

                                                o_cache_line_ben  = ben_comp (
                                                        i_address[$clog2(CACHE_LINE)-1:2],
                                                        i_ben );

                                                // Write to tag and also write out physical address.
                                                o_cache_tag_wr_en                = 1'd1;
                                                o_cache_tag[`ZAP_CACHE_TAG__TAG] = i_address[`ZAP_VA__CACHE_TAG];
                                                o_cache_tag_dirty                = 1'd1;

                                                o_cache_tag[`ZAP_CACHE_TAG__PA]  =
                                                i_phy_addr[31:$clog2(CACHE_LINE)];

                                                o_address                        = i_address;
                                                o_cache_way                      = i_cache_way;
                                        end
                                end

                                default: // Cache Miss (2'b01 or 2'b00)
                                begin
                                        if ( PREFETCH && pf_hit && i_rd && !i_wr )
                                        begin
                                                // ARM925T: prefetch buffer hit. Serve the word
                                                // from pf_word_ff and write the line to the cache
                                                // in FILL_COMPLETE.
                                                rhit        = 1'd1;
                                                pf_pend_nxt = 1'd0;
                                                if ( !i_stall )
                                                begin
                                                        pf_valid_nxt   = 1'd0;
                                                        for ( int i = 0; i < CACHE_LINE/4; i++ )
                                                        begin
                                                                buf_nxt[i] = pf_buf_ff[i];
                                                        end
                                                        fill_valid_nxt = {(CACHE_LINE/4){1'd1}};
                                                        fill_fault_nxt = 1'd0;
                                                        state_nxt      = FILL_COMPLETE;
                                                end
                                        end
                                        else if ( PREFETCH && pf_active_ff && i_rd && !i_wr && !pf_drop_nxt &&
                                                  (pf_va_ff == i_address[31:$clog2(CACHE_LINE)]) &&
                                                  (pf_pa_ff == i_phy_addr[31:$clog2(CACHE_LINE)]) )
                                        begin
                                                // ARM925T: demand miss matches the in-flight prefetch.
                                                // Adopt its beats into the demand fill buffer.
                                                pf_pend_nxt       = 1'd0;
                                                for ( int i = 0; i < CACHE_LINE/4; i++ )
                                                begin
                                                        buf_nxt[i] = pf_buf_nxt[i];
                                                end
                                                fill_valid_nxt    = pf_beat_valid_nxt;
                                                fill_fault_nxt    = 1'd0;
                                                pf_active_nxt     = 1'd0;
                                                pf_valid_nxt      = 1'd0;
                                                pf_beat_valid_nxt = '0;
                                                state_nxt         = (take ? beat_inc_ok : beat_cur_ok) ?
                                                                    FETCH_SINGLE : FILL_COMPLETE;
                                        end
                                        else if ( PREFETCH && pf_active_nxt )
                                        begin
                                                // ARM925T: an in-flight prefetch burst on the bus
                                                // to another line completes before the demand fill starts.
                                                pf_pend_nxt = 1'd0;
                                        end
                                        else
                                        begin
                                                // ARM925T: hold the lookup; the fill buffer
                                                // will answer it without a PC replay.
                                                pf_pend_nxt = 1'd0;
                                                if ( PREFETCH && pf_va_hit )
                                                begin
                                                        pf_valid_nxt = 1'd0;
                                                end

                                                if ( i_cache_tag_valid && cache_dirty )
                                                begin
                                                        // Set up counter
                                                        adr_ctr_nxt = 0;

                                                        // Clean a single cache line
                                                        state_nxt = CLEAN_SINGLE;
                                                end
                                                else if ( i_rd | i_wr )
                                                begin
                                                        // Set up counter
                                                        adr_ctr_nxt = 0;

                                                        // Fetch a single cache line
                                                        state_nxt = FETCH_SINGLE;
                                                end
                                        end
                                end
                                endcase
                        end
                        else // Non cacheable.
                        begin
                                pf_pend_nxt = 1'd0;
                                if ( !(PREFETCH && pf_active_nxt) )
                                begin
                                        state_nxt = UNCACHEABLE_PREPARE;
                                        o_hold    = 1'd1;
                                end
                        end
                end

                if ( PREFETCH && !pf_active_ff && pf_pend_nxt && pf_can_start && !i_wb_busy )
                begin
                        pf_pend_nxt       = 1'd0;
                        pf_active_nxt     = 1'd1;
                        pf_drop_nxt       = 1'd0;
                        pf_valid_nxt      = 1'd0;
                        pf_beat_valid_nxt = '0;
                        adr_ctr_nxt       = 0;
                        `zap_wb_prpr_read({pf_pa_ff, {$clog2(CACHE_LINE){1'd0}}}, CTI_BURST);
                end
        end

        UNCACHEABLE_PREPARE:
        begin
                o_hold          = 1'd1;
                state_nxt       = UNCACHEABLE;
                o_wb_stb_nxt    = 1'd1;
                o_wb_cyc_nxt    = 1'd1;
                o_wb_adr_nxt    = i_phy_addr;
                o_wb_dat_nxt    = i_din;
                o_wb_wen_nxt    = i_wr;
                o_wb_sel_nxt    = i_ben;
                o_wb_cti_nxt    = CTI_EOB;
        end

        UNCACHEABLE:
        // Uncacheable reads and writes definitely go through this.
        begin
                o_hold = 1'd1;

                if ( i_wb_ack | i_wb_err )
                begin
                        // ARM925T: complete in UNC_DONE (registered response).
                        state_nxt       = UNC_DONE;

                        `zap_kill_access;
                end
        end

        UNC_DONE: // ARM925T
        begin
                o_hold          = 1'd0;
                state_nxt       = IDLE;
                o_err           = unc_err_ff;
                o_fsr[3:0]      = TERMINAL_EXCEPTION;
        end

        CLEAN_SINGLE: // Clean single cache line
        begin
                o_err2 = i_rd || i_wr ? 1'd1 : 1'd0;

                // Generate address
                adr_ctr_nxt = take ? adr_ctr_inc : adr_ctr_ff;

                if ( take ? beat_inc_ok : beat_cur_ok )
                begin
                        // Sync up with memory. Use PA in cache tag itself.
                        o_wb_cyc_nxt = 1'd1;
                        o_wb_stb_nxt = 1'd1;
                        o_wb_wen_nxt = 1'd1;
                        o_wb_dat_nxt = take ? clean_single_d(cache_line, adr_ctr_inc) : clean_single_d(cache_line, adr_ctr_ff);
                        o_wb_adr_nxt = take ? wb_adr_inc : wb_adr_cur;
                        o_wb_cti_nxt = take ? cti_inc : cti_cur;
                        o_wb_sel_nxt = 4'b1111;
                end
                else
                begin
                        // Move to wait state
                        `zap_kill_access;
                        state_nxt = IDLE;

                        // Update tag. Remove dirty bit.
                        o_cache_tag_wr_en                      = 1'd1; // Implicitly sets valid (redundant).
                        o_cache_tag[`ZAP_CACHE_TAG__TAG]       = cache_tag[`ZAP_CACHE_TAG__TAG]; // Preserve.
                        o_cache_tag_dirty                      = 1'd0;
                        o_cache_tag[`ZAP_CACHE_TAG__PA]        = cache_tag[`ZAP_CACHE_TAG__PA]; // Preserve.
                end
        end

        FETCH_SINGLE: // ARM925T: fill in the background, restart into the FIFO.
        begin
                adr_ctr_nxt = take ? adr_ctr_inc : adr_ctr_ff;
                if (take)
                begin
                        buf_nxt[adr_ctr_ff[$clog2(CACHE_LINE/4)-1:0]] = i_wb_dat;
                        fill_valid_nxt[adr_ctr_ff[$clog2(CACHE_LINE/4)-1:0]] = 1'd1;
                        fill_fault_nxt = fill_fault_ff | i_wb_err;
                end

                if (wr)
                begin
                        tmp = address[$clog2(CACHE_LINE/4)+1:2];
                        buf_nxt[tmp][7:0]   = ben[0] ? din[7:0]   : buf_nxt[tmp][7:0];
                        buf_nxt[tmp][15:8]  = ben[1] ? din[15:8]  : buf_nxt[tmp][15:8];
                        buf_nxt[tmp][23:16] = ben[2] ? din[23:16] : buf_nxt[tmp][23:16];
                        buf_nxt[tmp][31:24] = ben[3] ? din[31:24] : buf_nxt[tmp][31:24];
                end

                if (take ? beat_inc_ok : beat_cur_ok)
                begin
                        `zap_wb_prpr_read(take ? fetch_adr_inc : fetch_adr_cur, take ? cti_inc : cti_cur);
                end
                else
                begin
                        `zap_kill_access;
                        state_nxt = FILL_COMPLETE;
                end
        end

        FILL_COMPLETE:
        begin
                // The error is sticky across ALL beats. Provisional FIFO
                // entries become precise prefetch aborts, including when the
                // fetch PC has moved beyond this line. Redirects discard them
                // using the normal pipeline clear priority.
                // No provisional word available: abort the held lookup here.
                o_err = fill_fault_ff && (i_rd || i_wr) &&
                        i_address[31:$clog2(CACHE_LINE)] == address[31:$clog2(CACHE_LINE)];
                o_err2 = !o_err && (i_rd || i_wr) &&
                         !(fill_ready_ff && !fill_fault_ff && i_rd && !i_wr && !wr &&
                           !i_busy && !i_fault && i_cache_en && i_cacheable &&
                           !i_cache_inv && !i_cache_clean);
                o_fsr[3:0] = TERMINAL_EXCEPTION;
                o_far = address;

                // RAM writes require !i_stall. A full FIFO may defer the
                // installation, but done releases its provisional head so
                // it can drain. Answer a ready word directly, otherwise replay
                // only the unanswered current lookup. The RAM collision bypass
                // forwards this write to the already-pipelined lookups.
                if (i_cache_inv || i_cache_clean)
                begin
                        // A CP15 fence can hold decode with the FIFO full.
                        // Do not wait for that FIFO to drain before servicing
                        // the fence. This clean I-side line may be discarded;
                        // an invalidate would discard it immediately anyway.
                        pf_valid_nxt = 1'd0;
                        pf_pend_nxt  = 1'd0;
                        state_nxt = IDLE;
                end
                else if (!i_stall)
                begin
                        if (!fill_fault_ff)
                        begin
                                for (int i=0; i<CACHE_LINE/4; i++)
                                        o_cache_line[32*i +: 32] = buf_ff[i];
                                o_cache_line_ben = {CACHE_LINE{1'd1}};
                                o_cache_tag_wr_en = 1'd1;
                                o_cache_tag[`ZAP_CACHE_TAG__TAG] = address[`ZAP_VA__CACHE_TAG];
                                o_cache_tag[`ZAP_CACHE_TAG__PA] = phy_addr[31:$clog2(CACHE_LINE)];
                                o_cache_tag_dirty = wr;

                                // ARM925T: prefetch the next line, never past
                                // a 1 KB boundary: 1 KB is the smallest unit
                                // of translation and permission (tiny pages,
                                // the subpage AP fields of small and large
                                // pages), so this fill's translation and
                                // permission check cover the next line too.
                                if ( PREFETCH && !wr && !pf_clear && i_cache_en && i_cacheable &&
                                     !i_fault && !i_busy &&
                                     i_rd && (fill_ready_ff || (i_address[31:$clog2(CACHE_LINE)] == next_va_line)) &&
                                     !(&address[9:$clog2(CACHE_LINE)]) && !i_pf_hit &&
                                     !(pf_valid_ff && (pf_va_ff == next_va_line) && (pf_pa_ff == next_pa_line)) )
                                begin
                                        pf_va_nxt         = next_va_line;
                                        pf_pa_nxt         = next_pa_line;
                                        pf_valid_nxt      = 1'd0;
                                        pf_drop_nxt       = 1'd0;
                                        pf_beat_valid_nxt = '0;
                                        if ( !i_wb_busy )
                                        begin
                                                pf_active_nxt = 1'd1;
                                                pf_pend_nxt   = 1'd0;
                                                adr_ctr_nxt   = 0;
                                                `zap_wb_prpr_read({next_pa_line, {$clog2(CACHE_LINE){1'd0}}}, CTI_BURST);
                                        end
                                        else
                                        begin
                                                pf_active_nxt = 1'd0;
                                                pf_pend_nxt   = 1'd1;
                                        end
                                end
                        end
                        state_nxt = IDLE;
                end
        end

        INVALIDATE: // Invalidate the cache - Almost Single Cycle
        begin
                cache_inv_req_nxt = 1'd1;
                cache_clean_req_nxt = 1'd0;

                if ( i_cache_inv_done )
                begin
                        cache_inv_req_nxt    = 1'd0;
                        state_nxt            = IDLE;
                        o_cache_inv_done     = 1'd1;
                end
        end

        CLEAN:  // Force cache to clean itself
        begin
                cache_clean_req_nxt = 1'd1;
                cache_inv_req_nxt   = 1'd0;

                if ( i_cache_clean_done )
                begin
                        cache_clean_req_nxt  = 1'd0;
                        state_nxt            = IDLE;
                        o_cache_clean_done   = 1'd1;
                end
        end

        // ------------------------------
        // Default Section
        // ------------------------------

        default:
        begin
                // Assigning X is OK to do and will result
                // in better synthesis.

                tmp                     = 'x;
                state_nxt               = 'x;
                adr_ctr_nxt             = 'x;
                o_wb_cyc_nxt            = 'x;
                o_wb_stb_nxt            = 'x;
                o_wb_adr_nxt            = 'x;
                o_wb_dat_nxt            = 'x;
                o_wb_cti_nxt            = 'x;
                o_wb_wen_nxt            = 'x;
                o_wb_sel_nxt            = 'x;
                cache_clean_req_nxt     = 'x;
                cache_inv_req_nxt       = 'x;
                o_fsr                   = 'x;
                o_far                   = 'x;
                o_cache_tag             = 'x;
                o_cache_inv_done        = 'x;
                o_cache_clean_done      = 'x;
                o_cache_tag_dirty       = 'x;
                o_cache_tag_wr_en       = 'x;
                o_cache_line            = 'x;
                o_cache_line_ben        = 'x;
                o_hold                  = 'x;
                o_err                   = 'x;
                o_err2                  = 'x;
                o_address               = 'x;
                o_cache_way             = 'x;

                for(int i=0;i<CACHE_LINE/4;i++)
                begin
                        buf_nxt[i] = 'x;
                end

                rhit                     = 'x;
                whit                     = 'x;
        end
        endcase

        // ARM925T: a clear (cache off, invalidate, clean, or i_pf_inv's
        // pulse) drops the buffer in any state; one in flight is dropped
        // when its burst ends.
        if ( PREFETCH && pf_clear )
        begin
                pf_valid_nxt = 1'd0;
                pf_pend_nxt  = 1'd0;
                if ( pf_active_nxt )
                begin
                        pf_drop_nxt = 1'd1;
                end
        end
end:blk1

// ----------------------------------------------------------------------------
// Tasks and functions.
// ----------------------------------------------------------------------------

function automatic [31:0] adapt_cache_data (
        input [$clog2(CACHE_LINE) - 3:0] shift,
        input [CACHE_LINE*8-1:0]         data
);
        localparam [31:0] W = $clog2(CACHE_LINE) + 3;

        /* verilator lint_off UNUSEDSIGNAL */
        logic [LINE_PAD-1:0] dummy;
        /* verilator lint_on UNUSEDSIGNAL */

        logic [W-1:0] shamt;

        shamt                     = {shift, 5'd0};
        {dummy, adapt_cache_data} =  data >> shamt;

endfunction : adapt_cache_data

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

endmodule : zap_cache_fsm

// ----------------------------------------------------------------------------
// END OF FILE
// ----------------------------------------------------------------------------
