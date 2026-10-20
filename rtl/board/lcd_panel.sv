// SPDX-License-Identifier: GPL-2.0-or-later
//
// The N-Gage QD display module (Nokia 4850819, "GD82"): a controller with its
// own 176x208 RGB565 frame memory on an 8-bit 8080 bus (D[7:0], D/CX, /WR,
// /RD, /CS, /RES) with a tearing-effect output. The controller IC is not
// identified; the command set is the MIPI-DCS-style one the firmware's lcd.ldd
// and boot code send (research/peripherals/DISPLAY.md section 4), checked
// against the MC2PA8201 and ST7637 datasheets for details lcd.ldd does not
// show.
//
// Bus: a byte is taken on the rising edge of /WR while /CS is low; D/CX low
// marks a command, high a parameter or pixel byte. A read returns a byte while
// /RD is low and steps on to the next on its rising edge. All bus inputs are
// sampled in clk, so a host in another clock domain must synchronise them, and
// /WR and /RD must each stay low and high for at least one clock. During RAMRD
// the next pixel is fetched after the second byte of a pixel has been read;
// /RD must then stay high for at least five clocks.
//
// Commands:
//   00 NOP, 01 SWRESET, 04 RDDID (dummy + 3 ID bytes), 09 RDDST (dummy + 4),
//   0A RDDPM, 0B RDDMADCTL, 0C RDDCOLMOD, 0D RDDIM, 0E RDDSM, 0F RDDSDR,
//   10/11 SLPIN/SLPOUT, 12 PTLON, 13 NORON, 20/21 INVOFF/INVON, 26 GAMSET,
//   28/29 DISPOFF/DISPON, 2A CASET, 2B PASET, 2C RAMWR, 2D RGBSET (48 bytes),
//   2E RAMRD (dummy, then 2 bytes a pixel), 30 PTLAR, 33 VSCRDEF, 34/35
//   TEOFF/TEON, 36 MADCTL, 37 VSCRSADD, 38/39 IDMOFF/IDMON, 3A COLMOD,
//   DA/DB/DC RDID1-3, and 24 with one parameter, which lcd.ldd sends but no
//   datasheet defines: it is taken and ignored. Every other opcode, and any
//   parameter past the ones a command takes, is a no-op.
//
// Pixel formats (COLMOD[2:0]): 3 = 12 bpp, two pixels in three bytes
// [R1G1][B1R2][G2B2], each 4-bit component expanded through the RGBSET table
// (16 R 5-bit, 16 G 6-bit, 16 B 5-bit, ST7637 layout); 6 = 18 bpp, one byte a
// component in bits 7:2; any other value = 16 bpp, [R5 G6hi][G6lo B5].
//
// Scan-out: a second read port gives the picture as the viewer sees it. A
// request on scan_en with viewer coordinates (0..175, 0..207, top-left first)
// returns the RGB565 pixel on scan_rgb four clocks later, where it stays
// until the next result. Display state is applied here: sleep and DISPOFF
// blank the picture, partial mode blanks the lines outside PTLAR, inversion
// and idle (8-colour) mode change the pixel, BGR swaps red and blue, and the
// vertical scroll area maps display lines to memory lines.
//
// Facts the research leaves open, each behind a parameter and marked [assumed]:
//   * PANEL_ROT180: the module is mounted rotated 180 degrees to its
//     controller's memory. lcd.ldd draws with MADCTL 0xD4 (MY, MX, ML, MH) on
//     one module variant and with MADCTL 0x00 plus coordinates mirrored in
//     software (175-x, 207-y) on the other; both put the logical pixel (x, y)
//     at memory (175-x, 207-y), and in the DCS command set ML and MH change
//     only the refresh order. Both variants come out upright only if memory
//     (175-x, 207-y) is at the viewer's (x, y).
//   * TE timing: the panel refreshes itself at TE_HZ (74 Hz, measured on the
//     N70 module) over 208 + TE_VBLANK_LINES lines; TE is high in the blank
//     lines (TEON mode 0) and also for TE_HPULSE_CLKS at each line (mode 1).
//     te_ext_sel = 1 makes TE follow te_ext instead (for example the video
//     output's vertical blank).
//   * ID1-ID3, the RDDID / RDID1-3 bytes.
//   * BLANK_RGB (sleep, DISPOFF) and PARTIAL_RGB (outside the partial area).
//   * COLMOD_RESET, the pixel format after reset.
//   * RAMRD returns 16 bpp whatever COLMOD says (as the ST7637, whose frame
//     memory is also 16-bit).
//   * ML, MH and the scroll area: TFA is counted from the top of memory
//     whatever ML says.
// Reset (reset input or /RES low) sets every register to its default and
// loads the default RGBSET table; SWRESET does the same but keeps the table.
// Neither clears the frame memory. Power-on and sleep-out delays are not
// modelled: commands are taken at once.
module lcd_panel #(
	parameter int          CLK_HZ          = 104_000_000,
	parameter int          TE_HZ           = 74,
	parameter int          TE_VBLANK_LINES = 12,
	parameter int          TE_HPULSE_CLKS  = 64,
	parameter logic [7:0]  ID1             = 8'h00,
	parameter logic [7:0]  ID2             = 8'h80,
	parameter logic [7:0]  ID3             = 8'h00,
	parameter bit          PANEL_ROT180    = 1'b1,
	parameter logic [15:0] BLANK_RGB       = 16'h0000,
	parameter logic [15:0] PARTIAL_RGB     = 16'h0000,
	parameter logic [7:0]  COLMOD_RESET    = 8'h05
) (
	input  logic        clk,
	input  logic        reset,

	// 8080 bus from the ASIC
	input  logic        csx,
	input  logic        dcx,
	input  logic        wrx,
	input  logic        rdx,
	input  logic        resx,
	input  logic  [7:0] d_i,
	output logic  [7:0] d_o,
	output logic        d_oe,
	output logic        te,

	// TE source: 0 = the panel's own refresh, 1 = te_ext
	input  logic        te_ext_sel,
	input  logic        te_ext,

	// scan-out port, viewer coordinates
	input  logic        scan_en,
	input  logic  [7:0] scan_x,
	input  logic  [7:0] scan_y,
	output logic [15:0] scan_rgb,

	output logic        display_on
);

	localparam int W = 176;
	localparam int H = 208;
	localparam int TE_LINES = H + TE_VBLANK_LINES;
	// clocks a panel line lasts (at least 2, so that slow test clocks work)
	localparam int TE_LINE_CLKS = (CLK_HZ / (TE_HZ * TE_LINES) < 2) ? 2 : CLK_HZ / (TE_HZ * TE_LINES);

	localparam logic [1:0] RD_NONE = 2'd0;
	localparam logic [1:0] RD_REG  = 2'd1;
	localparam logic [1:0] RD_RAM  = 2'd2;

	wire hw_rst = reset | ~resx;

	// ------------------------------------------------------------------
	// Bus sampling
	// ------------------------------------------------------------------
	logic       wrx_q, rdx_q, csx_q;
	logic       dcx_l;
	logic [7:0] d_l;

	always_ff @(posedge clk) begin
		wrx_q <= wrx;
		rdx_q <= rdx;
		csx_q <= csx;
		// the byte and D/CX as they were while /WR was low
		if (!wrx) begin
			d_l   <= d_i;
			dcx_l <= dcx;
		end
	end

	wire wr_ev   = ~hw_rst & ~csx_q & ~wrx_q & wrx;
	wire rd_rise = ~hw_rst & ~csx_q & ~rdx_q & rdx;
	wire cmd_ev  = wr_ev & ~dcx_l;
	wire par_ev  = wr_ev & dcx_l;

	// ------------------------------------------------------------------
	// Registers
	// ------------------------------------------------------------------
	logic  [7:0] cmd;
	logic  [5:0] pidx;
	logic        sleep, disp, inv, idle, ptl, scroll, te_on, te_mode;
	logic  [1:0] gamma;
	logic  [7:0] madctl, colmod;
	logic [15:0] xs, xe, ys, ye;
	logic [15:0] sr, er, tfa, vsa, bfa, ssa;
	logic  [4:0] lut_r [0:15];
	logic  [5:0] lut_g [0:15];
	logic  [4:0] lut_b [0:15];

	wire my  = madctl[7];
	wire mx  = madctl[6];
	wire mv  = madctl[5];
	wire ml  = madctl[4];
	wire bgr = madctl[3];
	wire mh  = madctl[2];

	// address counters shared by RAMWR and RAMRD
	logic [15:0] cc, pc;
	// pixel assembly
	logic  [1:0] pph;
	logic  [7:0] b0, b1;
	// write pipeline
	logic        pix_v;
	logic [15:0] pix_rgb, pix_c, pix_p;
	logic        w_v;
	logic  [7:0] w_row, w_col;
	logic [15:0] w_rgb;
	// read side
	logic  [1:0] rd_kind;
	logic  [2:0] rd_idx;
	logic        rd_lo;
	logic [15:0] rd_pix;
	logic        rr_start, rr_req, rr_ok, rr_inflight;
	logic [15:0] rr_addr;

	wire [2:0] fmt = colmod[2:0];

	// The memory position of address counter (c, p) under MADCTL MY/MX/MV:
	// {in range, row, column} (MC2PA8201 section 8.2.3).
	function automatic logic [16:0] map_pos(input logic [15:0] c, input logic [15:0] p,
			input logic fmy, input logic fmx, input logic fmv);
		logic       ok;
		logic [7:0] row, col;
		if (!fmv) begin
			ok  = (c < 16'(W)) && (p < 16'(H));
			col = fmx ? 8'(W - 1) - c[7:0] : c[7:0];
			row = fmy ? 8'(H - 1) - p[7:0] : p[7:0];
		end else begin
			ok  = (c < 16'(H)) && (p < 16'(W));
			row = fmy ? 8'(H - 1) - c[7:0] : c[7:0];
			col = fmx ? 8'(W - 1) - p[7:0] : p[7:0];
		end
		return {ok, row, col};
	endfunction

	// row * 176 + col
	function automatic logic [15:0] fb_addr(input logic [7:0] row, input logic [7:0] col);
		return {1'b0, row, 7'd0} + {3'd0, row, 5'd0} + {4'd0, row, 4'd0} + {8'd0, col};
	endfunction

	function automatic logic [4:0] lut_r_default(input int i);
		return (i == 15) ? 5'd31 : 5'(i * 2);
	endfunction
	function automatic logic [5:0] lut_g_default(input int i);
		return (i == 15) ? 6'd63 : 6'(i * 4);
	endfunction

	wire [16:0] cur_pos = map_pos(pix_c, pix_p, my, mx, mv);
	wire [16:0] rd_pos  = map_pos(cc, pc, my, mx, mv);

	// status word of RDDST (MC2PA8201 section 7.2.4)
	wire normal = ~ptl & ~scroll;
	wire [31:0] status = {~sleep, my, mx, mv, ml, bgr, mh, 1'b0,
		1'b0, fmt, idle, ptl, ~sleep, normal,
		scroll, 1'b0, inv, 1'b0, 1'b0, disp, te_on, 1'b0,
		gamma, te_mode, 5'd0};

	task automatic set_defaults();
		cmd      <= 8'h00;
		pidx     <= 6'd0;
		sleep    <= 1'b1;
		disp     <= 1'b0;
		inv      <= 1'b0;
		idle     <= 1'b0;
		ptl      <= 1'b0;
		scroll   <= 1'b0;
		te_on    <= 1'b0;
		te_mode  <= 1'b0;
		gamma    <= 2'd0;
		madctl   <= 8'h00;
		colmod   <= COLMOD_RESET;
		xs       <= 16'd0;
		xe       <= 16'(W - 1);
		ys       <= 16'd0;
		ye       <= 16'(H - 1);
		sr       <= 16'd0;
		er       <= 16'(H - 1);
		tfa      <= 16'd0;
		vsa      <= 16'(H);
		bfa      <= 16'd0;
		ssa      <= 16'd0;
		cc       <= 16'd0;
		pc       <= 16'd0;
		pph      <= 2'd0;
		rd_kind  <= RD_NONE;
		rd_idx   <= 3'd0;
		rd_lo    <= 1'b0;
		rr_start <= 1'b0;
	endtask

	// one finished pixel: hand it to the write pipeline and step the counters
	task automatic emit(input logic [15:0] rgb);
		pix_v   <= 1'b1;
		pix_rgb <= rgb;
		pix_c   <= cc;
		pix_p   <= pc;
		if (cc >= xe) begin
			cc <= xs;
			pc <= (pc >= ye) ? ys : pc + 16'd1;
		end else begin
			cc <= cc + 16'd1;
		end
	endtask

	always_ff @(posedge clk) begin
		pix_v    <= 1'b0;
		rr_start <= 1'b0;

		if (hw_rst) begin
			set_defaults();
			for (int i = 0; i < 16; i++) begin
				lut_r[i] <= lut_r_default(i);
				lut_g[i] <= lut_g_default(i);
				lut_b[i] <= lut_r_default(i);
			end
		end else if (cmd_ev) begin
			cmd     <= d_l;
			pidx    <= 6'd0;
			rd_kind <= RD_NONE;
			rd_idx  <= 3'd0;
			rd_lo   <= 1'b0;
			case (d_l)
				8'h01: set_defaults();
				8'h04, 8'h09, 8'h0A, 8'h0B, 8'h0C, 8'h0D, 8'h0E, 8'h0F,
				8'hDA, 8'hDB, 8'hDC: rd_kind <= RD_REG;
				8'h10: sleep <= 1'b1;
				8'h11: sleep <= 1'b0;
				8'h12: begin ptl <= 1'b1; scroll <= 1'b0; end
				8'h13: begin ptl <= 1'b0; scroll <= 1'b0; end
				8'h20: inv <= 1'b0;
				8'h21: inv <= 1'b1;
				8'h28: disp <= 1'b0;
				8'h29: disp <= 1'b1;
				8'h2C: begin
					cc  <= xs;
					pc  <= ys;
					pph <= 2'd0;
				end
				8'h2E: begin
					cc       <= xs;
					pc       <= ys;
					rd_kind  <= RD_RAM;
					rr_start <= 1'b1;
				end
				8'h34: te_on <= 1'b0;
				8'h35: te_on <= 1'b1;
				8'h37: scroll <= 1'b1;
				8'h38: idle <= 1'b0;
				8'h39: idle <= 1'b1;
				default: ;
			endcase
		end else if (par_ev) begin
			if (pidx != 6'd63) pidx <= pidx + 6'd1;
			case (cmd)
				8'h26: if (pidx == 6'd0) begin
					case (d_l)
						8'h01: gamma <= 2'd0;
						8'h02: gamma <= 2'd1;
						8'h04: gamma <= 2'd2;
						8'h08: gamma <= 2'd3;
						default: ;
					endcase
				end
				8'h2A: case (pidx)
					6'd0: xs[15:8] <= d_l;
					6'd1: xs[7:0]  <= d_l;
					6'd2: xe[15:8] <= d_l;
					6'd3: xe[7:0]  <= d_l;
					default: ;
				endcase
				8'h2B: case (pidx)
					6'd0: ys[15:8] <= d_l;
					6'd1: ys[7:0]  <= d_l;
					6'd2: ye[15:8] <= d_l;
					6'd3: ye[7:0]  <= d_l;
					default: ;
				endcase
				8'h2C: begin
					if (fmt == 3'd3) begin
						case (pph)
							2'd0: begin b0 <= d_l; pph <= 2'd1; end
							2'd1: begin
								emit({lut_r[b0[7:4]], lut_g[b0[3:0]], lut_b[d_l[7:4]]});
								b1  <= d_l;
								pph <= 2'd2;
							end
							default: begin
								emit({lut_r[b1[3:0]], lut_g[d_l[7:4]], lut_b[d_l[3:0]]});
								pph <= 2'd0;
							end
						endcase
					end else if (fmt == 3'd6) begin
						case (pph)
							2'd0: begin b0 <= d_l; pph <= 2'd1; end
							2'd1: begin b1 <= d_l; pph <= 2'd2; end
							default: begin
								emit({b0[7:3], b1[7:2], d_l[7:3]});
								pph <= 2'd0;
							end
						endcase
					end else begin
						if (pph == 2'd0) begin
							b0  <= d_l;
							pph <= 2'd1;
						end else begin
							emit({b0, d_l});
							pph <= 2'd0;
						end
					end
				end
				8'h2D: begin
					if (pidx < 6'd16)      lut_r[pidx[3:0]] <= d_l[4:0];
					else if (pidx < 6'd32) lut_g[pidx[3:0]] <= d_l[5:0];
					else if (pidx < 6'd48) lut_b[pidx[3:0]] <= d_l[4:0];
				end
				8'h30: case (pidx)
					6'd0: sr[15:8] <= d_l;
					6'd1: sr[7:0]  <= d_l;
					6'd2: er[15:8] <= d_l;
					6'd3: er[7:0]  <= d_l;
					default: ;
				endcase
				8'h33: case (pidx)
					6'd0: tfa[15:8] <= d_l;
					6'd1: tfa[7:0]  <= d_l;
					6'd2: vsa[15:8] <= d_l;
					6'd3: vsa[7:0]  <= d_l;
					6'd4: bfa[15:8] <= d_l;
					6'd5: bfa[7:0]  <= d_l;
					default: ;
				endcase
				8'h35: if (pidx == 6'd0) te_mode <= d_l[0];
				8'h36: if (pidx == 6'd0) madctl <= d_l;
				8'h37: case (pidx)
					6'd0: ssa[15:8] <= d_l;
					6'd1: ssa[7:0]  <= d_l;
					default: ;
				endcase
				8'h3A: if (pidx == 6'd0) colmod <= d_l;
				default: ;
			endcase
		end else if (rd_rise) begin
			if (rd_kind == RD_REG) begin
				if (rd_idx != 3'd7) rd_idx <= rd_idx + 3'd1;
			end else if (rd_kind == RD_RAM) begin
				if (rd_idx == 3'd0) begin
					rd_idx <= 3'd1;
				end else if (!rd_lo) begin
					rd_lo <= 1'b1;
				end else begin
					rd_lo <= 1'b0;
					if (cc >= xe) begin
						cc <= xs;
						pc <= (pc >= ye) ? ys : pc + 16'd1;
					end else begin
						cc <= cc + 16'd1;
					end
					rr_start <= 1'b1;
				end
			end
		end
	end

	// write pipeline: counter position -> memory position -> address
	always_ff @(posedge clk) begin
		w_v   <= pix_v & cur_pos[16];
		w_row <= cur_pos[15:8];
		w_col <= cur_pos[7:0];
		w_rgb <= pix_rgb;
	end

	// ------------------------------------------------------------------
	// Read data
	// ------------------------------------------------------------------
	logic [7:0] reg_byte;
	always_comb begin
		reg_byte = 8'h00;
		case (cmd)
			8'h04: case (rd_idx)
				3'd1: reg_byte = ID1;
				3'd2: reg_byte = ID2;
				3'd3: reg_byte = ID3;
				default: ;
			endcase
			8'h09: case (rd_idx)
				3'd1: reg_byte = status[31:24];
				3'd2: reg_byte = status[23:16];
				3'd3: reg_byte = status[15:8];
				3'd4: reg_byte = status[7:0];
				default: ;
			endcase
			8'h0A: if (rd_idx == 3'd1) reg_byte = {~sleep, idle, ptl, ~sleep, normal, disp, 2'b00};
			8'h0B: if (rd_idx == 3'd1) reg_byte = madctl;
			8'h0C: if (rd_idx == 3'd1) reg_byte = colmod;
			8'h0D: if (rd_idx == 3'd1) reg_byte = {scroll, 1'b0, inv, 3'b000, gamma};
			8'h0E: if (rd_idx == 3'd1) reg_byte = {te_on, te_mode, 6'd0};
			8'h0F: if (rd_idx == 3'd1) reg_byte = 8'hC0;
			8'hDA: if (rd_idx == 3'd1) reg_byte = ID1;
			8'hDB: if (rd_idx == 3'd1) reg_byte = ID2;
			8'hDC: if (rd_idx == 3'd1) reg_byte = ID3;
			default: ;
		endcase
	end

	always_comb begin
		case (rd_kind)
			RD_REG:  d_o = reg_byte;
			RD_RAM:  d_o = (rd_idx == 3'd0) ? 8'h00 : (rd_lo ? rd_pix[7:0] : rd_pix[15:8]);
			default: d_o = 8'h00;
		endcase
	end
	assign d_oe = ~hw_rst & ~csx & ~rdx;

	// ------------------------------------------------------------------
	// Frame memory and scan-out
	// ------------------------------------------------------------------
	logic        s1_v, s2_v, s3_v;
	logic  [7:0] s1_x, s1_y;
	logic  [7:0] s2_col, s2_row;
	logic        s2_show, s3_show, s2_ptl_out, s3_ptl_out;
	logic [15:0] ram_q;
	logic [15:0] ram_raddr;

	sdp_ram #(.AW(16), .DW(16), .DEPTH(W * H)) fb (
		.clk  (clk),
		.we   (w_v),
		.waddr(fb_addr(w_row, w_col)),
		.wdata(w_rgb),
		.raddr(ram_raddr),
		.rdata(ram_q)
	);

	// S1: viewer to native panel coordinates
	always_ff @(posedge clk) begin
		s1_v <= scan_en;
		s1_x <= PANEL_ROT180 ? 8'(W - 1) - scan_x : scan_x;
		s1_y <= PANEL_ROT180 ? 8'(H - 1) - scan_y : scan_y;
	end

	// S2: display line to memory line (vertical scroll), partial area
	logic [15:0] line, mrow, sum;
	logic        in_ptl;
	always_comb begin
		line = {8'd0, s1_y};
		mrow = line;
		sum  = ssa + (line - tfa);
		if (scroll && line >= tfa && line < tfa + vsa)
			mrow = (sum >= tfa + vsa) ? sum - vsa : sum;
		in_ptl = (sr <= er) ? (mrow >= sr && mrow <= er) : (mrow >= sr || mrow <= er);
	end

	always_ff @(posedge clk) begin
		s2_v       <= s1_v;
		s2_col     <= s1_x;
		s2_row     <= mrow[7:0];
		s2_show    <= ~sleep & disp & (mrow < 16'(H));
		s2_ptl_out <= ptl & ~in_ptl;
	end

	// S2 issues the read; RAMRD fetches take the port when the scan does not
	always_comb begin
		if (s2_v) ram_raddr = fb_addr(s2_row, s2_col);
		else      ram_raddr = rr_addr;
	end

	always_ff @(posedge clk) begin
		s3_v       <= s2_v;
		s3_show    <= s2_show;
		s3_ptl_out <= s2_ptl_out;
		rr_inflight <= 1'b0;
		if (rr_start) begin
			rr_req  <= 1'b1;
			rr_ok   <= rd_pos[16];
			rr_addr <= fb_addr(rd_pos[15:8], rd_pos[7:0]);
		end else if (rr_req && !s2_v) begin
			rr_req      <= 1'b0;
			rr_inflight <= 1'b1;
		end
		if (rr_inflight) rd_pix <= rr_ok ? ram_q : 16'h0000;
		if (hw_rst) begin
			rr_req      <= 1'b0;
			rr_inflight <= 1'b0;
		end
	end

	// S3: memory data to the pixel the panel shows
	logic [15:0] px;
	always_comb begin
		px = ram_q;
		if (bgr) px = {ram_q[4:0], ram_q[10:5], ram_q[15:11]};
		if (idle) px = {{5{px[15]}}, {6{px[10]}}, {5{px[4]}}};
		if (inv) px = ~px;
		if (s3_ptl_out) px = PARTIAL_RGB;
		if (!s3_show) px = BLANK_RGB;
	end

	always_ff @(posedge clk) begin
		if (s3_v) scan_rgb <= px;
	end

	assign display_on = disp & ~sleep;

	// ------------------------------------------------------------------
	// Tearing effect
	// ------------------------------------------------------------------
	logic [15:0] te_clk;
	logic  [9:0] te_line;

	always_ff @(posedge clk) begin
		if (reset) begin
			te_clk  <= 16'd0;
			te_line <= 10'd0;
		end else if (te_clk == 16'(TE_LINE_CLKS - 1)) begin
			te_clk  <= 16'd0;
			te_line <= (te_line == 10'(TE_LINES - 1)) ? 10'd0 : te_line + 10'd1;
		end else begin
			te_clk <= te_clk + 16'd1;
		end
	end

	wire te_int = (te_line >= 10'(H)) | (te_mode & (te_clk < 16'(TE_HPULSE_CLKS)));

	always_ff @(posedge clk) begin
		te <= te_on & ~sleep & ~hw_rst & (te_ext_sel ? te_ext : te_int);
	end

endmodule
