// SPDX-License-Identifier: GPL-2.0-or-later
//
// A stand-in for the CPU until there is one: it drives the display module's
// 8080 bus the way the firmware does and scans the keypad matrix the way the
// keyboard driver does, so the panel, the video output, the input mapping
// and the matrix can be seen working on a MiSTer.
//
// After /RES it sends SLPOUT, COLMOD 3 (12 bpp), the RGBSET table, MADCTL
// 0xD4, DISPON and NORON, and writes a whole picture (pattern() below):
// a red marker at the top-left, a white border, colour bars, a gradient and,
// in the bottom third, one box for each key of the matrix laid out as the
// matrix is (ROW0 at the top, COL0 at the left), with the power key in the
// empty ROW4/COL0 place. Then it scans: each column driven low in turn, the
// rows read; every key whose state differs from its box is redrawn through
// a CASET/PASET window, pressed keys yellow (power red).
module lcd_testgen #(
	parameter int RESET_CLKS  = 1040,     // /RES low, 10 us at 104 MHz
	parameter int WAKE_CLKS   = 10400,    // after /RES and SLPOUT, 100 us
	parameter int SETTLE_CLKS = 32        // a driven column before the rows are read
) (
	input  logic       clk,
	input  logic       reset,

	output logic       csx,
	output logic       dcx,
	output logic       wrx,
	output logic       rdx,
	output logic       resx,
	output logic [7:0] d,

	output logic [4:0] col_oe,
	output logic [4:0] col_out,
	input  logic [5:0] row_in,
	input  logic       pwronx
);

	import ngage_keys::*;

	localparam int K_POWER = 20;          // the empty ROW4/COL0 place

	// ------------------------------------------------------------------
	// The picture
	// ------------------------------------------------------------------
	function automatic logic [11:0] pattern(input logic [7:0] x, input logic [7:0] y,
			input logic [NKEYS-1:0] st);
		logic [9:0]  x3;
		logic [2:0]  bar;
		logic [3:0]  r4, g4;
		logic [2:0]  c, r;
		logic        hc, hr;
		logic [4:0]  k;
		x3 = {2'b00, x} + {1'b0, x, 1'b0};
		if (x < 8'd8 && y < 8'd8) return 12'hF00;
		if (x == 8'd0 || y == 8'd0 || x == 8'd175 || y == 8'd207) return 12'hFFF;
		if (y < 8'd64) begin
			bar = (x3[9:6] > 4'd7) ? 3'd7 : x3[8:6];
			case (bar)
				3'd0: return 12'hFFF;
				3'd1: return 12'hFF0;
				3'd2: return 12'h0FF;
				3'd3: return 12'h0F0;
				3'd4: return 12'hF0F;
				3'd5: return 12'hF00;
				3'd6: return 12'h00F;
				default: return 12'h000;
			endcase
		end
		if (y < 8'd128) begin
			r4 = (x3[9:5] > 5'd15) ? 4'd15 : x3[8:5];
			g4 = 4'((y - 8'd64) >> 2);
			return {r4, g4, 4'h8};
		end
		// key boxes: 28x10 at x = 8 + 34c, y = 132 + 12r
		hc = 1'b1;
		if      (x >= 8'd8   && x < 8'd36)  c = 3'd0;
		else if (x >= 8'd42  && x < 8'd70)  c = 3'd1;
		else if (x >= 8'd76  && x < 8'd104) c = 3'd2;
		else if (x >= 8'd110 && x < 8'd138) c = 3'd3;
		else if (x >= 8'd144 && x < 8'd172) c = 3'd4;
		else begin c = 3'd0; hc = 1'b0; end
		hr = 1'b1;
		if      (y >= 8'd132 && y < 8'd142) r = 3'd0;
		else if (y >= 8'd144 && y < 8'd154) r = 3'd1;
		else if (y >= 8'd156 && y < 8'd166) r = 3'd2;
		else if (y >= 8'd168 && y < 8'd178) r = 3'd3;
		else if (y >= 8'd180 && y < 8'd190) r = 3'd4;
		else if (y >= 8'd192 && y < 8'd202) r = 3'd5;
		else begin r = 3'd0; hr = 1'b0; end
		k = 5'({2'b00, r} * 3'd5) + {2'b00, c};
		if (hc && hr) begin
			if (k == 5'(K_POWER)) return st[k] ? 12'hF00 : 12'h400;
			if (FITTED[k]) return st[k] ? 12'hFF0 : 12'h226;
		end
		return 12'h222;
	endfunction

	// the box of key k
	function automatic logic [31:0] box(input logic [4:0] k);
		logic [7:0] x0, y0;
		logic [2:0] r, c;
		r = (k >= 5'd25) ? 3'd5 : (k >= 5'd20) ? 3'd4 : (k >= 5'd15) ? 3'd3 :
			(k >= 5'd10) ? 3'd2 : (k >= 5'd5) ? 3'd1 : 3'd0;
		c = 3'(k - 5'({2'b00, r} * 3'd5));
		x0 = 8'd8 + 8'({5'd0, c} * 8'd34);
		y0 = 8'd132 + 8'({5'd0, r} * 8'd12);
		return {x0, x0 + 8'd27, y0, y0 + 8'd9};
	endfunction

	// start-up bytes: {D/CX, byte}
	function automatic logic [8:0] init_byte(input logic [5:0] i);
		logic [5:0] j;
		j = i - 6'd4;
		case (i)
			6'd0: return {1'b0, 8'h11};        // SLPOUT
			6'd1: return {1'b0, 8'h3A};        // COLMOD
			6'd2: return {1'b1, 8'h03};        // 12 bpp
			6'd3: return {1'b0, 8'h2D};        // RGBSET
			6'd52: return {1'b0, 8'h36};       // MADCTL
			6'd53: return {1'b1, 8'hD4};
			6'd54: return {1'b0, 8'h29};       // DISPON
			6'd55: return {1'b0, 8'h13};       // NORON
			default: begin
				// the RGBSET table: 4-bit levels to 5/6/5 bits
				if (j < 6'd16)      return {1'b1, 3'd0, (j[3:0] == 4'd15) ? 5'd31 : {j[3:0], 1'b0}};
				else if (j < 6'd32) return {1'b1, 2'd0, (j[3:0] == 4'd15) ? 6'd63 : {j[3:0], 2'b00}};
				else                return {1'b1, 3'd0, (j[3:0] == 4'd15) ? 5'd31 : {j[3:0], 1'b0}};
			end
		endcase
	endfunction

	localparam int INIT_LEN = 56;

	// ------------------------------------------------------------------
	// Sequencer
	// ------------------------------------------------------------------
	localparam logic [3:0] S_RES   = 4'd0;
	localparam logic [3:0] S_WAKE  = 4'd1;
	localparam logic [3:0] S_INIT  = 4'd2;
	localparam logic [3:0] S_SLEEP = 4'd3;
	localparam logic [3:0] S_WIN   = 4'd4;
	localparam logic [3:0] S_PIX   = 4'd5;
	localparam logic [3:0] S_SCAN  = 4'd6;
	localparam logic [3:0] S_DIFF  = 4'd7;

	logic  [3:0] s;
	logic [15:0] wait_n;
	logic  [5:0] idx;
	logic  [1:0] slot;                 // four clocks a byte
	logic  [7:0] x0, x1, y0, y1, px, py;
	logic  [1:0] ph;                   // byte of a pixel pair
	logic [11:0] p1, p2;
	logic [NKEYS-1:0] drawn, seen;
	logic  [2:0] col;
	logic  [4:0] k;

	// the byte of the window command: CASET x0..x1, PASET y0..y1, RAMWR
	logic [8:0] win_byte;
	always_comb begin
		case (idx[3:0])
			4'd0:  win_byte = {1'b0, 8'h2A};
			4'd2:  win_byte = {1'b1, x0};
			4'd4:  win_byte = {1'b1, x1};
			4'd5:  win_byte = {1'b0, 8'h2B};
			4'd7:  win_byte = {1'b1, y0};
			4'd9:  win_byte = {1'b1, y1};
			4'd10: win_byte = {1'b0, 8'h2C};
			default: win_byte = {1'b1, 8'h00};   // the high bytes
		endcase
	end

	wire [11:0] pat_a = pattern(px, py, drawn);
	wire [11:0] pat_b = pattern(px + 8'd1, py, drawn);
	wire [31:0] kbox  = box(k);

	// put a byte on the bus in this four-clock slot
	task automatic put(input logic [8:0] b);
		dcx <= b[8];
		d   <= b[7:0];
		wrx <= 1'b0;
	endtask

	assign rdx = 1'b1;

	always_ff @(posedge clk) begin
		slot <= slot + 2'd1;
		if (slot == 2'd2) wrx <= 1'b1;
		if (reset) begin
			s       <= S_RES;
			wait_n  <= 16'(RESET_CLKS);
			resx    <= 1'b0;
			csx     <= 1'b1;
			wrx     <= 1'b1;
			dcx     <= 1'b1;
			d       <= 8'd0;
			slot    <= 2'd0;
			col_oe  <= 5'd0;
			col_out <= 5'd0;
			drawn   <= '0;
		end else begin
			case (s)
				S_RES: begin
					if (wait_n == 16'd0) begin
						resx   <= 1'b1;
						wait_n <= 16'(WAKE_CLKS);
						s      <= S_WAKE;
					end else wait_n <= wait_n - 16'd1;
				end
				S_WAKE: begin
					if (wait_n == 16'd0 && slot == 2'd3) begin
						csx <= 1'b0;
						idx <= 6'd0;
						s   <= S_INIT;
					end else if (wait_n != 16'd0) wait_n <= wait_n - 16'd1;
				end
				S_INIT: if (slot == 2'd3) begin
					put(init_byte(idx));
					idx <= idx + 6'd1;
					if (idx == 6'd0) begin
						// SLPOUT: wait before the rest
						wait_n <= 16'(WAKE_CLKS);
						s      <= S_SLEEP;
					end else if (idx == 6'(INIT_LEN - 1)) begin
						x0  <= 8'd0;   x1 <= 8'd175;
						y0  <= 8'd0;   y1 <= 8'd207;
						idx <= 6'd0;
						s   <= S_WIN;
					end
				end
				S_SLEEP: begin
					if (wait_n == 16'd0 && slot == 2'd3) s <= S_INIT;
					else if (wait_n != 16'd0) wait_n <= wait_n - 16'd1;
				end
				S_WIN: if (slot == 2'd3) begin
					put(win_byte);
					idx <= idx + 6'd1;
					if (idx == 6'd10) begin
						px <= x0;
						py <= y0;
						ph <= 2'd0;
						s  <= S_PIX;
					end
				end
				S_PIX: begin
					if (slot == 2'd2 && ph == 2'd0) begin
						p1 <= pat_a;
						p2 <= pat_b;
					end
					if (slot == 2'd3) begin
						case (ph)
							2'd0: put({1'b1, p1[11:4]});
							2'd1: put({1'b1, p1[3:0], p2[11:8]});
							default: put({1'b1, p2[7:0]});
						endcase
						ph <= (ph == 2'd2) ? 2'd0 : ph + 2'd1;
						if (ph == 2'd2) begin
							if (px + 8'd2 > x1) begin
								px <= x0;
								if (py == y1) begin
									col    <= 3'd0;
									wait_n <= 16'(SETTLE_CLKS);
									s      <= S_SCAN;
								end else py <= py + 8'd1;
							end else px <= px + 8'd2;
						end
					end
				end
				S_SCAN: begin
					// each column low in turn, the others released
					col_oe  <= 5'd1 << col;
					col_out <= 5'd0;
					if (wait_n != 16'd0) begin
						wait_n <= wait_n - 16'd1;
					end else begin
						for (int r = 0; r < ROWS; r++) seen[r * COLS + int'(col)] <= ~row_in[r];
						wait_n <= 16'(SETTLE_CLKS);
						if (col == 3'd4) begin
							col_oe <= 5'd0;
							k      <= 5'd0;
							s      <= S_DIFF;
						end else col <= col + 3'd1;
					end
				end
				S_DIFF: begin
					// the power key in its place; then the first key whose box is out of date
					seen[K_POWER] <= ~pwronx;
					if ((FITTED[k] || k == 5'(K_POWER)) &&
							((k == 5'(K_POWER)) ? (~pwronx != drawn[k]) : (seen[k] != drawn[k]))) begin
						drawn[k] <= (k == 5'(K_POWER)) ? ~pwronx : seen[k];
						{x0, x1, y0, y1} <= kbox;
						idx <= 6'd0;
						s   <= S_WIN;
					end else if (k == 5'(NKEYS - 1)) begin
						col    <= 3'd0;
						wait_n <= 16'(SETTLE_CLKS);
						s      <= S_SCAN;
					end else k <= k + 5'd1;
				end
				default: s <= S_RES;
			endcase
		end
	end

endmodule
