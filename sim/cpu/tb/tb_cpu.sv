// SPDX-License-Identifier: GPL-3.0-or-later
//
// Top of the CPU bench (sim/cpu) for Verilator: the arm925t wrapper with its
// bus and interrupts on ports, which main.cpp drives, plus probes into ZAP's
// writeback stage. The probes show the instruction (or micro-op) that
// commits at the next rising edge, and the register file and CPSR as they
// are; main.cpp turns them into a retirement trace. They work on both the
// generated netlist (rtl/cpu/arm925t_gen.v) and the SystemVerilog sources.
module tb_cpu #(
	parameter CORE = "ZAP",
	parameter bit ARM9_PREDICTOR = 1'b1,
	parameter bit HIVECS          = 1'b0,
	parameter int ICACHE_SIZE     = 16384,
	parameter int ICACHE_WAYS     = 2,
	parameter bit ICACHE_PREFETCH = 1'b0,
	parameter int DCACHE_SIZE     = 8192,
	parameter int DCACHE_WAYS     = 2,
	parameter int CACHE_LINE      = 16
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
	output logic [1:0]    bus_bte,
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
	output logic [7:0]    p_stall,     // same overlapping level counters as hardware
	output logic [3:0]    p_dcache,    // registered D-cache events exported by arm925t
	// data side, for the bus log: request to the D-cache, its virtual
	// address, alignment fault
	output logic          p_dreq,
	output logic [31:0]   p_dva,
	output logic          p_dalign,
	// address + 8 (+ 4 in Thumb) of the instruction making the data access
	output logic [31:0]   p_dpc8,
	// CP15 state: translation table base, domain access, MMU enable
	output logic [31:0]   p_ttb,
	output logic [31:0]   p_dacr,
	output logic          p_mmu,
	// CP15 waits for an interrupt (WFI)
	output logic          p_wfi,
	// D-cache state machine, for main.cpp --dcdbg
	output logic [15:0]   p_dc_state,
	output logic [5:0]    p_dc_events, // accept/store/dirty/fill beat/writeback beat/EOB
	output logic [31:0]   p_dc_addr,
	output logic [31:0]   p_dc_din,
	output logic [31:0]   p_dc_dat,
	output logic [15:0]   p_dc_flags,
	// Critical-word-first interface checks (no synthesized hardware).
	output logic [63:0]   p_dc_reg_wr,
	output logic [31:0]   p_dc_reg_data,
	output logic [31:0]   p_dc_fill_addr,
	output logic         p_dc_fill_take,
	// Blocking ARM9 loads capture cache completion before architectural W.
    output logic         p_blocking_load,
    output logic         p_arm9,
    output logic         p_arm9_predictor,
    output logic         p_load_capture,
    output logic [63:0]  p_load_commit,
    output logic [31:0]  p_load_value,
    // pre-decoder's prediction and the ALU's check, for main.cpp --pddbg
	output logic [31:0]   p_pd_pc,
	output logic [31:0]   p_pd_ins,
	output logic [31:0]   p_pd_ppc,
	output logic [31:0]   p_pd_wpc,
	output logic [31:0]   p_pd_pred,
	output logic [15:0]   p_pd_flags,
	output logic [31:0]   p_alu_ppc,
	output logic [7:0]    p_alu_flags,
	// --pddbg: the pre-decoder's output micro-op and the ALU's result
	output logic [39:0]   p_uop_ins,
	output logic [3:0]    p_uop_flags,
	output logic [31:0]   p_alu_res,
	output logic [7:0]    p_alu_dst,
	output logic [63:0]   p_sh_dbg,
	// Multiply occupancy and the selected younger instruction (bench only).
	output logic [3:0]    p_mult_state
);

	arm925t #(
		.CORE (CORE),
		.ARM9_PREDICTOR (ARM9_PREDICTOR),
		.HIVECS          (HIVECS),
		.ICACHE_SIZE     (ICACHE_SIZE),
		.ICACHE_WAYS     (ICACHE_WAYS),
		.ICACHE_PREFETCH (ICACHE_PREFETCH),
		.DCACHE_SIZE     (DCACHE_SIZE),
		.DCACHE_WAYS     (DCACHE_WAYS),
		.CACHE_LINE      (CACHE_LINE)
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
		.bus_bte   (bus_bte),
		.bus_rdata (bus_rdata),
		.bus_ack   (bus_ack),
		.bus_err   (bus_err),
		.dbg_dcache (p_dcache)
	);

	assign p_lock  = dut.u_zap.dc_lock;
	assign p_stall = dut.u_zap.o_dbg_stall;
	assign p_dreq  = dut.u_zap.cpu_dc_stb;
	assign p_dva   = dut.u_zap.cpu_daddr_va;
	assign p_dalign = dut.u_zap.cpu_align_fault;
	assign p_ttb   = dut.u_zap.cpu_baddr;
	assign p_dacr  = dut.u_zap.cpu_dac_reg;
	assign p_mmu   = dut.u_zap.cpu_mmu_en;
    assign p_arm9 = CORE == "ARM9";
    assign p_blocking_load = 1'b0; // V2 uses the shared nonblocking background write port.
    assign p_arm9_predictor = CORE == "ARM9" && ARM9_PREDICTOR;
	wire cp_drain_done;
	if (CORE == "ZAP") begin : g_zap_probes
    assign cp_drain_done = dut.u_zap.g_zap.u_zap_core.u_zap_cp15_cb.o_cp_done &&
        (dut.u_zap.g_zap.u_zap_core.u_zap_cp15_cb.i_cp_word[27:0] & 28'hfff0fff) == 28'he070f9a;
    assign p_load_capture = 0;
    assign p_load_commit = 0;
    assign p_load_value = 0;
	assign p_valid = dut.u_zap.g_zap.u_zap_core.u_zap_writeback.i_valid;
	assign p_cfail = dut.u_zap.g_zap.u_zap_core.u_zap_writeback.i_decompile_valid;
	assign p_last  = dut.u_zap.g_zap.u_zap_core.u_zap_writeback.i_uop_last;
	assign p_dabt  = dut.u_zap.g_zap.u_zap_core.u_zap_writeback.i_data_abt;
	assign p_fiq   = dut.u_zap.g_zap.u_zap_core.u_zap_writeback.i_fiq;
	assign p_irq   = dut.u_zap.g_zap.u_zap_core.u_zap_writeback.i_irq;
	assign p_iabt  = dut.u_zap.g_zap.u_zap_core.u_zap_writeback.i_instr_abt;
	assign p_swi   = dut.u_zap.g_zap.u_zap_core.u_zap_writeback.i_swi;
	assign p_und   = dut.u_zap.g_zap.u_zap_core.u_zap_writeback.i_und;
	assign p_copro = dut.u_zap.g_zap.u_zap_core.u_zap_writeback.i_copro_reg_en;
	assign p_pc8   = dut.u_zap.g_zap.u_zap_core.u_zap_writeback.i_pc_plus_8_buf_ff;
	assign p_cpsr  = dut.u_zap.g_zap.u_zap_core.u_zap_writeback.cpsr_ff;
	assign p_regs  = dut.u_zap.g_zap.u_zap_core.u_zap_writeback.u_zap_register_file.mem;
	assign p_dpc8  = dut.u_zap.g_zap.u_zap_core.postalu_pc_plus_8_ff;
	assign p_wfi   = dut.u_zap.g_zap.u_zap_core.u_zap_cp15_cb.state == 4'd12;
	`define PD dut.u_zap.g_zap.u_zap_core.u_zap_predecode
	`define AL dut.u_zap.g_zap.u_zap_core.u_zap_alu_main
	assign p_pd_pc    = `PD.skid_pc_ff;
	assign p_pd_ins   = `PD.mode32_instruction[31:0];
	assign p_pd_ppc   = `PD.o_ppc_ff;
	assign p_pd_wpc   = `PD.w_pc_from_decode;
	assign p_pd_pred  = `PD.skid_pred[31:0];
	assign p_pd_flags = {`PD.skid_pred[32], `PD.skid_taken, `PD.mode32_instruction_valid,
	                     `PD.w_clear_from_decode, `PD.o_clear_from_decode, `PD.mem_fetch_stall, `PD.stall,
	                     `PD.ras_we_ff, 3'(`PD.ras_ptr_ff), `PD.o_taken_ff, `PD.o_instruction_valid_ff};
	assign p_alu_ppc   = `AL.i_ppc_ff;
	assign p_alu_flags = {`AL.i_taken_ff, `AL.o_clear_from_alu, `AL.i_data_stall, 4'd0};
	assign p_uop_ins   = `PD.o_instruction_ff;
	assign p_uop_flags = {`PD.o_instruction_valid_ff, `PD.o_uop_last, `PD.o_irq_ff, `PD.o_stall_from_decode};
	assign p_alu_res   = `AL.o_alu_result_ff;
	assign p_alu_dst   = {`AL.o_dav_ff, 7'(`AL.o_destination_index_ff)};
	`define SH dut.u_zap.g_zap.u_zap_core.u_zap_shifter_main
	assign p_sh_dbg    = {8'(`SH.i_alu_source_ff), 8'(`SH.o_destination_index_ff), 7'd0, `SH.i_alu_dav_nxt,
	                      `SH.rn};
	assign p_mult_state = {`SH.i_clear_from_writeback || (`SH.i_clear_from_alu && !`SH.i_data_stall),
	                      dut.u_zap.g_zap.u_zap_core.u_zap_issue_main.skid_condition_code_ff != 4'd15,
	                      `SH.i_data_stall || `SH.i_stall_from_alu, `SH.multiply_busy};
	// Check the early decision against execution one stage later. This catches
	// stale flags/target or metadata misalignment across a hold/redirect.
	// Disable only when measuring an archived core without the early interface.
`ifndef ZAP_LEGACY_CORE
	begin : g_early_branch_check
		wire [31:0] actual_target = `AL.i_link_branch_ff[32] ?
			`AL.i_link_branch_ff[31:0] : `AL.quick_sum;
		always @(posedge clk) begin
			if (!reset && `SH.o_early_redirect_ff && !`AL.i_data_stall &&
			    !`AL.o_clear_from_alu && !`AL.i_clear_from_writeback &&
			    !`AL.sleep_ff && !`AL.i_data_mem_fault) begin
				if (`AL.o_dav_nxt) begin
					assert (`SH.o_early_target_ff == actual_target)
						else $fatal(1, "Early branch target differs from ALU execution");
					assert (!`AL.i_taken_ff[1] || `AL.i_ppc_ff != actual_target)
						else $fatal(1, "Early redirect on a correctly predicted branch");
				end else begin
					assert (`AL.i_taken_ff[1] && `SH.o_early_target_ff ==
					        `AL.i_pc_ff + (`AL.flags_ff[5] ? 32'd2 : 32'd4))
						else $fatal(1, "Early branch used stale condition flags");
				end
			end
		end
	end
`endif
	`undef SH
	`undef PD
	`undef AL
	end else begin : g_arm9_probes
    assign cp_drain_done = dut.u_zap.g_arm9.u_arm9_core.u_zap_cp15_cb.o_cp_done &&
        (dut.u_zap.g_arm9.u_arm9_core.u_zap_cp15_cb.i_cp_word[27:0] & 28'hfff0fff) == 28'he070f9a;
	`define A9 dut.u_zap.g_arm9.u_arm9_core

    assign p_load_capture = `A9.load_capture;
    assign p_load_commit = `A9.load_commit;
    assign p_load_value = `A9.load_value;
	assign p_valid = `A9.o_dbg_wb_valid;
	assign p_cfail = `A9.o_dbg_wb_dvalid;
	assign p_last = `A9.o_dbg_wb_uop_last;
	assign p_dabt = `A9.o_dbg_wb_dabt;
	assign p_fiq = `A9.o_dbg_wb_fiq;
	assign p_irq = `A9.o_dbg_wb_irq;
	assign p_iabt = `A9.o_dbg_wb_pabt;
	assign p_swi = `A9.o_dbg_wb_swi;
	assign p_und = `A9.o_dbg_wb_und;
	assign p_copro = `A9.copro_reg_en;
	assign p_pc8 = `A9.o_dbg_wb_pc;
	assign p_cpsr = `A9.o_dbg_wb_cpsr;
	assign p_regs = `A9.u_zap_writeback.u_zap_register_file.mem;
	assign p_dpc8 = `A9.data_pc8;
	assign p_wfi = `A9.o_dbg_wfi;
	assign p_pd_pc = `A9.pc;
	assign p_pd_ins = `A9.ins;
	assign p_pd_ppc = 0;
	assign p_pd_wpc = 0;
	assign p_pd_pred = 0;
	assign p_pd_flags = 0;
	assign p_alu_ppc = 0;
	assign p_alu_flags = 0;
	assign p_uop_ins = {8'd0, `A9.ins};
	assign p_uop_flags = 0;
	assign p_alu_res = `A9.ex_result;
	assign p_alu_dst = 0;
	assign p_sh_dbg = 0;
	assign p_mult_state = 0;
	`undef A9
	end
	// These assertions also run against the baseline netlist: they observe
	// acknowledged accesses and the real RAM address/permission pipeline.
	`define DC dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_cache_fsm
	`define DT dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_cache_tag_ram
	`define TC dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_tlb.u_zap_tlb_check
	localparam int DLINE_W = $clog2(CACHE_LINE);
	localparam int DSET_W = $clog2(DCACHE_SIZE / DCACHE_WAYS / CACHE_LINE);
	logic [DSET_W-1:0] dc_read_set, dc_response_set;
	logic dc_victim_valid;
	logic dc_installed;
	logic [31:DLINE_W] dc_victim_line;
	always_ff @(posedge clk) begin
		if (reset || `DC.o_idle) dc_installed <= 1'b0;
		else if (`DC.state_ff[7]) dc_installed <= 1'b1;
		if (!`DT.i_hold) begin
            dc_read_set <= CORE == "ARM9" ? `DT.rd_set : `DT.rd_set_del2;
            // SHORT_READ adds the registered compare/format response after
            // the RAM edge. Check the set belonging to that response.
            dc_response_set <= dc_read_set;
        end

		if (`DC.o_idle) begin
			dc_victim_valid <= `DC.i_cache_tag_valid;
			dc_victim_line <= {`DC.i_cache_tag[31-DLINE_W-DSET_W:0],
			                   `DC.i_address[DLINE_W +: DSET_W]};
		end
		if (!reset && `DC.hum_slot_ff)
			assert (`DC.i_cache_hit_early == `DC.i_cache_hit)
				else $fatal(1, "Registered HUM tag match differs from live lookup");
		if (!reset && `DC.state_ff[7])
			assert (!`DC.o_ack) else $fatal(1, "Hit collided with fill installation");
		if (!reset && (`DC.state_ff[3] || `DC.state_ff[4] || `DC.state_ff[10]) &&
		    (`DC.i_rd || `DC.i_wr) && `DC.o_ack) begin
			assert ((CORE == "ARM9" ? dc_response_set : dc_read_set) == `DC.i_address[DLINE_W +: DSET_W])
				else $fatal(1, "Hit under miss used an unaligned cache lookup");
			assert (dc_installed || `DC.i_address[31:DLINE_W] != `DC.address[31:DLINE_W])
				else $fatal(1, "Hit under miss accessed the filling line");
			assert (!dc_victim_valid || `DC.i_address[31:DLINE_W] != dc_victim_line)
				else $fatal(1, "Hit under miss accessed the reserved victim");
			assert (`DC.i_cache_hit && !`TC.o_walk && !`TC.o_fsr[3:0] &&
			        `TC.o_cacheable && !`DC.i_align_fault && !`DC.o_err && !`DC.o_err2 &&
			        !(`DC.i_wr && `TC.o_wt))
				else $fatal(1, "Hit under miss bypassed translation or a fault");
			assert (`DC.o_address == `DC.i_address)
				else $fatal(1, "Hit under miss wrote the background address");
		end
	end
	// Independent eviction scoreboard: capture the victim at acceptance,
	// check every drained word, and check fill-before-drain except for a
	// same-physical-line synonym. No DUT eligibility bit qualifies checks.
	logic dc_dirty_pending, dc_defer_expected;
	logic [31:DLINE_W] dc_saved_pa;
	logic [CACHE_LINE*8-1:0] dc_saved_line;
	integer dc_wb_beat;
	always_ff @(posedge clk) begin
		if (reset) begin
			dc_dirty_pending <= 1'b0;
			dc_defer_expected <= 1'b0;
			dc_wb_beat <= 0;
		end else begin
			if (p_dc_events[0]) begin
				assert (!dc_dirty_pending)
					else $fatal(1, "Second miss overwrote the pending victim");
				dc_dirty_pending <= p_dc_events[2];
				dc_saved_pa <= `DC.i_cache_tag[$bits(`DC.i_cache_tag)-1 -: 32-DLINE_W];
				dc_saved_line <= `DC.i_cache_line;
				dc_wb_beat <= 0;
				dc_defer_expected <= `DC.i_phy_addr[31:DLINE_W] !=
					`DC.i_cache_tag[$bits(`DC.i_cache_tag)-1 -: 32-DLINE_W];
			end
			if (`DC.state_ff[3] && `DC.take) begin
				assert (dc_dirty_pending && dc_installed == dc_defer_expected)
					else $fatal(1, "Dirty eviction used the wrong fill/writeback order");
				assert (`DC.o_wb_adr_ff == {dc_saved_pa, {DLINE_W{1'b0}}} + 32'(dc_wb_beat*4) &&
				        `DC.o_wb_dat_ff == dc_saved_line[dc_wb_beat*32 +: 32] && `DC.o_wb_sel_ff == 4'hf)
					else $fatal(1, "Deferred write-back lost the saved victim address or bytes");
				dc_wb_beat <= dc_wb_beat + 1;
				if (p_dc_events[5]) begin
					assert (dc_wb_beat == CACHE_LINE/4-1)
						else $fatal(1, "Incomplete victim write-back");
					dc_dirty_pending <= 1'b0;
				end
			end
			if (`DC.o_cache_inv_done || `DC.o_cache_clean_done || `DC.o_line_done)
				assert (!dc_dirty_pending)
					else $fatal(1, "Maintenance completed before the saved victim drained");
		end
	end
	always_ff @(posedge clk)
		if (!reset && cp_drain_done)
			assert (!dc_dirty_pending)
				else $fatal(1, "CP15 drain completed before the victim write-back");
	assign p_dc_events = {
		`DC.o_wb_cti_ff == 3'b111,
		`DC.state_ff[3] && `DC.take,
		`DC.state_ff[4] && `DC.take,
		`DC.i_cache_tag_valid && `DC.i_cache_tag_dirty,
		`DC.wr,
		`DC.o_idle && (`DC.i_rd || `DC.i_wr) && !`DC.i_align_fault &&
		!`DC.i_fault && !`DC.i_busy && `DC.i_cache_en && `DC.i_cacheable &&
		!(`DC.i_wr && `DC.i_wt) && !`DC.i_cache_hit
	};
	// A cacheable store miss already completes at acceptance on master.
	always_ff @(posedge clk)
		if (!reset && p_dc_events[0] && `DC.i_wr)
			assert (`DC.o_ack && !`DC.o_hold && !`DC.o_err && !`DC.o_err2)
				else $fatal(1, "Write-back store miss did not complete at acceptance");
	`undef DC
	`undef DT
	`undef TC

	assign p_dc_state = 16'(dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_cache_fsm.state_ff);
	assign p_dc_addr  = dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_cache_fsm.i_address;
	assign p_dc_din   = dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_cache_fsm.i_din;
	assign p_dc_dat   = dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_cache_fsm.o_dat;
	assign p_dc_reg_wr = dut.u_zap.dc_wreg_idx;
	assign p_dc_reg_data = dut.u_zap.dc_reg_data;
	assign p_dc_fill_addr = dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_cache_fsm.phy_addr;
	assign p_dc_fill_take = p_dc_state[4] &&
		dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_cache_fsm.take;
	assign p_dc_flags = {
		dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_cache_fsm.i_ben,         // 15:12
		dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_cache_fsm.o_cache_tag_wr_en, // 11
		|dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_cache_fsm.o_cache_line_ben, // 10
		dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_cache_fsm.i_cache_tag_valid, // 9
		dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_cache_fsm.i_cacheable,   // 8
		dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_cache_fsm.i_wt,          // 7
		dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_cache_fsm.i_cache_tag_dirty, // 6
		dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_cache_fsm.o_hold,        // 5
		dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_cache_fsm.o_err2,        // 4
		dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_cache_fsm.o_err,         // 3
		dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_cache_fsm.o_ack,         // 2
		dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_cache_fsm.i_wr,          // 1
		dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_cache_fsm.i_rd           // 0
	};

endmodule
