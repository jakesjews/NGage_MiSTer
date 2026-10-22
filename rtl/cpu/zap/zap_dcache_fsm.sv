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
output  logic [63:0]               o_reg_idx,
output  logic     [31:0]           o_dat,
output  logic                      o_ack,
output  logic                      o_err,
output  logic     [7:0]            o_fsr,
output  logic     [31:0]           o_far,
output  logic                      o_err2,

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
output  logic                      o_idle,

// Bus access ports, both NXT and FF.
output  logic             o_wb_cyc_ff, o_wb_cyc_nxt,
output  logic             o_wb_stb_ff, o_wb_stb_nxt,
output  logic     [31:0]  o_wb_adr_ff, o_wb_adr_nxt,
output  logic     [31:0]  o_wb_dat_ff, o_wb_dat_nxt,
output  logic     [3:0]   o_wb_sel_ff, o_wb_sel_nxt,
output  logic             o_wb_wen_ff, o_wb_wen_nxt,
output  logic     [2:0]   o_wb_cti_ff, o_wb_cti_nxt,
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
localparam [2:0] UNLOCK_REG           = 3'd7; // Unlock register
localparam [3:0] LINEOP               = 4'd8; // ARM925T: single-line operation
localparam [3:0] UNC_DONE             = 4'd9; // ARM925T: uncacheable access completes
localparam [3:0] UNLOCK_WR            = 4'd10; // ARM925T: background load written
localparam [31:0] NUMBER_OF_STATES    = 32'd11;

localparam [31:0] ADR_PAD              =  32'd32 - $clog2(CACHE_LINE/4) - 32'd1;
localparam [31:0] ADR_PAD_MINUS_2      =  ADR_PAD - 32'd2;
localparam [31:0] LINE_PAD             = (CACHE_LINE * 32'd8) - 32'd32;

// ----------------------------------------------------------------------------
// Variables
// ----------------------------------------------------------------------------

logic                                     cache_dirty;

logic [NUMBER_OF_STATES-1:0]              state_ff, state_nxt;
logic [31:0]                              buf_ff [(CACHE_LINE/4)-1:0];
logic [31:0]                              buf_nxt[(CACHE_LINE/4)-1:0];
logic                                     cache_clean_req_nxt,
                                          cache_clean_req_ff;
logic                                     cache_inv_req_nxt,
                                          cache_inv_req_ff;
logic                                     line_req_nxt, line_req_ff; // ARM925T
logic [$clog2(CACHE_LINE/4):0]            adr_ctr_ff, adr_ctr_nxt; // Needs to take on 0,1,2,3, ... CACHE_LINE/4
logic                                     rhit, whit;

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
logic    [63:0]                           reg_idx;
logic    [63:0]                           lock_nxt, lock_ff;
logic                                     wt_hit, wt_dirty; // ARM925T: write-through store.
logic    [5:0]                            ldfmt;            // ARM925T: format of a background load.
logic    [31:0]                           unc_dat_ff;       // ARM925T: registered bus response
logic    [31:0]                           reg_dat_ff;       // ARM925T: background load value
logic                                     unc_err_ff;       // ARM925T

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
assign o_cache_clean_req = cache_clean_req_ff; // Tie req flop to output.
assign o_cache_inv_req   = cache_inv_req_ff;   // Tie inv flop to output.
assign o_line_req        = line_req_ff;        // ARM925T

// Alias (ARM925T: the tag compare is in the tag RAM, i_cache_hit)
assign cache_dirty = i_cache_tag_dirty;

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
        else if ( state_nxt[UNLOCK_REG] )
        begin
                cache_line      <= o_cache_line;
        end
end

//
// ARM925T: the bus response of an uncacheable access is registered and
// passed on in UNC_DONE, a cycle later, so that the bus acknowledge and
// error are not in the same cycle as the pipeline's stall (timing).
//
// ARM925T: the value of a background load, written to its register in
// UNLOCK_WR, a cycle after the line arrives (timing).
always_ff @ ( posedge i_clk )
begin
        if ( state_ff[UNLOCK_REG] )
        begin
                reg_dat_ff <= ld_transform(adapt_cache_data(address[$clog2(CACHE_LINE)-1:2],
                                                            cache_line), ldfmt);
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
                phy_addr        <= i_phy_addr;
                way             <= i_cache_way;
                reg_idx         <= i_reg_idx;
                ldfmt           <= i_ldfmt;
                wt_hit          <= i_wr && i_wt && i_cacheable && i_cache_hit;
                wt_dirty        <= i_cache_hit_dirty;
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

// Idle indication
always_ff @ ( posedge i_clk )
begin
        o_idle <= state_nxt[IDLE];
end

// STATE MACHINE (Next State Logic)
always_comb
begin:next_state_logic

       // =======================================================
       // Local Vars Section
       // =======================================================

       logic [$clog2(CACHE_LINE/4)-1:0] tmp;

        // =====================================================
        // Default values section
        // (Done to avoid combo loops/incomplete assignments).
        // =====================================================

        tmp                     = {($clog2(CACHE_LINE/4)){1'd0}};
        state_nxt               = state_ff;
        adr_ctr_nxt             = adr_ctr_ff;
        o_wb_cyc_nxt            = o_wb_cyc_ff;
        o_wb_stb_nxt            = o_wb_stb_ff;
        o_wb_adr_nxt            = o_wb_adr_ff;
        o_wb_dat_nxt            = o_wb_dat_ff;
        o_wb_cti_nxt            = o_wb_cti_ff;
        lock_nxt                = lock_ff;
        o_wb_wen_nxt            = o_wb_wen_ff;
        o_wb_sel_nxt            = o_wb_sel_ff;
        cache_clean_req_nxt     = cache_clean_req_ff;
        cache_inv_req_nxt       = cache_clean_req_ff;
        line_req_nxt            = line_req_ff;
        o_line_done             = 0;
        o_lock                  = lock_ff;
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
        o_reg_dat               = 32'd0;
        o_reg_idx               = 64'd0;
        o_ack                   = 0;
        o_err                   = 0;
        o_err2                  = 0;
        o_address               = address;
        o_cache_way             = way;

        for(int i=0;i<CACHE_LINE/4;i++)
        begin
                buf_nxt[i] = buf_ff[i];
        end

        rhit = 1'd0;
        whit = 1'd0;

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
                `zap_kill_access

                if ( !i_rd && !i_wr )
                begin
                        //
                        // ARM925T: maintenance is only looked at when there
                        // is no access (CP15 starts it with the pipeline
                        // empty), and is acknowledged like an idle cycle, so
                        // that the requests from CP15 are not in the path
                        // from o_ack to the pipeline stall (timing).
                        //
                        o_ack = 1'd1;

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
                        o_ack = 1'd1;
                        o_fsr = 8'b0000_0001;
                        o_far = i_va;
                end
                else if ( i_fault )
                begin
                        // MMU access fault.
                        o_err = 1'd1;
                        o_ack = 1'd1;
                        o_fsr = i_fsr;
                        o_far = i_far;
                end
                else if ( i_busy )
                begin
                        // Wait it out - this is what err2 is for.
                        o_err2 = 1'd1;
                        o_ack  = 1'd1;
                end
                else if ( i_rd || i_wr )
                begin
                        if ( !i_cache_en )
                        begin
                                o_hold          = 1'd1;

                                state_nxt[IDLE] = 1'd0;
                                state_nxt[UNCACHEABLE] = 1'd1;

                                o_ack           = 1'd0; // Wait...
                                o_wb_stb_nxt    = 1'd1;
                                o_wb_cyc_nxt    = 1'd1;
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

                                o_ack           = 1'd0; // Wait...
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
                                if ( i_wr )
                                begin
                                        o_cache_line                     = {(CACHE_LINE/4){i_din}};
                                        o_cache_line_ben                 = ben_comp ( i_address[$clog2(CACHE_LINE)-1:2], i_ben );
                                        o_cache_tag_wr_en                = 1'd1;
                                        o_cache_tag[`ZAP_CACHE_TAG__TAG] = i_address[`ZAP_VA__CACHE_TAG];
                                        o_cache_tag_dirty                = 1'd1;
                                        o_cache_tag[`ZAP_CACHE_TAG__PA]  = i_phy_addr[31 : $clog2(CACHE_LINE)];
                                        o_address                        = i_address;
                                        o_cache_way                      = i_cache_way;
                                end

                                // ARM925T: the valid bit is the victim's: a
                                // hit is a hit whatever it says.
                                casez ({i_cache_hit,i_cache_tag_valid})

                                2'b1?: // Cache Hit
                                begin
                                        if ( i_rd ) // Read request.
                                        begin
                                                rhit    = 1'd1;
                                                o_ack   = 1'd1;
                                        end
                                        else if ( i_wr ) // Write request (the write itself is above)
                                        begin
                                                o_ack        = 1'd1;
                                                whit         = 1'd1;
                                        end
                                end

                                2'b01: // Unrelated tag, possibly dirty.
                                begin
                                        // Acknowledge current entry. Lock the register.
                                        o_ack               = 1'd1;

                                        // Lock register on load. ARM925T: upstream also
                                        // raised o_err2 if that register was locked, but
                                        // no register is locked in IDLE (a lock lasts
                                        // until UNLOCK_REG), and the term was in the
                                        // critical tag-compare to pipeline-stall path.
                                        if ( i_rd )
                                        begin
                                                lock_nxt[i_reg_idx_bin] = 1'd1;
                                        end

                                        if ( cache_dirty )
                                        begin
                                                // Set up counter
                                                adr_ctr_nxt = 0;

                                                // Clean a single cache line
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
                                                o_ack  = 1'd1;

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

                                o_ack           = 1'd0; // Wait...
                                o_hold          = 1'd1;
                        end
                end
        end

        state_ff[UNCACHEABLE_PREPARE]:
        begin
                o_ack           = 1'd0;
                o_hold          = 1'd1;

                state_nxt[UNCACHEABLE_PREPARE] = 1'd0;
                state_nxt[UNCACHEABLE]         = 1'd1;

                o_wb_stb_nxt    = 1'd1;
                o_wb_cyc_nxt    = 1'd1;
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
                o_ack  = 1'd0;
                o_hold = 1'd1;

                if ( i_wb_ack | i_wb_err )
                begin
                        // ARM925T: complete in UNC_DONE (registered response).
                        state_nxt[UNCACHEABLE] = 1'd0;
                        state_nxt[UNC_DONE]    = 1'd1;

                        `zap_kill_access;
                end
        end

        state_ff[UNC_DONE]: // ARM925T: the uncacheable access completes.
        begin
                o_ack           = 1'd1;
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
                        else if ( wt_hit )
                        begin
                                // ARM925T: write-through hit: update the line too.
                                o_cache_line                     = {(CACHE_LINE/4){din}};
                                o_cache_line_ben                 = ben_comp (address[$clog2(CACHE_LINE)-1:2], ben);
                                o_cache_tag_wr_en                = 1'd1;
                                o_cache_tag[`ZAP_CACHE_TAG__TAG] = address[`ZAP_VA__CACHE_TAG];
                                o_cache_tag_dirty                = wt_dirty;
                                o_cache_tag[`ZAP_CACHE_TAG__PA]  = phy_addr[31 : $clog2(CACHE_LINE)];
                                o_address                        = address;
                        end

                        `zap_kill_access;
                end
        end

        state_ff[CLEAN_SINGLE]: // Clean single cache line
        begin
                `zap_hit_under_miss;

                if(!rhit && !whit)
                begin
                        o_ack  = 1'd1;
                        o_err2 = i_rd || i_wr ? 1'd1 : 1'd0;
                end

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
                       o_wb_sel_nxt =  4'b1111;
                end
                else
                begin
                        // Move to wait state
                        `zap_kill_access;

                        adr_ctr_nxt = 0;

                        state_nxt[CLEAN_SINGLE] = 1'd0;
                        state_nxt[FETCH_SINGLE] = 1'd1;

                        // Update tag. Remove dirty bit.
                        o_cache_tag_wr_en                      = 1'd1; // Implicitly sets valid (redundant).
                        o_cache_tag[`ZAP_CACHE_TAG__TAG]       = cache_tag[`ZAP_CACHE_TAG__TAG]; // Preserve.
                        o_cache_tag_dirty                      = 1'd0;
                        o_cache_tag[`ZAP_CACHE_TAG__PA]        = cache_tag[`ZAP_CACHE_TAG__PA]; // Preserve.
                end
        end

        state_ff[FETCH_SINGLE]: // Fetch a single cache line
        begin
                `zap_hit_under_miss;

                if(!rhit && !whit)
                begin
                        o_ack  = 1'd1;
                        o_err2 = i_rd || i_wr ? 1'd1 : 1'd0;
                end

                // Generate address
                adr_ctr_nxt = take ? adr_ctr_inc : adr_ctr_ff;

                // Write to buffer
                buf_nxt[adr_ctr_ff[$clog2(CACHE_LINE/4)-1:0]] = (i_wb_ack|i_wb_err) ?
                                                                i_wb_dat :
                                                                buf_ff[adr_ctr_ff[$clog2(CACHE_LINE/4)-1:0]];

                // Manipulate buffer as needed
                if ( wr )
                begin
                        tmp = address[$clog2(CACHE_LINE/4)+1:2]; // Use value of X/4.

                        buf_nxt[tmp][7:0]   = ben[0] ? din[7:0]   : buf_nxt[tmp][7:0];
                        buf_nxt[tmp][15:8]  = ben[1] ? din[15:8]  : buf_nxt[tmp][15:8];
                        buf_nxt[tmp][23:16] = ben[2] ? din[23:16] : buf_nxt[tmp][23:16];
                        buf_nxt[tmp][31:24] = ben[3] ? din[31:24] : buf_nxt[tmp][31:24];
                end

                if ( take ? beat_inc_ok : beat_cur_ok )
                begin

                        // Fetch line from memory
                        `zap_wb_prpr_read(take ? fetch_adr_inc : fetch_adr_cur, take ? cti_inc : cti_cur);
                end
                else
                begin:blk12
                        // Update cache with previous buffers. Here _nxt refers to _ff except for the last one.

                        o_cache_line = 0;

                        for(int i=0;i<CACHE_LINE/4;i++)
                        begin
                                o_cache_line = o_cache_line | ({{LINE_PAD{1'd0}},buf_nxt[i][31:0]} << (32 * i));
                        end

                        o_cache_line_ben  = {CACHE_LINE{1'd1}};

                        // Update tag. Remove dirty and set valid
                        o_cache_tag_wr_en                       = 1'd1; // Implicitly sets valid.
                        o_cache_tag[`ZAP_CACHE_TAG__TAG]        = address[`ZAP_VA__CACHE_TAG];
                        o_cache_tag[`ZAP_CACHE_TAG__PA]         = phy_addr[31:$clog2(CACHE_LINE)];
                        o_cache_tag_dirty                       = !wr ? 1'd0 : 1'd1; // BUG FIX.

                        // Move to idle state
                        `zap_kill_access;

                        state_nxt[FETCH_SINGLE] = 1'd0;
                        state_nxt[UNLOCK_REG]   = 1'd1;
                end
        end

        state_ff[UNLOCK_REG]: // Load data into the register if required.
        begin
                `zap_hit_under_miss;

                if(!rhit && !whit)
                begin
                        o_ack  = 1'd1;
                        o_err2 = i_rd || i_wr ? 1'd1 : 1'd0;
                end

                if ( !wr )
                begin
                        // ARM925T: the register is written in UNLOCK_WR, from
                        // reg_dat_ff (the load's byte/halfword selection, sign
                        // extension or rotation; upstream wrote the whole word
                        // for every load, here, in the same cycle).
                end
                else // Update cache line.
                begin
                        o_ack        = 1'd1;

                        o_cache_line =
                        {(CACHE_LINE/4){din}};

                        o_cache_line_ben  = ben_comp (
                                address[$clog2(CACHE_LINE)-1:2],
                                ben );

                        // Write to tag and also write out physical address.
                        o_cache_tag_wr_en                = 1'd1;
                        o_cache_tag[`ZAP_CACHE_TAG__TAG] = address[`ZAP_VA__CACHE_TAG];
                        o_cache_tag_dirty                = 1'd1;
                        o_cache_tag[`ZAP_CACHE_TAG__PA]  = phy_addr[31 : $clog2(CACHE_LINE)];
                        o_address                        = address;
                end

                // Back to IDLE (ARM925T: through UNLOCK_WR for a load)
                state_nxt[UNLOCK_REG] = 1'd0;
                state_nxt[UNLOCK_WR]  = !wr;
                state_nxt[IDLE]       = wr;
        end

        state_ff[UNLOCK_WR]: // ARM925T: write the loaded register, unlock it.
        begin
                o_ack  = 1'd1;
                o_err2 = i_rd || i_wr ? 1'd1 : 1'd0;

                o_reg_dat = reg_dat_ff;
                o_reg_idx = reg_idx;

                //
                // Unlock the register on load. Clear the bit. Invert reg
                // idx and AND. Removes bits that were marked as 1 in reg_idx.
                //
                lock_nxt &= ~(reg_idx);

                state_nxt[UNLOCK_WR] = 1'd0;
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
                        o_line_done           = 1'd1;
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
                tmp                     = 'x;
                state_nxt               = 'x;
                adr_ctr_nxt             = 'x;
                o_wb_cyc_nxt            = 'x;
                o_wb_stb_nxt            = 'x;
                o_wb_adr_nxt            = 'x;
                o_wb_dat_nxt            = 'x;
                o_wb_cti_nxt            = 'x;
                lock_nxt                = 'x;
                o_wb_wen_nxt            = 'x;
                o_wb_sel_nxt            = 'x;
                cache_clean_req_nxt     = 'x;
                cache_inv_req_nxt       = 'x;
                line_req_nxt            = 'x;
                o_line_done             = 'x;
                o_lock                  = 'x;
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
                o_reg_dat               = 'x;
                o_reg_idx               = 'x;
                o_ack                   = 'x;
                o_err                   = 'x;
                o_err2                  = 'x;
                o_address               = 'x;
                o_cache_way             = 'x;
                rhit                    = 'x;
                whit                    = 'x;

                for(int i=0;i<CACHE_LINE/4;i++)
                begin
                        buf_nxt[i] = 'x;
                end
        end
        endcase
end : next_state_logic

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

endmodule : zap_dcache_fsm

// ----------------------------------------------------------------------------
// END OF FILE
// ----------------------------------------------------------------------------
