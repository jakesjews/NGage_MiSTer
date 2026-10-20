// SPDX-License-Identifier: GPL-2.0-or-later
//
// MiSTer controls to N-Gage QD keys: a key vector for keypad_matrix
// (ngage_keys positions) and the power key.
//
// Joystick (both of the first two pads), in the order of CONF_STR's J1 line:
//   d-pad = rocker; 4: 5, 5: 7 (the game keys); 6: OK; 7: left soft key;
//   8: right soft key; 9: Menu; 10: Call; 11: End; 12: *; 13: #; 14: Clear;
//   15: Edit; 16: Power.
// Keyboard (PS/2 set 2 codes from hps_io):
//   arrows: rocker            Enter, keypad Enter, Space: OK
//   0-9 and keypad 0-9: 0-9   Z: 5   X: 7
//   keypad * or -: *          keypad / or =: #
//   F1 / F2: left / right soft key      F3: Call   F4: End
//   F5 or Home: Menu          Backspace or Delete: Clear
//   left Shift: Edit          F8: Power
module ngage_input (
	input  logic                         clk,
	input  logic                         reset,
	input  logic [31:0]                  joy0,
	input  logic [31:0]                  joy1,
	input  logic [10:0]                  ps2_key,
	output logic [ngage_keys::NKEYS-1:0] keys,
	output logic                         power
);

	import ngage_keys::*;

	logic [NKEYS-1:0] kb;
	logic             kb_power;
	logic             toggle_q;

	wire        ev    = ps2_key[10] != toggle_q;
	wire        down  = ps2_key[9];
	wire        ext   = ps2_key[8];
	wire  [7:0] code  = ps2_key[7:0];

	always_ff @(posedge clk) begin
		toggle_q <= ps2_key[10];
		if (reset) begin
			kb       <= '0;
			kb_power <= 1'b0;
		end else if (ev) begin
			if (ext) begin
				case (code)
					8'h75: kb[K_UP]    <= down;
					8'h72: kb[K_DOWN]  <= down;
					8'h6B: kb[K_LEFT]  <= down;
					8'h74: kb[K_RIGHT] <= down;
					8'h5A: kb[K_OK]    <= down;   // keypad Enter
					8'h4A: kb[K_HASH]  <= down;   // keypad /
					8'h6C: kb[K_MENU]  <= down;   // Home
					8'h71: kb[K_CLEAR] <= down;   // Delete
					default: ;
				endcase
			end else begin
				case (code)
					8'h5A, 8'h29: kb[K_OK] <= down;   // Enter, Space
					8'h45, 8'h70: kb[K_0]  <= down;
					8'h16, 8'h69: kb[K_1]  <= down;
					8'h1E, 8'h72: kb[K_2]  <= down;
					8'h26, 8'h7A: kb[K_3]  <= down;
					8'h25, 8'h6B: kb[K_4]  <= down;
					8'h2E, 8'h73, 8'h1A: kb[K_5] <= down;   // 5, keypad 5, Z
					8'h36, 8'h74: kb[K_6]  <= down;
					8'h3D, 8'h6C, 8'h22: kb[K_7] <= down;   // 7, keypad 7, X
					8'h3E, 8'h75: kb[K_8]  <= down;
					8'h46, 8'h7D: kb[K_9]  <= down;
					8'h7C, 8'h7B: kb[K_STAR] <= down;       // keypad * and -
					8'h55: kb[K_HASH]  <= down;             // =
					8'h05: kb[K_LSOFT] <= down;             // F1
					8'h06: kb[K_RSOFT] <= down;             // F2
					8'h04: kb[K_CALL]  <= down;             // F3
					8'h0C: kb[K_END]   <= down;             // F4
					8'h03: kb[K_MENU]  <= down;             // F5
					8'h66: kb[K_CLEAR] <= down;             // Backspace
					8'h12: kb[K_EDIT]  <= down;             // left Shift
					8'h0A: kb_power    <= down;             // F8
					default: ;
				endcase
			end
		end
	end

	wire [31:0] j = joy0 | joy1;
	logic [NKEYS-1:0] jk;
	always_comb begin
		jk = '0;
		jk[K_RIGHT] = j[0];
		jk[K_LEFT]  = j[1];
		jk[K_DOWN]  = j[2];
		jk[K_UP]    = j[3];
		jk[K_5]     = j[4];
		jk[K_7]     = j[5];
		jk[K_OK]    = j[6];
		jk[K_LSOFT] = j[7];
		jk[K_RSOFT] = j[8];
		jk[K_MENU]  = j[9];
		jk[K_CALL]  = j[10];
		jk[K_END]   = j[11];
		jk[K_STAR]  = j[12];
		jk[K_HASH]  = j[13];
		jk[K_CLEAR] = j[14];
		jk[K_EDIT]  = j[15];
	end

	always_ff @(posedge clk) begin
		keys  <= kb | jk;
		power <= kb_power | j[16];
	end

endmodule
