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
// the I/O cells (sys/sys.tcl sets FAST_*_REGISTER for SDRAM_*).
//
// Policy: closed page. Each access opens its row with ACTIVE, reads or
// writes, and closes it with PRECHARGE; there is no bank interleaving. The
// mode register sets burst length 8 (sequential) for reads and single-
// location writes. A line read is one READ: the chip's burst wraps inside
// the 8-halfword block, so the word asked for comes first. A word read is
// the same READ cut short by the PRECHARGE after two halfwords. Writes issue
// one WRITE a halfword with its DQM (two for a word, eight for a line).
//
// Schedule at the defaults (clocks after the ACTIVE edge; tRCD, tRP 20 ns,
// tRAS 45 ns, tRC, tRFC 70 ns, tWR 15 ns: the slowest of the modules' data
// sheets, rounded up at 104 MHz to 3, 3, 5, 8, 8 and 2 clocks):
//   word read:   READ 3, PRECHARGE 5, word at the port 7, next ACTIVE 8
//   line read:   READ 3, PRECHARGE 11, words at 7, 9, 11, 13, next ACTIVE 14
//   word write:  WRITE 3-4, PRECHARGE 6, next ACTIVE 9
//   line write:  WRITE 3-10, PRECHARGE 12, next ACTIVE 15
// The request is taken at the ACTIVE edge, so a read's first word reaches
// rvalid 7 clocks (67 ns) after the request is taken.
//
// Refresh: one AUTO REFRESH every REFRESH_CLKS (780 at 104 MHz, 7.5 us),
// issued between accesses; an access never waits more than tRFC (8 clocks)
// for it, and it never waits more than the longest access (15 clocks), so
// refreshes are at most 795 clocks (7.64 us) apart, inside tREFI (8192 rows
// in 64 ms = 7.81 us). Power-up: POWERUP_US of NOPs, PRECHARGE ALL,
// INIT_REFRESHES refreshes, the mode register; ready rises after tMRD.
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
	localparam int CAP = RCD + CAS_LATENCY + CAPTURE_CLKS;   // first halfword captured

	// read of n halfwords: PRECHARGE after the last one leaves the chip (a
	// PRECHARGE CL-1 clocks before the edge of the last wanted halfword cuts
	// the burst there), and the next ACTIVE after tRP, tRC and the capture
	localparam int PRE_RW = imax(RAS, RCD + 2);
	localparam int PRE_RL = imax(RAS, RCD + 8);
	localparam int END_RW = imax(imax(RC, PRE_RW + RP), CAP + 2);
	localparam int END_RL = imax(imax(RC, PRE_RL + RP), CAP + 8);
	// write of n halfwords: PRECHARGE tWR after the last
	localparam int PRE_WW = imax(RAS, RCD + 1 + WR);
	localparam int PRE_WL = imax(RAS, RCD + 7 + WR);
	localparam int END_WW = imax(RC, PRE_WW + RP);
	localparam int END_WL = imax(RC, PRE_WL + RP);
	localparam int LONGEST = imax(imax(END_RW, END_RL), imax(END_WW, END_WL));

	localparam int REFI_CLKS     = T_REFI_NS * 1000 / T_PS;
	localparam int REFRESH_CLKS  = REFI_CLKS - LONGEST - RFC - REFRESH_SLACK;
	localparam int POWERUP_CLKS  = POWERUP_US * (CLK_HZ / 1_000_000);

	localparam int TW = $clog2(LONGEST + 2);

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

	// the access in progress: t counts the edges since its ACTIVE (the
	// value in a cycle is the edge being prepared)
	logic           active = 1'b0;
	logic           op_ref;               // a refresh, not an access
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

	wire idle = !active || t == t_end;

	logic           rvalid_q = 1'b0;

	assign ready     = ready_q;
	assign rvalid    = rvalid_q;
	assign busy      = !ready_q || !idle || ref_due;
	assign sdram_cke = 1'b1;
	assign sdram_cs_n = 1'b0;

	// read capture: halfword k at edge CAP + k; word j complete at CAP + 2j + 1
	wire [TW:0] tcap = {1'b0, t} - TW'(CAP);
	wire        cap_word = active && !op_ref && !op_we && t >= TW'(CAP + 1) && tcap[0] &&
	                       tcap < (op_line ? (TW + 1)'(8) : (TW + 1)'(2));

	assign rdata = {dq_q, dq_hold};

	// the halfword address of an access: column 8:0, row 21:9, bank 23:22
	wire [23:0] h = {addr, 1'b0};

	always_ff @(posedge clk) begin
		// the DQ input registers take the pins every clock
		dq_q    <= sdram_dq_i;
		dq_hold <= dq_q;

		// I/O registers, loaded every clock: a NOP unless set below; the
		// bank of the access throughout it, DQ released
		{sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_NOP;
		sdram_a     <= 13'd0;
		sdram_ba    <= op_ba;
		sdram_dqml  <= 1'b0;
		sdram_dqmh  <= 1'b0;
		sdram_dq_o  <= wsh[15:0];
		sdram_dq_oe <= 16'h0000;

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
						{sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_PRECHARGE;
						sdram_a[10] <= 1'b1;                  // all banks
					end
					icnt <= icnt + 16'd1;
					if (icnt == 16'(RP - 1)) begin
						istate <= I_REFRESH;
						icnt   <= '0;
						irefs  <= '0;
					end
				end
				I_REFRESH: begin
					if (icnt == 16'd0) {sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_REFRESH;
					icnt <= icnt + 16'd1;
					if (icnt == 16'(RFC - 1)) begin
						icnt  <= '0;
						irefs <= irefs + 4'd1;
						if (irefs == 4'(INIT_REFRESHES - 1)) istate <= I_MODE;
					end
				end
				I_MODE: begin
					if (icnt == 16'd0) begin
						{sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_MODE;
						sdram_a  <= MODE;
						sdram_ba <= 2'b00;
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
		if (active && !idle) begin
			t <= t + 1'd1;
			if (!op_ref) begin
				if (!op_we && t == TW'(RCD)) begin
					{sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_READ;
					sdram_a[8:0] <= op_col;
				end
				if (op_we && t >= TW'(RCD) && t < TW'(RCD) + (op_line ? TW'(8) : TW'(2))) begin
					{sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_WRITE;
					sdram_a     <= {wmask[1], wmask[0], 2'b00, op_col};
					sdram_dqml  <= wmask[0];
					sdram_dqmh  <= wmask[1];
					sdram_dq_oe <= 16'hFFFF;
					wsh         <= {16'h0000, wsh[127:16]};
					wmask       <= {2'b11, wmask[15:2]};
					op_col      <= {op_col[8:3], op_col[2:0] + 3'd1};
				end
				if (t == (op_we ? (op_line ? TW'(PRE_WL) : TW'(PRE_WW))
				                : (op_line ? TW'(PRE_RL) : TW'(PRE_RW)))) begin
					{sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_PRECHARGE;
				end
			end
		end else if (ready_q) begin
			active <= 1'b0;
			if (ref_due) begin
				// AUTO REFRESH (every bank is closed between accesses)
				{sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_REFRESH;
				active  <= 1'b1;
				op_ref  <= 1'b1;
				t       <= TW'(1);
				t_end   <= TW'(RFC);
				ref_due <= 1'b0;
				rcnt    <= '0;
			end else if (req) begin
				{sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_ACTIVE;
				sdram_a  <= h[21:9];
				sdram_ba <= h[23:22];
				op_ba    <= h[23:22];
				active   <= 1'b1;
				op_ref   <= 1'b0;
				op_we    <= we;
				op_line  <= line;
				t        <= TW'(1);
				t_end    <= we ? (line ? TW'(END_WL) : TW'(END_WW)) : (line ? TW'(END_RL) : TW'(END_RW));
				word     <= addr[3:2];
				if (we) begin
					// writes go from the start of the block (line) or the word
					op_col <= line ? {h[8:3], 3'b000} : {h[8:1], 1'b0};
					wsh    <= line ? wdata : {96'd0, wdata[32 * addr[3:2] +: 32]};
					wmask  <= line ? ~wbe : {12'hFFF, ~wbe[4 * addr[3:2] +: 4]};
				end else begin
					op_col <= h[8:0];
				end
			end
		end

		if (init) begin
			istate  <= I_WAIT;
			icnt    <= '0;
			ready_q <= 1'b0;
			active  <= 1'b0;
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
