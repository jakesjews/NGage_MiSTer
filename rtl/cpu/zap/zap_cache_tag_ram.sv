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
// This is the tag RAM and data RAM unit. The tag RAM holds both the
// virtual tag and the physical address. The physical address is used to
// avoid translation during clean operations. The cache data RAM is also
// present in this unit. This unit has a dedicated memory interface
// because it can perform global clean and flush by itself without
// depending on the cache controller.
//
// ARM925T: WAYS ways (1 or 2). Each way is a tag RAM and a data RAM of
// CACHE_SIZE/WAYS bytes, all read together at the set index of
// i_address_nxt. The hit (o_cache_hit) and the way of interest
// (o_cache_way: the way holding i_lookup_address, else the way a fill
// would take: an invalid way, else the least recently used) are found
// here. o_cache_words are the ways' words at the lookup address, chosen
// from the lines by the address bits (registers) before the hit chooses
// the way (o_cache_word_sel, the hit on way 1), so that the late select
// passes one 32-bit mux and the FSM can format each word in parallel
// with the compares; o_cache_line is the victim's line for a write-back;
// o_cache_tag, o_cache_tag_valid and o_cache_tag_dirty are the victim's
// too, all chosen from registers alone, so the
// FSM's miss decision does not wait for the compares (a hit is a hit
// whatever they say); o_cache_hit_dirty is the hit way's dirty bit. A
// write while the FSM is idle (i_idle) is a store hit: it goes to the way
// that hits, to no way on a miss, so the FSM presents it whatever the
// compares say and they gate the write enables directly. Any other write
// goes to i_cache_way, which the FSM returns from
// o_cache_way (buffered across a fill). One LRU bit per set, the TI925T's
// fixed LRU (TI SPRU671), updated on hits and fills; it is read with the
// set, pipelined and forwarded like the valid bits, so that the way of
// interest is one level of logic past the tag compares. A whole-cache clean
// walks the lines of every way; a single-line operation by VA finds the
// way holding the tag, one by index takes i_line_way.
//

`include "zap_defines.svh"

module zap_cache_tag_ram #(

parameter logic [31:0] CACHE_SIZE = 32'd1024, // Bytes, all ways together.
parameter logic [31:0] CACHE_LINE = 32'd8,
parameter logic [31:0] WAYS       = 32'd1     // ARM925T: 1 or 2.

)(

input   logic                            i_clk,
input   logic                            i_reset,
input   logic    [31:0]                  i_address_nxt,
input   logic    [31:0]                  i_address,
input   logic                            i_hold,
input   logic                            i_cache_en,
input   logic    [CACHE_LINE*8-1:0]      i_cache_line,
input   logic    [CACHE_LINE-1:0]        i_cache_line_ben,
output  logic    [CACHE_LINE*8-1:0]      o_cache_line,
output  logic    [WAYS-1:0][31:0]        o_cache_words,     // ARM925T: each way's word at the lookup address
output  logic                             o_cache_word_sel,  // ARM925T: the hit way's word is o_cache_words[1]
input   logic                            i_cache_tag_wr_en,
input   logic    [`ZAP_CACHE_TAG_WDT-1:0]i_cache_tag,
input   logic                            i_cache_tag_dirty,

output  logic    [`ZAP_CACHE_TAG_WDT-1:0] o_cache_tag,
output  logic                             o_cache_tag_valid,
output  logic                             o_cache_tag_dirty,

//
// ARM925T: the access being looked up (the FSM's i_address, three cycles
// after i_address_nxt, as the RAMs' outputs) and whether it is an access
// at all (for the LRU); the hit and the way of interest for it; the way
// a write (i_cache_tag_wr_en, i_cache_line_ben at i_address) goes to.
//
input   logic    [31:0]                   i_lookup_address,
input   logic                             i_access,
input   logic                             i_idle,
output  logic                             o_cache_hit,
output  logic                             o_cache_hit_dirty,
output  logic    [(WAYS > 1 ? $clog2(WAYS) : 1)-1:0] o_cache_way,
input   logic    [(WAYS > 1 ? $clog2(WAYS) : 1)-1:0] i_cache_way,

input   logic                             i_cache_clean_req,

/* verilator lint_off UNOPTFLAT */
output  logic                             o_cache_clean_done,
/* verilator lint_on UNOPTFLAT */

input   logic                             i_cache_inv_req,

/* verilator lint_off UNOPTFLAT */
output  logic                             o_cache_inv_done,
/* verilator lint_on UNOPTFLAT */

//
// ARM925T: single-line operation. While i_line_req is high, clean
// (i_line_op[0]) and/or invalidate (i_line_op[1]) the line at
// i_line_addr's index; with i_line_va, the way whose tag matches
// i_line_addr, if any (an operation by VA), else way i_line_way, whatever
// it holds (by index). o_line_done answers until i_line_req falls.
//
input   logic                             i_line_req,
input   logic    [1:0]                    i_line_op,
input   logic                             i_line_va,
input   logic    [31:0]                   i_line_addr,
input   logic    [(WAYS > 1 ? $clog2(WAYS) : 1)-1:0] i_line_way,
output  logic                             o_line_done,

//
// Cache clean operations occur through these ports.
// Bus access ports.
//
output  logic                             o_wb_cyc_ff, o_wb_cyc_nxt,
output  logic                             o_wb_stb_ff, o_wb_stb_nxt,
output  logic     [31:0]                  o_wb_adr_ff, o_wb_adr_nxt,
output  logic     [31:0]                  o_wb_dat_ff, o_wb_dat_nxt,
output  logic     [3:0]                   o_wb_sel_ff, o_wb_sel_nxt,
output  logic                             o_wb_wen_ff, o_wb_wen_nxt,
output  logic     [2:0]                   o_wb_cti_ff, o_wb_cti_nxt,
input logic      [31:0]                   i_wb_dat,
input logic                               i_wb_ack

);

// ----------------------------------------------------------------------------

`include "zap_localparams.svh"

// ARM925T: lines of a way (sets), lines of all ways, and their widths.
localparam [31:0] LINES     = CACHE_SIZE / WAYS / CACHE_LINE;
localparam [31:0] LINES_ALL = CACHE_SIZE / CACHE_LINE;
localparam [31:0] SET_W     = $clog2(LINES);
localparam [31:0] WAY_W     = WAYS > 1 ? $clog2(WAYS) : 32'd1;
localparam [31:0] FLAT_W    = $clog2(LINES_ALL);      // A line of any way: {way, set}.

localparam [31:0] NUMBER_OF_DIRTY_BLOCKS = LINES_ALL/16; // Keep cache size > 16 bytes.

// States.
typedef enum logic [12:0] {
        IDLE                           = 13'b0_0000_0000_0001,
        CACHE_CLEAN_GET_ADDRESS        = 13'b0_0000_0000_0010,
        CACHE_CLEAN_WRITE_PRE_PRE_WAIT = 13'b0_0000_0000_0100,
        CACHE_CLEAN_WRITE_PRE_WAIT     = 13'b0_0000_0000_1000,
        CACHE_CLEAN_WRITE_PRE          = 13'b0_0000_0001_0000,
        CACHE_CLEAN_WRITE              = 13'b0_0000_0010_0000,
        CACHE_INV                      = 13'b0_0000_0100_0000,
        LINE_W0                        = 13'b0_0000_1000_0000, // ARM925T: line operation
        LINE_W1                        = 13'b0_0001_0000_0000,
        LINE_W2                        = 13'b0_0010_0000_0000,
        LINE_W3                        = 13'b0_0100_0000_0000,
        LINE_CHECK                     = 13'b0_1000_0000_0000,
        LINE_INV                       = 13'b1_0000_0000_0000,
        `ZAP_DEFAULT_XX
} t_state;

// Padding widths.
localparam [31:0] BLK_CTR_PAD = 32 - $clog2(NUMBER_OF_DIRTY_BLOCKS) - 1;
localparam [31:0] ADR_CTR_PAD = 32 - $clog2(CACHE_LINE/4) - 1;
localparam [31:0] ZERO_WDT    = $clog2(CACHE_LINE/4) + 1;

// ----------------------------------------------------------------------------

logic [LINES_ALL-1:0]                      dirty;
logic [LINES_ALL-1:0]                      valid;
logic [LINES-1:0]                          lru;                 // ARM925T: the way to fill next (WAYS = 2).
logic [`ZAP_CACHE_TAG_WDT-1:0]             tag_ram_wr_data;
logic                                      tag_ram_wr_en;
logic [SET_W-1:0]                          tag_ram_wr_addr;     // The set written.
logic [WAYS-1:0]                           wr_sel;              // ARM925T: the way written, one-hot (none: no write).
logic [SET_W-1:0]                          rd_set, rd_set_del, rd_set_del2;   // The set read, in every way.
logic [FLAT_W-1:0]                         rd_flat_ff, rd_flat_nxt;           // ARM925T: the clean walk's or line operation's line.
logic [WAY_W-1:0]                          rd_way;                            // ARM925T: its way.
logic [SET_W-1:0]                          lk_set;              // ARM925T: the lookup's set.
logic                                      tag_ram_clear;
logic                                      tag_ram_clean;
t_state                                    state_ff, state_nxt;
logic [$clog2(NUMBER_OF_DIRTY_BLOCKS):0]   blk_ctr_ff, blk_ctr_nxt;
logic [$clog2(CACHE_LINE/4):0]             adr_ctr_ff, adr_ctr_nxt;
logic [WAYS-1:0]                           dirty_s1, dirty_s2, dirty_q;   // ARM925T: per way, aligned with the RAMs' reads.
logic [WAYS-1:0]                           valid_s1, valid_s2, valid_q;
logic [WAYS-1:0]                           hit;                 // ARM925T: per way.
logic [WAY_W-1:0]                          sel, victim;         // ARM925T: the way of interest; the way a fill takes.
logic [WAYS-1:0][`ZAP_CACHE_TAG_WDT-1:0]   tag_q;               // ARM925T: the tag RAMs' outputs.
logic [WAYS-1:0][CACHE_LINE*8-1:0]         line_q;              // ARM925T: the data RAMs' outputs.
logic [`ZAP_CACHE_TAG_WDT-1:0]             walk_tag;            // ARM925T: the walk's or line operation's line.
logic [$clog2(CACHE_LINE)-3:0]             lk_word;             // ARM925T: the lookup's word in its line.
logic [CACHE_LINE*8-1:0]                   walk_line;
logic                                      lru_s1, lru_s2, lru_q; // ARM925T: the set's LRU bit, aligned with the RAMs' reads.
logic                                      hit_upd_en;          // ARM925T: a hit updates the LRU bit of lk_set.
logic                                      hit_pend_en, hit_pend_val; // ARM925T: that update, written a cycle later.
logic [SET_W-1:0]                          hit_pend_set;
logic                                      cache_clean_done_nxt, cache_clean_done_ff;
logic                                      line_mode_ff, line_mode_nxt;   // ARM925T
logic                                      line_hit_ff, line_hit_nxt;     // ARM925T
logic                                      line_done_ff, line_done_nxt;   // ARM925T
logic                                      line_clear;                    // ARM925T
logic                                      pend_en, pend_dirty;           // ARM925T: write-behind
logic [SET_W-1:0]                          pend_addr;                     // ARM925T
logic [WAYS-1:0]                           pend_sel;                      // ARM925T: its way, one-hot
logic [WAYS-1:0][FLAT_W-1:0]               pend_flat;                     // ARM925T: its line in each way

logic                                      unused;
logic [BLK_CTR_PAD-1:0]                    dummy;
logic [CACHE_LINE*8-32-1:0]                line_dummy;
logic                                      cache_unused0;
logic                                      cache_unused1;
logic [WAYS-1:0][CACHE_LINE*8-1:0]         w_dummy;
logic [WAYS-1:0][`ZAP_CACHE_TAG_WDT-1:0]   w_dummy_1;

initial
begin
        assert ( WAYS == 1 || WAYS == 2 ) else
        $fatal(2, "zap_cache_tag_ram: WAYS must be 1 or 2.");
end

assign cache_unused0 = |{i_address[31: $clog2(CACHE_LINE)+SET_W], i_address[$clog2(CACHE_LINE)-1:0],
                         i_lookup_address[$clog2(CACHE_LINE)-1:0]};
assign cache_unused1 = |{i_address_nxt[31: $clog2(CACHE_LINE)+SET_W], i_address_nxt[$clog2(CACHE_LINE)-1:0]};
assign        unused = |{dummy, line_dummy, i_wb_dat, cache_unused0, cache_unused1, w_dummy, w_dummy_1};

// ARM925T: a line of any way as an index into valid and dirty.
function automatic [FLAT_W-1:0] flat ( input [WAY_W-1:0] w, input [SET_W-1:0] s );
        return FLAT_W'({w, s});
endfunction : flat

// ----------------------------------------------------------------------------

// ARM925T: one tag RAM and one data RAM per way, read at the same set.
for ( genvar w = 0; w < WAYS; w++ )
begin : g_way

zap_ram_simple_ben #(.WIDTH(CACHE_LINE*8), .DEPTH(LINES)) u_zap_ram_simple_data_ram (
        .i_clk(i_clk),
        .i_clken(!i_hold),

        .i_wr_en(i_cache_line_ben & {CACHE_LINE{wr_sel[w]}}),
        .i_wr_data(i_cache_line),

        .o_rd_data_pre(w_dummy[w]),
        .o_rd_data(line_q[w]),

        .i_wr_addr(tag_ram_wr_addr),
        .i_rd_addr(rd_set)
);

zap_ram_simple #(.WIDTH(`ZAP_CACHE_TAG_WDT), .DEPTH(LINES)) u_zap_ram_simple_tag (
        .i_clk(i_clk),
        .i_clken(!i_hold),

        .i_wr_en(tag_ram_wr_en && wr_sel[w]),
        .i_wr_data(tag_ram_wr_data),

        .o_rd_data_pre(w_dummy_1[w]),
        .o_rd_data(tag_q[w]),

        .i_wr_addr(tag_ram_wr_addr),
        .i_rd_addr(rd_set)
);

end : g_way

// ----------------------------------------------------------------------------

//
// ARM925T: the hit and the way of interest for the access at
// i_lookup_address, whose set the RAMs' outputs hold. The outputs the FSM
// sees are that way's: on a hit the line it reads or writes, on a miss the
// line a fill replaces (its tag and dirty bit decide a write-back).
//
assign lk_set  = i_lookup_address[`ZAP_VA__CACHE_INDEX];
assign lk_word = i_lookup_address[$clog2(CACHE_LINE)-1:2];

// Each way's word at the lookup address, from registers: the way is
// chosen after, by the hit.
always_comb
begin
        for ( int w = 0; w < WAYS; w++ )
        begin
                o_cache_words[w] = line_q[w][32 * lk_word +: 32];
        end
end

always_comb
begin
        for ( int w = 0; w < WAYS; w++ )
        begin
                hit[w] = valid_q[w] &&
                         ( tag_q[w][`ZAP_CACHE_TAG__TAG] == i_lookup_address[`ZAP_VA__CACHE_TAG] );
        end
end

if ( WAYS == 1 )
begin : g_direct
        assign victim            = 1'd0;
        assign sel               = 1'd0;
        assign lru               = '0;
        assign lru_q             = 1'd0;
        assign lru_s1            = 1'd0;
        assign lru_s2            = 1'd0;
        assign hit_pend_en       = 1'd0;
        assign hit_pend_val      = 1'd0;
        assign hit_pend_set      = '0;
        assign o_cache_tag       = tag_q[0];
        assign o_cache_line      = line_q[0];
        assign o_cache_word_sel  = 1'd0;
        assign o_cache_tag_valid = valid_q[0];
        assign o_cache_tag_dirty = dirty_q[0];
        assign o_cache_hit_dirty = dirty_q[0];
        assign walk_tag          = tag_q[0];
        assign walk_line         = line_q[0];
end
else
begin : g_lru
        //
        // The LRU bit of a set names the way to fill next: after a hit or a
        // fill, the other way. The bit is read with the set the RAMs read
        // and pipelined three deep with the pending updates forwarded (as
        // the valid bits are), so that the victim is a register's worth of
        // logic at the output. Both updates are written a cycle behind
        // (write-behind, as the tag writes): the hit's through hit_pend_*,
        // the fill's through pend_*. The hit, the later event, wins a set.
        //
        assign victim            = !valid_q[0] ? 1'd0 : !valid_q[1] ? 1'd1 : lru_q;
        assign sel               = hit[1] ? 1'd1 : hit[0] ? 1'd0 : victim;
        assign hit_upd_en        = i_access && o_cache_hit;

        // Explicit 2:1 muxes: a variable part-select of the packed arrays
        // became a multiply by the tag width in the generated netlist, and
        // Quartus put it in a DSP block on the hit path. The tag, valid,
        // dirty bits and the line are the victim's (registers only); the
        // hit chooses only between the two words, and only way 1's hit
        // matters for that (on a miss the word is not used).
        assign o_cache_tag       = victim ? tag_q[1]   : tag_q[0];
        assign o_cache_line      = victim ? line_q[1]  : line_q[0];
        assign o_cache_word_sel  = hit[1];
        assign o_cache_tag_valid = victim ? valid_q[1] : valid_q[0];
        assign o_cache_tag_dirty = victim ? dirty_q[1] : dirty_q[0];
        assign o_cache_hit_dirty = hit[1] ? dirty_q[1] : dirty_q[0];
        assign walk_tag          = rd_way ? tag_q[1]  : tag_q[0];
        assign walk_line         = rd_way ? line_q[1] : line_q[0];

        // The pending updates (last cycle's, registered), forwarded into the
        // reads in flight at every stage, and this cycle's into the output
        // stage (as the valid bits); the hit's wins a set.
        function automatic logic lru_fwd ( input [SET_W-1:0] set, input logic prev );
                return set == hit_pend_set && hit_pend_en              ? hit_pend_val :
                       set == pend_addr    && pend_en && (|pend_sel) ? pend_sel[0]  :
                       prev;
        endfunction
        function automatic logic lru_fwd_now ( input [SET_W-1:0] set, input logic prev );
                return set == lk_set          && hit_upd_en                 ? ~sel      :
                       set == tag_ram_wr_addr && tag_ram_wr_en && (|wr_sel) ? wr_sel[0] :
                       lru_fwd ( set, prev );
        endfunction

        always_ff @ ( posedge i_clk )
        begin
                if ( i_reset )
                begin
                        hit_pend_en <= 1'd0;
                end
                else
                begin
                        hit_pend_en <= hit_upd_en && !i_hold;
                end

                hit_pend_set <= lk_set;
                hit_pend_val <= ~sel;
        end

        always_ff @ ( posedge i_clk )
        begin
                if ( i_reset || tag_ram_clear )
                begin
                        lru <= '0;
                end
                else
                begin
                        if ( pend_en && (|pend_sel) )
                        begin
                                lru [ pend_addr ] <= pend_sel[0]; // way 0 written: fill way 1 next
                        end

                        if ( hit_pend_en )
                        begin
                                lru [ hit_pend_set ] <= hit_pend_val;
                        end
                end
        end

        always_ff @ ( posedge i_clk )
        begin
                if ( i_reset )
                begin
                        lru_q  <= 1'd0;
                        lru_s2 <= 1'd0;
                        lru_s1 <= 1'd0;
                end
                else if ( !i_hold || tag_ram_clear || line_clear )
                begin
                        lru_q  <= lru_fwd_now ( rd_set_del2, lru_s2 );
                        lru_s2 <= lru_fwd ( rd_set_del,  lru_s1 );
                        lru_s1 <= lru_fwd ( rd_set,      lru [ rd_set ] );
                end
        end
end

assign o_cache_hit       = |hit;
assign o_cache_way       = sel;

// The way a write goes to: idle, the way that hits (a store hit); else the
// way the FSM buffered with the address (a fill, a clean, a write-through).
// (pend_flat: the pending write's line, a wire so that no function call
// indexes a nonblocking assignment, which Verilator 5.032 rejects.)
always_comb
begin
        for ( int w = 0; w < WAYS; w++ )
        begin
                wr_sel[w]    = i_idle ? hit[w] : ( i_cache_way == WAY_W'(w) );
                pend_flat[w] = flat ( WAY_W'(w), pend_addr );
        end
end

// ----------------------------------------------------------------------------

always_ff @ ( posedge i_clk )
begin
        if ( !i_hold )
        begin
                rd_set_del  <= rd_set;
                rd_set_del2 <= rd_set_del;
        end
end

//
// ARM925T: the valid and dirty bits are written one cycle after the tag RAM
// (write-behind), so that the late write enable from the D-cache FSM drives
// one register instead of the enables of every valid and dirty flop
// (timing). The reads in flight take the live write only into the output
// stage (the lookup two behind the writer, which is at the output in the
// cycle after the write) and the pending write, from pend_*, into every
// stage; upstream forwarded the live write into all three stages, so the
// live enable, a function of the tag compare, sat in front of each. Same
// cycles. Tag writes happen only in IDLE, where no clean, clear or line
// operation is active, and the arrays are read directly only outside IDLE.
//
always_ff @ ( posedge i_clk )
begin
        if ( i_reset )
        begin
                pend_en <= 1'd0;
        end
        else
        begin
                pend_en <= tag_ram_wr_en && !i_hold;
        end

        pend_addr  <= tag_ram_wr_addr;
        pend_sel   <= wr_sel;
        pend_dirty <= i_cache_tag_dirty;
end

always_ff @ ( posedge i_clk )
begin
        if ( i_reset )
        begin
                dirty_q               <= '0;
                dirty_s2              <= '0;
                dirty_s1              <= '0;
                dirty                 <= '0;
        end
        else
        begin
                if ( !i_hold || tag_ram_clean || line_clear )
                begin
                        for ( int w = 0; w < WAYS; w++ )
                        begin
                                dirty_q[w]  <= rd_set_del2 == tag_ram_wr_addr && tag_ram_wr_en && wr_sel[w]   ? i_cache_tag_dirty :
                                               rd_set_del2 == pend_addr       && pend_en       && pend_sel[w] ? pend_dirty        :
                                               dirty_s2[w];
                                dirty_s2[w] <= rd_set_del  == pend_addr && pend_en && pend_sel[w] ? pend_dirty : dirty_s1[w];
                                dirty_s1[w] <= rd_set      == pend_addr && pend_en && pend_sel[w] ? pend_dirty :
                                               dirty [ flat(WAY_W'(w), rd_set) ];
                        end
                end

                for ( int w = 0; w < WAYS; w++ )
                begin
                        if ( pend_en && pend_sel[w] )
                        begin
                                dirty [ pend_flat[w] ] <= pend_dirty;
                        end
                end

                if ( tag_ram_clean || line_clear )
                begin
                        dirty [ rd_flat_ff ] <= 1'd0;
                end
        end
end

always_ff @ ( posedge i_clk )
begin
        if ( i_reset )
        begin
                valid_q             <= '0;
                valid_s2            <= '0;
                valid_s1            <= '0;
                valid               <= '0;
        end
        else
        begin
                if ( !i_hold || tag_ram_clear || line_clear )
                begin
                        for ( int w = 0; w < WAYS; w++ )
                        begin
                                valid_q[w]  <= rd_set_del2 == tag_ram_wr_addr && tag_ram_wr_en && wr_sel[w]   ? 1'd1 :
                                               rd_set_del2 == pend_addr       && pend_en       && pend_sel[w] ? 1'd1 :
                                               valid_s2[w];
                                valid_s2[w] <= rd_set_del  == pend_addr && pend_en && pend_sel[w] ? 1'd1 : valid_s1[w];
                                valid_s1[w] <= rd_set      == pend_addr && pend_en && pend_sel[w] ? 1'd1 :
                                               valid [ flat(WAY_W'(w), rd_set) ];
                        end
                end

                // ARM925T: the pending write (above) first, then the clears.
                for ( int w = 0; w < WAYS; w++ )
                begin
                        if ( pend_en && pend_sel[w] )
                        begin
                                valid [ pend_flat[w] ] <= 1'd1;
                        end
                end

                // ARM925T: a disabled cache is cleared in every cycle, held
                // or not (upstream: only when not held). Nothing reads the
                // valid bits while the cache is off, and the hold, which
                // comes late from the cache FSM, no longer drives the
                // synchronous clear of every valid flop (timing).
                if ( tag_ram_clear || !i_cache_en )
                begin
                        valid <= '0;
                end
                else if ( line_clear )
                begin
                        valid [ rd_flat_ff ]   <= 1'd0; // ARM925T
                end
        end
end

// ----------------------------------------------------------------------------

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
                adr_ctr_ff              <= 0;
                blk_ctr_ff              <= 0;
                cache_clean_done_ff     <= 0;
                rd_flat_ff              <= 0;
                line_mode_ff            <= 0;
                line_hit_ff             <= 0;
                line_done_ff            <= 0;

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
                adr_ctr_ff              <= adr_ctr_nxt;
                blk_ctr_ff              <= blk_ctr_nxt;
                cache_clean_done_ff     <= cache_clean_done_nxt;
                rd_flat_ff              <= rd_flat_nxt;
                line_mode_ff            <= line_mode_nxt;
                line_hit_ff             <= line_hit_nxt;
                line_done_ff            <= line_done_nxt;

                // STATE
                state_ff                <= state_nxt;
        end
end

// ----------------------------------------------------------------------------

// The set the RAMs read: the next access in IDLE, else the walk's or line
// operation's line (ARM925T: and its way, for that line's outputs).
assign rd_set = state_ff == IDLE ?
                i_address_nxt [`ZAP_VA__CACHE_INDEX] :
                rd_flat_ff [SET_W-1:0];

assign rd_way = WAY_W'(rd_flat_ff >> SET_W);

always_comb
begin:blk1

        // --------------------------------------------------
        // Local Vars Section
        // --------------------------------------------------

        logic [31:0] shamt, data, pa;

        // --------------------------------------------------
        // Defaults Value Section
        // (Done to avoid combo loops/incomplete assignments).
        // --------------------------------------------------

        line_dummy              = {(CACHE_LINE*8-32){1'd0}};
        shamt                   = '0;
        data                    = '0;
        pa                      = '0;
        dummy                   = '0;
        state_nxt               = state_ff;
        rd_flat_nxt             = get_tag_ram_rd_addr (blk_ctr_ff, dirty);
        tag_ram_wr_addr         = i_address[`ZAP_VA__CACHE_INDEX];
        tag_ram_wr_en           = 0;
        tag_ram_clear           = 0;
        tag_ram_clean           = 0;
        adr_ctr_nxt             = adr_ctr_ff;
        blk_ctr_nxt             = blk_ctr_ff;
        cache_clean_done_nxt    = cache_clean_done_ff;
        o_cache_inv_done        = 0;
        line_mode_nxt           = line_mode_ff;
        line_hit_nxt            = line_hit_ff;
        line_done_nxt           = line_done_ff & i_line_req;
        line_clear              = 0;
        o_wb_cyc_nxt            = o_wb_cyc_ff;
        o_wb_stb_nxt            = o_wb_stb_ff;
        o_wb_adr_nxt            = o_wb_adr_ff;
        o_wb_dat_nxt            = o_wb_dat_ff;
        o_wb_sel_nxt            = o_wb_sel_ff;
        o_wb_wen_nxt            = o_wb_wen_ff;
        o_wb_cti_nxt            = o_wb_cti_ff;
        tag_ram_wr_data         = 0;
        o_cache_clean_done      = cache_clean_done_ff;
        o_line_done             = line_done_ff;

        // --------------------------------------------------
        // FSM Code Section
        // --------------------------------------------------

        case ( state_ff )

        IDLE:
        begin
                `zap_kill_access;

                tag_ram_wr_addr = i_address     [`ZAP_VA__CACHE_INDEX];
                tag_ram_wr_en   = i_cache_tag_wr_en;
                tag_ram_wr_data = i_cache_tag;

                cache_clean_done_nxt = 1'd0;

                if ( i_cache_clean_req && !cache_clean_done_ff )
                begin
                        tag_ram_wr_en = 0;
                        blk_ctr_nxt   = 0;

                        state_nxt     = CACHE_CLEAN_GET_ADDRESS;
                end
                else if ( i_cache_inv_req && !cache_clean_done_ff )
                begin
                        tag_ram_wr_en = 0;
                        state_nxt     = CACHE_INV;
                end
                else if ( i_line_req && !line_done_ff )
                begin
                        // ARM925T: read the line's tag, data, valid, dirty.
                        tag_ram_wr_en       = 0;
                        rd_flat_nxt         = flat ( i_line_way, i_line_addr[`ZAP_VA__CACHE_INDEX] );
                        line_mode_nxt       = 1'd1;
                        state_nxt           = LINE_W0;
                end
        end

        // ARM925T: wait for the pipelined RAMs (as for a clean).
        LINE_W0: begin rd_flat_nxt = rd_flat_ff; state_nxt = LINE_W1; end
        LINE_W1: begin rd_flat_nxt = rd_flat_ff; state_nxt = LINE_W2; end
        LINE_W2: begin rd_flat_nxt = rd_flat_ff; state_nxt = LINE_W3; end
        LINE_W3: begin rd_flat_nxt = rd_flat_ff; state_nxt = LINE_CHECK; end

        LINE_CHECK:
        begin
                // ARM925T: the way: by VA, the one holding the tag; by
                // index, i_line_way (already in rd_flat_ff).
                rd_flat_nxt  = rd_flat_ff;
                line_hit_nxt = 1'd0;

                for ( int w = 0; w < WAYS; w++ )
                begin
                        if ( valid [ flat(WAY_W'(w), rd_flat_ff[SET_W-1:0]) ] &&
                             ( i_line_va ? tag_q[w][`ZAP_CACHE_TAG__TAG] == i_line_addr[`ZAP_VA__CACHE_TAG]
                                         : WAY_W'(w) == rd_way ) )
                        begin
                                line_hit_nxt = 1'd1;
                                rd_flat_nxt  = flat ( WAY_W'(w), rd_flat_ff[SET_W-1:0] );
                        end
                end

                adr_ctr_nxt = 0;

                if ( i_line_op[0] && line_hit_nxt && dirty[rd_flat_nxt] )
                begin
                        // Write the line back (CACHE_CLEAN_WRITE returns to LINE_INV).
                        state_nxt = CACHE_CLEAN_WRITE;
                end
                else
                begin
                        state_nxt = LINE_INV;
                end
        end

        LINE_INV:
        begin
                rd_flat_nxt         = rd_flat_ff;
                line_clear          = i_line_op[1] && line_hit_ff;
                line_mode_nxt       = 1'd0;
                line_done_nxt       = 1'd1;
                state_nxt           = IDLE;
        end

        CACHE_CLEAN_GET_ADDRESS:
        begin
                if ( &baggage(dirty, blk_ctr_ff) )
                begin
                        // Move to next block.
                        {dummy, blk_ctr_nxt} = {dummy, blk_ctr_ff} + 32'd1;

                        if ( {{BLK_CTR_PAD{1'd0}}, blk_ctr_ff} == NUMBER_OF_DIRTY_BLOCKS - 1 )
                        begin
                                state_nxt            = IDLE;
                                cache_clean_done_nxt = 1'd1;
                        end
                end
                else
                begin
                        // Go to state.
                        state_nxt = CACHE_CLEAN_WRITE_PRE_PRE_WAIT;
                end

                adr_ctr_nxt     = 0; // Initialize address counter.
        end

        CACHE_CLEAN_WRITE_PRE_PRE_WAIT:
        begin
                state_nxt = CACHE_CLEAN_WRITE_PRE_WAIT;
        end

        CACHE_CLEAN_WRITE_PRE_WAIT: // Since RAM is pipelined.
        begin
                state_nxt       = CACHE_CLEAN_WRITE_PRE;
        end

        CACHE_CLEAN_WRITE_PRE: // Since RAM is pipelined.
        begin
                state_nxt       = CACHE_CLEAN_WRITE;
        end

        CACHE_CLEAN_WRITE:
        begin
                // ARM925T: a single-line write-back keeps reading its line.
                if ( line_mode_ff )
                begin
                        rd_flat_nxt = rd_flat_ff;
                end

                adr_ctr_nxt = adr_ctr_ff + ((i_wb_ack && o_wb_stb_ff) ?
                              {{(ZERO_WDT-1){1'd0}}, 1'd1} :
                              {ZERO_WDT{1'd0}});

                if ( {{ADR_CTR_PAD{1'd0}}, adr_ctr_nxt} > ((CACHE_LINE/4) - 1) )
                begin
                        // Remove dirty marking. BUG FIX.
                        tag_ram_clean = 1;

                        // Kill access.
                        `zap_kill_access;

                        // Go to new state (ARM925T: back to the line operation).
                        state_nxt = line_mode_ff ? LINE_INV : CACHE_CLEAN_GET_ADDRESS;
                end
                else
                begin
                        shamt = {{(ADR_CTR_PAD-5){1'd0}}, adr_ctr_nxt, 5'd0};
                        {line_dummy, data}  = walk_line >> shamt;

                        pa    = {walk_tag[`ZAP_CACHE_TAG__PA],
                                {$clog2(CACHE_LINE){1'd0}}};

                        o_wb_cyc_nxt = 1'd1;
                        o_wb_stb_nxt = 1'd1;
                        o_wb_wen_nxt = 1'd1;

                        // Perform a Wishbone write using Physical Address.
                        // Uses WB burst protocol for higher efficency.
                        o_wb_dat_nxt = data;
                        o_wb_adr_nxt = pa + ({{(ADR_CTR_PAD-2){1'd0}}, adr_ctr_nxt, 2'd0});
                        o_wb_cti_nxt = ({{ADR_CTR_PAD{1'd0}},adr_ctr_nxt} != (CACHE_LINE/4)-1) ?
                        CTI_BURST : CTI_EOB;
                        o_wb_sel_nxt = 4'b1111;
                end
        end

        CACHE_INV:
        begin
                tag_ram_clear    = 1'd1;
                state_nxt        = IDLE;
                o_cache_inv_done = 1'd1;
        end

        // ------------------------------------------------------
        // Default Section (To simplify synthesis)
        // ------------------------------------------------------

        default: // Cannot happen.
        begin
                // Assigning X here can simplify synthesis.

                line_dummy              = 'x;
                shamt                   = 'x;
                data                    = 'x;
                pa                      = 'x;
                dummy                   = 'x;
                state_nxt               = XX;
                rd_flat_nxt             = 'x;
                tag_ram_wr_addr         = 'x;
                tag_ram_wr_en           = 'x;
                tag_ram_clear           = 'x;
                tag_ram_clean           = 'x;
                adr_ctr_nxt             = 'x;
                blk_ctr_nxt             = 'x;
                cache_clean_done_nxt    = 'x;
                o_cache_inv_done        = 'x;
                o_wb_cyc_nxt            = 'x;
                o_wb_stb_nxt            = 'x;
                o_wb_adr_nxt            = 'x;
                o_wb_dat_nxt            = 'x;
                o_wb_sel_nxt            = 'x;
                o_wb_wen_nxt            = 'x;
                o_wb_cti_nxt            = 'x;
                tag_ram_wr_data         = 'x;
                o_cache_clean_done      = 'x;
        end
        endcase
end:blk1

// -----------------------------------------------------------------------------

// Priority encoder. Bit 0 is prioritized.
function automatic  [4:0] pri_enc ( input [15:0] in );
                casez ( in )
                16'b???????????????1: return 5'd0;
                16'b??????????????10: return 5'd1;
                16'b?????????????100: return 5'd2;
                16'b????????????1000: return 5'd3;
                16'b???????????10000: return 5'd4;
                16'b??????????100000: return 5'd5;
                16'b?????????1000000: return 5'd6;
                16'b????????10000000: return 5'd7;
                16'b???????100000000: return 5'd8;
                16'b??????1000000000: return 5'd9;
                16'b?????10000000000: return 5'd10;
                16'b????100000000000: return 5'd11;
                16'b???1000000000000: return 5'd12;
                16'b??10000000000000: return 5'd13;
                16'b?100000000000000: return 5'd14;
                16'b1000000000000000: return 5'd15;
                default             : return 5'b11111;
                endcase
endfunction : pri_enc

// -----------------------------------------------------------------------------

// The first dirty line of a block of 16, over the lines of every way.
function automatic [FLAT_W-1:0] get_tag_ram_rd_addr (
input [$clog2(NUMBER_OF_DIRTY_BLOCKS):0]   blk_ctr,
input [LINES_ALL-1:0]                      Dirty
);

        localparam [31:0] W = $clog2(NUMBER_OF_DIRTY_BLOCKS) + 5;

        logic [15:0]                               dirty_new;
        logic [4:0]                                enc;
        logic [W-1:0]                              shamt;
        logic [31:0]                               sum;
        logic [LINES_ALL - 16 - 1:0]               unused1;
        logic                                      unused0;

        sum                 = 32'd0;
        shamt               = {blk_ctr, 4'd0};
        {unused1,dirty_new} = Dirty >> shamt;
        enc                 = pri_enc(dirty_new[15:0]);
        sum[W:0]            = {1'd0, shamt[W-1:0]} + {1'd0, {{(W-5){1'd0}}, enc}};
        unused0             = |{sum[31:FLAT_W]};
        get_tag_ram_rd_addr = sum[FLAT_W-1:0];

endfunction : get_tag_ram_rd_addr

// ----------------------------------------------------------------------------

function automatic [4:0] baggage (
        input [LINES_ALL-1:0]                           Dirty,
        input [$clog2(NUMBER_OF_DIRTY_BLOCKS):0]        blk_ctr
);

        logic [LINES_ALL-1:0] w_dirty;
        logic [15:0] val;
        logic [LINES_ALL - 16 - 1:0] unused1;

        w_dirty        = Dirty >> {blk_ctr, 4'd0};
        {unused1, val} = w_dirty;

        return pri_enc(val);

endfunction : baggage

// ----------------------------------------------------------------------------

endmodule : zap_cache_tag_ram

// ----------------------------------------------------------------------------
// END OF FILE
// ----------------------------------------------------------------------------

