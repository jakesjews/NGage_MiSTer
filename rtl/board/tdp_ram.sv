// SPDX-License-Identifier: GPL-2.0-or-later
// True dual-port block RAM, one clock: each port reads and writes, and a
// write returns the new data on its own port. This is Quartus's template for
// an M10K in true dual-port mode.
module tdp_ram #(
	parameter int AW = 9,
	parameter int DW = 16
) (
	input  logic          clk,

	input  logic          we_a,
	input  logic [AW-1:0] addr_a,
	input  logic [DW-1:0] wdata_a,
	output logic [DW-1:0] q_a,

	input  logic          we_b,
	input  logic [AW-1:0] addr_b,
	input  logic [DW-1:0] wdata_b,
	output logic [DW-1:0] q_b
);

	logic [DW-1:0] mem [0:(1 << AW) - 1];

	always_ff @(posedge clk) begin
		if (we_a) begin
			mem[addr_a] <= wdata_a;
			q_a <= wdata_a;
		end else begin
			q_a <= mem[addr_a];
		end
	end

	always_ff @(posedge clk) begin
		if (we_b) begin
			mem[addr_b] <= wdata_b;
			q_b <= wdata_b;
		end else begin
			q_b <= mem[addr_b];
		end
	end

endmodule
