// SPDX-License-Identifier: GPL-3.0-or-later
//
// The N-Gage QD's processor: a TI ARM925T (ARMv4T ARM9TDMI integer core,
// CP15 with the TI extensions, MMU, 16 KB I-cache, 8 KB D-cache) as found in
// Nokia's UPP_WD2 ASIC. Built from the ZAP core (rtl/cpu/zap, GPL-3.0-or-
// later, see rtl/cpu/zap/NOTICE) with ARMv4T and ARM925T behaviour switched
// on through its parameters. docs/CPU.md describes the design, the deviations
// from a real ARM925T and the tests.
//
// Quartus compiles rtl/cpu/arm925t_gen.v, which tools/gen_cpu.sh makes from
// this file and rtl/cpu/zap with sv2v.
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
//     and fetches can prefetch-abort. Cacheable D-cache fills retain ZAP's
//     existing behavior: consume the returned data without a data abort.
//   * The bus outputs come straight from flip-flops in ZAP's bus merger.
// Interrupts are level-sensitive and active high (the inverse of the
// ARM925T's nIRQ/nFIQ); they pass a two-flop synchroniser inside ZAP.
// reset is synchronous and active high; drive it from a flip-flop.
module arm925t #(
	// Reset value of control register bit V (the ARM925T's HIVECS pin):
	// 1 puts the exception vectors, and the reset address, at 0xFFFF0000.
	parameter bit          HIVECS      = 1'b0,
	// Cache geometry: the ARM925T's 16 KB I / 8 KB D, 2-way with LRU
	// replacement, 16-byte lines (docs/CPU.md). ICACHE_SIZE may also be
	// set to 32768 (32 KB, 1,024 sets); ICACHE_PREFETCH enables the
	// one-line sequential next-line prefetch (off: the phone has none and
	// the games measured no gain from it; the logic is cycle-identical off).
	parameter int          ICACHE_SIZE     = 16384,
	parameter int          ICACHE_WAYS     = 2,
	parameter bit          ICACHE_PREFETCH = 1'b0,
	// A 16 KB two-way experiment retains the 8 KB CP15 identity; its
	// by-index maintenance visits both physical set colours (docs/CPU.md).
	parameter int          DCACHE_SIZE     = 8192,
	parameter int          DCACHE_WAYS     = 2,
	parameter int          CACHE_LINE      = 16
) (
	input  logic        clk,
	input  logic        reset,

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

	localparam logic [31:0] RESET_VECTOR = HIVECS ? 32'hFFFF0000 : 32'h00000000;

	logic       wb_cyc, wb_stb;
	logic [2:0] wb_cti;

	zap_top #(
		.V4T             (1'b1),
		.TI925T          (1'b1),
		.CP15_ID         (32'h54029252),
		.CP15_CTYPE      (32'h05109149),
		.HIVECS          (HIVECS),
		.RESET_VECTOR    (RESET_VECTOR),
		.CODE_CACHE_SIZE     (32'(ICACHE_SIZE)),
		.CODE_CACHE_LINE     (32'(CACHE_LINE)),
		.CODE_CACHE_WAYS     (32'(ICACHE_WAYS)),
		.CODE_CACHE_PREFETCH (ICACHE_PREFETCH),
		.DATA_CACHE_SIZE     (32'(DCACHE_SIZE)),
		.DATA_CACHE_LINE     (32'(CACHE_LINE)),
		.DATA_CACHE_WAYS     (32'(DCACHE_WAYS))
	) u_zap (
		.i_clk    (clk),
		.i_reset  (reset),
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
