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
// This is the top level cache module that contains the MMU and cache.
// This is the instruction cache. Not that i_wr = 0.
//

module zap_cache #( // INSTRUCTION CACHE

parameter [31:0] CACHE_SIZE             = 32'd1024,
parameter [31:0] SPAGE_TLB_ENTRIES      = 32'd8,
parameter [31:0] LPAGE_TLB_ENTRIES      = 32'd8,
parameter [31:0] SECTION_TLB_ENTRIES    = 32'd8,
parameter [31:0] FPAGE_TLB_ENTRIES      = 32'd8,
parameter [31:0] CACHE_LINE             = 32'd8,
parameter [31:0] WAYS                   = 32'd1, // ARM925T: 1 or 2 (zap_cache_tag_ram).
parameter [31:0] CPSR_MODE              = 32'd4,
parameter [0:0]  PREFETCH               = 1'd0   // ARM925T: sequential next-line prefetch.

)
(

// Clock and reset.
input   logic            i_clk,
input   logic            i_reset,

// RAM stall.
input   logic            i_stall,

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
output logic  [31:0]     o_dat,
output  logic            o_ack,
output  logic            o_err,
output  logic [7:0]      o_fsr,
output  logic [31:0]     o_far,
output  logic            o_err2,
output  logic            o_fill_pending, o_fill_done, o_fill_fault,
// [0] demand completion, [1] demand wait, [2] wait selected onto this
// wrapper's bus, [3] I-TLB walk beat (ACK or ERR).
output  logic [3:0]      o_dbg_icache,

// MMU controls from/to processor.
input   logic            i_mmu_en,
input   logic            i_cache_en,
input   logic            i_cache_inv_req,
input   logic            i_cache_clean_req,
output logic             o_cache_inv_done,
output  logic            o_cache_clean_done,

input   logic [CPSR_MODE:0]    i_cpsr,
input   logic [1:0]            i_sr,
input   logic [31:0]           i_baddr,
input   logic [31:0]           i_dac_reg,
input   logic                  i_tlb_inv,
input   logic                  i_wb_busy,
input   logic                  i_pf_inv,

// Wishbone. Signals from all 4 modules are ORed.
output logic              o_wb_stb, o_wb_stb_nxt,
output logic              o_wb_cyc, o_wb_cyc_nxt,
output logic              o_wb_wen, o_wb_wen_nxt,
output logic  [3:0]       o_wb_sel, o_wb_sel_nxt,
output logic  [31:0]      o_wb_dat, o_wb_dat_nxt,
output logic  [31:0]      o_wb_adr, o_wb_adr_nxt,
output logic  [2:0]       o_wb_cti, o_wb_cti_nxt,
output logic  [1:0]       o_wb_bte, o_wb_bte_nxt,
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
logic [1:0]                      cache_bte;
logic [31:0]                     tlb_phy_addr;
logic [7:0]                      tlb_fsr;
logic [31:0]                     tlb_far;
logic                            tlb_fault;
logic                            tlb_cacheable;
logic                            tlb_busy;
logic [CACHE_LINE*8-1:0]         tr_cache_line;
logic [WAYS-1:0][31:0]           tr_cache_words;   // ARM925T
logic                            tr_cache_word_sel; // ARM925T
logic [CACHE_LINE*8-1:0]         cf_cache_line;
logic [CACHE_LINE-1:0]           cf_cache_line_ben;
logic                            cf_cache_tag_wr_en;
logic [`ZAP_CACHE_TAG_WDT-1:0]   tr_cache_tag, cf_cache_tag;
logic                            tr_cache_tag_valid;
logic                            tr_cache_hit;                  // ARM925T
logic [(WAYS > 1 ? $clog2(WAYS) : 1)-1:0] tr_cache_way, cf_cache_way; // ARM925T
logic                            tr_cache_tag_dirty, cf_cache_tag_dirty;
logic                            cf_cache_clean_req, cf_cache_inv_req;
logic                            tr_cache_inv_done, tr_cache_clean_done;
logic [2:0]                      wb_ack;
logic [2:0]                      state_ff, state_nxt;
logic [31:0]                     cache_address;
logic                            hold;
logic                            idle;
logic [2:0]                      wb_err;
logic [31:0]                     pf_addr;
logic                            tr_pf_hit;
logic                            mmu_en_q;
logic [1:0]                      sr_q;
logic [31:0]                     baddr_q, dac_reg_q;
logic                            pf_inv;
logic                            unused;
assign o_dbg_icache[2] = o_dbg_icache[1] && state_ff == SELECT_CCH;
assign o_dbg_icache[3] = state_ff == SELECT_TLB && o_wb_cyc && o_wb_stb && (i_wb_ack || i_wb_err);

//
// ARM925T: the prefetch buffer is dropped on a TLB invalidate, a D-side
// clean/invalidate or line operation (code may have been written), and on
// any change of the MMU enable, S/R, translation base or domain access.
// Registered (a cycle late) to keep the 32-bit compares off the fetch
// acknowledge; harmless, since a buffer hit is still checked against the
// live translation (fault, cacheable, physical address) like a cache hit,
// and the cache itself (virtually tagged) is not dropped on these at all.
//
always_ff @ ( posedge i_clk )
begin
        if ( i_reset )
        begin
                mmu_en_q  <= 1'd0;
                sr_q      <= 2'd0;
                baddr_q   <= 32'd0;
                dac_reg_q <= 32'd0;
                pf_inv    <= 1'd1;
        end
        else
        begin
                mmu_en_q  <= i_mmu_en;
                sr_q      <= i_sr;
                baddr_q   <= i_baddr;
                dac_reg_q <= i_dac_reg;
                pf_inv    <= i_tlb_inv || i_pf_inv || (i_mmu_en != mmu_en_q) || (i_sr != sr_q) ||
                             (i_baddr != baddr_q) || (i_dac_reg != dac_reg_q);
        end
end

// Selection 2 of Wishbone CTI[2x3] is always on all CPU supported modes.
assign wb_cti[2] = CTI_EOB;

// wb_err[1] is unused.
assign unused = |{wb_err[1]};

// Basic cache FSM - serves as manager 0.
zap_cache_fsm #(.CACHE_SIZE(CACHE_SIZE), .CACHE_LINE(CACHE_LINE), .WAYS(WAYS), .PREFETCH(PREFETCH)) u_zap_cache_fsm (
        .i_clk                  (i_clk),
        .i_reset                (i_reset),
        .i_address              (i_address),
        .i_address_check        (i_address_check),
        .i_stall                (i_stall),
        .i_rd                   (i_rd),
        .i_wr                   (i_wr),
        .i_din                  (i_dat),
        .o_idle                 (idle),
        .i_pf_hit               (tr_pf_hit),
        .i_pf_inv               (pf_inv),
        .i_wb_busy              (i_wb_busy || tlb_busy ||
                                 (state_ff != SELECT_CCH && o_wb_stb)),
        .o_pf_addr              (pf_addr),
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
        .i_cache_line           (tr_cache_line),
        .i_cache_words          (tr_cache_words),
        .i_cache_word_sel       (tr_cache_word_sel),
        .i_cache_tag_dirty      (tr_cache_tag_dirty),
        .i_cache_tag            (tr_cache_tag),
        .i_cache_tag_valid      (tr_cache_tag_valid),
        .i_cache_hit            (tr_cache_hit),
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
        .i_busy                 (tlb_busy),
        .o_err2                 (o_err2),
        .o_fill_pending         (o_fill_pending),
        .o_fill_done            (o_fill_done),
        .o_fill_fault           (o_fill_fault),
        .o_dbg_icache           (o_dbg_icache[1:0]),
        .o_address              (cache_address),
        .o_wb_cyc_nxt           (wb_cyc[0]),
        .o_hold                 (hold),

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
        .o_wb_bte_nxt           (cache_bte),
        .i_wb_dat               (i_wb_dat),
        .i_wb_ack               (wb_ack[0]),
        .i_wb_err               (wb_err[0])
);

// Cache Tag RAM - As a manager - this performs cache clean - manager 1.
zap_cache_tag_ram #(.CACHE_SIZE(CACHE_SIZE), .CACHE_LINE(CACHE_LINE), .WAYS(WAYS), .PREFETCH(PREFETCH)) u_zap_cache_tag_ram (
        .i_clk                  (i_clk),
        .i_reset                (i_reset),
        .i_address_nxt          (i_address_nxt),
        .i_address              (cache_address),
        .i_lookup_address       (i_address),
        .i_lookup_check_address (32'b0),
        .i_lookup_stall         (1'b0),
        /* verilator lint_off PINCONNECTEMPTY */
        .o_cache_hit_early      (),
        /* verilator lint_on PINCONNECTEMPTY */            // ARM925T
        .i_access               (i_rd || i_wr),
        .i_idle                 (idle),
        .o_cache_hit            (tr_cache_hit),
        /* verilator lint_off PINCONNECTEMPTY */
        .o_cache_hit_dirty      (),                     // never dirty
        /* verilator lint_on PINCONNECTEMPTY */
        .o_cache_way            (tr_cache_way),
        .i_cache_way            (cf_cache_way),
        .i_hold                 (hold || i_stall),
        .i_cache_en             (i_cache_en),
        .i_cache_line           (cf_cache_line),
        .o_cache_line           (tr_cache_line),
        .o_cache_words          (tr_cache_words),
        .o_cache_word_sel       (tr_cache_word_sel),
        .i_cache_line_ben       (cf_cache_line_ben),
        .i_cache_tag_wr_en      (cf_cache_tag_wr_en),
        .i_cache_tag            (cf_cache_tag),
        .i_cache_tag_dirty      (cf_cache_tag_dirty),
        .o_cache_tag            (tr_cache_tag),
        .o_cache_tag_valid      (tr_cache_tag_valid),
        .o_cache_tag_dirty      (tr_cache_tag_dirty),
        .i_cache_inv_req        (cf_cache_inv_req),
        .o_cache_inv_done       (tr_cache_inv_done),
        .i_cache_clean_req      (cf_cache_clean_req),
        .o_cache_clean_done     (tr_cache_clean_done),
        .i_line_req             (1'd0),         // ARM925T: D-side only
        .i_line_op              (2'd0),
        .i_line_va              (1'd0),
        .i_line_addr            (32'd0),
        .i_line_way             ('0),
        /* verilator lint_off PINCONNECTEMPTY */
        .o_line_done            (),
        /* verilator lint_on PINCONNECTEMPTY */
        .i_pf_addr              (pf_addr),
        .o_pf_hit               (tr_pf_hit),

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
        .i_wb_ack               (wb_ack[1])
);

// ZAP TLB control module. Includes TLB RAM inside - manager 2.
zap_tlb #(
        .LPAGE_TLB_ENTRIES      (LPAGE_TLB_ENTRIES),
        .SPAGE_TLB_ENTRIES      (SPAGE_TLB_ENTRIES),
        .SECTION_TLB_ENTRIES    (SECTION_TLB_ENTRIES),
        .FPAGE_TLB_ENTRIES      (FPAGE_TLB_ENTRIES),
        .CPSR_MODE              (ZAP_CPSR_MODE),
        .MMU_OFF_CACHEABLE      (1'd1)          // ARM925T: fetches with the MMU off are cacheable
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
        .i_hold         (hold || i_stall),
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
        /* verilator lint_off PINCONNECTEMPTY */
        .o_wt           (),
        .o_hit_ok       (),             // ARM925T: D-side only
        /* verilator lint_on PINCONNECTEMPTY */
        .o_cacheable    (tlb_cacheable),
        .o_busy         (tlb_busy),
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
        //
        // Change state only if strobe is inactive or strobe has just completed.
        // ERR follows ACK. There's an assertion to check that.
        //
        if ( !o_wb_stb || (o_wb_stb && (i_wb_ack || i_wb_err) && (o_wb_cti == CTI_EOB)) )
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

// Route ERRs and ACKs to respective managers.
always_comb
begin
        case(state_ff)
        SELECT_CCH: {wb_err, wb_ack} = {2'd0, i_wb_err, 2'd0, i_wb_ack};
        SELECT_TAG: {wb_err, wb_ack} = {1'd0, i_wb_err, 2'd0, i_wb_ack, 1'd0};
        SELECT_TLB: {wb_err, wb_ack} = {i_wb_err, 2'd0, i_wb_ack, 2'd0};
        default:    {wb_err, wb_ack} = {6{1'dx}};
        endcase
end

//
// ARM925T: the next CYC is any manager's when the bus may change hands
// (the condition the state machine uses), else the current manager's: the
// value the mux below would give, since the manager the priority select
// chooses has CYC whenever any has; one level after the acknowledge
// instead of through the select (timing).
//
assign o_wb_cyc_nxt = ( !o_wb_stb || (o_wb_stb && (i_wb_ack || i_wb_err) && (o_wb_cti == CTI_EOB)) ) ? (|wb_cyc) : (|(state_ff & wb_cyc));

// ARM925T: compute the selected strobe directly, alongside arbitration.
// The hold case still uses the current owner; a new request retains the
// TLB > tag > cache priority even if a manager's CYC and STB differ.
assign o_wb_stb_nxt = ((!o_wb_stb || (o_wb_stb && i_wb_ack)) && (|wb_cyc)) ?
        ((wb_cyc[2] && wb_stb[2]) ||
         (!wb_cyc[2] && wb_cyc[1] && wb_stb[1]) ||
         (!wb_cyc[2] && !wb_cyc[1] && wb_cyc[0] && wb_stb[0])) :
        (|(state_ff & wb_stb));

// Only demand fills wrap; maintenance and TLB accesses remain linear.
assign o_wb_bte_nxt = state_nxt == SELECT_CCH ? cache_bte : 2'b00;

// Combo signals for external MUXing.
always_comb
begin
        case(state_nxt)
        SELECT_CCH:
        begin
                o_wb_adr_nxt = wb_adr[0];
                o_wb_dat_nxt = wb_dat[0];
                o_wb_cti_nxt = wb_cti[0];
                o_wb_sel_nxt = wb_sel[0];
                o_wb_wen_nxt = wb_wen[0];
        end
        SELECT_TAG:
        begin
                o_wb_adr_nxt = wb_adr[1];
                o_wb_dat_nxt = wb_dat[1];
                o_wb_cti_nxt = wb_cti[1];
                o_wb_sel_nxt = wb_sel[1];
                o_wb_wen_nxt = wb_wen[1];
        end
        SELECT_TLB:
        begin
                o_wb_adr_nxt = wb_adr[2];
                o_wb_dat_nxt = wb_dat[2];
                o_wb_cti_nxt = wb_cti[2];
                o_wb_sel_nxt = wb_sel[2];
                o_wb_wen_nxt = wb_wen[2];
        end
        default: // Assigning X will cause synthesis to better optimize.
        begin
                o_wb_adr_nxt = 'x;
                o_wb_dat_nxt = 'x;
                o_wb_cti_nxt = 'x;
                o_wb_sel_nxt = 'x;
                o_wb_wen_nxt = 'x;
        end
        endcase
end

endmodule : zap_cache

// ----------------------------------------------------------------------------
// END OF FILE
// ----------------------------------------------------------------------------
