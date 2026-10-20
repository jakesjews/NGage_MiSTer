// SPDX-License-Identifier: GPL-3.0-or-later
//
// Top of the CPU bench (sim/cpu) for Verilator: the arm925t wrapper with its
// bus and interrupts on ports, which main.cpp drives, plus probes into ZAP's
// writeback stage. The probes show the instruction (or micro-op) that
// commits at the next rising edge, and the register file and CPSR as they
// are; main.cpp turns them into a retirement trace. They work on both the
// generated netlist (rtl/cpu/arm925t_gen.v) and the SystemVerilog sources.
module tb_cpu #(
	parameter bit HIVECS      = 1'b0,
	parameter int ICACHE_SIZE = 16384,
	parameter int DCACHE_SIZE = 8192,
	parameter int CACHE_LINE  = 16
) (
	input  logic          clk,
	input  logic          reset,
	input  logic          irq,
	input  logic          fiq,

	output logic          bus_req,
	output logic          bus_we,
	output logic [31:0]   bus_addr,
	output logic [3:0]    bus_be,
	output logic [31:0]   bus_wdata,
	output logic          bus_burst,
	input  logic [31:0]   bus_rdata,
	input  logic          bus_ack,
	input  logic          bus_err,

	// writeback stage, this cycle
	output logic          p_valid,     // executes (condition passed)
	output logic          p_cfail,     // condition failed
	output logic          p_last,      // last micro-op of the instruction
	output logic [1:0]    p_dabt,      // [0] data abort taken, [1] replay
	output logic          p_fiq,
	output logic          p_irq,
	output logic          p_iabt,
	output logic          p_swi,
	output logic          p_und,
	output logic          p_copro,     // CP15 writes a core register
	output logic [31:0]   p_pc8,       // instruction address + 8 (ARM) / + 4 (Thumb)
	// state
	output logic [31:0]   p_cpsr,
	output logic [1279:0] p_regs,      // 40 physical registers, 32 bits each
	output logic [63:0]   p_lock,      // registers waiting for a background load
	// data side, for the bus log: request to the D-cache, its virtual
	// address, alignment fault
	output logic          p_dreq,
	output logic [31:0]   p_dva,
	output logic          p_dalign
);

	arm925t #(
		.HIVECS      (HIVECS),
		.ICACHE_SIZE (ICACHE_SIZE),
		.DCACHE_SIZE (DCACHE_SIZE),
		.CACHE_LINE  (CACHE_LINE)
	) dut (
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
		.bus_rdata (bus_rdata),
		.bus_ack   (bus_ack),
		.bus_err   (bus_err)
	);

	assign p_valid = dut.u_zap.u_zap_core.u_zap_writeback.i_valid;
	assign p_cfail = dut.u_zap.u_zap_core.u_zap_writeback.i_decompile_valid;
	assign p_last  = dut.u_zap.u_zap_core.u_zap_writeback.i_uop_last;
	assign p_dabt  = dut.u_zap.u_zap_core.u_zap_writeback.i_data_abt;
	assign p_fiq   = dut.u_zap.u_zap_core.u_zap_writeback.i_fiq;
	assign p_irq   = dut.u_zap.u_zap_core.u_zap_writeback.i_irq;
	assign p_iabt  = dut.u_zap.u_zap_core.u_zap_writeback.i_instr_abt;
	assign p_swi   = dut.u_zap.u_zap_core.u_zap_writeback.i_swi;
	assign p_und   = dut.u_zap.u_zap_core.u_zap_writeback.i_und;
	assign p_copro = dut.u_zap.u_zap_core.u_zap_writeback.i_copro_reg_en;
	assign p_pc8   = dut.u_zap.u_zap_core.u_zap_writeback.i_pc_plus_8_buf_ff;
	assign p_cpsr  = dut.u_zap.u_zap_core.u_zap_writeback.cpsr_ff;
	assign p_regs  = dut.u_zap.u_zap_core.u_zap_writeback.u_zap_register_file.mem;
	assign p_lock  = dut.u_zap.dc_lock;
	assign p_dreq  = dut.u_zap.cpu_dc_stb;
	assign p_dva   = dut.u_zap.cpu_daddr_va;
	assign p_dalign = dut.u_zap.cpu_align_fault;

endmodule
