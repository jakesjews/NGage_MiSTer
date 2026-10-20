// SPDX-License-Identifier: GPL-2.0-or-later
//
// Scan-out of the display module's picture to MiSTer video.
//
// The 176x208 portrait picture is placed in the middle of a 60 Hz, 15.7 kHz
// frame (262 lines, 240p-compatible), so it comes out centred on a CRT over
// direct video or the analog output, and the HDMI scaler, which crops to DE,
// gets just the picture. With rotate set the picture is turned a quarter
// turn for a landscape TV and becomes 208x176; a new setting takes effect at
// the next frame.
//
// Default timing, for a 104 MHz clock and a pixel every 16 clocks (6.5 MHz):
//   413 pixels a line (63.5 us, 15.74 kHz), hsync 31 pixels (4.8 us);
//   262 lines a frame (60.07 Hz), vsync 3 lines.
// H_CENTER and V_CENTER put the middle of the picture where the middle of a
// TV's visible area is: 37 us after the start of hsync, and line 140.
//
// The picture comes from the panel's scan port: one request (scan_en, with
// panel coordinates) for each visible pixel, a pixel ahead; the answer must
// be on scan_rgb before the next pixel clock, so CE_DIV must exceed the
// source's latency (lcd_panel: four clocks). RGB565 is widened to 8 bits a
// component by repeating the top bits. Syncs are active high; blanked pixels
// are black. ce_pix marks the clocks at which the outputs hold a new pixel.
module video_out #(
	parameter int CE_DIV   = 16,
	parameter int H_TOTAL  = 413,
	parameter int H_SYNC   = 31,
	parameter int H_CENTER = 242,
	parameter int V_TOTAL  = 262,
	parameter int V_SYNC   = 3,
	parameter int V_CENTER = 140
) (
	input  logic        clk,
	input  logic        reset,

	// 0 = portrait, 1 = a quarter turn clockwise, 2 = anticlockwise, 3 = portrait
	input  logic  [1:0] rotate,

	output logic        scan_en,
	output logic  [7:0] scan_x,
	output logic  [7:0] scan_y,
	input  logic [15:0] scan_rgb,

	output logic        ce_pix,
	output logic        hsync,
	output logic        vsync,
	output logic        hblank,
	output logic        vblank,
	output logic        de,
	output logic  [7:0] red,
	output logic  [7:0] green,
	output logic  [7:0] blue,
	// the orientation of the frame being sent, for the aspect ratio
	output logic        rotated
);

	localparam int PW = 176;
	localparam int PH = 208;

	logic  [7:0] cediv;       // CE_DIV up to 256
	logic  [9:0] hc, vc;      // the pixel sent at the next pixel clock
	logic  [1:0] rot;
	logic        ce;

	assign ce = (cediv == 8'd0);

	// picture position for the orientation
	wire        turned = rot == 2'd1 || rot == 2'd2;
	wire  [9:0] aw = turned ? 10'(PH) : 10'(PW);
	wire  [9:0] ah = turned ? 10'(PW) : 10'(PH);
	wire  [9:0] h0 = 10'(H_CENTER) - (aw >> 1);
	wire  [9:0] v0 = 10'(V_CENTER) - (ah >> 1);

	// the position after hc, vc
	wire  [9:0] hn = (hc == 10'(H_TOTAL - 1)) ? 10'd0 : hc + 10'd1;
	wire  [9:0] vn = (hc != 10'(H_TOTAL - 1)) ? vc : (vc == 10'(V_TOTAL - 1)) ? 10'd0 : vc + 10'd1;

	wire        h_act  = hc >= h0 && hc < h0 + aw;
	wire        v_act  = vc >= v0 && vc < v0 + ah;
	wire        hn_act = hn >= h0 && hn < h0 + aw;
	wire        vn_act = vn >= v0 && vn < v0 + ah;
	// position inside the picture (in range wherever it is used)
	wire  [7:0] ox = 8'(hn - h0);
	wire  [7:0] oy = 8'(vn - v0);

	always_ff @(posedge clk) begin
		ce_pix  <= 1'b0;
		scan_en <= 1'b0;
		if (reset) begin
			cediv   <= 8'd0;
			hc      <= 10'd0;
			vc      <= 10'd0;
			rot     <= rotate;
			hsync   <= 1'b0;
			vsync   <= 1'b0;
			hblank  <= 1'b1;
			vblank  <= 1'b1;
			de      <= 1'b0;
			red     <= 8'd0;
			green   <= 8'd0;
			blue    <= 8'd0;
		end else begin
			cediv <= (cediv == 8'(CE_DIV - 1)) ? 8'd0 : cediv + 8'd1;
			if (ce) begin
				ce_pix <= 1'b1;
				hsync  <= hc < 10'(H_SYNC);
				vsync  <= vc < 10'(V_SYNC);
				hblank <= ~h_act;
				vblank <= ~v_act;
				de     <= h_act & v_act;
				if (h_act && v_act) begin
					red   <= {scan_rgb[15:11], scan_rgb[15:13]};
					green <= {scan_rgb[10:5], scan_rgb[10:9]};
					blue  <= {scan_rgb[4:0], scan_rgb[4:2]};
				end else begin
					red   <= 8'd0;
					green <= 8'd0;
					blue  <= 8'd0;
				end
				hc <= hn;
				vc <= vn;
				// a new orientation starts with a frame
				if (hn == 10'd0 && vn == 10'd0) rot <= rotate;
				// ask for the pixel of the next pixel clock
				if (hn_act && vn_act) begin
					scan_en <= 1'b1;
					case (rot)
						2'd1: begin scan_x <= oy; scan_y <= 8'(PH - 1) - ox; end
						2'd2: begin scan_x <= 8'(PW - 1) - oy; scan_y <= ox; end
						default: begin scan_x <= ox; scan_y <= oy; end
					endcase
				end
			end
		end
	end

	assign rotated = turned;

endmodule
