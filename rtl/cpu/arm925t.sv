// SPDX-License-Identifier: GPL-3.0-or-later
//
// The N-Gage QD's processor: a TI ARM925T (ARMv4T ARM9TDMI integer core,
// CP15 with the TI extensions, MMU, 16 KB I-cache, 8 KB D-cache) as found in
// Nokia's UPP_WD2 ASIC. This project's own CPU: an eight-stage pipeline
// (arm925t_core and the stage files beside it) with caches, MMU, CP15,
// register file and writeback that are derived from the ZAP processor
// (Revanth Kamaraj, GPL-3.0-or-later; rtl/cpu/NOTICE says which files).
// Every module is arm925t_*; this file is the top and holds the core's
// configuration (the two cache sizes are its only parameters). docs/CPU.md describes the design, the deviations from a
// real ARM925T and the tests.
//
// Quartus compiles rtl/cpu/arm925t_gen.v, which tools/gen_cpu.sh makes from
// this file and rtl/cpu/arm925t_*.sv with sv2v.
//
// Memory bus (one master, req/ack, as elsewhere in this core):
//   * A request is held, unchanged, until the cycle in which bus_ack (or
//     bus_err) is high; that cycle completes it and carries the read data.
//     The next request can start in the following cycle, so a responder must
//     not take bus_req in its ack cycle as a new request.
//   * bus_addr is a byte address with bits 1:0 zero; bus_be selects the bytes
//     (bus_be[0] = bits 7:0). Reads always return the whole word.
//   * bus_burst = 1: this beat is part of a cache-line burst and another beat
//     follows in bus_bte order (00: linear, 01: wrap four words). D-cache
//     16-byte fills start at the requested word; other fills and write-backs
//     start at word zero. bus_burst is high on all but the last beat.
//     Everything else (uncached data, MMU table walks, cache-off fetches)
//     is a single beat with bus_burst = 0.
//   * bus_err completes the beat. Uncached data/table walks can data-abort
//     and fetches can prefetch-abort. Cacheable D-cache fills consume the
//     returned data without a data abort.
//   * The bus outputs come straight from flip-flops in arm925t_wb_merger.
// Interrupts are level-sensitive and active high (the inverse of the
// ARM925T's nIRQ/nFIQ); they pass a two-flop synchroniser (arm925t_sync2).
// reset is synchronous and active high; drive it from a flip-flop.
module arm925t #(
	// The caches as built, in bytes: 32 KB each. With real_caches they are
	// the ARM925T's and the phone's, 16 KB for instructions (512 sets)
	// and 8 KB for data (256 sets, VA[11:4]): the same two ways and
	// 16-byte lines, with the set index cut to the smaller cache's
	// (rtl/cpu/arm925t_cache_tag_ram.sv). The core's menu chooses
	// (NGage.sv, "CPU caches"); the phone's sizes are its default. CP15's
	// cache type register reports the phone's sizes in either setting.
	// The releases up to NGage_20261114 had 32 KB each and nothing else,
	// those from 2026-11-16 the phone's sizes and nothing else
	// (docs/PROGRESS-LOG.md, 2026-11-16 and 2026-11-27). A size at or
	// under the phone's builds that cache alone: real_caches then does
	// nothing to it.
	parameter int ICACHE_SIZE = 32768,
	parameter int DCACHE_SIZE = 32768
) (
	input  logic        clk,
	input  logic        reset,
	// the caches are the phone's sizes; it may change only while reset is high
	input  logic        real_caches,

	input  logic        irq,
	input  logic        fiq,

	output logic        bus_req,
	output logic        bus_we,
	output logic [31:0] bus_addr,
	output logic [3:0]  bus_be,
	output logic [31:0] bus_wdata,
	output logic        bus_burst,
	output logic [1:0]  bus_bte,
	input  logic [31:0] bus_rdata,
	input  logic        bus_ack,
	input  logic        bus_err,
	// With the first ACK of a wrap-4 fill: the target guarantees no later
	// beat can ERR. Tie low for buses without this guarantee.
	input  logic        bus_no_late_error,
	output logic [31:0] dbg_pc,      // committed PC (debug overlay)

	// Debug trace taps (rtl/mister/dbg_trace.sv): the writeback stage as
	// sim/harness/coreboot_main.cpp watches it, and the data port's
	// completed accesses (dbg_d_done: the data cache answered one).
	output logic        dbg_wb_valid,
	output logic        dbg_wfi,
	output logic        dbg_wb_dvalid,
	output logic        dbg_wb_uop_last,
	output logic [1:0]  dbg_wb_dabt,
	output logic        dbg_wb_pabt,
	output logic        dbg_wb_und,
	output logic        dbg_wb_swi,
	output logic        dbg_wb_irq,
	output logic        dbg_wb_fiq,
	output logic [31:0] dbg_wb_pc,       // the stage's PC: address + 8 (+ 4 in Thumb)
	output logic [31:0] dbg_wb_cpsr,     // before the instruction
	output logic [31:0] dbg_wb_cpsr_nxt, // after it
	output logic [7:0]  dbg_stall,       // stall and flush taps (dbg_counters)
	// One-clock events for dbg_counters' per-second accumulation:
	// [0] load-miss fill, [1] store-miss fill, [2] line write-back
	// (eviction or maintenance), [3] uncached data access (excludes WT).
	output logic [3:0]  dbg_dcache,
	// [0] FIFO full, [1] fetch no ACK, [2] demand fill completed,
	// [3] fetch no ACK and FIFO not full, [4] fill waits behind DATA,
	// [5] fill selected on external bus (qualify with arbiter grant),
	// [6] I-TLB beat, [7] D-TLB beat. See NGage.sv DBG_CNT layout.
	output logic [7:0]  dbg_icache,
	output logic        dbg_d_done,
	output logic        dbg_d_we,
	output logic [31:0] dbg_d_va,
	output logic [3:0]  dbg_d_sel,
	output logic [31:0] dbg_d_wdata,
	output logic [31:0] dbg_d_rdata
);

	// Apart from the two cache sizes above, the configuration is the
	// core's one configuration: constants, not parameters, so that no
	// build and no test runs with another.
	// Cache geometry: 2-way with LRU replacement, 16-byte lines
	// (docs/CPU.md); the sizes are below.
	localparam int ICACHE_WAYS = 2;
	localparam int DCACHE_WAYS = 2;
	localparam int CACHE_LINE  = 16;
	// The phone's sizes (TI SPRU671; CP15_CTYPE below says the same).
	localparam int ICACHE_REAL = 16384;
	localparam int DCACHE_REAL = 8192;
	// The small-page TLBs: two ways of 256 entries each, indexed by the
	// page number's low bits. The ARM925T's TLBs are 64-entry and fully
	// associative; with one way, two pages 1 MB apart (the same offset in
	// two EKA1 chunks) evict each other at every access
	// (rtl/cpu/arm925t_tlb.sv).
	localparam int DTLB_SPAGE_WAYS = 2;
	localparam int DTLB_SPAGE_SETS = 256;
	localparam int ITLB_SPAGE_WAYS = 2;
	localparam int ITLB_SPAGE_SETS = 256;
	// The other three TLB buffers of either side, one way each: 64
	// sections, 32 large pages, 64 tiny pages.
	localparam int TLB_SECTION_ENTRIES = 64;
	localparam int TLB_LPAGE_ENTRIES   = 32;
	localparam int TLB_FPAGE_ENTRIES   = 64;

	// Control register bit V is 0 at reset (the ARM925T's HIVECS pin, low in
	// the phone): the vectors and the reset address are at 0.
	localparam logic [31:0] RESET_VECTOR = 32'h00000000;

	logic       wb_cyc, wb_stb;
	logic [2:0] wb_cti;

	arm925t_top #(
		.CP15_ID         (32'h54029252),
		.CP15_CTYPE      (32'h05109149),
		.RESET_VECTOR    (RESET_VECTOR),
		.CODE_CACHE_SIZE     (32'(ICACHE_SIZE)),
		.CODE_CACHE_SMALL    (32'(ICACHE_SIZE > ICACHE_REAL ? ICACHE_REAL : ICACHE_SIZE)),
		.CODE_CACHE_LINE     (32'(CACHE_LINE)),
		.CODE_CACHE_WAYS     (32'(ICACHE_WAYS)),
		.DATA_CACHE_SIZE     (32'(DCACHE_SIZE)),
		.DATA_CACHE_SMALL    (32'(DCACHE_SIZE > DCACHE_REAL ? DCACHE_REAL : DCACHE_SIZE)),
		.DATA_CACHE_LINE     (32'(CACHE_LINE)),
		.DATA_CACHE_WAYS     (32'(DCACHE_WAYS)),
		.DATA_SPAGE_TLB_ENTRIES (32'(DTLB_SPAGE_SETS)),
		.DATA_SPAGE_TLB_WAYS    (32'(DTLB_SPAGE_WAYS)),
		.CODE_SPAGE_TLB_ENTRIES (32'(ITLB_SPAGE_SETS)),
		.CODE_SPAGE_TLB_WAYS    (32'(ITLB_SPAGE_WAYS)),
		.DATA_SECTION_TLB_ENTRIES (32'(TLB_SECTION_ENTRIES)),
		.DATA_LPAGE_TLB_ENTRIES   (32'(TLB_LPAGE_ENTRIES)),
		.DATA_FPAGE_TLB_ENTRIES   (32'(TLB_FPAGE_ENTRIES)),
		.CODE_SECTION_TLB_ENTRIES (32'(TLB_SECTION_ENTRIES)),
		.CODE_LPAGE_TLB_ENTRIES   (32'(TLB_LPAGE_ENTRIES)),
		.CODE_FPAGE_TLB_ENTRIES   (32'(TLB_FPAGE_ENTRIES))
	) u_top (
		.i_clk    (clk),
		.i_reset  (reset),
		.i_small_caches (real_caches),
		.i_irq    (irq),
		.i_fiq    (fiq),
		.o_dbg_pc(dbg_pc),
		.o_dbg_wb_valid    (dbg_wb_valid),
		.o_dbg_wfi         (dbg_wfi),
		.o_dbg_wb_dvalid   (dbg_wb_dvalid),
		.o_dbg_wb_uop_last (dbg_wb_uop_last),
		.o_dbg_wb_dabt     (dbg_wb_dabt),
		.o_dbg_wb_pabt     (dbg_wb_pabt),
		.o_dbg_wb_und      (dbg_wb_und),
		.o_dbg_wb_swi      (dbg_wb_swi),
		.o_dbg_wb_irq      (dbg_wb_irq),
		.o_dbg_wb_fiq      (dbg_wb_fiq),
		.o_dbg_wb_pc       (dbg_wb_pc),
		.o_dbg_wb_cpsr     (dbg_wb_cpsr),
		.o_dbg_wb_cpsr_nxt (dbg_wb_cpsr_nxt),
		.o_dbg_stall       (dbg_stall),
		.o_dbg_dcache      (dbg_dcache),
		.o_dbg_icache       (dbg_icache),
		.o_dbg_d_done      (dbg_d_done),
		.o_dbg_d_we        (dbg_d_we),
		.o_dbg_d_va        (dbg_d_va),
		.o_dbg_d_sel       (dbg_d_sel),
		.o_dbg_d_wdata     (dbg_d_wdata),
		.o_dbg_d_rdata     (dbg_d_rdata),
		.o_wb_cyc (wb_cyc),
		.o_wb_stb (wb_stb),
		.o_wb_adr (bus_addr),
		.o_wb_we  (bus_we),
		.o_wb_dat (bus_wdata),
		.o_wb_sel (bus_be),
		.o_wb_cti (wb_cti),
		.o_wb_bte (bus_bte),
		.i_wb_ack (bus_ack),
		.i_wb_dat (bus_rdata),
		.i_wb_err (bus_err),
		.i_wb_no_late_error (bus_no_late_error)
	);

	assign bus_req   = wb_cyc & wb_stb;
	assign bus_burst = wb_cti == 3'b010;

endmodule
