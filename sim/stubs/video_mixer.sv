// Simulation stand-in for sys/video_mixer.sv. The framework's module declares
// R_in/G_in/B_in inside unnamed generate blocks and uses them outside; Quartus
// accepts that, Verilator (following the standard) makes the outer names
// implicit undriven nets, so the real mixer simulates as black. This passes
// the picture through a register at each pixel, as the mixer does with the
// scandoubler off.
module video_mixer #(
	parameter LINE_LENGTH = 768,
	parameter HALF_DEPTH  = 0,
	parameter GAMMA       = 0
) (
	input  wire        CLK_VIDEO,
	output reg         CE_PIXEL,
	input  wire        ce_pix,
	input  wire        scandoubler,
	input  wire        hq2x,
	inout  wire [21:0] gamma_bus,
	input  wire  [7:0] R,
	input  wire  [7:0] G,
	input  wire  [7:0] B,
	input  wire        HSync,
	input  wire        VSync,
	input  wire        HBlank,
	input  wire        VBlank,
	input  wire        HDMI_FREEZE,
	output wire        freeze_sync,
	output reg   [7:0] VGA_R,
	output reg   [7:0] VGA_G,
	output reg   [7:0] VGA_B,
	output reg         VGA_VS,
	output reg         VGA_HS,
	output reg         VGA_DE
);
	assign freeze_sync = 1'b0;
	assign gamma_bus[21] = 1'b0;

	always @(posedge CLK_VIDEO) begin
		CE_PIXEL <= ce_pix;
		if (ce_pix) begin
			VGA_R  <= R;
			VGA_G  <= G;
			VGA_B  <= B;
			VGA_HS <= HSync;
			VGA_VS <= VSync;
			VGA_DE <= ~(HBlank | VBlank);
		end
	end
endmodule
