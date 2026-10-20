// SPDX-License-Identifier: GPL-2.0-or-later
// Stand-in for the UPP_WD2 peripheral models on upp_bus's register bus: a
// store of 2^AW words that returns what was written (bytes as written,
// other bytes 0 after power-up). The word index folds the page bits into
// the offset (and 0x0D000000 apart from 0x0C000000), so the register pages
// seen so far (0x0C12xxxx, 0x0C14xxxx, 0x0C15xxxx, 0x0DExxxxx) mostly land
// apart; it is not a decoder. Every
// access takes two clocks (p_wait in the first).
module upp_periph_stub #(
	parameter int AW = 10
) (
	input  logic        clk,
	input  logic        reset,
	input  logic        p_sel,
	input  logic        p_we,
	input  logic [27:0] p_addr,
	input  logic [31:0] p_wdata,
	input  logic [3:0]  p_be,
	output logic [31:0] p_rdata,
	output logic        p_wait
);

	logic second = 1'b0;

	wire [AW-1:0] idx = p_addr[2 +: AW] ^ p_addr[2 + AW +: AW] ^ {p_addr[24], {(AW - 1){1'b0}}};

	assign p_wait = p_sel && !second;

	always_ff @(posedge clk) begin
		second <= p_sel && !second && !reset;
	end

	bram32 #(.AW(AW)) store (
		.clk(clk),
		.we(p_sel && p_we && !second),
		.be(p_be),
		.waddr(idx),
		.wdata(p_wdata),
		.raddr(idx),
		.rdata(p_rdata)
	);

endmodule
