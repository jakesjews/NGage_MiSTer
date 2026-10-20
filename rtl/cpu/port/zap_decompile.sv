// SPDX-License-Identifier: GPL-3.0-or-later
//
// Stand-in for ZAP's zap_decompile (rtl/cpu/zap/zap_decompile.sv), which
// only turns instructions into text for simulation traces. With SYNTHESIS
// defined the original has an undriven output, which sv2v and Quartus 17 do
// not take well; this version drives a constant. tools/gen_cpu.sh uses it in
// place of the original.
module zap_decompile #(
	parameter [31:0] INS_WDT = 32'd36
) (
	input  logic [36-1:0]  i_instruction,
	input  logic           i_dav,
	output logic [64*8-1:0] o_decompile
);

	assign o_decompile = '0;

	logic unused;
	assign unused = |{i_instruction, i_dav, INS_WDT};

endmodule
