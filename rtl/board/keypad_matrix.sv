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
// scan the other way round. The paths are combinational, as through the
// switches; register them on the ASIC side.
//
// keys: bit row * 5 + column (ngage_keys); positions without a switch are
// ignored.
module keypad_matrix (
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

	logic [NKEYS-1:0] k;
	logic [COLS-1:0]  col_low;
	logic [ROWS-1:0]  row_low;

	assign k = keys & FITTED;

	// Spread "low" through the pressed keys. A path between two lines visits
	// each of the 11 lines at most once, so it has at most 10 steps; each
	// pass below takes a step from the columns to the rows and one back, and
	// a path that starts on a row gains nothing from the first half-pass.
	always_comb begin
		col_low = col_oe & ~col_out;
		row_low = row_oe & ~row_out;
		for (int pass = 0; pass < 6; pass++) begin
			for (int r = 0; r < ROWS; r++)
				for (int c = 0; c < COLS; c++)
					if (k[r * COLS + c] && col_low[c]) row_low[r] = 1'b1;
			for (int c = 0; c < COLS; c++)
				for (int r = 0; r < ROWS; r++)
					if (k[r * COLS + c] && row_low[r]) col_low[c] = 1'b1;
		end
	end

	assign col_in = ~col_low;
	assign row_in = ~row_low;
	assign pwronx = ~power;

endmodule
