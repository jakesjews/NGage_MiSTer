// SPDX-License-Identifier: GPL-3.0-or-later
//
// Top of the CPU bench (sim/cpu) for Verilator: the arm925t wrapper with its
// bus and interrupts on ports, which main.cpp drives, plus probes into ZAP's
// writeback stage. The probes show the instruction (or micro-op) that
// commits at the next rising edge, and the register file and CPSR as they
// are; main.cpp turns them into a retirement trace. They work on both the
// generated netlist (rtl/cpu/arm925t_gen.v) and the SystemVerilog sources.
module tb_cpu #(
	parameter bit ARM9_PREDICTOR = 1'b1,
	parameter bit HIVECS          = 1'b0,
	parameter int ICACHE_SIZE     = 16384,
	parameter int ICACHE_WAYS     = 2,
	parameter bit ICACHE_PREFETCH = 1'b0,
	parameter int DCACHE_WAYS     = 2,
	parameter int CACHE_LINE      = 16
) (
	`ifdef CPU_PROFILE
    output logic [63:0] p_profile_flags,
    output logic [31:0] p_profile_pc,p_profile_ins,p_profile_retire_ins,p_profile_target,
`endif
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
	input  logic          bus_no_late_error,

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
	output logic          p_ic_fill_active,
	output logic          p_ic_fill_terminal,
	output logic          p_ic_fill_first_window,
	output logic [31:0]   p_ic_fill_addr,
	output logic [7:0]    p_icache,    // fetch, fill, arbitration and TLB taps
	output logic [3:0]    p_dcache,    // registered D-cache events exported by arm925t
	// data side, for the bus log: request to the D-cache, its virtual
	// address, alignment fault
	output logic          p_dreq,
	output logic [31:0]   p_dva,
	output logic          p_dalign,
	// address + 8 (+ 4 in Thumb) of the instruction making the data access
	output logic [31:0]   p_dpc8,
	// TLB walks: [0] a D-side walk starts, [1] of another section than the
	// check that asked for it, [2] an I-side walk starts, [3] of another
	// section; the walked and the missed (checked) addresses; for V2 the
	// memory pipeline's state and W's request when a D-side walk starts
	output logic [3:0]    p_tlbwalk,
	output logic [31:0]   p_dwalk_va, p_dwalk_miss_va, p_iwalk_va, p_iwalk_miss_va,
	output logic [4:0]    p_dwalk_ctx,
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
	output logic [2:0]    p_recovery, // 1 miss, 2 held/retry, 3 late hit, 4 ZAP replay
    output logic [5:0]    p_recovery_slots, // valid younger queue/uop slots, V2 only
	output logic [3:0]    p_mult_state
);
`ifdef CPU_PROFILE
    assign p_profile_flags=dut.profile_probe.flags;
    assign p_profile_pc=dut.profile_probe.decode_pc;
    assign p_profile_ins=dut.profile_probe.decode_ins;
    assign p_profile_retire_ins=dut.profile_probe.retire_ins;
    assign p_profile_target=dut.profile_probe.recovery_target;
`endif


	arm925t #(
		.ARM9_PREDICTOR (ARM9_PREDICTOR),
		.HIVECS          (HIVECS),
		.ICACHE_SIZE     (ICACHE_SIZE),
		.ICACHE_WAYS     (ICACHE_WAYS),
		.ICACHE_PREFETCH (ICACHE_PREFETCH),
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
		.bus_no_late_error(bus_no_late_error),
		.dbg_icache (p_icache),
		.dbg_dcache (p_dcache)
	);

	assign p_lock  = dut.u_zap.dc_lock;
	assign p_stall = dut.u_zap.o_dbg_stall;
	assign p_dreq  = dut.u_zap.cpu_dc_stb;
	assign p_dva   = dut.u_zap.cpu_daddr_va;
	assign p_dalign = dut.u_zap.cpu_align_fault;
	assign p_ttb   = dut.u_zap.cpu_baddr;
	// A walker fetches the descriptor of the address its cache presents
	// (zap_tlb_fsm i_address, captured while IDLE); the miss that started
	// it was decided on the check address registered with o_walk.
	`define TLBD dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_tlb
	`define TLBI dut.u_zap.l_generate_with_cache_mmu.u_code_cache.u_zap_tlb
	logic [31:0] dwalk_miss_va = 0, iwalk_miss_va = 0;
	always @(posedge clk) begin
		if (`TLBD.u_zap_tlb_check.i_clkena) dwalk_miss_va <= `TLBD.u_zap_tlb_check.i_va;
		if (`TLBI.u_zap_tlb_check.i_clkena) iwalk_miss_va <= `TLBI.u_zap_tlb_check.i_va;
	end
	assign p_tlbwalk = {`TLBI.u_zap_tlb_fsm.walk && `TLBI.u_zap_tlb_fsm.i_address[31:20] != iwalk_miss_va[31:20],
	                    `TLBI.u_zap_tlb_fsm.walk,
	                    `TLBD.u_zap_tlb_fsm.walk && `TLBD.u_zap_tlb_fsm.i_address[31:20] != dwalk_miss_va[31:20],
	                    `TLBD.u_zap_tlb_fsm.walk};
	assign p_dwalk_va = `TLBD.u_zap_tlb_fsm.i_address;
	assign p_dwalk_miss_va = dwalk_miss_va;
	assign p_iwalk_va = `TLBI.u_zap_tlb_fsm.i_address;
	assign p_iwalk_miss_va = iwalk_miss_va;
	`undef TLBD
	`undef TLBI
	assign p_dacr  = dut.u_zap.cpu_dac_reg;
	assign p_mmu   = dut.u_zap.cpu_mmu_en;
    assign p_arm9 = 1'b1;
    assign p_blocking_load = 1'b0; // V2 uses the shared nonblocking background write port.
    assign p_arm9_predictor = ARM9_PREDICTOR;
	wire cp_drain_done;
	if (1) begin : g_arm9_probes
    assign cp_drain_done = dut.u_zap.g_arm9.u_arm9_core.u_zap_cp15_cb.o_cp_done &&
        (dut.u_zap.g_arm9.u_arm9_core.u_zap_cp15_cb.i_cp_word[27:0] & 28'hfff0fff) == 28'he070f9a;
	`define A9 dut.u_zap.g_arm9.u_arm9_core
    assign p_dwalk_ctx = {`A9.request, 4'(`A9.memory_state)};

    // Snapshot before retirement changes the backend owners. These counters
    // describe discarded valid uop/queue slots, not unique ISA instructions.
    always @(posedge clk) begin
        p_recovery <= 0; p_recovery_slots <= 0;
        if (!reset && `A9.wb_complete && `A9.scalar_replay && !`A9.wb_exception) begin
            p_recovery <= `A9.i_data_short_hit ? 3'd3 : `A9.w_waited ? 3'd2 : 3'd1;
            p_recovery_slots <= 6'(`A9.u_front_decode.u_fetch.count) +
                6'(`A9.u_front_decode.u_decode.count) +
                6'(`A9.u_front_decode.u_decode.d2_valid) + 6'(`A9.d_valid) +
                6'(`A9.a_a_valid) + 6'(`A9.m[$bits(`A9.m)-1]) + 6'(`A9.skid[$bits(`A9.skid)-1]);
        end
    end
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
    // Compare the look-ahead matches with the producers actually occupying
    // their registers now, including all hold/retry/reload transitions.
    wire [23:0] producer_tags=`A9.mw_tag;
    wire [3:0] producer_writes=`A9.mw_write;
    wire [23:0] source_tags=`A9.d_tag;
    wire [15:0] source_matches=`A9.d_forward_match;
    always @(posedge clk) if(!reset&&`A9.d_valid)
        for(int src=0;src<4;src++)for(int prod=0;prod<2;prod++)for(int lane=0;lane<2;lane++)
            assert (source_matches[src*4+prod*2+lane] ==
                (`A9.d_used[src]&&producer_writes[prod*2+lane]&&
                source_tags[src*6+:6]==producer_tags[prod*12+lane*6+:6]))
                else $fatal(1,"ARM9 forwarding match lost its producer/consumer owner");
    // W's lock select belongs to the held request, including reload/SWP.
    // A first qualified hit must forward precisely the word being retired.
    always @(posedge clk) if(!reset)begin
        assert (`A9.w_load_select == (64'd1 << `A9.o_dc_reg_idx_bin))
            else $fatal(1,"ARM9 W lock selector lost its destination owner");
        if(`A9.wb_complete&&`A9.request&&!`A9.o_data_wb_we&&
           `A9.i_data_short_hit&&!`A9.w_waited&&!`A9.wb_exception)
            assert (`A9.i_data_short_data == `A9.load_data)
                else $fatal(1,"ARM9 speculative load word differs from retired response");
        if(`A9.wb_flush)begin
            assert (!`A9.wb_complete&&!`A9.request)
                else $fatal(1,"ARM9 younger work escaped retirement recovery");
        end
    end
    if(ARM9_PREDICTOR)begin : check_w_ras_repair
        logic checked;
        logic [2:0] expected_pointer;
        logic [3:0] expected_count;
        always @(posedge clk)begin
            if(!reset&&checked)begin
                assert (`A9.u_front_decode.u_fetch.g_predictor.u_predict.o_pointer==expected_pointer&&
                        `A9.u_front_decode.u_fetch.g_predictor.u_predict.o_count==expected_count)
                    else $fatal(1,"W recovery did not restore its own RAS checkpoint/action");
            end
            checked<=!reset&&`A9.wb_flush;
            expected_pointer<=`A9.wb_repair_pointer;
            expected_count<=`A9.wb_repair_count;
            case(`A9.wb_repair_action)
                1:begin
                    expected_pointer<=`A9.wb_repair_pointer+1'b1;
                    expected_count<=`A9.wb_repair_count==8?4'd8:`A9.wb_repair_count+1'b1;
                end
                2:if(`A9.wb_repair_count!=0)begin
                    expected_pointer<=`A9.wb_repair_pointer-1'b1;
                    expected_count<=`A9.wb_repair_count-1'b1;
                end
                3:begin expected_pointer<=0;expected_count<=0;end
                default:;
            endcase
        end
    end
	`undef A9
	end
	// These assertions also run against the baseline netlist: they observe
	// acknowledged accesses and the real RAM address/permission pipeline.
	`define DC dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_cache_fsm
	`define DT dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_cache_tag_ram
	`define TC dut.u_zap.l_generate_with_cache_mmu.u_data_cache.u_zap_tlb.u_zap_tlb_check
	localparam int DLINE_W = $clog2(CACHE_LINE);
	localparam int DSET_W = $clog2(16384 / DCACHE_WAYS / CACHE_LINE);   // the fixed 16 KB D-cache
	logic [DSET_W-1:0] dc_read_set, dc_response_set;
	logic dc_victim_valid;
	logic dc_installed;
	logic [31:DLINE_W] dc_victim_line;
	always_ff @(posedge clk) begin
		if (reset || `DC.o_idle) dc_installed <= 1'b0;
		else if (`DC.state_ff[7]) dc_installed <= 1'b1;
		if (!`DT.i_hold) begin
            dc_read_set <= `DT.rd_set;
            // SHORT_READ adds the registered compare/format response after
            // the RAM edge. Check the set belonging to that response.
            dc_response_set <= dc_read_set;
        end

		if (`DC.o_idle) begin
			dc_victim_valid <= `DC.i_cache_tag_valid;
			dc_victim_line <= {`DC.i_cache_tag[31-DLINE_W-DSET_W:0],
			                   `DC.i_address[DLINE_W +: DSET_W]};
		end
		// Only a presented access consumes the registered match (the HUM ACK,
		// live write and accepted-hit LRU update all need i_rd or i_wr). With
		// no request, ZAP's early compare follows the next check address and
		// may differ (seen in arm9_swi_lock_rtl's long deferred write-backs).
		if (!reset && `DC.hum_slot_ff && (`DC.i_rd || `DC.i_wr))
			assert (`DC.i_cache_hit_early == `DC.i_cache_hit)
				else $fatal(1, "Registered HUM tag match differs from live lookup");
		if (!reset && `DC.state_ff[7])
			assert (!`DC.o_ack) else $fatal(1, "Hit collided with fill installation");
		if (!reset && (`DC.state_ff[3] || `DC.state_ff[4] || `DC.state_ff[10]) &&
		    (`DC.i_rd || `DC.i_wr) && `DC.o_ack) begin
			assert (dc_response_set == `DC.i_address[DLINE_W +: DSET_W])
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

	// End-to-end demand CWF checks independent of the FSM's word selectors.
	// Count accepted beats; derive the expected order from the original miss.
	`define IC dut.u_zap.l_generate_with_cache_mmu.u_code_cache.u_zap_cache_fsm
	assign p_ic_fill_active = `IC.state_ff == 4;
	assign p_ic_fill_terminal = p_ic_fill_active && `IC.take && `IC.o_wb_cti_ff == 3'b111;
	assign p_ic_fill_first_window = p_ic_fill_active && `IC.adr_ctr_ff == 1 && !`IC.take;
	assign p_ic_fill_addr = `IC.address;
	if (CACHE_LINE == 16 && !ICACHE_PREFETCH) begin : g_icwf_check
		logic [31:0] expected_addr;
		logic [1:0] beat;
		logic [3:0] seen;
		logic [127:0] returned;
		logic pending, first_ready;
		logic [31:0] first_data;
		always @(posedge clk) begin
			if (reset) begin
				pending <= 1'b0;
				first_ready <= 1'b0;
				seen <= '0;
				beat <= '0;
			end else begin
				first_ready <= 1'b0;
				if (`IC.state_ff == 0 && `IC.state_nxt == 4) begin
					assert (!pending) else $fatal(1, "Overlapping I demand fills");
					expected_addr <= {`IC.i_phy_addr[31:2], 2'b00};
					beat <= '0;
					seen <= '0;
					pending <= 1'b1;
				end
				if (`IC.state_ff == 4 && `IC.take) begin
					assert (pending && `IC.o_wb_adr_ff == expected_addr)
						else $fatal(1, "I fill did not start at / wrap from critical word");
					assert (bus_req && !bus_we && bus_addr == expected_addr && bus_bte == 1)
						else $fatal(1, "I fill wrap/address lost through merger");
					assert (bus_burst == (beat != 3))
						else $fatal(1, "I fill EOB follows word index instead of beat count");
					assert (!seen[expected_addr[3:2]]) else $fatal(1, "I fill repeated a word");
					seen[expected_addr[3:2]] <= 1'b1;
					returned[32*expected_addr[3:2] +: 32] <= `IC.i_wb_dat;
					expected_addr <= {expected_addr[31:4], expected_addr[3:2] + 2'd1, 2'b00};
					beat <= beat + 2'd1;
					if (beat == 0 && `IC.fill_lookup[31:2] == `IC.address[31:2]) begin
						first_ready <= 1'b1;
						first_data <= `IC.i_wb_dat;
					end
				end
				if (first_ready) begin
					assert (`IC.fill_ready_ff && `IC.response_dat_ff == first_data)
						else $fatal(1, "Critical I word did not reach registered early-restart bypass");
				end
				if (`IC.state_ff == 8 && pending) begin
					assert (seen == 4'b1111 && `IC.fill_valid_ff == 4'b1111)
						else $fatal(1, "Incomplete I fill at completion");
					for (int w = 0; w < 4; w++)
						assert (`IC.buf_ff[w] == returned[32*w +: 32])
							else $fatal(1, "I fill installed rotated words");
					pending <= 1'b0;
				end
			end
		end
	end
	`undef IC

endmodule
