// SPDX-License-Identifier: GPL-2.0-or-later
// A small first-word-fall-through FIFO for the UPP peripherals: 2^AW entries
// in a block RAM (sdp_ram) behind one output register. dout is valid while
// valid is high; pop takes it. The output register is refilled a clock after
// it empties, so a word every two clocks at most (the users are slower).
// full: the RAM can take no more (push is then ignored); room: the free
// RAM entries; empty: nothing in the FIFO at all. flush empties it.
module upp_fifo #(
	parameter int DW = 32,
	parameter int AW = 4
) (
	input  logic          clk,
	input  logic          flush,

	input  logic          push,
	input  logic [DW-1:0] din,
	input  logic          pop,
	output logic [DW-1:0] dout,
	output logic          valid,

	output logic          full,
	output logic          empty,
	output logic [AW:0]   room
);

	localparam logic [AW:0] DEPTH = (AW + 1)'(1 << AW);

	logic [AW-1:0] wp, rp;
	logic [AW:0]   n;                  // entries in the RAM
	logic          inflight;           // a RAM read whose data arrives next clock
	logic [DW-1:0] q;

	wire do_push  = push && n != DEPTH;
	wire do_pop   = pop && valid;
	wire do_fetch = n != '0 && !inflight && (!valid || do_pop);

	sdp_ram #(.AW(AW), .DW(DW)) ram (
		.clk(clk),
		.we(do_push),
		.waddr(wp),
		.wdata(din),
		.raddr(rp),
		.rdata(q)
	);

	assign full  = n == DEPTH;
	assign room  = DEPTH - n;
	assign empty = n == '0 && !inflight && !valid;

	always_ff @(posedge clk) begin
		if (do_push) wp <= wp + 1'd1;
		if (do_fetch) rp <= rp + 1'd1;
		n <= n + (AW + 1)'(do_push) - (AW + 1)'(do_fetch);
		inflight <= do_fetch;
		if (inflight) begin
			dout  <= q;
			valid <= 1'b1;
		end else if (do_pop) begin
			valid <= 1'b0;
		end
		if (flush) begin
			wp       <= '0;
			rp       <= '0;
			n        <= '0;
			inflight <= 1'b0;
			valid    <= 1'b0;
		end
	end

endmodule
