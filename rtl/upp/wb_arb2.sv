// SPDX-License-Identifier: GPL-2.0-or-later
//
// Two Wishbone B3 masters onto upp_bus: the CPU (m0, classic cycles and
// CTI/BTE bursts) and the DMA controller (m1, classic single beats). The
// grant is a register, so the slave sees the granted master's signals through
// one multiplexer and nothing else; it changes only between transactions:
//   * at the clock edge where the slave answers the last beat of the owner's
//     transaction (a beat with CTI other than 010), if the other master is
//     asking: the owner may hold CYC for its next transaction, so this is where
//     the other gets its turn. upp_bus is back in its idle state in the
//     following clock (after the last beat of a transaction it always is).
//   * at any edge where the owner has CYC low, the bus is idle and the other
//     is asking.
// So with both asking the masters take turns transaction by transaction; a
// master that is not granted waits with its request up.
module wb_arb2 (
	input  logic        clk,
	input  logic        reset,

	input  logic        m0_cyc,
	input  logic        m0_stb,
	input  logic        m0_we,
	input  logic [31:0] m0_adr,
	input  logic [31:0] m0_dat,
	input  logic [3:0]  m0_sel,
	input  logic [2:0]  m0_cti,
	input  logic [1:0]  m0_bte,
	output logic        m0_ack,
	output logic        m0_err,
	output logic        dbg_m1_owner, // observation of registered grant

	input  logic        m1_cyc,
	input  logic        m1_stb,
	input  logic        m1_we,
	input  logic [31:0] m1_adr,
	input  logic [31:0] m1_dat,
	input  logic [3:0]  m1_sel,
	output logic        m1_ack,
	output logic        m1_err,

	output logic        s_cyc,
	output logic        s_stb,
	output logic        s_we,
	output logic [31:0] s_adr,
	output logic [31:0] s_dat,
	output logic [3:0]  s_sel,
	output logic [2:0]  s_cti,
	output logic [1:0]  s_bte,
	input  logic        s_ack,
	input  logic        s_err,
	input  logic        s_idle
);

	logic gnt = 1'b0;                  // 1: m1
	// a copy for the address and data multiplexers (the grant reaches far
	// into upp_bus through them; timing), kept apart from gnt
	(* preserve *) logic gnt_ad = 1'b0;

	assign dbg_m1_owner = gnt;
	assign s_cyc = gnt ? m1_cyc : m0_cyc;
	assign s_stb = gnt ? m1_stb : m0_stb;
	assign s_we  = gnt_ad ? m1_we  : m0_we;
	assign s_adr = gnt_ad ? m1_adr : m0_adr;
	assign s_dat = gnt_ad ? m1_dat : m0_dat;
	assign s_sel = gnt_ad ? m1_sel : m0_sel;
	assign s_cti = gnt ? 3'b111 : m0_cti;
	assign s_bte = gnt ? 2'b00  : m0_bte;

	assign m0_ack = s_ack && !gnt;
	assign m0_err = s_err && !gnt;
	assign m1_ack = s_ack && gnt;
	assign m1_err = s_err && gnt;

	wire other   = gnt ? m0_cyc : m1_cyc;
	wire txn_end = (s_ack || s_err) && s_cti != 3'b010;
	wire swap    = other && (txn_end || (!s_cyc && s_idle));

	always_ff @(posedge clk) begin
		if (swap) begin
			gnt    <= !gnt;
			gnt_ad <= !gnt;
		end
		if (reset) begin
			gnt    <= 1'b0;
			gnt_ad <= 1'b0;
		end
	end

	// simulation: upp_bus is idle in the clock after every change of grant
	// synthesis translate_off
	logic swapped = 1'b0;
	always_ff @(posedge clk) begin
		if (swapped && !s_idle && !reset) $error("wb_arb2: the grant changed while upp_bus was busy");
		swapped <= swap && !reset;
	end
	// synthesis translate_on

endmodule
