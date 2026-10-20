// SPDX-License-Identifier: GPL-2.0-or-later
//
// The N-Gage QD keys by their place in the 6-row x 5-column switch matrix:
// bit row * 5 + column of a key vector. Positions from the keyboard driver's
// matrix-to-scancode table in the firmware (ekeyb.dll table 3), which agrees
// with the RH-47 keypad schematic except that it has Clear at ROW0/COL3 and
// Edit at ROW1/COL3 (research/peripherals/INPUT.md section 3.2). The power
// key is not in the matrix: it goes to the UEMK.
//
//          COL0    COL1    COL2    COL3    COL4
//   ROW0   Up      Left    RSoft   Clear   Menu
//   ROW1   Down    Right   End     Edit    OK
//   ROW2   LSoft   -       1       6       8
//   ROW3   Call    -       5       7       #
//   ROW4   -       -       9       0       3
//   ROW5   -       -       *       2       4
package ngage_keys;

	localparam int ROWS = 6;
	localparam int COLS = 5;
	localparam int NKEYS = ROWS * COLS;

	localparam int K_UP    = 0;
	localparam int K_LEFT  = 1;
	localparam int K_RSOFT = 2;
	localparam int K_CLEAR = 3;
	localparam int K_MENU  = 4;
	localparam int K_DOWN  = 5;
	localparam int K_RIGHT = 6;
	localparam int K_END   = 7;
	localparam int K_EDIT  = 8;
	localparam int K_OK    = 9;
	localparam int K_LSOFT = 10;
	localparam int K_1     = 12;
	localparam int K_6     = 13;
	localparam int K_8     = 14;
	localparam int K_CALL  = 15;
	localparam int K_5     = 17;
	localparam int K_7     = 18;
	localparam int K_HASH  = 19;
	localparam int K_9     = 22;
	localparam int K_0     = 23;
	localparam int K_3     = 24;
	localparam int K_STAR  = 27;
	localparam int K_2     = 28;
	localparam int K_4     = 29;

	// the 24 positions that have a switch
	localparam logic [NKEYS-1:0] FITTED = 30'b111_00_111_00_111_01_111_01_11111_11111;

endpackage
