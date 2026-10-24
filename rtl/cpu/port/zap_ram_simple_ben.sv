// SPDX-License-Identifier: GPL-3.0-or-later
//
// ZAP's byte-enable RAM (rtl/cpu/zap/zap_ram_simple_ben.sv) rebuilt as one
// zap_ram_simple per byte lane. After sv2v, Quartus 17 does not infer the
// original as block RAM and builds the cache data arrays from flip-flops;
// one plain RAM per lane infers M10K. The behaviour is the same: a three-
// clock read with the write-collision bypass, worked out for each byte.
// tools/gen_cpu.sh uses this file in place of the original.
module zap_ram_simple_ben #(
	parameter logic [31:0] WIDTH = 32'd32,
	parameter logic [31:0] DEPTH = 32'd32,
	parameter logic SHORT_READ = 1'b0
) (
	input  logic                     i_clk,
	input  logic                     i_clken,
	input  logic [WIDTH/8-1:0]       i_wr_en,
	input  logic [WIDTH-1:0]         i_wr_data,
	input  logic [$clog2(DEPTH)-1:0] i_wr_addr,
	input  logic [$clog2(DEPTH)-1:0] i_rd_addr,
	output logic [WIDTH-1:0]         o_rd_data_pre,
	output logic [WIDTH-1:0]         o_rd_data
);

	for (genvar i = 0; i < WIDTH / 8; i++) begin : lane
		zap_ram_simple #(
			.WIDTH(32'd8),
			.DEPTH(DEPTH),
			.SHORT_READ(SHORT_READ)
		) u_lane (
			.i_clk         (i_clk),
			.i_clken       (i_clken),
			.i_wr_en       (i_wr_en[i]),
			.i_wr_data     (i_wr_data[i*8 +: 8]),
			.i_wr_addr     (i_wr_addr),
			.i_rd_addr     (i_rd_addr),
			.o_rd_data_pre (o_rd_data_pre[i*8 +: 8]),
			.o_rd_data     (o_rd_data[i*8 +: 8])
		);
	end

endmodule
