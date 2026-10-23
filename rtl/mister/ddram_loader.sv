// SPDX-License-Identifier: GPL-2.0-or-later
//
// The NOR flash images, loaded from the OSD (hps_io ioctl, WIDE = 1), into
// DDR3 through the framework's DDRAM port, where the flash models' memory
// ports will read them.
//
// Development ioctl_index 3 is CS0 (16 MB), 4 is CS1 (8 MB). They go to
// ARM addresses 0x31000000 and 0x32000000, in the 0x30000000 block that
// MiSTer cores use and Linux does not (research/hps-hybrid/MISTER-DDR3-MAP.md);
// the SDRAM image the guest will use sits below at 0x30000000. Bytes past a
// chip's size are dropped. Each 16-bit word is one DDR3 write with two byte
// lanes enabled; ioctl_wait holds the HPS while a write waits for the port.
// loaded[n] is set when a whole download for chip n has finished and
// cleared when a new one starts.
module ddram_loader #(
	parameter logic [28:0] CS0_BASE  = 29'h0620_0000,   // 0x31000000 / 8
	parameter logic [28:0] CS1_BASE  = 29'h0640_0000,   // 0x32000000 / 8
	parameter int          CS0_BYTES = 16 << 20,
	parameter int          CS1_BYTES = 8 << 20
) (
	input  logic        clk,
	input  logic        reset,

	input  logic        ioctl_download,
	input  logic [15:0] ioctl_index,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,
	input  logic [15:0] ioctl_dout,
	output logic        ioctl_wait,

	input  logic        ddram_busy,
	output logic  [7:0] ddram_burstcnt,
	output logic [28:0] ddram_addr,
	output logic [63:0] ddram_din,
	output logic  [7:0] ddram_be,
	output logic        ddram_we,
	output logic        ddram_rd,

	output logic  [1:0] loaded
);

	wire is_cs0 = ioctl_index[5:0] == 6'd3;
	wire is_cs1 = ioctl_index[5:0] == 6'd4;
	wire in_range = (is_cs0 && {5'd0, ioctl_addr} < CS0_BYTES) || (is_cs1 && {5'd0, ioctl_addr} < CS1_BYTES);

	logic dl_q;

	assign ddram_burstcnt = 8'd1;
	assign ddram_rd = 1'b0;
	assign ioctl_wait = ddram_we;

	always_ff @(posedge clk) begin
		dl_q <= ioctl_download;
		if (ddram_we && !ddram_busy) ddram_we <= 1'b0;

		if (ioctl_download && ioctl_wr && in_range) begin
			ddram_we   <= 1'b1;
			ddram_addr <= (is_cs0 ? CS0_BASE : CS1_BASE) + {5'd0, ioctl_addr[26:3]};
			ddram_din  <= {4{ioctl_dout}};
			ddram_be   <= 8'b11 << {ioctl_addr[2:1], 1'b0};
		end

		if (ioctl_download && !dl_q) begin
			if (is_cs0) loaded[0] <= 1'b0;
			if (is_cs1) loaded[1] <= 1'b0;
		end
		if (!ioctl_download && dl_q) begin
			if (is_cs0) loaded[0] <= 1'b1;
			if (is_cs1) loaded[1] <= 1'b1;
		end

		if (reset) begin
			ddram_we <= 1'b0;
			loaded   <= 2'b00;
		end
	end

endmodule
