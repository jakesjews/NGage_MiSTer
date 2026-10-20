// Simulation stand-in for the Altera PLL: the bench's clock is clk_sys.
module pll (
	input  wire refclk,
	input  wire rst,
	output wire outclk_0,
	output wire locked
);
	assign outclk_0 = refclk;
	assign locked   = ~rst;
endmodule
