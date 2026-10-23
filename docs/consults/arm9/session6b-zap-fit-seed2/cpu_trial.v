// SPDX-License-Identifier: GPL-3.0-or-later
//
// Standalone Quartus trial of the CPU (rtl/cpu/arm925t_gen.v): resources
// and timing at the core clock. Every CPU input comes from a pin through a
// register and every bus output goes through a register to a pin, so no
// logic can be optimised away and only the CPU's own paths (plus one
// register at each side) are timed. See run.sh.
module cpu_trial (
	input  wire        clk,
	input  wire        rst_in,
	input  wire        irq_in,
	input  wire        fiq_in,
	input  wire [31:0] rdata_in,
	input  wire        ack_in,
	input  wire        err_in,
	output reg         req_o,
	output reg         we_o,
	output reg         burst_o,
	output reg  [31:0] addr_o,
	output reg  [31:0] wdata_o,
	output reg  [3:0]  be_o
);
	reg        reset, irq, fiq, ack, err;
	reg [31:0] rdata;
	wire        bus_req, bus_we, bus_burst;
	wire [31:0] bus_addr, bus_wdata;
	wire [3:0]  bus_be;

	always @(posedge clk) begin
		reset <= rst_in;
		irq   <= irq_in;
		fiq   <= fiq_in;
		rdata <= rdata_in;
		ack   <= ack_in;
		err   <= err_in;
		req_o   <= bus_req;
		we_o    <= bus_we;
		burst_o <= bus_burst;
		addr_o  <= bus_addr;
		wdata_o <= bus_wdata;
		be_o    <= bus_be;
	end

	arm925t cpu (
		.clk       (clk),
		.reset     (reset),
		.irq       (irq),
		.fiq       (fiq),
		.bus_req   (bus_req),
		.bus_we    (bus_we),
		.bus_addr  (bus_addr),
		.bus_be    (bus_be),
		.bus_wdata (bus_wdata),
		.bus_burst (bus_burst),
		.bus_rdata (rdata),
		.bus_ack   (ack),
		.bus_err   (err)
	);
endmodule
