// SPDX-License-Identifier: GPL-2.0-or-later
// Simple dual-port block RAM: one write port, one registered read port, one
// clock. Quartus infers an M10K/MLAB array from this template; a read of the
// address being written returns the old data.
module sdp_ram #(
	parameter int AW = 10,
	parameter int DW = 16,
	parameter int DEPTH = 1 << AW
) (
	input  logic          clk,
	input  logic          we,
	input  logic [AW-1:0] waddr,
	input  logic [DW-1:0] wdata,
	input  logic [AW-1:0] raddr,
	output logic [DW-1:0] rdata
);

	logic [DW-1:0] mem [0:DEPTH-1];

	always_ff @(posedge clk) begin
		if (we) mem[waddr] <= wdata;
		rdata <= mem[raddr];
	end

endmodule
