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
// interest is one level of logic past the tag compares. Metadata lives in
// synchronous M10Ks: four valid banks and sixteen dirty banks per way, plus
// one LRU RAM. Valid groups have a live flag, cleared atomically on invalidate;
// the first install rewrites the whole four-set group, without epoch rollover.
// Dirty banking retains the original 16-line-per-clock maintenance scan.
// SHORT_READ selects only the first RAM edge and its collision bypass; the
// three-stage forwarding registers exist only in the normal configuration.
// ACCEPTED_HIT_UPDATE retains the short D-port's accepted-response LRU owner,
// independently of a younger/held lookup. A whole-cache clean
// walks the lines of every way; a single-line operation by VA finds the
// way holding the tag, one by index takes i_line_way.
//

`include "zap_defines.svh"

module zap_cache_tag_ram #(

parameter logic SHORT_READ = 1'b0,
parameter logic ACCEPTED_HIT_UPDATE = 1'b0,
// ARM9V2 (SHORT_READ): the read/write set collision as a register loaded on
// the RAM address registers' own edge, not compared after them.
parameter logic REG_COLLISION = 1'b0,
parameter logic TRACK_DIRTY = 1'b1, // The instruction cache is read-only.
parameter logic [31:0] CACHE_SIZE = 32'd1024, // Bytes, all ways together.
parameter logic [31:0] CACHE_LINE = 32'd8,
parameter logic [31:0] WAYS       = 32'd1,    // ARM925T: 1 or 2.
// ARM925T: capacity visible to software's by-index maintenance loops.
// Larger physical caches visit every set colour for each reported index.
parameter logic [31:0] INDEX_SIZE = CACHE_SIZE,
parameter logic        PREFETCH   = 1'd0,     // ARM925T: I-cache next-line prefetch check.
// ARM9V2: the valid and dirty banks of a way in one byte-lane RAM each
// group (a bank per byte lane, byte enables): the banks share their read
// and write addresses, so the RAM ports are the same; one M10K holds four
// banks instead of one each.
parameter logic        META_PACK  = SHORT_READ,
// ARM9V2: a way's data byte lanes in one byte-enabled RAM (zap_ram_bytes)
// instead of one RAM per byte; the lanes share the clock enable and the
// read and write addresses. The D-cache only (its stores write bytes;
// Quartus already merges the I-cache's lanes).
parameter logic        DATA_PACK  = SHORT_READ && TRACK_DIRTY

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
input logic [31:0] i_lookup_check_address, // ARM925T: D-side next access.
input logic i_lookup_stall, // Select held current access during lookup repair.
(* dont_retime *) output logic o_cache_hit_early,
input   logic                             i_access,
input   logic                             i_accepted_hit,
input   logic [31:0]                      i_accepted_address,
input   logic [(WAYS > 1 ? $clog2(WAYS) : 1)-1:0] i_accepted_way,
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

// ARM925T: 1-cycle VA tag check for I-cache sequential prefetch (PREFETCH = 1).
input   logic    [31:0]                   i_pf_addr,
output  logic                             o_pf_hit,

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
localparam [31:0] INDEX_LINES = INDEX_SIZE / WAYS / CACHE_LINE;
localparam [31:0] INDEX_MASK = INDEX_LINES - 32'd1;
localparam [31:0] SET_W     = $clog2(LINES);
localparam [31:0] WAY_W     = WAYS > 1 ? $clog2(WAYS) : 32'd1;
localparam [31:0] FLAT_W    = $clog2(LINES_ALL);      // A line of any way: {way, set}.
localparam [31:0] TAG_W     = 32'd31 - $clog2(CACHE_LINE) - SET_W + 32'd1;

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

// Metadata arrays are synchronous block RAMs. Only group-initialized flags
// remain flops, so reset does not require a sweep of the dirty RAM.
logic [15:0] dirty_scan;
logic [WAYS-1:0][15:0] dirty_group_q;
logic valid_write_en;
logic [SET_W-1:0] valid_write_set;
logic [WAYS-1:0] valid_write_way;
logic valid_write_data;
logic dirty_write_en, dirty_write_data;
logic [SET_W-1:0] dirty_write_set;
logic [WAYS-1:0] dirty_write_way;
logic [SET_W-5:0] dirty_read_group;
logic [3:0] dirty_read_bit_ff;
logic [WAYS-1:0] dirty_s1_raw, valid_s1_raw;
logic [SET_W-1:0] hit_upd_set;
logic [WAY_W-1:0] hit_upd_way;
logic [`ZAP_CACHE_TAG_WDT-1:0]             tag_ram_wr_data;
logic                                      tag_ram_wr_en;
logic [SET_W-1:0]                          tag_ram_wr_addr;     // The set written.
logic [WAYS-1:0]                           wr_sel;              // ARM925T: the way written, one-hot (none: no write).
logic [SET_W-1:0]                          rd_set, rd_set_del, rd_set_del2;   // The set read, in every way.
logic [FLAT_W-1:0]                         rd_flat_ff, rd_flat_nxt;           // ARM925T: the clean walk's or line operation's line.
logic [WAY_W-1:0]                          rd_way;                            // ARM925T: its way.
logic [SET_W-1:0]                          lk_set;              // ARM925T: the lookup's set.
logic                                      take;                // ARM925T: a write-back beat is acknowledged
logic [$clog2(CACHE_LINE/4):0]             adr_ctr_inc;         // ARM925T: the next beat, from registers
logic                                      beat_cur_ok, beat_inc_ok;
logic [2:0]                                cti_cur, cti_inc;
logic [31:0]                               wb_adr_cur, wb_adr_inc, wb_word_cur, wb_word_inc;
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
if (SHORT_READ) begin : g_short_ram
        // ARM9V2: one descriptor for the entire cache. The RAM read and
        // write data capture are unchanged; equality belongs AFTER this
        // edge, not after A's adder and before 32 byte-lane registers.
        (* dont_retime *) logic [SET_W-1:0] rd_addr_q, wr_addr_q;
        logic [WAYS-1:0] tag_en_q;
        logic [WAYS-1:0][CACHE_LINE-1:0] byte_en_q;
        logic [`ZAP_CACHE_TAG_WDT-1:0] tag_data_q;
        logic [CACHE_LINE*8-1:0] line_data_q;
        // REG_COLLISION: collision_q is rd_addr_q == wr_addr_q, compared
        // before the edge that loads them both; it then drives every byte's
        // and tag's bypass select (fanout ~280) straight from a register.
        (* dont_retime *) logic collision_q;
        wire collision = REG_COLLISION ? collision_q : rd_addr_q == wr_addr_q;
        always_ff @(posedge i_clk) if (!i_hold) begin
                rd_addr_q <= rd_set;
                wr_addr_q <= tag_ram_wr_addr;
                collision_q <= rd_set == tag_ram_wr_addr;
                tag_data_q <= tag_ram_wr_data;
                line_data_q <= i_cache_line;
                for (int w=0; w<WAYS; w++) begin
                        tag_en_q[w] <= tag_ram_wr_en && wr_sel[w];
                        byte_en_q[w] <= i_cache_line_ben & {CACHE_LINE{wr_sel[w]}};
                end
        end
        for (genvar w=0; w<WAYS; w++) begin : g_way
                logic [`ZAP_CACHE_TAG_WDT-1:0] tag_read;
                // Use the port's module-level RAM template: Quartus 17
                // maps inline arrays in this enclosing cache to registers.
                zap_ram_simple #(.WIDTH(`ZAP_CACHE_TAG_WDT), .DEPTH(LINES),
                    .SHORT_READ(1'b1), .SHORT_RAW(1'b1)) u_tag (
                    .i_clk(i_clk), .i_clken(!i_hold),
                    .i_wr_en(tag_ram_wr_en && wr_sel[w]), .i_wr_data(tag_ram_wr_data),
                    .i_wr_addr(tag_ram_wr_addr), .i_rd_addr(rd_set),
                    .o_rd_data(tag_read), .o_rd_data_pre());
                assign tag_q[w] = collision && tag_en_q[w] ? tag_data_q : tag_read;
                logic [CACHE_LINE*8-1:0] packed_read;
                if (DATA_PACK) begin : g_packed_data
                        zap_ram_bytes #(.BYTES(CACHE_LINE), .DEPTH(LINES)) u_data (
                            .i_clk(i_clk), .i_clken(!i_hold),
                            .i_wr_en(i_cache_line_ben & {CACHE_LINE{wr_sel[w]}}),
                            .i_wr_data(i_cache_line),
                            .i_wr_addr(tag_ram_wr_addr), .i_rd_addr(rd_set),
                            .o_rd_data(packed_read));
                end else begin : g_byte_data
                        assign packed_read = '0;
                end
                for (genvar b=0; b<CACHE_LINE; b++) begin : g_byte
                        logic [7:0] data_read;
                        if (DATA_PACK) begin : g_packed
                                assign data_read = packed_read[8*b +: 8];
                        end else begin : g_ram
                        zap_ram_simple #(.WIDTH(32'd8), .DEPTH(LINES),
                            .SHORT_READ(1'b1), .SHORT_RAW(1'b1)) u_data (
                            .i_clk(i_clk), .i_clken(!i_hold),
                            .i_wr_en(i_cache_line_ben[b] && wr_sel[w]),
                            .i_wr_data(i_cache_line[8*b +: 8]),
                            .i_wr_addr(tag_ram_wr_addr), .i_rd_addr(rd_set),
                            .o_rd_data(data_read), .o_rd_data_pre());
                        end
                        assign line_q[w][8*b +: 8] = collision && byte_en_q[w][b] ?
                                line_data_q[8*b +: 8] : data_read;
                end
                assign w_dummy[w] = line_q[w];
                assign w_dummy_1[w] = tag_q[w];
        end
`ifndef SYNTHESIS
        logic loaded;
        always_ff @(posedge i_clk) if (!i_hold) loaded <= 1'b1;
        always_ff @(posedge i_clk) if (loaded && !i_reset)
                assert (collision_q == (rd_addr_q == wr_addr_q)) else $fatal(1, "registered set collision");
`endif
end else begin : g_long_ram
for ( genvar w = 0; w < WAYS; w++ )
begin : g_way

zap_ram_simple_ben #(.WIDTH(CACHE_LINE*8), .DEPTH(LINES), .SHORT_READ(SHORT_READ)) u_zap_ram_simple_data_ram (
        .i_clk(i_clk),
        .i_clken(!i_hold),

        .i_wr_en(i_cache_line_ben & {CACHE_LINE{wr_sel[w]}}),
        .i_wr_data(i_cache_line),

        .o_rd_data_pre(w_dummy[w]),
        .o_rd_data(line_q[w]),

        .i_wr_addr(tag_ram_wr_addr),
        .i_rd_addr(rd_set)
);

zap_ram_simple #(.WIDTH(`ZAP_CACHE_TAG_WDT), .DEPTH(LINES), .SHORT_READ(SHORT_READ)) u_zap_ram_simple_tag (
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
end : g_long_ram

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

// ARM925T: compare one stage early for the background-hit ACK. The
// second-stage tag includes RAM forwarding through the preceding edge;
// metadata's write-behind update needs its matching pending-valid bypass.
// A current hit write cannot change tag identity. A current fill write
// changes only the reserved victim/filling lines, which the D-cache FSM
// excludes from HUM. Maintenance never enables a HUM slot.
// Compare both candidate addresses before the one-bit stall selection.
logic [WAYS-1:0] hit_check, hit_held;
for (genvar w = 0; w < WAYS; w++) begin : g_hit_early
        wire pre_valid = valid_s2[w] ||
                         (rd_set_del2 == pend_addr && pend_en && pend_sel[w]);
        assign hit_check[w] = pre_valid &&
            w_dummy_1[w][`ZAP_CACHE_TAG__TAG] == i_lookup_check_address[`ZAP_VA__CACHE_TAG];
        assign hit_held[w] = pre_valid &&
            w_dummy_1[w][`ZAP_CACHE_TAG__TAG] == i_lookup_address[`ZAP_VA__CACHE_TAG];
end
always_ff @(posedge i_clk)
        if (i_reset) o_cache_hit_early <= 1'b0;
        else if (!i_hold)
                o_cache_hit_early <= SHORT_READ ? (|hit) : i_lookup_stall ? (|hit_held) : (|hit_check);

if ( WAYS == 1 )
begin : g_direct
        assign victim            = 1'd0;
        assign sel               = 1'd0;
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
        assign victim            = !valid_q[0] ? 1'd0 : !valid_q[1] ? 1'd1 :
            (ACCEPTED_HIT_UPDATE && i_accepted_hit && hit_upd_set == lk_set) ? ~i_accepted_way : lru_q;
        assign sel               = hit[1] ? 1'd1 : hit[0] ? 1'd0 : victim;
        assign hit_upd_en        = ACCEPTED_HIT_UPDATE ? i_accepted_hit : i_access && o_cache_hit;
        assign hit_upd_set       = ACCEPTED_HIT_UPDATE ? i_accepted_address[`ZAP_VA__CACHE_INDEX] : lk_set;
        assign hit_upd_way       = ACCEPTED_HIT_UPDATE ? i_accepted_way : sel;

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
                return set == hit_upd_set     && hit_upd_en                 ? ~hit_upd_way      :
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
                        hit_pend_en <= hit_upd_en && (!i_hold || (ACCEPTED_HIT_UPDATE && i_accepted_hit));
                end

                hit_pend_set <= hit_upd_set;
                hit_pend_val <= ~hit_upd_way;
        end

        // One RAM write port. Hits take priority; an independent coincident
        // fill waits in one entry. The exclusive install slot bounds this
        // backlog. A newer hit to that set supersedes the deferred fill.
        (* ramstyle = "M10K" *) logic lru_mem [LINES-1:0];
        logic lru_read, lru_read_fwd, lru_read_value;
        logic [SET_W-1:0] lru_read_set_q,lru_write_set_q;
        logic defer_en, defer_val;
        logic [SET_W-1:0] defer_set;
        logic lru_wr_en, lru_wr_val;
        logic [SET_W-1:0] lru_wr_set;
        wire fill_update = pend_en && (|pend_sel);
        assign lru_wr_en = hit_pend_en || fill_update || defer_en;
        assign lru_wr_set = hit_pend_en ? hit_pend_set : fill_update ? pend_addr : defer_set;
        assign lru_wr_val = hit_pend_en ? hit_pend_val : fill_update ? pend_sel[0] : defer_val;
        always_ff @(posedge i_clk) begin
                if (lru_wr_en) lru_mem[lru_wr_set] <= lru_wr_val;
                if (!i_hold || tag_ram_clear || line_clear) begin
                        lru_read <= lru_mem[rd_set];
                        lru_read_fwd <= lru_wr_en && (SHORT_READ || lru_wr_set == rd_set);
                        lru_read_set_q<=rd_set;lru_write_set_q<=lru_wr_set;
                        lru_read_value <= lru_wr_val;
                end
                if (i_reset || tag_ram_clear) defer_en <= 1'b0;
                else begin
                        if (lru_wr_en && lru_wr_set == defer_set) defer_en <= 1'b0;
                        if (hit_pend_en && fill_update && hit_pend_set != pend_addr) begin
                                defer_en <= 1'b1;
                                defer_set <= pend_addr;
                                defer_val <= pend_sel[0];
                        end
                end
        end
        `ifndef SYNTHESIS
        always_ff @(posedge i_clk) if (!i_reset)
                assert (!(defer_en && hit_pend_en && fill_update &&
                          hit_pend_set != pend_addr && hit_pend_set != defer_set && pend_addr != defer_set))
                    else $fatal(1, "cache LRU deferred fill overflow");
        `endif
        wire lru_first = lru_read_fwd && (!SHORT_READ || lru_read_set_q==lru_write_set_q) ? lru_read_value : lru_read;
        wire lru_deferred = defer_en && defer_set == rd_set_del ? defer_val : lru_first;
        if (SHORT_READ) begin : g_short
                logic hit_en,tag_en,deferred_en,hit_value,tag_value,deferred_value;
                logic [SET_W-1:0] read_set,hit_set,tag_set,deferred_set;
                always_ff @(posedge i_clk) if (!i_hold || tag_ram_clear || line_clear) begin
                        read_set<=rd_set;hit_set<=hit_upd_set;tag_set<=tag_ram_wr_addr;deferred_set<=defer_set;
                        hit_en<=hit_upd_en;tag_en<=tag_ram_wr_en&&(|wr_sel);deferred_en<=defer_en;
                        hit_value<=~hit_upd_way;tag_value<=wr_sel[0];deferred_value<=defer_val;
                end
                assign lru_q = hit_en && hit_set==read_set ? hit_value :
                    tag_en && tag_set==read_set ? tag_value :
                    deferred_en && deferred_set==read_set ? deferred_value : lru_first;
                assign lru_s1 = 1'b0;assign lru_s2 = 1'b0;
        end else begin : g_long
                assign lru_s1 = lru_deferred;
                always_ff @(posedge i_clk) if (!i_hold || tag_ram_clear || line_clear) begin
                        lru_s2 <= lru_fwd(rd_set_del, lru_s1);
                        lru_q <= lru_fwd_now(rd_set_del2, lru_s2);
                end
        end

end

assign o_cache_hit       = |hit;
assign o_cache_way       = sel;

//
// ARM925T: 1-cycle VA tag lookup for sequential next-line prefetch (I-cache).
// Kept in a dedicated 1-cycle synchronous block RAM per way so the 3-stage
// demand tag RAM (u_zap_ram_simple_tag) and its critical hit compare path
// are completely untouched.
//
if ( PREFETCH )
begin : g_prefetch
        logic [WAYS-1:0][TAG_W-1:0] pf_tag_q;
        logic [WAYS-1:0] pf_valid_q;
        logic [SET_W-1:0]           pf_set_q;
        logic [TAG_W-1:0]           pf_addr_tag_q;
        logic [TAG_W-1:0]           pend_tag;
        logic [WAYS-1:0]            pf_way_hit;
        logic                       unused_pf;

        assign unused_pf = |i_pf_addr[$clog2(CACHE_LINE)-1:0];

        for ( genvar w = 0; w < WAYS; w++ )
        begin : g_pf_way
                logic [TAG_W-1:0] pf_tag_mem [LINES-1:0];
                logic [LINES/4-1:0] pf_live;
                logic pf_live_q;
                logic [3:0] pf_valid_group;
                logic [1:0] pf_bit_q;
                wire [SET_W-1:0] pf_set = i_pf_addr[`ZAP_VA__CACHE_INDEX];
                always_ff @(posedge i_clk) begin
                        if (i_reset || tag_ram_clear || !i_cache_en) pf_live <= '0;
                        else if (pend_en && pend_sel[w]) pf_live[pend_addr[SET_W-1:2]] <= 1'b1;
                        pf_live_q <= !i_reset && !tag_ram_clear && i_cache_en &&
                            (pf_live[pf_set[SET_W-1:2]] ||
                             (pend_en && pend_sel[w] && pend_addr[SET_W-1:2] == pf_set[SET_W-1:2]));
                        pf_bit_q <= pf_set[1:0];
                end
                for (genvar b=0; b<4; b++) begin : g_valid
                        logic read_bit, collision, forward_bit;
                        wire write_bank = valid_write_en && valid_write_way[w] &&
                            ((!pf_live[valid_write_set[SET_W-1:2]] && valid_write_data) || valid_write_set[1:0] == b[1:0]);
                        wire write_bit = valid_write_data && valid_write_set[1:0] == b[1:0];
                        zap_cache_metadata_ram #(.DEPTH(LINES/4)) valid_ram (
                                .i_clk(i_clk), .i_read_en(1'b1),
                                .i_write_en(write_bank), .i_write_data(write_bit),
                                .i_read_address(pf_set[SET_W-1:2]),
                                .i_write_address(valid_write_set[SET_W-1:2]), .o_data(read_bit)
                        );
                        always_ff @(posedge i_clk) begin
                                collision <= write_bank && valid_write_set[SET_W-1:2] == pf_set[SET_W-1:2];
                                forward_bit <= write_bit;
                        end
                        assign pf_valid_group[b] = collision ? forward_bit : read_bit;
                end
                assign pf_valid_q[w] = pf_live_q && pf_valid_group[pf_bit_q];

                always_ff @ ( posedge i_clk )
                begin
                        if ( !i_hold && tag_ram_wr_en && wr_sel[w] )
                        begin
                                pf_tag_mem[tag_ram_wr_addr] <= tag_ram_wr_data[`ZAP_CACHE_TAG__TAG];
                        end

                        pf_tag_q[w] <= pf_tag_mem[i_pf_addr[`ZAP_VA__CACHE_INDEX]];
                end
        end : g_pf_way

        always_ff @ ( posedge i_clk )
        begin
                pf_set_q      <= i_pf_addr[`ZAP_VA__CACHE_INDEX];
                pf_addr_tag_q <= i_pf_addr[`ZAP_VA__CACHE_TAG];
                pend_tag      <= tag_ram_wr_data[`ZAP_CACHE_TAG__TAG];
        end

        always_comb
        begin
                for ( int w = 0; w < WAYS; w++ )
                begin
                        pf_way_hit[w] = !tag_ram_clear && i_cache_en && (
                                ( pend_en && pend_sel[w] && (pend_addr == pf_set_q) ) ?
                                        ( pend_tag == pf_addr_tag_q ) :
                                        ( pf_valid_q[w] && (pf_tag_q[w] == pf_addr_tag_q) )
                        );
                end
        end

        assign o_pf_hit = |pf_way_hit;
end : g_prefetch
else
begin : g_no_prefetch
        logic unused_pf;
        assign unused_pf = |i_pf_addr;
        assign o_pf_hit  = 1'd0;
end : g_no_prefetch

// The way a write goes to: idle, the way that hits (a store hit); else the
// way the FSM buffered with the address (a fill, a clean, a write-through).
always_comb
begin
        for ( int w = 0; w < WAYS; w++ )
        begin
                wr_sel[w]    = i_idle ? hit[w] : ( i_cache_way == WAY_W'(w) );
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
// operation is active. Maintenance reads the same registered metadata.
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

// ARM925T: valid bits are four interleaved RAM banks per way. One live
// flag per four-set group acts as a non-wrapping generation: invalidate
// clears those flags in the original single clock. The next install in a
// dead group writes all four bank entries, setting only the installed line.
// No stale RAM bit can become live again; there is no epoch rollover.
always_comb begin
        valid_write_en = pend_en || line_clear;
        valid_write_set = pend_addr;
        valid_write_way = pend_sel;
        valid_write_data = 1'b1;
        if (line_clear) begin
                valid_write_set = rd_flat_ff[SET_W-1:0];
                for (int w=0; w<WAYS; w++) valid_write_way[w] = rd_way == WAY_W'(w);
                valid_write_data = 1'b0;
        end
        dirty_write_en = pend_en || tag_ram_clean || line_clear;
        dirty_write_set = pend_addr;
        dirty_write_way = pend_sel;
        dirty_write_data = pend_dirty;
        if (tag_ram_clean || line_clear) begin
                dirty_write_set = rd_flat_ff[SET_W-1:0];
                for (int w=0; w<WAYS; w++) dirty_write_way[w] = rd_way == WAY_W'(w);
                dirty_write_data = 1'b0;
        end
        dirty_read_group = rd_set[SET_W-1:4];
        if (state_ff == IDLE && i_cache_clean_req) dirty_read_group = '0;
        else if (!line_mode_ff && state_ff != IDLE && state_ff != CACHE_INV)
                dirty_read_group = blk_ctr_nxt[SET_W-5:0];
end
assign dirty_scan = dirty_group_q[WAY_W'(blk_ctr_ff >> (SET_W-4))];
always_ff @(posedge i_clk) if (!i_hold || tag_ram_clean || line_clear) dirty_read_bit_ff <= rd_set[3:0];

// ARM9V2: metadata uses RAM banks; the short port compares captured
// descriptors after their RAM-read edge, as the tag/byte data port does.
// Valid and dirty maintenance enables are deliberately independent.
logic [SET_W-1:0] meta_v_read, meta_v_write, meta_v_pending;
logic [SET_W-1:0] meta_d_write;
logic [SET_W-5:0] meta_d_read;
logic [SET_W-1:0] meta_now_v_read, meta_now_v_write, meta_now_d_read, meta_now_d_write;
logic [WAYS-1:0] meta_now_v_en,meta_now_d_en,meta_pending_en;
logic meta_now_dirty;
if (SHORT_READ) begin : g_short_descriptors
    always_ff @(posedge i_clk) begin
        if (!i_hold || tag_ram_clear || line_clear) begin
            meta_v_read<=rd_set;meta_v_write<=valid_write_set;meta_v_pending<=pend_addr;
            meta_pending_en<=pend_sel&{WAYS{pend_en}};
            meta_now_v_read<=rd_set;meta_now_v_write<=tag_ram_wr_addr;
            meta_now_v_en<=wr_sel&{WAYS{tag_ram_wr_en}};
        end
        if (!i_hold || tag_ram_clean || line_clear) begin
            meta_d_read<=dirty_read_group;meta_d_write<=dirty_write_set;
            meta_now_d_read<=rd_set;meta_now_d_write<=tag_ram_wr_addr;
            meta_now_d_en<=wr_sel&{WAYS{tag_ram_wr_en}};
            meta_now_dirty<=i_cache_tag_dirty;
        end
        if (i_reset) begin meta_now_v_en<=0;meta_now_d_en<=0;meta_pending_en<=0;end
    end
end else begin : g_no_short_descriptors
    assign meta_v_read=0;assign meta_v_write=0;assign meta_v_pending=0;
    assign meta_d_write=0;assign meta_d_read=0;
    assign meta_now_v_read=0;assign meta_now_v_write=0;
    assign meta_now_d_read=0;assign meta_now_d_write=0;
    assign meta_now_v_en=0;assign meta_now_d_en=0;assign meta_pending_en=0;assign meta_now_dirty=0;
end

for (genvar w=0; w<WAYS; w++) begin : g_metadata
        logic [LINES/4-1:0] valid_live;
        logic valid_live_q;
        logic [3:0] valid_group_q;
        logic [1:0] valid_read_bit;
        always_ff @(posedge i_clk) begin
                if (i_reset || tag_ram_clear || !i_cache_en) valid_live <= '0;
                else if (pend_en && pend_sel[w]) valid_live[pend_addr[SET_W-1:2]] <= 1'b1;
                if (!i_hold || tag_ram_clear || line_clear) begin
                        valid_read_bit <= rd_set[1:0];
                        valid_live_q <= valid_live[rd_set[SET_W-1:2]] ||
                            (!SHORT_READ &&
                            (pend_en && pend_sel[w] && pend_addr[SET_W-1:2] == rd_set[SET_W-1:2]));
                end
                if (i_reset) valid_live_q <= 1'b0;
        end
        logic [3:0] valid_lane_we, valid_lane_wd, valid_lane_q;
        if (META_PACK) begin : g_valid_lanes
                zap_cache_metadata_lanes #(.DEPTH(LINES/4), .LANES(4)) valid_rams (
                        .i_clk(i_clk), .i_read_en(!i_hold || tag_ram_clear || line_clear),
                        .i_write_en(valid_lane_we), .i_write_data(valid_lane_wd),
                        .i_read_address(rd_set[SET_W-1:2]),
                        .i_write_address(valid_write_set[SET_W-1:2]), .o_data(valid_lane_q)
                );
        end else begin : g_valid_unpacked
                assign valid_lane_q = 4'd0;
        end
        for (genvar b=0; b<4; b++) begin : g_valid_bank
                logic read_bit, collision, forward_bit;
                wire write_bank = valid_write_en && valid_write_way[w] &&
                    ((!valid_live[valid_write_set[SET_W-1:2]] && valid_write_data) ||
                     valid_write_set[1:0] == b[1:0]);
                wire write_bit = valid_write_set[1:0] == b[1:0] && valid_write_data;
                if (META_PACK) begin : g_packed
                        assign valid_lane_we[b] = write_bank; assign valid_lane_wd[b] = write_bit;
                        assign read_bit = valid_lane_q[b];
                end else begin : g_ram
                        assign valid_lane_we[b] = 1'b0; assign valid_lane_wd[b] = 1'b0;
                zap_cache_metadata_ram #(.DEPTH(LINES/4)) valid_ram (
                        .i_clk(i_clk), .i_read_en(!i_hold || tag_ram_clear || line_clear),
                        .i_write_en(write_bank), .i_write_data(write_bit),
                        .i_read_address(rd_set[SET_W-1:2]),
                        .i_write_address(valid_write_set[SET_W-1:2]), .o_data(read_bit)
                );
                end
                always_ff @(posedge i_clk) begin
                        if (!i_hold || tag_ram_clear || line_clear) begin
                                collision <= write_bank && (SHORT_READ || valid_write_set[SET_W-1:2] == rd_set[SET_W-1:2]);
                                forward_bit <= write_bit;
                        end
                end
                assign valid_group_q[b] = collision && (!SHORT_READ || meta_v_write[SET_W-1:2]==meta_v_read[SET_W-1:2]) ? forward_bit : read_bit;
        end
        assign valid_s1_raw[w] = (valid_live_q || (SHORT_READ && meta_pending_en[w] && meta_v_pending[SET_W-1:2]==meta_v_read[SET_W-1:2])) && valid_group_q[valid_read_bit];

        // Sixteen banks preserve the old 16-line-per-clock clean scanner.
        // No serial walk is introduced for clean/test-and-clean. Each bank
        // has a synchronous read and one update port; no array read mux.
        if (TRACK_DIRTY) begin : g_dirty
        logic [LINES/16-1:0] dirty_initialized;
        logic dirty_initialized_q, dirty_update_q;
        always_ff @(posedge i_clk) begin
                if (i_reset) dirty_initialized <= '0;
                else if (dirty_write_en && dirty_write_way[w])
                        dirty_initialized[dirty_write_set[SET_W-1:4]] <= 1'b1;
                if (!i_hold || tag_ram_clean || line_clear)
                        dirty_initialized_q <= dirty_initialized[dirty_read_group] ||
                            (!SHORT_READ && dirty_write_en && dirty_write_way[w] && dirty_write_set[SET_W-1:4] == dirty_read_group);
                if (!i_hold || tag_ram_clean || line_clear) dirty_update_q<=dirty_write_en&&dirty_write_way[w];
                if (i_reset) dirty_update_q<=0;
                if (i_reset) dirty_initialized_q <= 1'b0;
        end
        logic [15:0] dirty_lane_we, dirty_lane_wd, dirty_lane_q;
        if (META_PACK) begin : g_dirty_lanes
                zap_cache_metadata_lanes #(.DEPTH(LINES/16), .LANES(16)) dirty_rams (
                        .i_clk(i_clk), .i_read_en(!i_hold || tag_ram_clean || line_clear),
                        .i_write_en(dirty_lane_we), .i_write_data(dirty_lane_wd),
                        .i_read_address(dirty_read_group),
                        .i_write_address(dirty_write_set[SET_W-1:4]), .o_data(dirty_lane_q)
                );
        end else begin : g_dirty_unpacked
                assign dirty_lane_q = 16'd0;
        end
        for (genvar b=0; b<16; b++) begin : g_bank
                logic read_bit, collision, forward_bit;
                wire write_bank = dirty_write_en && dirty_write_way[w] &&
                    (!dirty_initialized[dirty_write_set[SET_W-1:4]] || dirty_write_set[3:0] == b[3:0]);
                wire write_bit = dirty_write_set[3:0] == b[3:0] && dirty_write_data;
                if (META_PACK) begin : g_packed
                        assign dirty_lane_we[b] = write_bank; assign dirty_lane_wd[b] = write_bit;
                        assign read_bit = dirty_lane_q[b];
                end else begin : g_ram
                        assign dirty_lane_we[b] = 1'b0; assign dirty_lane_wd[b] = 1'b0;
                zap_cache_metadata_ram #(.DEPTH(LINES/16)) dirty_ram (
                        .i_clk(i_clk), .i_read_en(!i_hold || tag_ram_clean || line_clear),
                        .i_write_en(write_bank), .i_write_data(write_bit),
                        .i_read_address(dirty_read_group),
                        .i_write_address(dirty_write_set[SET_W-1:4]), .o_data(read_bit)
                );
                end
                always_ff @(posedge i_clk) begin
                        if (!i_hold || tag_ram_clean || line_clear) begin
                                collision <= write_bank && (SHORT_READ || dirty_write_set[SET_W-1:4] == dirty_read_group);
                                forward_bit <= write_bit;
                        end
                end
                assign dirty_group_q[w][b] = (dirty_initialized_q || (SHORT_READ && dirty_update_q && meta_d_write[SET_W-1:4]==meta_d_read)) &&
                    (collision && (!SHORT_READ || meta_d_write[SET_W-1:4]==meta_d_read) ? forward_bit : read_bit);
        end
        end else begin : g_read_only
                assign dirty_group_q[w] = 16'b0;
        end
        assign dirty_s1_raw[w] = dirty_group_q[w][dirty_read_bit_ff];
        if (SHORT_READ) begin : g_short
                assign valid_q[w] = (meta_now_v_en[w] && meta_now_v_write==meta_now_v_read) || valid_s1_raw[w];
                assign dirty_q[w] = meta_now_d_en[w] && meta_now_d_write==meta_now_d_read ? meta_now_dirty : dirty_s1_raw[w];
                assign valid_s1[w] = 1'b0;assign valid_s2[w] = 1'b0;
                assign dirty_s1[w] = 1'b0;assign dirty_s2[w] = 1'b0;
        end else begin : g_long
                assign valid_s1[w] = valid_s1_raw[w];
                assign dirty_s1[w] = dirty_s1_raw[w];
                always_ff @(posedge i_clk) begin
                        if (i_reset) begin
                                valid_s2[w] <= 1'b0;
                                valid_q[w] <= 1'b0;
                                dirty_s2[w] <= 1'b0;
                                dirty_q[w] <= 1'b0;
                        end else begin
                                if (!i_hold || tag_ram_clear || line_clear) begin
                                        valid_s2[w] <= rd_set_del == pend_addr && pend_en && pend_sel[w] ? 1'b1 : valid_s1[w];
                                        valid_q[w] <= rd_set_del2 == tag_ram_wr_addr && tag_ram_wr_en && wr_sel[w] ? 1'b1 :
                                            rd_set_del2 == pend_addr && pend_en && pend_sel[w] ? 1'b1 : valid_s2[w];
                                end
                                if (!i_hold || tag_ram_clean || line_clear) begin
                                        dirty_s2[w] <= rd_set_del == pend_addr && pend_en && pend_sel[w] ? pend_dirty : dirty_s1[w];
                                        dirty_q[w] <= rd_set_del2 == tag_ram_wr_addr && tag_ram_wr_en && wr_sel[w] ? i_cache_tag_dirty :
                                            rd_set_del2 == pend_addr && pend_en && pend_sel[w] ? pend_dirty : dirty_s2[w];
                                end
                        end
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

// ARM925T: the write-back's next beat is chosen by the acknowledge between
// the current beat and the next, both formed from registers (timing).
assign take        = i_wb_ack && o_wb_stb_ff;
assign adr_ctr_inc = adr_ctr_ff + {{(ZERO_WDT-1){1'd0}}, 1'd1};
assign beat_cur_ok = {{ADR_CTR_PAD{1'd0}}, adr_ctr_ff}  <= ((CACHE_LINE/4) - 1);
assign beat_inc_ok = {{ADR_CTR_PAD{1'd0}}, adr_ctr_inc} <= ((CACHE_LINE/4) - 1);
assign cti_cur     = ({{ADR_CTR_PAD{1'd0}}, adr_ctr_ff}  != (CACHE_LINE/4)-1) ? CTI_BURST : CTI_EOB;
assign cti_inc     = ({{ADR_CTR_PAD{1'd0}}, adr_ctr_inc} != (CACHE_LINE/4)-1) ? CTI_BURST : CTI_EOB;
assign wb_adr_cur  = {walk_tag[`ZAP_CACHE_TAG__PA], {$clog2(CACHE_LINE){1'd0}}} + ({{(ADR_CTR_PAD-2){1'd0}}, adr_ctr_ff,  2'd0});
assign wb_adr_inc  = {walk_tag[`ZAP_CACHE_TAG__PA], {$clog2(CACHE_LINE){1'd0}}} + ({{(ADR_CTR_PAD-2){1'd0}}, adr_ctr_inc, 2'd0});
assign wb_word_cur = walk_line[32 * adr_ctr_ff[$clog2(CACHE_LINE/4)-1:0]  +: 32];
assign wb_word_inc = walk_line[32 * adr_ctr_inc[$clog2(CACHE_LINE/4)-1:0] +: 32];

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
        rd_flat_nxt             = {blk_ctr_ff[$clog2(NUMBER_OF_DIRTY_BLOCKS)-1:0], 4'b0} + FLAT_W'(pri_enc(dirty_scan));
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
        tag_ram_wr_data         = i_cache_tag; // ARM925T: enable qualifies the payload.
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
                        // By-VA names an actual line. By-index names a
                        // reported set: start with its first physical colour.
                        if (!i_line_va && INDEX_SIZE < CACHE_SIZE)
                                rd_flat_nxt = flat (i_line_way,
                                    i_line_addr[`ZAP_VA__CACHE_INDEX] & INDEX_MASK[SET_W-1:0]);
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
                        if ( valid_q[w] &&
                             ( i_line_va ? tag_q[w][`ZAP_CACHE_TAG__TAG] == i_line_addr[`ZAP_VA__CACHE_TAG]
                                         : WAY_W'(w) == rd_way ) )
                        begin
                                line_hit_nxt = 1'd1;
                                rd_flat_nxt  = flat ( WAY_W'(w), rd_flat_ff[SET_W-1:0] );
                        end
                end

                adr_ctr_nxt = 0;

                if ( i_line_op[0] && line_hit_nxt && dirty_q[WAY_W'(rd_flat_nxt >> SET_W)] )
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
                // ARM925T: c0 still reports the phone's 8 KB D-cache.
                // Its index loop must clean/invalidate added sets too.
                // Reuse the maintenance read/write pipeline, preserving the
                // selected way and low set bits. No live hit-path logic.
                if (!i_line_va && INDEX_SIZE < CACHE_SIZE &&
                    (rd_flat_ff & FLAT_W'(LINES - INDEX_LINES)) != FLAT_W'(LINES - INDEX_LINES))
                begin
                        rd_flat_nxt   = rd_flat_ff + FLAT_W'(INDEX_LINES);
                        line_mode_nxt = 1'd1;
                        line_done_nxt = 1'd0;
                        state_nxt     = LINE_W0;
                end
        end

        CACHE_CLEAN_GET_ADDRESS:
        begin
                if ( &pri_enc(dirty_scan) )
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

                adr_ctr_nxt = take ? adr_ctr_inc : adr_ctr_ff;

                if ( !(take ? beat_inc_ok : beat_cur_ok) )
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
                        data  = take ? wb_word_inc : wb_word_cur;

                        o_wb_cyc_nxt = 1'd1;
                        o_wb_stb_nxt = 1'd1;
                        o_wb_wen_nxt = 1'd1;

                        // Perform a Wishbone write using Physical Address.
                        // Uses WB burst protocol for higher efficency.
                        o_wb_dat_nxt = data;
                        o_wb_adr_nxt = take ? wb_adr_inc : wb_adr_cur;
                        o_wb_cti_nxt = take ? cti_inc : cti_cur;
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

endmodule : zap_cache_tag_ram

// ----------------------------------------------------------------------------
// END OF FILE
// ----------------------------------------------------------------------------


// A separate inference boundary is intentional. Quartus 17 loses ramstyle
// on scalar memories inside nested generate loops after sv2v elaboration,
// and otherwise implements the small dirty banks as registers.
// ARM9V2 (META_PACK): LANES one-bit banks with shared read and write
// addresses in one RAM, each bank in its own byte lane with its own write
// enable (byte enables), so Quartus packs four banks into an M10K. The
// unused bits of each byte are written zero. Same ports and timing as
// LANES zap_cache_metadata_ram instances.
module zap_cache_metadata_lanes #(
        parameter integer DEPTH = 32,
        parameter integer LANES = 4
) (
        input logic i_clk,
        input logic i_read_en,
        input logic [LANES-1:0] i_write_en,
        input logic [LANES-1:0] i_write_data,
        input logic [$clog2(DEPTH)-1:0] i_read_address,
        input logic [$clog2(DEPTH)-1:0] i_write_address,
        output logic [LANES-1:0] o_data
);
        logic [LANES-1:0][7:0] wdata, q;
        always_comb for (int l = 0; l < LANES; l++) wdata[l] = {7'd0, i_write_data[l]};
        always_comb for (int l = 0; l < LANES; l++) o_data[l] = q[l][0];
`ifdef SYNTHESIS
        // Intel's primitive directly (see zap_ram_bytes): four lanes per M10K.
        localparam integer W = 8*LANES, BYTES = LANES;
        wire [$clog2(DEPTH)-1:0] i_wr_addr_x = i_write_address, i_rd_addr_x = i_read_address;
        altsyncram #(
                .operation_mode("DUAL_PORT"), .ram_block_type("M10K"), .intended_device_family("Cyclone V"),
                .lpm_type("altsyncram"), .power_up_uninitialized("FALSE"),
                .width_a(W), .widthad_a($clog2(DEPTH)), .numwords_a(DEPTH),
                .width_b(W), .widthad_b($clog2(DEPTH)), .numwords_b(DEPTH),
                .width_byteena_a(BYTES), .byte_size(8),
                .address_reg_b("CLOCK0"), .outdata_reg_b("UNREGISTERED"),
                .clock_enable_input_a("NORMAL"), .clock_enable_input_b("NORMAL"),
                .clock_enable_output_b("BYPASS"), .rdcontrol_reg_b("CLOCK0"),
                .read_during_write_mode_mixed_ports("OLD_DATA"),
                .address_aclr_b("NONE"), .outdata_aclr_b("NONE")
        ) u_ram (
                .clock0(i_clk), .clocken0(1'b1), .wren_a(|i_write_en), .address_a(i_wr_addr_x), .data_a(wdata),
                .byteena_a(i_write_en), .address_b(i_rd_addr_x), .rden_b(i_read_en), .q_b(q)
        );
`else
        logic [LANES-1:0][7:0] mem [DEPTH-1:0];
        always_ff @(posedge i_clk) begin
                for (int l = 0; l < LANES; l++)
                        if (i_write_en[l]) mem[i_write_address][l] <= wdata[l];
                if (i_read_en) q <= mem[i_read_address];
        end
`endif
endmodule

module zap_cache_metadata_ram #(
        parameter integer DEPTH = 32
) (
        input logic i_clk,
        input logic i_read_en,
        input logic i_write_en,
        input logic i_write_data,
        input logic [$clog2(DEPTH)-1:0] i_read_address,
        input logic [$clog2(DEPTH)-1:0] i_write_address,
        output logic o_data
);
        (* ramstyle = "M10K" *) logic [0:0] mem [DEPTH-1:0];
        always_ff @(posedge i_clk)
                if (i_write_en) mem[i_write_address] <= i_write_data;
        always_ff @(posedge i_clk)
                if (i_read_en) o_data <= mem[i_read_address];
endmodule
