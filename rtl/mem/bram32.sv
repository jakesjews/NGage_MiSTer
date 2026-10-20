// SPDX-License-Identifier: GPL-2.0-or-later
// A 32-bit block RAM with byte enables, built as one sdp_ram per byte lane
// (Quartus 17 infers each lane as M10K; a byte-enable template can end up in
// registers): one write port, one registered read port, one clock. A read
// of the word being written returns the old data.
module bram32 #(
	parameter int AW = 10
) (
	input  logic          clk,
	input  logic          we,
	input  logic [3:0]    be,
	input  logic [AW-1:0] waddr,
	input  logic [31:0]   wdata,
	input  logic [AW-1:0] raddr,
	output logic [31:0]   rdata
);

	genvar i;
	generate
		for (i = 0; i < 4; i++) begin : g_lane
			sdp_ram #(.AW(AW), .DW(8)) lane (
				.clk(clk),
				.we(we && be[i]),
				.waddr(waddr),
				.wdata(wdata[8 * i +: 8]),
				.raddr(raddr),
				.rdata(rdata[8 * i +: 8])
			);
		end
	endgenerate

endmodule
