// SPDX-License-Identifier: GPL-2.0-or-later
// Behavioural altsyncram for Verilator (the benches and lint compile the
// sv2v netlist, which instantiates Intel's RAM primitive directly). Only the
// configuration the core uses: DUAL_PORT (simple dual port), one clock
// (clock0, clocken0 gating both ports' input registers), port A writes with
// byte enables, port B reads with an optional read enable, the read word
// unregistered after the address register, and OLD_DATA on a read and
// write of one address on the same edge. Anything else stops elaboration.
/* verilator lint_off UNUSEDPARAM */
module altsyncram #(
	parameter operation_mode = "DUAL_PORT",
	parameter integer width_a = 8, widthad_a = 1, numwords_a = 2,
	parameter integer width_b = 8, widthad_b = 1, numwords_b = 2,
	parameter integer width_byteena_a = 1, byte_size = 8,
	parameter address_reg_b = "CLOCK0",
	parameter outdata_reg_b = "UNREGISTERED",
	parameter clock_enable_input_a = "NORMAL",
	parameter clock_enable_input_b = "NORMAL",
	parameter clock_enable_output_b = "BYPASS",
	parameter rdcontrol_reg_b = "CLOCK0",
	parameter read_during_write_mode_mixed_ports = "OLD_DATA",
	parameter ram_block_type = "AUTO",
	parameter intended_device_family = "Cyclone V",
	parameter lpm_type = "altsyncram",
	parameter power_up_uninitialized = "FALSE",
	parameter address_aclr_b = "NONE",
	parameter outdata_aclr_b = "NONE"
) (
	input  logic                       clock0,
	input  logic                       clocken0,
	input  logic                       wren_a,
	input  logic [widthad_a-1:0]       address_a,
	input  logic [width_a-1:0]         data_a,
	input  logic [width_byteena_a-1:0] byteena_a,
	input  logic [widthad_b-1:0]       address_b,
	input  logic                       rden_b,
	output logic [width_b-1:0]         q_b
);
	initial if (operation_mode != "DUAL_PORT" || width_a != width_b || widthad_a != widthad_b ||
	            outdata_reg_b != "UNREGISTERED" || address_reg_b != "CLOCK0" ||
	            width_a != width_byteena_a * byte_size)
		$fatal(1, "altsyncram model: unsupported configuration");
	logic [width_a-1:0] mem [numwords_a];
	always_ff @(posedge clock0) if (clocken0) begin
		if (wren_a)
			for (int b = 0; b < width_byteena_a; b++)
				if (byteena_a[b]) mem[address_a][byte_size*b +: byte_size] <= data_a[byte_size*b +: byte_size];
		if (rden_b) q_b <= mem[address_b];
	end
endmodule
/* verilator lint_on UNUSEDPARAM */
