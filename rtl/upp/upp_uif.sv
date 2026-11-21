// SPDX-License-Identifier: GPL-2.0-or-later
//
// UPP_WD2 UIF general-purpose ports D and E (0x0C150400-0x0C15041F), wired to
// the N-Gage QD's key matrix, and the CTSI interrupt status they raise
// (0x0C150100), as the reference model has them (model/hw/ngage_keypad.c,
// from ekeyb.dll, RH-29 v4.60; docs/UPP_WD2.md). 16-bit registers:
//
//   D      E
//   +0x00  +0x0C  data: the output latch (5 / 6 bits); reads give the pin
//                 levels (ekeyb 0x5041CBA8 reads, inverts, keeps 0x1F / 0x3F)
//   +0x02  +0x0E  direction, 1 = output. A write sets the bits in its low byte
//                 and clears the bits in its high byte (ops 2/3 at 0x5041C804);
//                 reads give the bits ([model guess] for all set/clear registers)
//   +0x04  +0x10  interrupt enable, the same set/clear format (ops 4/5)
//   +0x08  +0x14  unknown, the same format; stored (ops 6/7)
//   +0x0A  +0x16  pull-up enable, the same format (ops 8/9); the lines are
//                 pulled up whatever it says
//   +0x18         written 0 at keypad init (0x5041CCFC); stored
//   +0x06, +0x12, +0x1A-+0x1E  read 0
// Port D = columns COL0-4, port E = rows ROW0-5 (ekeyb's line masks 0x3F1F,
// 0x5041C6F8). An output pin reads its latch; an input pin reads the line as
// the matrix (rtl/board/keypad_matrix.sv) gives it. The model joins only a
// pressed key's own row and column; the board model also shows ghost keys.
//
// CTSI +0x100 (16 bits): bit 2 latches when an interrupt-enabled port E input
// falls, bit 3 when a port D input does ([model guess] for port D); writing 1
// clears them (ekeyb's CTSI handler 0x5041B9E0 tests bit 2 and writes 0xC,
// 0x5041CD6C). The other bits are stored (the bootstrap writes 0x8000, 0x2EE4).
//
// CTSI's second group, for the Bluetooth module's interrupt line (model/hw/
// ngage_bt.c, from cbus.dll and btldd.ldd):
//   +0x102  status: bit 4 latches a pulse of bt_irq; writing 1 clears it
//           (btldd 0x503F0B68). It reads as set only while enabled, a guess
//           and the safe one: cbus.dll's handler (0x5037D5D4) faults when it
//           finds the bit with no driver registered for it.
//   +0x014  write 1s: disable those bits of the group (btldd 0x503F084C)
//   +0x016  write 1s: enable them (0x503F0B48); both read the enables
// CTSI_IRQ (source 25, shared with cbus.dll) is high while bit 2 or 3 is set
// or the module's bit is, enabled.
// Native NOS delay calibration uses the free-running down-counter at +0x112
// and the programmable reload window at +0x114. The model uses the NEM-4
// approximation of 32.768 kHz. The independent NOS deadline counter at
// +0x116 advances at 64 Hz using the same prescaler.
// A match at +0x118 sets status bit 7. Write that bit at +0x012/+0x010 to
// enable/disable it and at +0x100 to acknowledge it.
// Bits 12 and 13 are software interrupts in the same CTSI group. +0x012
// sets and enables them, +0x010 clears and disables them, and +0x100
// acknowledges their pending status.
// The MDI peer pulses bits 9 and 10. The same group controls their enable and
// acknowledges their status, which remains latched until acknowledged.
// Keypad and interrupt accesses are 16-bit, as enforced by upp_periph.
module upp_uif #(
	parameter int CLK_HZ = 104_000_000
) (
	input  logic        clk,
	input  logic        reset,

	input  logic        acc,
	input  logic        wr,
	input  logic [11:0] off,          // byte offset in the 0x0C150000 page
	input  logic        hi,           // the access is to the upper halfword (bytes 3:2)
	input  logic [31:0] wdata,
	input  logic [3:0]  be,
	output logic [31:0] rmask,
	output logic [31:0] rdata,

	input  logic        bt_irq,       // the Bluetooth module's interrupt line, a pulse
	input  logic [1:0]  mdi_events,
	output logic        nos_tick,
	output logic        ctsi_irq,

	output logic [4:0]  col_oe,
	output logic [4:0]  col_out,
	output logic [5:0]  row_oe,
	output logic [5:0]  row_out,
	input  logic [4:0]  col_in,
	input  logic [5:0]  row_in
);

	localparam logic [15:0] CTSI_NOS_EVENTS = 16'h3680;
	logic [15:0] ctsi;
	logic        bt_latch;
	logic [15:0] bt_en;
	logic [4:0]  data_d;
	logic [5:0]  data_e;
	logic [7:0]  dir_d, ien_d, misc_d, pull_d, dir_e, ien_e, misc_e, pull_e;
	logic [15:0] reg18;
	logic [4:0]  last_c;
	logic [5:0]  last_r;

	// pin levels: outputs show their latch
	wire [4:0] cols = (dir_d[4:0] & data_d) | (~dir_d[4:0] & col_in);
	wire [5:0] rows = (dir_e[5:0] & data_e) | (~dir_e[5:0] & row_in);

	assign col_oe  = dir_d[4:0];
	assign col_out = data_d;
	assign row_oe  = dir_e[5:0];
	assign row_out = data_e;

	wire is_ctsi = off == 12'h100;
	wire is_cten = off == 12'h014;
	wire is_calibration_counter = off == 12'h110;
	wire is_calibration_window  = off == 12'h114;
	wire is_nos_enable = off == 12'h010;
	wire is_nos_compare = off == 12'h118;
	wire [4:0] w = {off[4:2], hi, 1'b0};          // the 16-bit register's offset
	wire [15:0] wv = hi ? wdata[31:16] : wdata[15:0];

	localparam int CAL_DIV = CLK_HZ / 32_768;
	localparam int CAL_DIV_BITS = CAL_DIV > 0 ? $clog2(CAL_DIV + 1) : 1;
	// Use one extra system clock on the first CAL_LONG_TICKS of each 512
	// calibration ticks so the NOS period is exactly CLK_HZ / 64.
	localparam int CAL_LONG_TICKS = CLK_HZ / 64 - 512 * CAL_DIV;
	localparam logic [15:0] CAL_DEFAULT_WINDOW = 16'h0080;
	logic [CAL_DIV_BITS-1:0] calibration_divider;
	logic [15:0] calibration_counter, calibration_window;
	logic [8:0]  calibration_phase;
	logic [15:0] nos_counter, nos_compare;
	logic        nos_enable, nos_pending, nos_compare_valid;
	logic [1:0]  nos_soft_enable, nos_soft_pending;
	logic [1:0]  mdi_enable, mdi_pending;
	wire [15:0] calibration_reload = calibration_window == 16'd0 ? CAL_DEFAULT_WINDOW : calibration_window;
	wire [15:0] next_calibration_window = {
		be[1] ? wdata[15:8] : calibration_window[15:8],
		be[0] ? wdata[7:0] : calibration_window[7:0]
	};
	wire calibration_long = calibration_phase < 9'(CAL_LONG_TICKS);
	wire calibration_tick = calibration_divider == CAL_DIV_BITS'(CAL_DIV - 1) + CAL_DIV_BITS'(calibration_long);
	wire window_written = wr && is_calibration_window && |be[1:0];
	assign nos_tick = calibration_tick && (&calibration_phase);
	wire compare_written = wr && is_nos_compare && |be[1:0];
	wire [15:0] next_nos_compare = {
		be[1] ? wdata[15:8] : nos_compare[15:8],
		be[0] ? wdata[7:0] : nos_compare[7:0]
	};
	wire [15:0] active_compare = compare_written ? next_nos_compare : nos_compare;
	wire [1:0] soft_set = wr && is_nos_enable && be[3] ? wdata[29:28] : 2'd0;
	wire [1:0] soft_disable = wr && is_nos_enable && be[1] ? wdata[13:12] : 2'd0;
	wire [1:0] soft_ack = wr && is_ctsi && be[1] ? wdata[13:12] : 2'd0;
	wire [1:0] mdi_set = wr && is_nos_enable && be[3] ? wdata[26:25] : 2'd0;
	wire [1:0] mdi_disable = wr && is_nos_enable && be[1] ? wdata[10:9] : 2'd0;
	wire [1:0] mdi_ack = wr && is_ctsi && be[1] ? wdata[10:9] : 2'd0;

	always_ff @(posedge clk) begin
		if (reset) begin
			calibration_divider <= '0;
			calibration_counter <= CAL_DEFAULT_WINDOW;
			calibration_window  <= 16'd0;
			calibration_phase   <= 9'd0;
		end else begin
			calibration_divider <= calibration_tick ? '0 : calibration_divider + 1'd1;
			if (calibration_tick) calibration_phase <= calibration_phase + 1'd1;
			if (window_written) begin
				calibration_window <= next_calibration_window;
				calibration_counter <= next_calibration_window == 16'd0 ? CAL_DEFAULT_WINDOW : next_calibration_window;
			end else if (calibration_tick) begin
				calibration_counter <= calibration_counter == 16'd0 ? calibration_reload : calibration_counter - 16'd1;
			end
		end
	end

	always_ff @(posedge clk) begin
		if (reset) begin
			nos_counter       <= 16'd0;
			nos_compare       <= 16'd0;
			nos_enable        <= 1'b0;
			nos_pending       <= 1'b0;
			nos_compare_valid <= 1'b0;
			nos_soft_enable   <= 2'd0;
			nos_soft_pending  <= 2'd0;
			mdi_enable        <= 2'd0;
			mdi_pending       <= 2'd0;
		end else begin
			if (nos_tick) nos_counter <= nos_counter + 16'd1;
			if (compare_written) begin
				nos_compare <= next_nos_compare;
				nos_compare_valid <= 1'b1;
			end
			if (wr && is_nos_enable)
				nos_enable <= (nos_enable || (be[2] && wdata[23])) && !(be[0] && wdata[7]);
			if (wr && is_ctsi && be[0] && wdata[7]) nos_pending <= 1'b0;
			nos_soft_enable  <= (nos_soft_enable | soft_set) & ~soft_disable;
			nos_soft_pending <= (nos_soft_pending | soft_set) & ~(soft_disable | soft_ack);
			mdi_enable      <= (mdi_enable | mdi_set) & ~mdi_disable;
			mdi_pending     <= (mdi_pending & ~mdi_ack) | mdi_events;
			if ((compare_written && nos_counter == next_nos_compare) ||
			    (nos_tick && (nos_compare_valid || compare_written) && nos_counter + 16'd1 == active_compare))
				nos_pending <= 1'b1;
		end
	end

	always_comb begin
		rmask = 32'd0;
		rdata = 32'd0;
		if (acc) begin
			if (is_calibration_counter) begin
				rmask = 32'hFFFF_0000;
				rdata = {calibration_counter, 16'd0};
			end else if (is_calibration_window) begin
				rmask = '1;
				rdata = {nos_counter, calibration_reload};
			end else if (is_nos_compare) begin
				rmask = 32'h0000_FFFF;
				rdata = {16'd0, nos_compare};
			end else if (is_nos_enable) begin
				rmask = 32'h3680_0000;
				rdata = {2'd0, nos_soft_enable, 1'b0, mdi_enable, 1'b0, nos_enable, 23'd0};
			end else if (is_ctsi) begin
				rmask = '1;
				rdata = {11'd0, bt_latch && bt_en[4], 4'd0,
				         ctsi | {2'd0, nos_soft_pending, 1'b0, mdi_pending, 1'b0, nos_pending, 7'd0}};
			end else if (is_cten) begin
				rmask = '1;
				rdata = {bt_en, bt_en};
			end else begin
				rmask = '1;
				case (off[4:2])
					3'd0: rdata = {8'd0, dir_d, 11'd0, cols};
					3'd1: rdata = {24'd0, ien_d};
					3'd2: rdata = {8'd0, pull_d, 8'd0, misc_d};
					3'd3: rdata = {8'd0, dir_e, 10'd0, rows};
					3'd4: rdata = {24'd0, ien_e};
					3'd5: rdata = {8'd0, pull_e, 8'd0, misc_e};
					3'd6: rdata = {16'd0, reg18};
					default: rdata = 32'd0;
				endcase
			end
		end
	end

	function automatic logic [7:0] setclr(input logic [7:0] v, input logic [15:0] x);
		return (v | x[7:0]) & ~x[15:8];
	endfunction

	wire [5:0] fell_r = last_r & ~rows & ien_e[5:0] & ~dir_e[5:0];
	wire [4:0] fell_c = last_c & ~cols & ien_d[4:0] & ~dir_d[4:0];

	always_ff @(posedge clk) begin
		last_r <= rows;
		last_c <= cols;
		if (fell_r != 6'd0) ctsi[2] <= 1'b1;
		if (fell_c != 5'd0) ctsi[3] <= 1'b1;

		if (bt_irq) bt_latch <= 1'b1;

		if (wr && !is_calibration_counter && !is_calibration_window && !is_nos_enable && !is_nos_compare) begin
			if (is_ctsi && hi) begin
				// the module's bit clears when written 1 (and stays set by a pulse now)
				if (wv[4] && !bt_irq) bt_latch <= 1'b0;
			end else if (is_ctsi) begin
				// bits 2 and 3 clear when written 1 (and stay set by an edge now)
				ctsi <= {wdata[15:4], ctsi[3:2] & ~wdata[3:2] | {fell_c != 5'd0, fell_r != 6'd0}, wdata[1:0]}
				        & ~CTSI_NOS_EVENTS;
			end else if (is_cten) begin
				bt_en <= hi ? (bt_en | wv) : (bt_en & ~wv);
			end else begin
				case (w)
					5'h00: data_d <= wv[4:0];
					5'h02: dir_d  <= setclr(dir_d, wv);
					5'h04: ien_d  <= setclr(ien_d, wv);
					5'h08: misc_d <= setclr(misc_d, wv);
					5'h0A: pull_d <= setclr(pull_d, wv);
					5'h0C: data_e <= wv[5:0];
					5'h0E: dir_e  <= setclr(dir_e, wv);
					5'h10: ien_e  <= setclr(ien_e, wv);
					5'h14: misc_e <= setclr(misc_e, wv);
					5'h16: pull_e <= setclr(pull_e, wv);
					5'h18: reg18  <= wv;
					default: ;
				endcase
			end
		end

		if (reset) begin
			ctsi   <= 16'd0;
			bt_latch <= 1'b0;
			bt_en  <= 16'd0;
			data_d <= 5'h1F;
			data_e <= 6'h3F;
			dir_d  <= 8'd0;
			ien_d  <= 8'd0;
			misc_d <= 8'd0;
			pull_d <= 8'd0;
			dir_e  <= 8'd0;
			ien_e  <= 8'd0;
			misc_e <= 8'd0;
			pull_e <= 8'd0;
			reg18  <= 16'd0;
			last_c <= 5'h1F;
			last_r <= 6'h3F;
		end
	end

	assign ctsi_irq = ctsi[2] | ctsi[3] | (bt_latch & bt_en[4]) |
	                  (nos_pending & nos_enable) | (|(nos_soft_pending & nos_soft_enable)) |
	                  (|(mdi_pending & mdi_enable));


endmodule
