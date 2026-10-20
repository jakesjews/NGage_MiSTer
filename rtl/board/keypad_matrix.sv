// SPDX-License-Identifier: GPL-2.0-or-later
//
// The N-Gage QD keypad: a plain 6-row x 5-column switch matrix on UPP_WD2
// GPIOs (rows GPIO12-15,17,18; columns GPIO8-11,16), scanned by software,
// and the power key, which is wired to the UEMK's PWRONX instead.
//
// Given what the ASIC drives on each line, the module returns the level each
// line has, as the switches make it. A pressed key joins its row and its
// column; the lines joined through pressed keys form one net, so several keys
// held together show the same ghost keys the real matrix does. A net is low
// when any line in it is driven low, otherwise high: driven high or pulled up
// (the firmware reads the lines active-low, research/peripherals/INPUT.md
// section 3.1). A line driven high against a low one reads low [assumed: the
// columns have 100 ohm series resistors on the keypad board, and which side
// wins a fight is not documented].
//
// The firmware drives columns and reads rows; rows may be driven too, for a
// scan the other way round. From the drive to the levels the path is
// combinational, as through the switches. Which lines are joined depends only
// on the keys, and is worked out in registers, one step of a path a clock: a
// change of the keys has reached every line of a net ten clocks later (a
// tenth of a microsecond, against key presses of tens of milliseconds).
//
// keys: bit row * 5 + column (ngage_keys); positions without a switch are
// ignored.
module keypad_matrix (
	input  logic                         clk,
	input  logic [ngage_keys::NKEYS-1:0] keys,
	input  logic                         power,

	input  logic [ngage_keys::COLS-1:0]  col_oe,
	input  logic [ngage_keys::COLS-1:0]  col_out,
	input  logic [ngage_keys::ROWS-1:0]  row_oe,
	input  logic [ngage_keys::ROWS-1:0]  row_out,

	output logic [ngage_keys::COLS-1:0]  col_in,
	output logic [ngage_keys::ROWS-1:0]  row_in,

	// to the UEMK: low while the power key is held
	output logic                         pwronx
);

	import ngage_keys::*;

	// lines 0-4 are the columns, 5-10 the rows
	localparam int N = COLS + ROWS;

	logic [NKEYS-1:0] k;
	// all ones never matches the fitted keys, so the first clock loads the joins
	logic [NKEYS-1:0] k_q = '1;
	logic [N-1:0]     adj   [0:N-1];   // joined by one pressed key
	logic [N-1:0]     reach [0:N-1];   // joined by a path of pressed keys

	assign k = keys & FITTED;

	always_comb begin
		for (int i = 0; i < N; i++) adj[i] = '0;
		for (int r = 0; r < ROWS; r++)
			for (int c = 0; c < COLS; c++)
				if (k[r * COLS + c]) begin
					adj[c][COLS + r] = 1'b1;
					adj[COLS + r][c] = 1'b1;
				end
	end

	// the joins, a step longer each clock; started again when the keys change
	always_ff @(posedge clk) begin
		k_q <= k;
		for (int i = 0; i < N; i++) begin
			if (k != k_q) begin
				reach[i] <= adj[i];
			end else begin
				logic [N-1:0] next;
				next = reach[i];
				for (int j = 0; j < N; j++) if (reach[i][j]) next = next | adj[j];
				reach[i] <= next;
			end
		end
	end

	logic [N-1:0] drv_low, low;
	assign drv_low = {row_oe & ~row_out, col_oe & ~col_out};

	always_comb begin
		for (int i = 0; i < N; i++) low[i] = drv_low[i] | |(reach[i] & drv_low);
	end

	assign col_in = ~low[COLS-1:0];
	assign row_in = ~low[N-1:COLS];
	assign pwronx = ~power;

endmodule
