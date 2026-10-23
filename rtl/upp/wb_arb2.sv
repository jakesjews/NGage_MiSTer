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
//
// m2 (the memory self-test, rtl/upp/wb_selftest.sv) takes m0's place while
// m2_on is high: m2_on is a register outside (the core's self-test select,
// which changes only at the start of a reset pulse) and m2_on_nxt its D
// input. The slave's signals are then one AND-OR of the three masters with
// registered one-hot selects formed from the grant's and m2_on's next
// values: the same signals as "gnt ? m1 : m2_on ? m2 : m0", one level of
// logic from the masters' registers instead of two multiplexers (timing).
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

	input  logic        m1_cyc,
	input  logic        m1_stb,
	input  logic        m1_we,
	input  logic [31:0] m1_adr,
	input  logic [31:0] m1_dat,
	input  logic [3:0]  m1_sel,
	output logic        m1_ack,
	output logic        m1_err,

	input  logic        m2_on,
	input  logic        m2_on_nxt,
	input  logic        m2_cyc,
	input  logic        m2_stb,
	input  logic        m2_we,
	input  logic [31:0] m2_adr,
	input  logic [31:0] m2_dat,
	input  logic [3:0]  m2_sel,
	input  logic [2:0]  m2_cti,
	input  logic [1:0]  m2_bte,

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
	// one-hot selects {m2, m1, m0}: gnt ? m1 : m2_on ? m2 : m0. One copy
	// for the address and data multiplexers (the grant reaches far into
	// upp_bus through them; timing), one for the controls, kept apart
	(* preserve *) logic [2:0] sel_ad = 3'b001;
	(* preserve *) logic [2:0] sel_ct = 3'b001;

	assign s_cyc = (sel_ct[0] && m0_cyc) || (sel_ct[1] && m1_cyc) || (sel_ct[2] && m2_cyc);
	assign s_stb = (sel_ct[0] && m0_stb) || (sel_ct[1] && m1_stb) || (sel_ct[2] && m2_stb);
	assign s_we  = (sel_ad[0] && m0_we)  || (sel_ad[1] && m1_we)  || (sel_ad[2] && m2_we);
	assign s_adr = ({32{sel_ad[0]}} & m0_adr) | ({32{sel_ad[1]}} & m1_adr) | ({32{sel_ad[2]}} & m2_adr);
	assign s_dat = ({32{sel_ad[0]}} & m0_dat) | ({32{sel_ad[1]}} & m1_dat) | ({32{sel_ad[2]}} & m2_dat);
	assign s_sel = ({4{sel_ad[0]}} & m0_sel)  | ({4{sel_ad[1]}} & m1_sel)  | ({4{sel_ad[2]}} & m2_sel);
	assign s_cti = ({3{sel_ct[0]}} & m0_cti)  | {3{sel_ct[1]}}             | ({3{sel_ct[2]}} & m2_cti);
	assign s_bte = ({2{sel_ct[0]}} & m0_bte)  | ({2{sel_ct[2]}} & m2_bte);

	assign m0_ack = s_ack && !gnt;
	assign m0_err = s_err && !gnt;
	assign m1_ack = s_ack && gnt;
	assign m1_err = s_err && gnt;

	wire other   = gnt ? (m2_on ? m2_cyc : m0_cyc) : m1_cyc;
	wire txn_end = (s_ack || s_err) && s_cti != 3'b010;
	wire swap    = other && (txn_end || (!s_cyc && s_idle));
	wire gnt_nxt = reset ? 1'b0 : (swap ? !gnt : gnt);
	wire [2:0] sel_nxt = {!gnt_nxt && m2_on_nxt, gnt_nxt, !gnt_nxt && !m2_on_nxt};

	always_ff @(posedge clk) begin
		gnt    <= gnt_nxt;
		sel_ad <= sel_nxt;
		sel_ct <= sel_nxt;
	end

	// simulation: upp_bus is idle in the clock after every change of grant,
	// and the selects follow the grant and m2_on
	// synthesis translate_off
	logic swapped = 1'b0;
	always_ff @(posedge clk) begin
		if (swapped && !s_idle && !reset) $error("wb_arb2: the grant changed while upp_bus was busy");
		swapped <= swap && !reset;
		if (sel_ad != {!gnt && m2_on, gnt, !gnt && !m2_on} || sel_ct != sel_ad)
			$error("wb_arb2: the selects do not follow the grant and m2_on");
	end
	// synthesis translate_on

endmodule
