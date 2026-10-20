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
// CTSI_IRQ (source 25, shared with cbus.dll) is high while bit 2 or 3 is set.
// Accesses are 16-bit (upp_periph drops others, as the model's regions do).
module upp_uif (
	input  logic        clk,
	input  logic        reset,

	input  logic        acc,
	input  logic        wr,
	input  logic [11:0] off,          // byte offset in the 0x0C150000 page
	input  logic        hi,           // the access is to the upper halfword (bytes 3:2)
	input  logic [31:0] wdata,
	output logic [31:0] rmask,
	output logic [31:0] rdata,

	output logic        ctsi_irq,

	output logic [4:0]  col_oe,
	output logic [4:0]  col_out,
	output logic [5:0]  row_oe,
	output logic [5:0]  row_out,
	input  logic [4:0]  col_in,
	input  logic [5:0]  row_in
);

	logic [15:0] ctsi;
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
	wire [4:0] w = {off[4:2], hi, 1'b0};          // the 16-bit register's offset
	wire [15:0] wv = hi ? wdata[31:16] : wdata[15:0];

	always_comb begin
		rmask = 32'd0;
		rdata = 32'd0;
		if (acc) begin
			if (is_ctsi) begin
				rmask = 32'h0000_FFFF;
				rdata = {16'd0, ctsi};
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

		if (wr) begin
			if (is_ctsi) begin
				// bits 2 and 3 clear when written 1 (and stay set by an edge now)
				ctsi <= {wdata[15:4], ctsi[3:2] & ~wdata[3:2] | {fell_c != 5'd0, fell_r != 6'd0}, wdata[1:0]};
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

	assign ctsi_irq = ctsi[2] | ctsi[3];


endmodule
