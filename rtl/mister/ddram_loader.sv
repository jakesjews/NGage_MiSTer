// SPDX-License-Identifier: GPL-2.0-or-later
//
// F3 loads CS0. F4 loads CS1 followed by CS2 for NEM-4. The ROM lengths
// select the flash layout. Keep the CPU in reset until both lengths agree.
module ddram_loader #(
	parameter logic [28:0] CS0_BASE = 29'h0620_0000,   // 0x31000000 / 8
	parameter logic [28:0] CS1_BASE = 29'h0640_0000    // 0x32000000 / 8
) (
	input  logic        clk,
	input  logic        reset,

	input  logic        ioctl_download,
	input  logic [15:0] ioctl_index,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,
	input  logic [15:0] ioctl_dout,
	output logic        ioctl_wait,
	input  logic        preserve_c,
	output logic        size_error = 1'b0,

	input  logic        ddram_busy,
	output logic  [7:0] ddram_burstcnt,
	output logic [28:0] ddram_addr,
	output logic [63:0] ddram_din,
	output logic  [7:0] ddram_be,
	output logic        ddram_we,
	output logic        ddram_rd,

	output logic  [1:0] loaded,
	output logic        profile_match,
	output logic        nem4
);
	localparam logic [26:0] CHIP_BYTES = 27'h080_0000;
	wire is_cs0 = ioctl_index[5:0] == 6'd3;
	wire is_cs1 = ioctl_index[5:0] == 6'd4;
	wire in_range = ioctl_addr < (CHIP_BYTES << 1);
	wire protected_word = is_cs1 && preserve_c &&
	                      ioctl_addr >= (CHIP_BYTES >> 1) && ioctl_addr < CHIP_BYTES;

	logic dl_q, too_large;
	logic [1:0] chip;
	logic [26:0] last_addr;
	logic second_pair;

	wire one_chip = last_addr == CHIP_BYTES - 27'd2;
	wire two_chips = last_addr == (CHIP_BYTES << 1) - 27'd2;
	assign profile_match = nem4 == second_pair;

	assign ddram_burstcnt = 8'd1;
	assign ddram_rd = 1'b0;
	assign ioctl_wait = ddram_we;

	always_ff @(posedge clk) begin
		dl_q <= ioctl_download;
		size_error <= 1'b0;
		if (ddram_we && !ddram_busy) ddram_we <= 1'b0;

		if (ioctl_download && !dl_q) begin
			chip <= {is_cs1, is_cs0};
			loaded <= loaded & ~{is_cs1, is_cs0};
			last_addr <= '1;
			too_large <= 1'b0;
		end
		if (ioctl_download && ioctl_wr) begin
			last_addr <= ioctl_addr;
			if (!in_range) too_large <= 1'b1;
			if (in_range && !protected_word) begin
				ddram_we   <= 1'b1;
				ddram_addr <= (is_cs0 ? CS0_BASE : CS1_BASE) + {5'd0, ioctl_addr[26:3]};
				ddram_din  <= {4{ioctl_dout}};
				ddram_be   <= 8'b11 << {ioctl_addr[2:1], 1'b0};
			end
		end
		if (!ioctl_download && dl_q) begin
			if (!too_large && (one_chip || two_chips)) begin
				loaded <= loaded | chip;
				if (chip[0]) begin
					nem4 <= one_chip;
					size_error <= loaded[1] && one_chip != second_pair;
				end else begin
					second_pair <= two_chips;
					size_error <= loaded[0] && nem4 != two_chips;
				end
			end else size_error <= 1'b1;
		end

		if (reset) begin
			ddram_we <= 1'b0;
			loaded <= 2'b00;
			nem4 <= 1'b0;
			second_pair <= 1'b0;
			dl_q <= 1'b0;
		end
	end
endmodule
