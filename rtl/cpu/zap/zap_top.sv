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
//
// This is the top module of the ZAP processor. It contains instances of
// processor core and the memory management units. I and D WB busses
// are provided.
//

module zap_top #(
        parameter CORE = "ZAP",
        parameter logic ARM9_PREDICTOR = 1'b1,

// -----------------------------------
// CP15 L4 bit default.
// -----------------------------------

parameter logic [0:0] CP15_L4_DEFAULT            = 1'd0,

// -----------------------------------
// Only core. When 1, cache and MMU
// are not present.
// -----------------------------------

parameter logic [0:0]      ONLY_CORE          = 1'd0,

// -----------------------------------
// Set reset vector here
// -----------------------------------

parameter logic [31:0]       RESET_VECTOR      = 32'd0,

// -----------------------------------
// Set initial value of CPSR here.
// -----------------------------------

parameter logic [31:0]       CPSR_INIT          = {24'd0, 1'd1,1'd1,1'd0,5'b10011},

// -----------------------------------
// Enable BE-32
// -----------------------------------

parameter logic  [0:0]       BE_32_ENABLE       = 1'd0,

// -----------------------------------
// BP entries, FIFO depths
// -----------------------------------

parameter logic  [31:0]       BP_ENTRIES         = 32'd512,  // Predictor depth.
parameter logic  [31:0]       FIFO_DEPTH         = 32'd16,   // FIFO depth.
parameter logic  [31:0]       RAS_DEPTH          = 32'd4,    // Depth of RAS.

// ----------------------------------
// Data MMU/Cache configuration.
// ----------------------------------
// ARM925T: the TLBs are direct-mapped buffers indexed by the low bits of
// the page number (sections VA[25:20], large VA[20:16], small VA[19:12],
// tiny VA[15:10]). With the upstream sizes (4/8/16/32) the firmware's
// exception-vector page at virtual 0 and its kernel code pages at
// 0x50320000 shared small-page slot 0 and evicted each other on every
// exception, a two-level walk each time (the measured boot: a walk every
// 78 clocks). The real part has 64-entry associative TLBs.
parameter logic [31:0] DATA_SECTION_TLB_ENTRIES =  32'd64,    // Section TLB entries.
parameter logic [31:0] DATA_LPAGE_TLB_ENTRIES   =  32'd32,    // Large page TLB entries.
parameter logic [31:0] DATA_SPAGE_TLB_ENTRIES   =  32'd256,   // Small page TLB entries.
parameter logic [31:0] DATA_FPAGE_TLB_ENTRIES   =  32'd64,   // Tiny page TLB entries.
parameter logic [31:0] DATA_CACHE_SIZE          =  32'd8192, // Cache size in bytes.
parameter logic [31:0] DATA_CACHE_LINE          =  32'd64,   // Cache line size in bytes.
parameter logic [31:0] DATA_CACHE_WAYS          =  32'd1,    // ARM925T: 1 or 2.

// ----------------------------------
// Code MMU/Cache configuration.
// ----------------------------------
parameter logic [31:0] CODE_SECTION_TLB_ENTRIES =  32'd64,    // Section TLB entries.
parameter logic [31:0] CODE_LPAGE_TLB_ENTRIES   =  32'd32,    // Large page TLB entries.
parameter logic [31:0] CODE_SPAGE_TLB_ENTRIES   =  32'd256,   // Small page TLB entries.
parameter logic [31:0] CODE_FPAGE_TLB_ENTRIES   =  32'd64,   // Fine page TLB entries.
parameter logic [31:0] CODE_CACHE_SIZE          =  32'd8192, // Cache size in bytes.
parameter logic [31:0] CODE_CACHE_LINE          =  32'd64,   // Ccahe line size in bytes.
parameter logic [31:0] CODE_CACHE_WAYS          =  32'd1,    // ARM925T: 1 or 2.
parameter logic        CODE_CACHE_PREFETCH      =  1'd0,     // ARM925T: sequential next-line prefetch.

// ----------------------------------
// ARM925T options. The defaults give upstream ZAP; rtl/cpu/arm925t.sv
// sets the ARM925T values. See docs/CPU.md.
// ----------------------------------
parameter logic        V4T          = 1'd0,          // ARMv4T: ARMv5 instructions are UNDEFINED,
                                                     // v4T interworking, ARMv4 PSRs.
parameter logic        TI925T       = 1'd0,          // TI925T CP15: control register, A and V bits,
                                                     // c15 registers, c7 operations, FSR codes.
parameter logic [31:0] CP15_ID      = 32'h0005AAA0,  // c0 main ID (with TI925T: TI config O = 0).
parameter logic [31:0] CP15_CTYPE   = 32'd0,         // c0 cache type; 0 = from the cache parameters.
parameter logic        HIVECS       = 1'd0           // Reset value of control bit V (TI925T).

)(
        `ifndef SYNTHESIS

        // --------------------------------------
        // Trace. Only for DV. Leave open.
        // --------------------------------------

        output  logic  [1023:0]    o_trace,
        output  logic              o_trace_valid,
        output  logic              o_trace_uop_last,

        `endif

        // --------------------------------------
        // Clock and reset
        // --------------------------------------

        // ARM925T: committed PC, for the core's debug overlay.
        output  logic  [31:0]    o_dbg_pc,

        // ARM925T: debug trace taps (rtl/mister/dbg_trace.sv): the
        // writeback stage, and the data port's completed accesses.
        output  logic            o_dbg_wb_valid,
        output  logic            o_dbg_wfi,
        output  logic            o_dbg_wb_dvalid,
        output  logic            o_dbg_wb_uop_last,
        output  logic  [1:0]     o_dbg_wb_dabt,
        output  logic            o_dbg_wb_pabt,
        output  logic            o_dbg_wb_und,
        output  logic            o_dbg_wb_swi,
        output  logic            o_dbg_wb_irq,
        output  logic            o_dbg_wb_fiq,
        output  logic  [31:0]    o_dbg_wb_pc,
        output  logic  [31:0]    o_dbg_wb_cpsr,
        output  logic  [31:0]    o_dbg_wb_cpsr_nxt,
        output  logic  [7:0]     o_dbg_stall,
        output  logic  [3:0]     o_dbg_dcache,
        output  logic            o_dbg_d_done,
        output  logic            o_dbg_d_we,
        output  logic  [31:0]    o_dbg_d_va,
        output  logic  [3:0]     o_dbg_d_sel,
        output  logic  [31:0]    o_dbg_d_wdata,
        output  logic  [31:0]    o_dbg_d_rdata,

        input   logic            i_clk,
        input   logic            i_reset,

        // ---------------------------------------
        // Interrupts.
        // Both of them are active high and level
        // trigerred.
        // ---------------------------------------

        input   logic            i_irq,
        input   logic            i_fiq,

        // ---------------------
        // Wishbone interface.
        // ---------------------

        output  logic            o_wb_cyc,
        output  logic            o_wb_stb,
        output  logic  [31:0]    o_wb_adr,
        output  logic            o_wb_we,
        output  logic  [31:0]    o_wb_dat,
        output  logic  [3:0]     o_wb_sel,
        output  logic  [2:0]     o_wb_cti,
        output  logic  [1:0]     o_wb_bte,
        input   logic            i_wb_ack,
        input   logic  [31:0]    i_wb_dat,
        input   logic            i_wb_err
);

`include "zap_defines.svh"
`include "zap_localparams.svh"
`include "zap_functions.svh"

// Assertion.

always@(posedge i_clk) // Assertion.
begin
        if (!i_reset && o_wb_cyc)
        begin
                assert ( |o_wb_cti ) else  $fatal(2, "O_WB_CTI is not EOB.");
        end
end

logic            wb_cyc, wb_stb, wb_we;
logic [3:0]      wb_sel;
logic [31:0]     wb_dat, wb_idat;
logic [31:0]     wb_adr;
logic [2:0]      wb_cti;
logic            wb_ack;
logic            wb_err;
logic            cpu_mmu_en;
logic [ZAP_CPSR_MODE:0] cpu_cpsr;
logic            cpu_mem_translate;
logic [ZAP_CPSR_MODE:0] cpu_mem_cpsr;   // ARM925T: see zap_core o_mem_cpsr
logic [31:0]     cpu_daddr, cpu_daddr_nxt, cpu_daddr_check;
logic [31:0]     cpu_iaddr, cpu_iaddr_nxt, cpu_iaddr_check;
assign o_dbg_pc = cpu_iaddr; // ARM925T: debug overlay

// ARM925T: debug trace taps. A data access is done in a clock in which the
// data cache acks it and does not ask for it again (err2).
assign o_dbg_d_done  = cpu_dc_stb && data_ack && !dcache_err2;
assign o_dbg_d_we    = cpu_dc_we;
assign o_dbg_d_va    = cpu_daddr;
assign o_dbg_d_sel   = cpu_dc_sel;
assign o_dbg_d_wdata = cpu_dc_dat;
assign o_dbg_d_rdata = dc_data;
logic [7:0]      dc_fsr;
logic [31:0]     dc_far;
logic            cpu_dc_en, cpu_ic_en;
logic [1:0]      cpu_sr;
logic [31:0]     cpu_baddr, cpu_dac_reg;
logic            cpu_dc_inv, cpu_ic_inv;
logic            cpu_dc_clean, cpu_ic_clean;
logic            dc_inv_done, ic_inv_done, dc_clean_done, ic_clean_done;
logic            cpu_dtlb_inv, cpu_itlb_inv;
logic            data_ack, data_err, instr_ack, instr_err;
logic [31:0]     ic_data, dc_data, cpu_dc_dat;
logic [31:0] dc_short_data;
logic dc_short_hit;
logic            cpu_instr_stb;
logic            cpu_dc_we, cpu_dc_stb;
logic [3:0]      cpu_dc_sel;
logic            c_wb_stb;
logic            c_wb_cyc;
logic            c_wb_wen;
logic [3:0]      c_wb_sel;
logic [31:0]     c_wb_dat;
logic [31:0]     c_wb_adr;
logic [2:0]      c_wb_cti;
logic            c_wb_ack;
logic            c_wb_err;
logic            d_wb_stb;
logic            d_wb_cyc;
logic            d_wb_wen;
logic [3:0]      d_wb_sel;
logic [31:0]     d_wb_dat;
logic [31:0]     d_wb_adr;
logic [2:0]      d_wb_cti;
logic [1:0]      d_wb_bte;
logic            d_wb_ack;
logic            d_wb_err;
logic [63:0]     dc_rreg_idx, dc_wreg_idx;
logic [5:0]      dc_rreg_idx_bin;
logic [63:0]     dc_lock;
logic dc_lock_any, dc_lock_owner;
logic [5:0] dc_lock_owner_next;
logic [31:0]     dc_reg_data;
logic            icache_err2, dcache_err2;
logic arm9_data_stall, data_fill_busy;
logic [31:0] ic_data_early;
logic ic_hit;
logic            icache_fill_pending, icache_fill_done, icache_fill_fault;
logic            cpu_dwe_check, cpu_dre_check;
logic            s_reset, s_fiq, s_irq;
logic            cpu_align_fault;   // ARM925T
logic            cpu_dline_req, cpu_dline_va, dc_line_done;   // ARM925T
logic [1:0]      cpu_dline_op;                                // ARM925T
logic [31:0]     cpu_dline_addr;                              // ARM925T
logic            cpu_dline_way;                               // ARM925T
logic [31:0]     cpu_daddr_va;      // ARM925T
logic [5:0] cpu_dldfmt_check;
logic [5:0]      cpu_dldfmt;        // ARM925T
logic            code_stall;

assign          s_reset = i_reset;

zap_dual_rank_synchronizer #(.WIDTH(2)) u_sync (
        .i_clk   (i_clk),
        .i_reset (i_reset),
        .i_async ({i_fiq, i_irq}),
        .o_sync  ({s_fiq, s_irq})
);

`ifdef SYNTHESIS

/* verilator lint_off UNUSEDSIGNAL */

logic [1023:0]       o_trace;
logic                o_trace_valid;
logic                o_trace_uop_last;

/* verilator lint_on UNUSEDSIGNAL */

`endif

wire dc_writeback_busy; // ARM925T: registered eviction ownership

if (CORE == "ZAP") begin : g_zap
assign arm9_data_stall = 1'b0;
assign dc_lock_owner_next = 0;
wire unused_lock_summaries = &{1'b0,dc_lock_any,dc_lock_owner};
assign cpu_dldfmt_check = 6'd0;
zap_core #(
        .CP15_L4_DEFAULT(CP15_L4_DEFAULT),
        .BP_ENTRIES(BP_ENTRIES),
        .FIFO_DEPTH(FIFO_DEPTH),
        .RAS_DEPTH(RAS_DEPTH),
        .BE_32_ENABLE(BE_32_ENABLE),
        .RESET_VECTOR(RESET_VECTOR),
        .CPSR_INIT(CPSR_INIT),
        .DATA_CACHE_SIZE(DATA_CACHE_SIZE),
        .DATA_CACHE_LINE(DATA_CACHE_LINE),
        .DATA_CACHE_WAYS(DATA_CACHE_WAYS),
        .LOAD_FORMATTED(!ONLY_CORE),     // ARM925T
        .CODE_CACHE_SIZE(CODE_CACHE_SIZE),
        .CODE_CACHE_LINE(CODE_CACHE_LINE),
        .CPSR_MODE(ZAP_CPSR_MODE),
        .V4T(V4T),
        .TI925T(TI925T),
        .CP15_ID(CP15_ID),
        .CP15_CTYPE(CP15_CTYPE),
        .HIVECS(HIVECS)
) u_zap_core
(
// Trace
.o_trace                (o_trace),
.o_trace_valid          (o_trace_valid),
.o_trace_uop_last       (o_trace_uop_last),

// ARM925T: debug trace taps.
.o_dbg_wb_valid         (o_dbg_wb_valid),
.o_dbg_wfi              (o_dbg_wfi),
.o_dbg_wb_dvalid        (o_dbg_wb_dvalid),
.o_dbg_wb_uop_last      (o_dbg_wb_uop_last),
.o_dbg_wb_dabt          (o_dbg_wb_dabt),
.o_dbg_wb_pabt          (o_dbg_wb_pabt),
.o_dbg_wb_und           (o_dbg_wb_und),
.o_dbg_wb_swi           (o_dbg_wb_swi),
.o_dbg_wb_irq           (o_dbg_wb_irq),
.o_dbg_wb_fiq           (o_dbg_wb_fiq),
.o_dbg_wb_pc            (o_dbg_wb_pc),
.o_dbg_wb_cpsr          (o_dbg_wb_cpsr),
.o_dbg_wb_cpsr_nxt      (o_dbg_wb_cpsr_nxt),
.o_dbg_stall            (o_dbg_stall),

// Clock and reset.
.i_clk                  (i_clk),
.i_reset                (s_reset),

// Code related.
.o_instr_wb_adr         (cpu_iaddr),
.o_instr_wb_stb         (cpu_instr_stb),
/* verilator lint_off PINCONNECTEMPTY */
.o_instr_wb_cyc         (),
.o_instr_wb_we          (),
.o_instr_wb_sel         (),
/* verilator lint_on PINCONNECTEMPTY */
.o_code_stall           (code_stall),

.i_instr_wb_dat         (!ONLY_CORE ? ic_data   : i_wb_dat),
.i_instr_wb_ack         (instr_ack),
.i_instr_wb_err         (instr_err),

// Data related.
.o_data_wb_we           (cpu_dc_we),
.o_data_wb_adr          (cpu_daddr),
.o_data_wb_sel          (cpu_dc_sel),
.o_data_wb_dat          (cpu_dc_dat),
/* verilator lint_off PINCONNECTEMPTY */
.o_data_wb_cyc          (),
.o_pid                  (),
/* verilator lint_on PINCONNECTEMPTY */
.o_data_wb_stb          (cpu_dc_stb),
.i_data_wb_dat          (!ONLY_CORE ? dc_data :
                         BE_32_ENABLE ? be_32(i_wb_dat, o_wb_sel) : i_wb_dat),
                        // Swap data into CPU based on current o_wb_sel.

.i_data_wb_ack          (data_ack),
.i_data_wb_err          (data_err),

// Interrupts.
.i_fiq                  (s_fiq),
.i_irq                  (s_irq),

// MMU/cache is present.
.i_fsr                  (!ONLY_CORE ? {24'd0,dc_fsr} : '0),
.i_far                  (!ONLY_CORE ? dc_far : '0),

.o_mem_translate        (cpu_mem_translate),
.o_mem_cpsr             (cpu_mem_cpsr),
.o_data_wb_align_fault  (cpu_align_fault),
.o_data_wb_va           (cpu_daddr_va),
.o_data_wb_ldfmt        (cpu_dldfmt),
.o_dcache_line_req      (cpu_dline_req),
.o_dcache_line_op       (cpu_dline_op),
.o_dcache_line_va       (cpu_dline_va),
.o_dcache_line_addr     (cpu_dline_addr),
.o_dcache_line_way      (cpu_dline_way),
.i_dcache_line_done     (!ONLY_CORE ? dc_line_done : 1'd1),
.i_dcache_writeback_busy (!ONLY_CORE ? dc_writeback_busy : 1'd0),
.o_dac                  (cpu_dac_reg),
.o_baddr                (cpu_baddr),
.o_mmu_en               (cpu_mmu_en),
.o_sr                   (cpu_sr),
.o_dcache_inv           (cpu_dc_inv),
.o_icache_inv           (cpu_ic_inv),
.o_dcache_clean         (cpu_dc_clean),
.o_icache_clean         (cpu_ic_clean),
.o_dtlb_inv             (cpu_dtlb_inv),
.o_itlb_inv             (cpu_itlb_inv),
.o_dcache_en            (cpu_dc_en),
.o_icache_en            (cpu_ic_en),
.o_data_wb_adr_nxt      (cpu_daddr_nxt),
// Data addr nxt. Used to drive address of data tag RAM.
.o_data_wb_adr_check    (cpu_daddr_check),
.o_data_wb_we_check     (cpu_dwe_check),
.o_data_wb_re_check     (cpu_dre_check),
.o_instr_wb_adr_nxt     (cpu_iaddr_nxt),
// PC addr nxt. Drives read address of code tag RAM.
.o_instr_wb_adr_check   (cpu_iaddr_check),
.o_cpsr                 (cpu_cpsr[ZAP_CPSR_MODE:0]),
.o_dc_reg_idx           (dc_rreg_idx),
.o_dc_reg_idx_bin       (dc_rreg_idx_bin),

.i_dc_reg_idx           (!ONLY_CORE ? dc_wreg_idx : '0),
.i_dc_lock              (!ONLY_CORE ? dc_lock : '0),
.i_dc_reg_dat           (!ONLY_CORE ? dc_reg_data : '0),
.i_dcache_inv_done      (!ONLY_CORE ? dc_inv_done : '0),
.i_icache_inv_done      (!ONLY_CORE ? ic_inv_done : '0),
.i_dcache_clean_done    (!ONLY_CORE ? dc_clean_done : '0),
.i_icache_clean_done    (!ONLY_CORE ? ic_clean_done : '0),
.i_icache_err2          (!ONLY_CORE ? icache_err2 : '0),
.i_icache_fill_pending  (!ONLY_CORE && icache_fill_pending),
.i_icache_fill_done     (!ONLY_CORE && icache_fill_done),
.i_icache_fill_fault    (!ONLY_CORE && icache_fill_fault),
.i_dcache_err2          (!ONLY_CORE ? dcache_err2 : '0)
);
end else if (CORE == "ARM9") begin : g_arm9
arm9v2_core #(
.ARM9_PREDICTOR        (ARM9_PREDICTOR),
        .CP15_L4_DEFAULT(CP15_L4_DEFAULT),
        .BP_ENTRIES(BP_ENTRIES),
        .FIFO_DEPTH(FIFO_DEPTH),
        .RAS_DEPTH(RAS_DEPTH),
        .BE_32_ENABLE(BE_32_ENABLE),
        .RESET_VECTOR(RESET_VECTOR),
        .CPSR_INIT(CPSR_INIT),
        .DATA_CACHE_SIZE(DATA_CACHE_SIZE),
        .DATA_CACHE_LINE(DATA_CACHE_LINE),
        .DATA_CACHE_WAYS(DATA_CACHE_WAYS),
        .LOAD_FORMATTED(!ONLY_CORE),     // ARM925T
        .CODE_CACHE_SIZE(CODE_CACHE_SIZE),
        .CODE_CACHE_LINE(CODE_CACHE_LINE),
        .CPSR_MODE(ZAP_CPSR_MODE),
        .V4T(V4T),
        .TI925T(TI925T),
        .CP15_ID(CP15_ID),
        .CP15_CTYPE(CP15_CTYPE),
        .HIVECS(HIVECS)
) u_arm9_core
(
// Trace
.o_trace                (o_trace),
.o_trace_valid          (o_trace_valid),
.o_trace_uop_last       (o_trace_uop_last),

// ARM925T: debug trace taps.
.o_dbg_wb_valid         (o_dbg_wb_valid),
.o_dbg_wfi              (o_dbg_wfi),
.o_dbg_wb_dvalid        (o_dbg_wb_dvalid),
.o_dbg_wb_uop_last      (o_dbg_wb_uop_last),
.o_dbg_wb_dabt          (o_dbg_wb_dabt),
.o_dbg_wb_pabt          (o_dbg_wb_pabt),
.o_dbg_wb_und           (o_dbg_wb_und),
.o_dbg_wb_swi           (o_dbg_wb_swi),
.o_dbg_wb_irq           (o_dbg_wb_irq),
.o_dbg_wb_fiq           (o_dbg_wb_fiq),
.o_dbg_wb_pc            (o_dbg_wb_pc),
.o_dbg_wb_cpsr          (o_dbg_wb_cpsr),
.o_dbg_wb_cpsr_nxt      (o_dbg_wb_cpsr_nxt),
.o_dbg_stall            (o_dbg_stall),

// Clock and reset.
.o_data_stall           (arm9_data_stall),
.i_data_fill_busy       (data_fill_busy),
.i_clk                  (i_clk),
.i_reset                (s_reset),

// Code related.
.o_instr_wb_adr         (cpu_iaddr),
.o_instr_wb_stb         (cpu_instr_stb),
/* verilator lint_off PINCONNECTEMPTY */
.o_instr_wb_cyc         (),
.o_instr_wb_we          (),
.o_instr_wb_sel         (),
/* verilator lint_on PINCONNECTEMPTY */
.o_code_stall           (code_stall),

.i_instr_wb_dat         (!ONLY_CORE ? ic_data   : i_wb_dat),
.i_instr_data_early     (ic_data_early),
.i_instr_hit            (!ONLY_CORE && ic_hit),
.i_instr_wb_ack         (instr_ack),
.i_instr_wb_err         (instr_err),

// Data related.
.o_data_wb_we           (cpu_dc_we),
.o_data_wb_adr          (cpu_daddr),
.o_data_wb_sel          (cpu_dc_sel),
.o_data_wb_dat          (cpu_dc_dat),
/* verilator lint_off PINCONNECTEMPTY */
.o_data_wb_cyc          (),
.o_pid                  (),
/* verilator lint_on PINCONNECTEMPTY */
.o_data_wb_stb          (cpu_dc_stb),
.i_data_short_data(dc_short_data),.i_data_short_hit(dc_short_hit),
.i_data_wb_dat          (!ONLY_CORE ? dc_data :
                         BE_32_ENABLE ? be_32(i_wb_dat, o_wb_sel) : i_wb_dat),
                        // Swap data into CPU based on current o_wb_sel.

.i_data_wb_ack          (data_ack),
.i_data_wb_err          (data_err),

// Interrupts.
.i_fiq                  (s_fiq),
.i_irq                  (s_irq),

// MMU/cache is present.
.i_fsr                  (!ONLY_CORE ? {24'd0,dc_fsr} : '0),
.i_far                  (!ONLY_CORE ? dc_far : '0),

.o_mem_translate        (cpu_mem_translate),
.o_mem_cpsr             (cpu_mem_cpsr),
.o_data_wb_align_fault  (cpu_align_fault),
.o_data_wb_va           (cpu_daddr_va),
.o_data_wb_ldfmt        (cpu_dldfmt),
.o_data_wb_ldfmt_check  (cpu_dldfmt_check),
.o_dcache_line_req      (cpu_dline_req),
.o_dcache_line_op       (cpu_dline_op),
.o_dcache_line_va       (cpu_dline_va),
.o_dcache_line_addr     (cpu_dline_addr),
.o_dcache_line_way      (cpu_dline_way),
.i_dcache_line_done     (!ONLY_CORE ? dc_line_done : 1'd1),
.i_dcache_writeback_busy (!ONLY_CORE ? dc_writeback_busy : 1'd0),
.o_dac                  (cpu_dac_reg),
.o_baddr                (cpu_baddr),
.o_mmu_en               (cpu_mmu_en),
.o_sr                   (cpu_sr),
.o_dcache_inv           (cpu_dc_inv),
.o_icache_inv           (cpu_ic_inv),
.o_dcache_clean         (cpu_dc_clean),
.o_icache_clean         (cpu_ic_clean),
.o_dtlb_inv             (cpu_dtlb_inv),
.o_itlb_inv             (cpu_itlb_inv),
.o_dcache_en            (cpu_dc_en),
.o_icache_en            (cpu_ic_en),
.o_data_wb_adr_nxt      (cpu_daddr_nxt),
// Data addr nxt. Used to drive address of data tag RAM.
.o_data_wb_adr_check    (cpu_daddr_check),
.o_data_wb_we_check     (cpu_dwe_check),
.o_data_wb_re_check     (cpu_dre_check),
.o_instr_wb_adr_nxt     (cpu_iaddr_nxt),
// PC addr nxt. Drives read address of code tag RAM.
.o_instr_wb_adr_check   (cpu_iaddr_check),
.o_cpsr                 (cpu_cpsr[ZAP_CPSR_MODE:0]),
.o_dc_reg_idx           (dc_rreg_idx),
.o_dc_reg_idx_bin       (dc_rreg_idx_bin),

.i_dc_reg_idx           (!ONLY_CORE ? dc_wreg_idx : '0),
.i_dc_lock              (!ONLY_CORE ? dc_lock : '0),
.i_dc_lock_any          (!ONLY_CORE && dc_lock_any),
.i_dc_lock_owner        (!ONLY_CORE && dc_lock_owner),
.o_dc_lock_owner_next   (dc_lock_owner_next),
.i_dc_reg_dat           (!ONLY_CORE ? dc_reg_data : '0),
.i_dcache_inv_done      (!ONLY_CORE ? dc_inv_done : '0),
.i_icache_inv_done      (!ONLY_CORE ? ic_inv_done : '0),
.i_dcache_clean_done    (!ONLY_CORE ? dc_clean_done : '0),
.i_icache_clean_done    (!ONLY_CORE ? ic_clean_done : '0),
.i_icache_err2          (!ONLY_CORE ? icache_err2 : '0),
.i_icache_fill_pending  (!ONLY_CORE && icache_fill_pending),
.i_icache_fill_done     (!ONLY_CORE && icache_fill_done),
.i_icache_fill_fault    (!ONLY_CORE && icache_fill_fault),
.i_dcache_err2          (!ONLY_CORE ? dcache_err2 : '0)
);
end else begin : g_invalid_core
    initial $fatal(1, "CORE must be ZAP or ARM9");
end

if ( !ONLY_CORE )
begin : l_tieoffs_full
         // Normal case - with cache and MMU.
end : l_tieoffs_full
else
begin : l_tieoffs_only_core
        assign o_dbg_dcache    = '0;
        assign dc_wreg_idx     = '0;
        assign dc_lock         = '0;
        assign {dc_lock_any,dc_lock_owner} = '0;
        assign dc_reg_data     = '0;
        assign dc_inv_done     = '0;
        assign ic_inv_done     = '0;
        assign dc_clean_done   = '0;
        assign ic_clean_done   = '0;
        assign icache_err2     = '0;
        assign {icache_fill_pending, icache_fill_done, icache_fill_fault} = '0;
        assign dcache_err2     = '0;
        assign data_fill_busy = 1'b0;
        assign dc_fsr          = '0;
        assign dc_far          = '0;
        assign dc_data         = '0;
        assign dc_short_data = 0;assign dc_short_hit = 0;
        assign ic_data         = '0;
        assign c_wb_ack        = '0;
        assign c_wb_err        = '0;
        assign d_wb_ack        = '0;
        assign d_wb_err        = '0;
        assign wb_cyc          = '0;
        assign wb_stb          = '0;
        assign wb_we           = '0;
        assign wb_sel          = '0;
        assign wb_idat         = '0;
        assign wb_adr          = '0;
        assign wb_cti          = CTI_EOB;
        assign wb_ack          = '0;
        assign wb_err          = '0;
        assign c_wb_stb        = '0;
        assign c_wb_cyc        = '0;
        assign c_wb_wen        = '0;
        assign c_wb_sel        = '0;
        assign c_wb_dat        = '0;
        assign c_wb_adr        = '0;
        assign c_wb_cti        = CTI_EOB;
        assign d_wb_stb        = '0;
        assign d_wb_cyc        = '0;
        assign d_wb_wen        = '0;
        assign d_wb_sel        = '0;
        assign d_wb_dat        = '0;
        assign d_wb_adr        = '0;
        assign d_wb_cti        = CTI_EOB;
        assign d_wb_bte        = 2'b00;
        assign wb_dat          = '0;

        logic unused;

        assign unused =
           (    |dc_wreg_idx       )
         | (    |dc_lock           )
         | (    |dc_reg_data       )
         | (    |dc_inv_done       )
         | (    |ic_inv_done       )
         | (    |dc_clean_done     )
         | (    |ic_clean_done     )
         | (    |icache_err2       )
         | (    |dcache_err2       )
         | (    |dc_fsr            )
         | (    |dc_far            )
         | (    |dc_data           )
         | (    |ic_data           )
         | (    |c_wb_ack          )
         | (    |c_wb_err          )
         | (    |d_wb_ack          )
         | (    |d_wb_err          )
         | (    |wb_cyc            )
         | (    |wb_stb            )
         | (    |wb_we             )
         | (    |wb_sel            )
         | (    |wb_idat           )
         | (    |wb_adr            )
         | (    |wb_cti            )
         | (    |wb_ack            )
         | (    |wb_err            )
         | (    |c_wb_stb          )
         | (    |c_wb_cyc          )
         | (    |c_wb_wen          )
         | (    |c_wb_sel          )
         | (    |c_wb_dat          )
         | (    |c_wb_adr          )
         | (    |c_wb_cti          )
         | (    |d_wb_stb          )
         | (    |d_wb_cyc          )
         | (    |d_wb_wen          )
         | (    |d_wb_sel          )
         | (    |d_wb_dat          )
         | (    |d_wb_adr          )
         | (    |d_wb_cti          )
         | (    |d_wb_bte          )
         | (    |wb_dat            )
         | (    |cpu_mmu_en        )
         | (    |cpu_cpsr          )
         | (    |cpu_mem_translate )
         | (    |cpu_daddr_nxt     )
         | (    |cpu_daddr_check   )
         | (    |cpu_iaddr_nxt     )
         | (    |cpu_iaddr_check   )
         | (    |cpu_dc_en         )
         | (    |cpu_ic_en         )
         | (    |cpu_sr            )
         | (    |cpu_baddr         )
         | (    |cpu_dac_reg       )
         | (    |cpu_dc_inv        )
         | (    |cpu_ic_inv        )
         | (    |cpu_dc_clean      )
         | (    |cpu_ic_clean      )
         | (    |cpu_dtlb_inv      )
         | (    |cpu_itlb_inv      )
         | (    |dc_rreg_idx       )
         | (    |dc_rreg_idx_bin   )
         | (    |cpu_dwe_check     )
         | (    |cpu_dre_check     )
         | (    |code_stall        )
         ;
end : l_tieoffs_only_core

if ( !ONLY_CORE )
begin : l_merger_for_core_with_cache_mmu

        zap_wb_merger #(.ONLY_CORE(1'd0)) u_zap_wb_merger (

        .i_clk(i_clk),
        .i_reset(s_reset),

        .i_c_wb_stb(c_wb_stb ),
        .i_c_wb_cyc(c_wb_cyc ),
        .i_c_wb_wen(c_wb_wen ),
        .i_c_wb_sel(c_wb_sel ),
        .i_c_wb_dat(c_wb_dat ),
        .i_c_wb_adr(c_wb_adr ),
        .i_c_wb_cti(c_wb_cti ),
        .o_c_wb_ack(c_wb_ack ),
        .o_c_wb_err(c_wb_err ),

        .i_d_wb_stb(d_wb_stb ),
        .i_d_wb_cyc(d_wb_cyc ),
        .i_d_wb_wen(d_wb_wen ),
        .i_d_wb_sel(d_wb_sel ),
        .i_d_wb_dat(d_wb_dat ),
        .i_d_wb_adr(d_wb_adr ),
        .i_d_wb_cti(d_wb_cti ),
        .i_d_wb_bte(d_wb_bte ),
        .o_d_wb_ack(d_wb_ack ),
        .o_d_wb_err(d_wb_err ),

        .o_wb_cyc  (wb_cyc   ),
        .o_wb_stb  (wb_stb   ),
        .o_wb_wen  (wb_we    ),
        .o_wb_sel  (wb_sel   ),
        .o_wb_dat  (wb_idat  ),
        .o_wb_adr  (wb_adr   ),
        .o_wb_cti  (wb_cti   ),
        .o_wb_bte  (o_wb_bte ),
        .i_wb_ack  (wb_ack   ),
        .i_wb_err  (wb_err   )

        );
end : l_merger_for_core_with_cache_mmu
else // if ( ONLY_CORE )
begin : l_merger_for_core_without_cache_mmu
        zap_wb_merger #(.ONLY_CORE(1'd1)) u_zap_wb_merger (

        .i_clk(i_clk),
        .i_reset(s_reset),

        .i_c_wb_stb(cpu_instr_stb),
        .i_c_wb_cyc(cpu_instr_stb),
        .i_c_wb_wen(1'h0),
        .i_c_wb_sel(4'hF),
        .i_c_wb_dat(32'd0),
        .i_c_wb_adr(cpu_iaddr),
        .i_c_wb_cti(3'b111),
        .o_c_wb_ack(instr_ack),
        .o_c_wb_err(instr_err),

        .i_d_wb_stb(cpu_dc_stb),
        .i_d_wb_cyc(cpu_dc_stb),
        .i_d_wb_wen(cpu_dc_we),

        // Swap sel from CPU if BE_32_ENABLE = 1.
        .i_d_wb_sel(BE_32_ENABLE ? be_sel_32(cpu_dc_sel) : cpu_dc_sel),

        .i_d_wb_dat(cpu_dc_dat),
        .i_d_wb_adr(cpu_daddr),
        .i_d_wb_cti(3'b111),
        .i_d_wb_bte(2'b00),
        .o_d_wb_ack(data_ack),
        .o_d_wb_err(data_err),

        .o_wb_cyc  (o_wb_cyc ),
        .o_wb_stb  (o_wb_stb ),
        .o_wb_wen  (o_wb_we  ),
        .o_wb_sel  (o_wb_sel ),
        .o_wb_dat  (o_wb_dat ),
        .o_wb_adr  (o_wb_adr ),
        .o_wb_cti  (o_wb_cti ),
        .o_wb_bte  (o_wb_bte ),
        .i_wb_ack  (i_wb_ack ),
        .i_wb_err  (i_wb_err )

        );
end : l_merger_for_core_without_cache_mmu


///////////////////////////////////////////////////////////////////////////////
// Put cache and MMU only if ONLY_CORE == 0
///////////////////////////////////////////////////////////////////////////////

if ( !ONLY_CORE )
begin: l_generate_with_cache_mmu

zap_dcache #(
        .CACHE_SIZE(DATA_CACHE_SIZE),
        .SPAGE_TLB_ENTRIES(DATA_SPAGE_TLB_ENTRIES),
        .LPAGE_TLB_ENTRIES(DATA_LPAGE_TLB_ENTRIES),
        .SECTION_TLB_ENTRIES(DATA_SECTION_TLB_ENTRIES),
        .FPAGE_TLB_ENTRIES(DATA_FPAGE_TLB_ENTRIES),
        .CACHE_LINE(DATA_CACHE_LINE), // ARM925T: upstream passed CODE_CACHE_LINE.
        .WAYS(DATA_CACHE_WAYS),
        .SHORT_READ(CORE == "ARM9"),
        .BE_32_ENABLE(BE_32_ENABLE),
        .EXT_ABORT_FS(TI925T ? 4'b1000 : 4'b0010)
)
u_data_cache (
.o_dbg_dcache           (o_dbg_dcache),
.i_clk                  (i_clk),
.i_stall                (arm9_data_stall),
.o_fill_busy            (data_fill_busy),
.i_reset                (s_reset),
.i_address              (cpu_daddr      ),
.i_address_nxt          (cpu_daddr_nxt  ),
.i_address_check        (cpu_daddr_check),
.i_wr_check             (cpu_dwe_check),
.i_rd_check             (cpu_dre_check),
.i_rd                   (!cpu_dc_we && cpu_dc_stb),
.i_wr                   ( cpu_dc_we && cpu_dc_stb),
.i_ben                  (cpu_dc_sel),
.i_dat                  (cpu_dc_dat),
.i_align_fault          (cpu_align_fault),
.i_va                   (cpu_daddr_va),
.i_ldfmt                (cpu_dldfmt),
.i_ldfmt_check          (cpu_dldfmt_check),
.i_line_req             (cpu_dline_req),
.i_line_op              (cpu_dline_op),
.i_line_va              (cpu_dline_va),
.i_line_addr            (cpu_dline_addr),
.i_line_way             (cpu_dline_way),
.o_line_done            (dc_line_done),
.i_reg_idx              (dc_rreg_idx),
.i_reg_idx_bin          (dc_rreg_idx_bin),

.o_short_data(dc_short_data),.o_short_hit(dc_short_hit),
.o_dat                  (dc_data),
.o_ack                  (data_ack),
.o_writeback_busy       (dc_writeback_busy),
.o_err                  (data_err),
.o_lock                 (dc_lock),
.i_lock_owner_next      (dc_lock_owner_next),
.o_lock_any             (dc_lock_any),
.o_lock_owner           (dc_lock_owner),
.o_reg_dat              (dc_reg_data),
.o_reg_idx              (dc_wreg_idx),
.o_fsr                  (dc_fsr),
.o_far                  (dc_far),
.o_cache_inv_done       (dc_inv_done),
.o_cache_clean_done     (dc_clean_done),

.i_mmu_en               (cpu_mmu_en),
.i_cache_en             (cpu_dc_en),
.i_cache_inv_req        (cpu_dc_inv),
.i_cache_clean_req      (cpu_dc_clean),
.i_cpsr                 (cpu_mem_translate ? USR : cpu_mem_cpsr),
.i_sr                   (cpu_sr),
.i_baddr                (cpu_baddr),
.i_dac_reg              (cpu_dac_reg),
.i_tlb_inv              (cpu_dtlb_inv),

.o_err2                 (dcache_err2),

/* verilator lint_off PINCONNECTEMPTY */
.o_wb_stb               (),
.o_wb_cyc               (),
.o_wb_wen               (),
.o_wb_sel               (),
.o_wb_dat               (),
.o_wb_adr               (),
.o_wb_cti               (),
.o_wb_bte               (),
/* verilator lint_on PINCONNECTEMPTY */

.i_wb_dat               (wb_dat),
.i_wb_ack               (d_wb_ack),
.i_wb_err               (d_wb_err),

.o_wb_stb_nxt           (d_wb_stb),
.o_wb_cyc_nxt           (d_wb_cyc),
.o_wb_wen_nxt           (d_wb_wen),
.o_wb_sel_nxt           (d_wb_sel),
.o_wb_dat_nxt           (d_wb_dat),
.o_wb_adr_nxt           (d_wb_adr),
.o_wb_bte_nxt           (d_wb_bte),
.o_wb_cti_nxt           (d_wb_cti)
);

zap_cache #(
.CACHE_SIZE(CODE_CACHE_SIZE),
.SPAGE_TLB_ENTRIES(CODE_SPAGE_TLB_ENTRIES),
.LPAGE_TLB_ENTRIES(CODE_LPAGE_TLB_ENTRIES),
.SECTION_TLB_ENTRIES(CODE_SECTION_TLB_ENTRIES),
.FPAGE_TLB_ENTRIES(CODE_FPAGE_TLB_ENTRIES),
.CACHE_LINE(CODE_CACHE_LINE), // ARM925T: upstream passed DATA_CACHE_LINE.
.WAYS(CODE_CACHE_WAYS),
.SHORT_READ(CORE == "ARM9"),
.PREFETCH(CODE_CACHE_PREFETCH)
)
u_code_cache (
.i_clk              (i_clk),
.i_stall            (code_stall),
.i_reset            (s_reset),

.i_address          ((cpu_iaddr     & 32'hFFFF_FFFC)  ), // Cut off lower 2 bits.
.i_address_nxt      ((cpu_iaddr_nxt & 32'hFFFF_FFFC)  ), // Cut off lower 2 bits.
.i_address_check    ((cpu_iaddr_check & 32'hFFFF_FFFC)),

.i_wr_check         (1'd0),
.i_rd_check         (1'd1),

.i_rd              (cpu_instr_stb),
.i_wr              (1'd0),
.i_ben             (4'b1111),
.i_dat             (32'd0),
.o_dat             (ic_data),
.o_data_early      (ic_data_early),
.o_hit             (ic_hit),
.o_ack             (instr_ack),
.o_err             (instr_err),

/* verilator lint_off PINCONNECTEMPTY */
.o_fsr             (),
.o_far             (),
/* verilator lint_on PINCONNECTEMPTY */

.i_mmu_en          (cpu_mmu_en),
.i_cache_en        (cpu_ic_en),
.i_cache_inv_req   (cpu_ic_inv),
.i_cache_clean_req (cpu_ic_clean),
.o_cache_inv_done  (ic_inv_done),
.o_cache_clean_done(ic_clean_done),
// ARM925T: fetches are checked in the current mode. Upstream also applied
// the data side's LDRT/STRT "user view" flag, which is undefined ('x)
// whenever that pipeline stage is empty, so fetches from privileged-only
// pages could abort at random.
.i_cpsr            (cpu_cpsr[ZAP_CPSR_MODE:0]),
.i_sr              (cpu_sr),
.i_baddr           (cpu_baddr),
.i_dac_reg         (cpu_dac_reg),
.i_tlb_inv         (cpu_itlb_inv),
.i_wb_busy         (d_wb_cyc || d_wb_ack || (|dc_lock) || cpu_dc_clean || cpu_dc_inv || cpu_dline_req),
.i_pf_inv          (cpu_dc_clean || cpu_dc_inv || cpu_dline_req),
.o_err2            (icache_err2),
.o_fill_pending    (icache_fill_pending),
.o_fill_done       (icache_fill_done),
.o_fill_fault      (icache_fill_fault),

/* verilator lint_off PINCONNECTEMPTY */
.o_wb_stb       (),
.o_wb_cyc       (),
.o_wb_wen       (),
.o_wb_sel       (),
.o_wb_dat       (),
.o_wb_adr       (),
.o_wb_cti       (),
/* verilator lint_on PINCONNECTEMPTY */

.i_wb_dat       (wb_dat),
.i_wb_ack       (c_wb_ack),
.i_wb_err       (c_wb_err),

.o_wb_stb_nxt   (c_wb_stb),
.o_wb_cyc_nxt   (c_wb_cyc),
.o_wb_wen_nxt   (c_wb_wen),
.o_wb_sel_nxt   (c_wb_sel),
.o_wb_dat_nxt   (c_wb_dat),
.o_wb_adr_nxt   (c_wb_adr),
.o_wb_cti_nxt   (c_wb_cti)
);

assign o_wb_cyc = wb_cyc;
assign o_wb_stb = wb_stb;
assign o_wb_we  = wb_we;
assign o_wb_sel = wb_sel;
assign o_wb_dat = wb_idat;
assign o_wb_adr = wb_adr;
assign o_wb_cti = wb_cti;
assign wb_dat   = i_wb_dat;
assign wb_ack   = i_wb_ack;
assign wb_err   = i_wb_err;

end : l_generate_with_cache_mmu

endmodule // zap_top.v

///////////////////////////////////////////////////////////////////////////////
// EOF
///////////////////////////////////////////////////////////////////////////////
