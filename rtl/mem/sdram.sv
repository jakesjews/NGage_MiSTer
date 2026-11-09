// SPDX-License-Identifier: GPL-3.0-or-later
//
// SDRAM controller for the MiSTer SDRAM module (16-bit, 32 MB or larger:
// AS4C16M16SA, AS4C32M16SB, IS42S16320, W9825G6KH class). It holds the
// N-Gage's 16 MB SDRAM in the first 16 MB; the rest is spare.
//
// Derived from Sorgelig's MiSTer SDRAM controller (sdram.sv, Copyright (c)
// 2015-2019 Sorgelig, GPL-3.0-or-later; copies in
// ../direct-video/PMD85/rtl/sdram.sv and GBA_MiSTer, which credit the
// hamsterworks "Simple SDRAM Controller"): the command encoding, the mode
// register, the power-up sequence, SDRAM_CLK as the inverted clock from a
// DDIO output, DQM carried on A12:A11 during READ and WRITE, and the read
// capture one clock after the CAS latency. The request port, the 16-byte
// line transfers and the timing schedule are new.
//
// Clocking. Everything runs on clk (clk_sys, 104 MHz: 2 x 52 MHz). The chip
// gets ~clk from a DDIO output, so it samples a command half a clock (4.8 ns)
// after the FPGA's output registers launch it; both leave through the same
// kind of I/O register, so setup and hold are each about T/2. Read data is
// captured in the DQ input register CAS_LATENCY + CAPTURE_CLKS clocks after
// the READ edge. With the clock-out delay and the input delay (together
// D = 4.5-7 ns), tAC <= 6 ns and tOH >= 2.5 ns, the window of the element is
// [1.5T + tAC + D, 2.5T + tOH + D] after the READ edge, 27.4-31.0 ns at
// 104 MHz worst case, and the capture edge at 3T = 28.8 ns sits inside it
// with about 1.4 ns either side. Command, address, DQM and DQ registers sit in
// the I/O cells (sys/sys.tcl sets FAST_*_REGISTER for SDRAM_*). They copy a
// stage of internal registers (p_*), where the schedule's decisions land,
// so that the I/O registers at the chip's edge need no logic before them
// (timing); everything reaches the pins a clock later, and the capture
// clock (CAP) counts that clock too.
//
// Policy: open page, one row per bank. A hit issues READ/WRITE immediately;
// a closed bank needs ACTIVE and tRCD; a conflict precharges only that bank,
// waits tRP and the previous ACTIVE's tRC, then opens the new row. Per-bank
// saturating ages enforce tRAS even across multiple accesses. The mapping
// uses 1 KB rows with bank bits at byte address 13:12 (4 KB interleaving). No reordering or
// overlapping accesses. All four rows close for each refresh.
//
// Mode: burst length 8 (sequential) for reads, single-location writes. A
// line read wraps inside the 8-halfword block, requested word first. Word
// reads issue BURST TERMINATE two clocks after READ, leaving two halfwords
// with the same capture schedule. Writes issue one WRITE per halfword with
// its DQM (two for a word, eight for a line). Reads finish after capture;
// writes finish tWR after the last WRITE. This leaves the shared data bus
// free for either direction, with DQM low before any read data arrives.
//
// Schedule at the defaults (tRCD, tRP 20 ns, tRAS 45 ns, tRC, tRFC 70 ns,
// tWR 15 ns, rounded up at 104 MHz to 3, 3, 5, 8, 8 and 2 clocks):
//                    column command     words at port     next request
//   word read hit:    READ 0, STOP 2      5                 6
//   line read hit:    READ 0              5, 7, 9, 11      12
//   word write hit:   WRITE 0-1                            3
//   line write hit:   WRITE 0-7                            9
// A closed bank adds ACTIVE at 0 and 3 clocks to these numbers; a conflict
// adds PRECHARGE at 0, ACTIVE at 3 and 6 clocks (plus any outstanding tRAS
// or tRC wait). Commands reach the pins one clock after the listed edge,
// through the unchanged output stage. Capture includes that extra clock.
//
// Refresh: after REFRESH_CLKS (755 by default), block new requests, finish
// the current access and tRAS, PRECHARGE ALL, wait tRP, AUTO REFRESH, wait
// tRFC. The timer resets on AUTO REFRESH. Its interval reserves the worst
// access (conservatively 23 clocks), close wait (8), due-flag latency (2),
// tRFC (8) and REFRESH_SLACK (16): even that bound is 788 clocks (7.58 us)
// between refreshes, below tREFI (8192 rows in 64 ms = 7.81 us). Normally
// closing and refreshing takes 3 + 8 = 11 clocks. Power-up: POWERUP_US of
// NOPs, PRECHARGE ALL, INIT_REFRESHES refreshes, mode register, then tMRD.
//
// Port (one clock domain with the requester):
//   A request is taken at an edge where req is high and busy is low; addr,
//   we, line, wdata and wbe must be valid then and are latched. A read
//   returns its words on rvalid/rword/rdata, one every other clock, in the
//   chip's order (from addr's word, wrapping in the 16-byte block); rdata
//   is driven straight from the DQ input registers and is valid only while
//   rvalid is high. A write needs nothing back: its data is latched.
//   wdata/wbe are indexed by the byte in the 16-byte block (word k of the
//   block in wdata[32k+31:32k]); a word write uses the word at addr only.
//   Accesses are carried out in order.
//
// Unknowns, behind parameters: the module's chip and speed grade (timing
// above, CAS_LATENCY 2: every MiSTer module's chip runs CL2 at 104 MHz), the
// board delay that CAPTURE_CLKS assumes, the module size (only the first
// 32 MB, 9 column bits, are used, which every module has).
module sdram #(
	parameter int CLK_HZ          = 104_000_000,
	parameter int CAS_LATENCY     = 2,
	parameter int CAPTURE_CLKS    = 1,       // clocks from the chip's data edge to the DQ capture
	parameter int T_RCD_NS        = 20,
	parameter int T_RP_NS         = 20,
	parameter int T_RAS_NS        = 45,
	parameter int T_RC_NS         = 70,
	parameter int T_RFC_NS        = 70,
	parameter int T_WR_NS         = 15,
	parameter int T_REFI_NS       = 7812,    // 64 ms / 8192 rows
	parameter int REFRESH_SLACK   = 16,      // clocks of margin under tREFI
	parameter int POWERUP_US      = 200,
	parameter int INIT_REFRESHES  = 8
) (
	input  logic         clk,
	input  logic         init,      // restarts the power-up sequence while high
	output logic         ready,     // the chip is set up

	input  logic         req,
	output logic         busy,
	input  logic         we,
	input  logic         line,      // 1: 16 bytes, 0: one word
	input  logic [24:2]  addr,      // word address in the module
	input  logic [127:0] wdata,
	input  logic [15:0]  wbe,
	output logic         rvalid,
	output logic [1:0]   rword,     // word of the block that rdata holds
	output logic [31:0]  rdata,

	output logic         sdram_cke,
	output logic         sdram_cs_n,
	output logic         sdram_ras_n,
	output logic         sdram_cas_n,
	output logic         sdram_we_n,
	output logic [1:0]   sdram_ba,
	output logic [12:0]  sdram_a,
	output logic         sdram_dqml,
	output logic         sdram_dqmh,
	output logic [15:0]  sdram_dq_o,
	output logic [15:0]  sdram_dq_oe,
	input  logic [15:0]  sdram_dq_i
);

	// ------------------------------------------------------------------
	// Timing in clocks
	// ------------------------------------------------------------------
	localparam int T_PS = 1_000_000_000 / (CLK_HZ / 1000);

	function automatic int clks(input int ns);
		return (ns * 1000 + T_PS - 1) / T_PS;
	endfunction

	function automatic int imax(input int a, input int b);
		return (a > b) ? a : b;
	endfunction

	localparam int RCD = imax(1, clks(T_RCD_NS));
	localparam int RP  = imax(1, clks(T_RP_NS));
	localparam int RAS = imax(1, clks(T_RAS_NS));
	localparam int RC  = imax(1, clks(T_RC_NS));
	localparam int RFC = imax(1, clks(T_RFC_NS));
	localparam int WR  = imax(2, clks(T_WR_NS));
	localparam int MRD = 2;
	// first halfword captured (+ 1: the output stage before the I/O registers)
	localparam int CAP = RCD + CAS_LATENCY + CAPTURE_CLKS + 1;

	// Keep the capture schedule relative to a real or virtual ACTIVE. A
	// row hit starts at RCD and issues its column command on acceptance.
	// Reads finish after capture; writes keep DQ free for WR clocks after
	// the last halfword (also covers write-to-read and DQM recovery).
	localparam int END_RW = CAP + 2;
	localparam int END_RL = CAP + 8;
	localparam int END_WW = RCD + 1 + WR;
	localparam int END_WL = RCD + 7 + WR;
	localparam int AGE_MAX = imax(RAS, RC);
	localparam int AW = $clog2(AGE_MAX + 1);
	// Conservative bounds even for an access accepted just after ACTIVE:
	// finish tRAS, PRECHARGE, then respect both tRP and the previous tRC.
	localparam int LONGEST = imax(RAS + RP, RC) + imax(imax(END_RW, END_RL), imax(END_WW, END_WL));
	localparam int REF_CLOSE = RAS + RP;

	localparam int REFI_CLKS     = T_REFI_NS * 1000 / T_PS;
	localparam int REFRESH_CLKS  = REFI_CLKS - LONGEST - REF_CLOSE - RFC - REFRESH_SLACK - 2;
	localparam int POWERUP_CLKS  = POWERUP_US * (CLK_HZ / 1_000_000);

	localparam int TW = $clog2(imax(LONGEST, RFC) + 2);

	// Mode register: single-location writes (A9), CAS latency, sequential,
	// burst length 8
	localparam logic [12:0] MODE = {3'b000, 1'b1, 2'b00, 3'(CAS_LATENCY), 1'b0, 3'b011};

	// {ras_n, cas_n, we_n}
	localparam logic [2:0] CMD_NOP       = 3'b111;
	localparam logic [2:0] CMD_ACTIVE    = 3'b011;
	localparam logic [2:0] CMD_READ      = 3'b101;
	localparam logic [2:0] CMD_WRITE     = 3'b100;
	localparam logic [2:0] CMD_PRECHARGE = 3'b010;
	localparam logic [2:0] CMD_REFRESH   = 3'b001;
	localparam logic [2:0] CMD_MODE      = 3'b000;
	localparam logic [2:0] CMD_STOP      = 3'b110;

	// ------------------------------------------------------------------
	// State
	// ------------------------------------------------------------------
	typedef enum logic [2:0] {
		I_WAIT,          // power-up NOPs
		I_PRECHARGE,
		I_REFRESH,
		I_MODE,
		I_DONE
	} init_t;

	init_t          istate = I_WAIT;
	logic [15:0]    icnt = '0;
	logic [3:0]     irefs = '0;

	// t is the edge being prepared, relative to ACTIVE in ACCESS, or to
	// PRECHARGE / REFRESH in the wait states. No request reordering.
	typedef enum logic [2:0] { IDLE, PRE_WAIT, ACT_WAIT, ACCESS,
	                           REF_PRE, REF_RP, REF_WAIT } state_t;
	state_t         state = IDLE;
	logic [3:0]     row_open = '0;
	logic [12:0]    row_addr [0:3];
	logic [AW-1:0]  row_age [0:3];  // saturating age of each bank's last ACTIVE
	logic [3:0]     pre_ok;
	// (Quartus 17 wants the genvar declared and an explicit generate block)
	genvar b;
	generate
		for (b = 0; b < 4; b = b + 1) begin : bank_timing
			assign pre_ok[b] = !row_open[b] || row_age[b] >= AW'(RAS);
		end
	endgenerate
	logic [12:0]    op_row;
	logic           op_we, op_line;
	logic [TW-1:0]  t;
	logic [TW-1:0]  t_end;
	logic [1:0]     op_ba = 2'b00;
	logic [8:0]     op_col;
	logic [127:0]   wsh;                  // write halfwords, next at the bottom
	logic [15:0]    wmask;                // their DQM, two bits each
	logic [1:0]     word;                 // next read word of the block
	logic [15:0]    dq_q, dq_hold;        // the last two captured halfwords

	logic [15:0]    rcnt = '0;
	logic           ref_due = 1'b0;
	logic           ready_q = 1'b0;

	wire idle = state == IDLE || (state == ACCESS && t == t_end) ||
	            (state == REF_WAIT && t == TW'(RFC));

	// the output stage (see Clocking): the schedule sets these, the I/O
	// registers take them a clock later
	logic        p_ras_n = 1'b1, p_cas_n = 1'b1, p_we_n = 1'b1;
	logic [1:0]  p_ba;
	logic [12:0] p_a;
	logic        p_dqml, p_dqmh;
	logic [15:0] p_dq_o;
	logic [15:0] p_dq_oe = 16'h0000;
	always_ff @(posedge clk) begin
		{sdram_ras_n, sdram_cas_n, sdram_we_n} <= {p_ras_n, p_cas_n, p_we_n};
		sdram_ba    <= p_ba;
		sdram_a     <= p_a;
		sdram_dqml  <= p_dqml;
		sdram_dqmh  <= p_dqmh;
		sdram_dq_o  <= p_dq_o;
		sdram_dq_oe <= p_dq_oe;
	end

	logic           rvalid_q = 1'b0;

	assign ready     = ready_q;
	assign rvalid    = rvalid_q;
	assign busy      = !ready_q || !idle || ref_due;
	assign sdram_cke = 1'b1;
	assign sdram_cs_n = 1'b0;

	// read capture: halfword k at edge CAP + k; word j complete at CAP + 2j + 1
	wire [TW:0] tcap = {1'b0, t} - TW'(CAP);
	wire        cap_word = state == ACCESS && !op_we && t >= TW'(CAP + 1) && tcap[0] &&
	                       tcap < (op_line ? (TW + 1)'(8) : (TW + 1)'(2));

	assign rdata = {dq_q, dq_hold};

	// Physical halfword address: column 8:0, row 21:9, bank 23:22.
	// Move logical byte bits 13:12 to the bank; preserve every other bit.
	// This is a bijective remap of all 32 MB; port addresses stay unchanged.
	wire [23:0] h = {addr[13:12], addr[24:14], addr[11:10], addr[9:2], 1'b0};
	wire take = ready_q && idle && !ref_due && req;
	wire hit = row_open[h[23:22]] && row_addr[h[23:22]] == h[21:9];
	wire hit_start = take && hit;
	wire [8:0] req_col = we && line ? {h[8:3], 3'b000} : h[8:0];
	wire [127:0] req_wsh = line ? wdata : {96'd0, wdata[32 * addr[3:2] +: 32]};
	wire [15:0] req_mask = line ? ~wbe : {12'hFFF, ~wbe[4 * addr[3:2] +: 4]};
	wire read_now = (hit_start && !we) || (state == ACCESS && !idle && !op_we && t == TW'(RCD));
	wire write_now = (hit_start && we) || (state == ACCESS && !idle && op_we &&
	                  t >= TW'(RCD) && t < TW'(RCD) + (op_line ? TW'(8) : TW'(2)));
	wire [8:0] col_now = hit_start ? req_col : op_col;
	wire [127:0] wsh_now = hit_start ? req_wsh : wsh;
	wire [15:0] mask_now = hit_start ? req_mask : wmask;

	always_ff @(posedge clk) begin
		// the DQ input registers take the pins every clock
		dq_q    <= sdram_dq_i;
		dq_hold <= dq_q;

		// output stage, loaded every clock: a NOP unless set below; the
		// bank of the access throughout it, DQ released
		{p_ras_n, p_cas_n, p_we_n} <= CMD_NOP;
		p_a     <= 13'd0;
		p_ba    <= op_ba;
		p_dqml  <= 1'b0;
		p_dqmh  <= 1'b0;
		p_dq_o  <= wsh[15:0];
		p_dq_oe <= 16'h0000;
		for (int b = 0; b < 4; b = b + 1) begin
			if (row_age[b] < AW'(AGE_MAX)) row_age[b] <= row_age[b] + 1'b1;
		end

		rvalid_q <= 1'b0;
		if (cap_word) begin
			rvalid_q <= 1'b1;
			rword  <= word;
			word   <= word + 2'd1;
		end

		// ---- refresh timer ----
		if (ready_q) begin
			if (rcnt == 16'(REFRESH_CLKS)) ref_due <= 1'b1;
			else rcnt <= rcnt + 16'd1;
		end

		// ---- power-up ----
		if (!ready_q) begin
			case (istate)
				I_WAIT: begin
					icnt <= icnt + 16'd1;
					if (icnt == 16'(POWERUP_CLKS)) begin
						istate <= I_PRECHARGE;
						icnt   <= '0;
					end
				end
				I_PRECHARGE: begin
					if (icnt == 16'd0) begin
						{p_ras_n, p_cas_n, p_we_n} <= CMD_PRECHARGE;
						p_a[10] <= 1'b1;                  // all banks
					end
					icnt <= icnt + 16'd1;
					if (icnt == 16'(RP - 1)) begin
						istate <= I_REFRESH;
						icnt   <= '0;
						irefs  <= '0;
					end
				end
				I_REFRESH: begin
					if (icnt == 16'd0) {p_ras_n, p_cas_n, p_we_n} <= CMD_REFRESH;
					icnt <= icnt + 16'd1;
					if (icnt == 16'(RFC - 1)) begin
						icnt  <= '0;
						irefs <= irefs + 4'd1;
						if (irefs == 4'(INIT_REFRESHES - 1)) istate <= I_MODE;
					end
				end
				I_MODE: begin
					if (icnt == 16'd0) begin
						{p_ras_n, p_cas_n, p_we_n} <= CMD_MODE;
						p_a  <= MODE;
						p_ba <= 2'b00;
					end
					icnt <= icnt + 16'd1;
					if (icnt == 16'(MRD - 1)) istate <= I_DONE;
				end
				default: begin
					ready_q <= 1'b1;
					rcnt    <= '0;
					ref_due <= 1'b0;
				end
			endcase
		end

		// ---- the access in progress ----
		if (ready_q && !idle) begin
			case (state)
				PRE_WAIT: if (pre_ok[op_ba]) begin
					{p_ras_n, p_cas_n, p_we_n} <= CMD_PRECHARGE;
					row_open[op_ba] <= 1'b0;
					state <= ACT_WAIT;
					t <= TW'(1);
				end
				ACT_WAIT: begin
					if (t < TW'(RP)) t <= t + 1'b1;
					if (t >= TW'(RP) && row_age[op_ba] >= AW'(RC)) begin
						{p_ras_n, p_cas_n, p_we_n} <= CMD_ACTIVE;
						p_a <= op_row;
						row_addr[op_ba] <= op_row;
						row_open[op_ba] <= 1'b1;
						row_age[op_ba] <= AW'(1);
						state <= ACCESS;
						t <= TW'(1);
					end
				end
				ACCESS: begin
					t <= t + 1'b1;
					// BURST TERMINATE has the same CL delay as READ. Issued
					// two clocks after READ, it leaves exactly two halfwords
					// on DQ, without closing the row or changing DQM.
					if (!op_we && !op_line && t == TW'(RCD + 2))
						{p_ras_n, p_cas_n, p_we_n} <= CMD_STOP;
				end
				REF_PRE: if (&pre_ok) begin
					{p_ras_n, p_cas_n, p_we_n} <= CMD_PRECHARGE;
					p_a[10] <= 1'b1;
					row_open <= '0;
					state <= REF_RP;
					t <= TW'(1);
				end
				REF_RP: begin
					t <= t + 1'b1;
					if (t == TW'(RP)) begin
						{p_ras_n, p_cas_n, p_we_n} <= CMD_REFRESH;
						state <= REF_WAIT;
						t <= TW'(1);
						ref_due <= 1'b0;
						rcnt <= '0;
					end
				end
				REF_WAIT: t <= t + 1'b1;
				default: ;
			endcase
		end else if (ready_q) begin
			state <= IDLE;
			if (ref_due) begin
				// Stop accepting accesses until all banks are precharged,
				// tRP has elapsed, and AUTO REFRESH has completed its tRFC.
				state <= REF_PRE;
				if (&pre_ok) begin
					{p_ras_n, p_cas_n, p_we_n} <= CMD_PRECHARGE;
					p_a[10] <= 1'b1;
					row_open <= '0;
					state <= REF_RP;
					t <= TW'(1);
				end
			end else if (req) begin
				p_ba     <= h[23:22];
				op_ba    <= h[23:22];
				op_row   <= h[21:9];
				op_we    <= we;
				op_line  <= line;
				t_end    <= we ? (line ? TW'(END_WL) : TW'(END_WW)) : (line ? TW'(END_RL) : TW'(END_RW));
				word     <= addr[3:2];
				op_col   <= req_col;
				wsh      <= req_wsh;
				wmask    <= req_mask;
				if (hit) begin
					state <= ACCESS;
					t <= TW'(RCD + 1);
				end else if (row_open[h[23:22]]) begin
					state <= PRE_WAIT;
					if (pre_ok[h[23:22]]) begin
						{p_ras_n, p_cas_n, p_we_n} <= CMD_PRECHARGE;
						row_open[h[23:22]] <= 1'b0;
						state <= ACT_WAIT;
						t <= TW'(1);
					end
				end else begin
					state <= ACT_WAIT;
					t <= TW'(RP); // already closed: no new tRP to wait
					if (row_age[h[23:22]] >= AW'(RC)) begin
						{p_ras_n, p_cas_n, p_we_n} <= CMD_ACTIVE;
						p_a <= h[21:9];
						row_addr[h[23:22]] <= h[21:9];
						row_open[h[23:22]] <= 1'b1;
						row_age[h[23:22]] <= AW'(1);
						state <= ACCESS;
						t <= TW'(1);
					end
				end
			end
		end

		// A hit uses the request directly for its first column command;
		// later beats and misses use the latched operands. These muxes end
		// at p_*, preserving the logic-free I/O register stage.
		if (read_now) begin
			{p_ras_n, p_cas_n, p_we_n} <= CMD_READ;
			p_a[8:0] <= col_now;
		end
		if (write_now) begin
			{p_ras_n, p_cas_n, p_we_n} <= CMD_WRITE;
			p_a <= {mask_now[1], mask_now[0], 2'b00, col_now};
			p_dqml <= mask_now[0];
			p_dqmh <= mask_now[1];
			p_dq_o <= wsh_now[15:0];
			p_dq_oe <= 16'hFFFF;
			wsh <= {16'h0000, wsh_now[127:16]};
			wmask <= {2'b11, mask_now[15:2]};
			op_col <= {col_now[8:3], col_now[2:0] + 3'd1};
		end

		if (init) begin
			istate  <= I_WAIT;
			icnt    <= '0;
			ready_q <= 1'b0;
			state   <= IDLE;
			row_open <= '0;
			for (int b = 0; b < 4; b = b + 1) row_age[b] <= AW'(AGE_MAX);
			ref_due <= 1'b0;
		end
	end

endmodule

// SDRAM_CLK: the inverted clock from a DDIO output, so that it leaves the
// FPGA through an I/O register like the commands it clocks.
module sdram_clkout (
	input  logic clk,
	output logic sdram_clk
);
`ifdef VERILATOR
	assign sdram_clk = ~clk;
`else
	altddio_out #(
		.extend_oe_disable("OFF"),
		.intended_device_family("Cyclone V"),
		.invert_output("OFF"),
		.lpm_hint("UNUSED"),
		.lpm_type("altddio_out"),
		.oe_reg("UNREGISTERED"),
		.power_up_high("OFF"),
		.width(1)
	) ddio (
		.datain_h(1'b0),
		.datain_l(1'b1),
		.outclock(clk),
		.dataout(sdram_clk),
		.aclr(1'b0),
		.aset(1'b0),
		.oe(1'b1),
		.outclocken(1'b1),
		.sclr(1'b0),
		.sset(1'b0)
	);
`endif
endmodule
