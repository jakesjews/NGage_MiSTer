// SPDX-License-Identifier: GPL-3.0-or-later
// ARM9 bring-up controller. Interface derived from ZAP by Revanth Kamaraj.
// See docs/ARM9.md for the conservative, non-overlapped bring-up schedule.
module arm9_core #(

        // For CP15 purposes.
        parameter logic [0:0]  CP15_L4_DEFAULT = 0,
        parameter logic [31:0] DATA_CACHE_SIZE = 1024,
        parameter logic [31:0] CODE_CACHE_SIZE = 1024,
        parameter logic [31:0] DATA_CACHE_LINE = 64,
        parameter logic [31:0] DATA_CACHE_WAYS = 1,     // ARM925T
        parameter logic        LOAD_FORMATTED  = 1'd0,  // ARM925T: the D-cache formats loads (zap_memory_main)
        parameter logic [31:0] CODE_CACHE_LINE = 64,

        // Reset vector. Safe to not override.
        parameter logic [31:0] RESET_VECTOR     = 32'd0,

        // Initial CPSR. Safe to not override.
        parameter logic [31:0] CPSR_INIT        = {24'd0, 1'd1,1'd1,1'd0,5'b10011},

        // For CP15 purposes. Actual conversion is handled at a higher module.
        parameter logic BE_32_ENABLE            = 1'd0,

        // Number of branch predictor entries.
        parameter logic [31:0] BP_ENTRIES       = 32'd1024,

        // Depth of FIFO.
        parameter logic [31:0] FIFO_DEPTH       = 32'd4,

        // RAS depth.
        parameter logic [31:0] RAS_DEPTH        = 32'd4,

        // CPSR mode.
        parameter logic [31:0] CPSR_MODE        = 32'd4,

        // ARM925T options (see zap_top).
        parameter logic        V4T              = 1'd0,
        parameter logic        TI925T           = 1'd0,
        parameter logic [31:0] CP15_ID          = 32'h0005AAA0,
        parameter logic [31:0] CP15_CTYPE       = 32'd0,
        parameter logic        HIVECS           = 1'd0
)
(

// ------------------------------------------------
// Trace port
// ------------------------------------------------

output logic [1023:0]                    o_trace,
output logic                             o_trace_valid,
output logic                             o_trace_uop_last,

// ------------------------------------------------
// Clock and reset. Reset is synchronous.
// ------------------------------------------------

input logic                              i_clk,
input logic                              i_reset,

// -------------------------------------------------
// Wishbone memory access for data.
// -------------------------------------------------

output logic                             o_data_wb_we,
output logic                             o_data_wb_cyc,
output logic                             o_data_wb_stb,
output logic[31:0]                       o_data_wb_adr,
input logic                              i_data_wb_ack,
input logic                              i_data_wb_err,
input logic  [31:0]                      i_data_wb_dat,
output logic [31:0]                      o_data_wb_dat,
output logic  [3:0]                      o_data_wb_sel,

// Next state stuff for Wishbone data.
output logic [31:0]                      o_data_wb_adr_nxt,

// Check.
output logic [31:0]                      o_data_wb_adr_check,
output logic                             o_data_wb_we_check,
output logic                             o_data_wb_re_check,

// Force user view.
output logic                             o_mem_translate,

// ARM925T: the access on o_data_wb_* breaks the alignment rule (control bit
// A) and its full virtual address, for the FAR.
output logic                             o_data_wb_align_fault,
output logic [31:0]                      o_data_wb_va,
// ARM925T: how a load on o_data_wb_* turns the word into the register
// value (address bits 1:0, signed byte, unsigned byte, signed halfword,
// unsigned halfword), for loads the D-cache completes in the background.
output logic [5:0]                       o_data_wb_ldfmt,

// ARM925T: single-line D-cache operation (zap_cp15_cb).
output logic                             o_dcache_line_req,
output logic [1:0]                       o_dcache_line_op,
output logic                             o_dcache_line_va,
output logic [31:0]                      o_dcache_line_addr,
output logic                             o_dcache_line_way,   // ARM925T
input  logic                             i_dcache_line_done,

// --------------------------------------------------
// Interrupts. Active high.
// --------------------------------------------------

input logic                              i_fiq,                  // FIQ signal.
input logic                              i_irq,                  // IRQ signal.

// ---------------------------------------------------
// Wishbone instruction access ports.
// ---------------------------------------------------

output logic     [31:0]                  o_instr_wb_adr, // Code address.
output logic                             o_instr_wb_cyc, // Always 1.
output logic                             o_instr_wb_stb, // Always 1.
output logic                             o_instr_wb_we,  // Always 0.
input logic [31:0]                       i_instr_wb_dat, // A 32-bit ZAP instruction.
input logic                              i_instr_wb_ack, // Instruction available.
input logic                              i_instr_wb_err, // Instruction abort fault.
output logic [3:0]                       o_instr_wb_sel, // wishbone byte select.

// Instruction wishbone nxt ports.
output logic     [31:0]                  o_instr_wb_adr_nxt,

// Check address.
output logic    [31:0]                   o_instr_wb_adr_check,

// Determines user or supervisory mode. Cache must use this for VM.
output logic      [CPSR_MODE:0]           o_cpsr,

// ARM925T: the mode of the data access being checked (with o_mem_translate)
output logic      [CPSR_MODE:0]           o_mem_cpsr,

// -----------------------------------------------------
// For MMU/cache connectivity.
// -----------------------------------------------------

output logic                             o_code_stall,
input logic      [31:0]                  i_fsr,
input logic      [31:0]                  i_far,
output logic      [31:0]                 o_dac,
output logic      [31:0]                 o_baddr,
output logic                             o_mmu_en,
output logic      [1:0]                  o_sr,
output logic      [7:0]                  o_pid,
output logic                             o_dcache_inv,
output logic                             o_icache_inv,
output logic                             o_dcache_clean,
output logic                             o_icache_clean,
output logic                             o_dtlb_inv,
output logic                             o_itlb_inv,
output logic                             o_dcache_en,
output logic                             o_icache_en,
input   logic                            i_dcache_inv_done,
input   logic                            i_icache_inv_done,
input   logic                            i_dcache_clean_done,
input   logic                            i_icache_clean_done,
input   logic                            i_icache_err2,
input logic i_icache_fill_pending, i_icache_fill_done, i_icache_fill_fault,
input   logic                            i_dcache_err2,

// -----------------------------------------------------
// Background load.
// -----------------------------------------------------

input   logic [63:0]                     i_dc_reg_idx, // Register to load to.
input   logic [31:0]                     i_dc_reg_dat, // Register data.
input   logic [63:0]                     i_dc_lock,    // Register that is locked.
output  logic [63:0]                     o_dc_reg_idx, // Register index.
output  logic [5:0]                      o_dc_reg_idx_bin, // Binary index.

// -----------------------------------------------------
// ARM925T: debug trace taps, the writeback stage's inputs
// (rtl/mister/dbg_trace.sv watches them as sim/harness/coreboot_main.cpp does).
// -----------------------------------------------------

output  logic                            o_dbg_wb_valid,
output  logic                            o_dbg_wfi,       // ARM925T: in wait for interrupt
output  logic                            o_dbg_wb_dvalid,
output  logic                            o_dbg_wb_uop_last,
output  logic [1:0]                      o_dbg_wb_dabt,
output  logic                            o_dbg_wb_pabt,
output  logic                            o_dbg_wb_und,
output  logic                            o_dbg_wb_swi,
output  logic                            o_dbg_wb_irq,
output  logic                            o_dbg_wb_fiq,
output  logic [31:0]                     o_dbg_wb_pc,
output  logic [31:0]                     o_dbg_wb_cpsr,
output  logic [31:0]                     o_dbg_wb_cpsr_nxt,
// ARM925T: where the clocks go (rtl/mister/dbg_counters.sv): the data
// side's bus wait, the fetch's, no instruction out of the fetch FIFO, the
// issue, shifter and decode stalls, the ALU's flush (a branch the predictor
// got wrong) and the writeback's (an exception, a CP15 fence).
output  logic [7:0]                      o_dbg_stall

);

`include "zap_localparams.svh"
`include "zap_defines.svh"
`include "zap_functions.svh"

// This first integration deliberately admits one architectural instruction at
// a time. Stage registers are real, but overlap/forwarding is a subsequent gate.
// No younger memory side effect can escape an older exception in this version.
typedef enum logic [4:0] {
    F1, F2, F3, FETCH, FETCH_TAIL, DECODE, SHIFT_WAIT, EXECUTE,
    M1, M2, M3, MEMORY, LOAD_CLASSIFY, LOAD_WAIT, WRITEBACK, COPRO
} state_t;
typedef enum logic [3:0] {
    K_DP, K_MRS, K_MSR, K_BRANCH, K_BX, K_MEM, K_BLOCK, K_CP,
    K_UND, K_SWI, K_BL_PREFIX, K_BL_SUFFIX, K_SWP
} kind_t;
state_t state;
kind_t kind_d, kind_e;
logic [31:0] pc, pc8, raw_ins, ins, cpsr, cpsr_next;
logic [34:0] translated;
logic thumb_und, thumb_align;
logic fetch_abort, irq_pending, fiq_pending;
logic [3:0][5:0] read_tag;
logic [3:0][31:0] read_value, value_d, value_e;
logic [3:0] op_d, op_e;
logic [1:0] shift_type_d, shift_type_e;
logic [4:0] shift_amount_d, shift_amount_e;
logic shift_register_d, shift_register_e, immediate_d, immediate_e;
logic immediate_carry_d, immediate_carry_e;
logic [31:0] ex_result, ex_store, ex_branch;
logic [3:0] ex_flags;
logic ex_pass, ex_write, ex_write_flags;
logic [31:0] flags_e, branch_offset_d, branch_offset_e;
logic [5:0] dst_e, base_e;
logic [31:0] psr_mask_d, psr_mask_e;
logic [31:0] m_address, m_write_data, m_read_data;
logic [3:0] m_sel;
logic [5:0] m_format, m_dst;
logic m_load, m_align, m_user;
logic swap_store;
logic [31:0] w_value, w_flags, w_target;
logic [5:0] w_dst;
logic w_valid, w_cfail, w_load, w_redirect, w_last;
logic w_dabt, w_pabt, w_irq, w_fiq, w_swi, w_und;
logic [15:0] remaining, list_d;
logic [3:0] transfer_reg_d;
logic [4:0] transfer_count_d;
logic sequence_active;
logic [31:0] sequence_address, sequence_base;
logic [31:0] copro_reg_wr_data, copro_reg_rd_data;
logic [5:0] copro_reg_wr_index, copro_reg_rd_index;
logic copro_done, copro_reg_en, align_en, hivecs, l4_enable;
logic [31:0] effective_address, updated_base, next_pc;
logic [31:0] vector_base;

// The common top supplies already formatted D-cache data. Parameters retained
// for the drop-in core interface that do not apply to this controller.
wire unused = &{1'b0, LOAD_FORMATTED, BP_ENTRIES, FIFO_DEPTH, RAS_DEPTH, translated[33:32]};
assign cpsr = o_dbg_wb_cpsr;
assign pc8 = pc + (cpsr[5] ? 32'd4 : 32'd8);
assign vector_base = hivecs ? 32'hffff0000 : 32'd0;
assign ins = translated[31:0];
// BL halves are decoded below from the original Thumb encoding; do not fold
// them together. Each half remains an interruptible architectural instruction.
zap_mode16_decoder #(.V4T(1'b1)) u_thumb (
    .i_instruction(raw_ins), .i_instruction_valid(1'b1), .i_offset(11'd0),
    .i_prev_prefix(1'b0), .i_irq(1'b0), .i_fiq(1'b0), .i_cpsr_ff_t(cpsr[5]),
    .o_instruction(translated), .o_instruction_valid(), .o_und(thumb_und),
    .o_force32_align(thumb_align), .o_irq(), .o_fiq()
);

function automatic [31:0] fcse(input [31:0] address);
    return address[31:25] == 0 ? {o_pid[6:0], address[24:0]} : address;
endfunction
function automatic [31:0] rotate_right(input [31:0] v, input [4:0] n);
    return (v >> n) | (v << ((32 - {1'b0,n}) & 63));
endfunction

always_comb begin
    kind_d = K_UND;
    if (ins[27:24] == 4'hf) kind_d = K_SWI;
    else if (ins[27:25] == 3'b101) kind_d = K_BRANCH;
    else if (ins[27:25] == 3'b100) kind_d = K_BLOCK;
    else if (ins[27:26] == 2'b01 && !(ins[25] && ins[4])) kind_d = K_MEM;
    else if ((ins & 32'h0fb00ff0) == 32'h01000090) kind_d = K_SWP;
    else if ((ins & 32'h0ffffff0) == 32'h012fff10) kind_d = K_BX;
    else if ((ins & 32'h0fbf0fff) == 32'h010f0000) kind_d = K_MRS;
    else if ((ins & 32'h0db0f000) == 32'h0120f000) kind_d = K_MSR;
    else if (ins[27:24] == 4'he && ins[4] && ins[11:8] == 4'hf)
        kind_d = cpsr[4:0] == USR ? K_UND : K_CP;
    else if (ins[27:25] == 0 && ins[7] && ins[4] && ins[6:5] != 0)
        kind_d = K_MEM;
    else if (ins[27:26] == 0 && !(ins[7] && ins[4] && !ins[25]) &&
             !(!ins[20] && ins[24:23] == 2'b10)) kind_d = K_DP;
    if (cpsr[5] && raw_ins[15:11] == 5'b11110) kind_d = K_BL_PREFIX;
    if (cpsr[5] && raw_ins[15:11] == 5'b11111) kind_d = K_BL_SUFFIX;
    if (thumb_und) kind_d = K_UND;

    list_d = sequence_active ? remaining : ins[15:0];
    // Empty register lists are deliberately undefined until their ARM9
    // writeback semantics have directed coverage.
    if (kind_d == K_BLOCK && list_d == 0) kind_d = K_UND;
    transfer_reg_d = 0;
    transfer_count_d = 0;
    for (int n=15; n>=0; n--) begin
        if (list_d[n]) transfer_reg_d = 4'(n);
        transfer_count_d = transfer_count_d + {4'd0, ins[n]};
    end
    read_tag[0] = translate({1'b0, ins[19:16]}, cpsr[4:0]);
    read_tag[1] = translate({1'b0, ins[3:0]}, cpsr[4:0]);
    read_tag[2] = translate(ARCH_CURR_SPSR, cpsr[4:0]);
    read_tag[3] = translate({1'b0, ins[15:12]}, cpsr[4:0]);
    if (kind_d == K_BLOCK)
        read_tag[3] = translate({1'b0, transfer_reg_d},
            ins[22] && !(ins[20] && ins[15]) ? USR : cpsr[4:0]);
    shift_register_d = kind_d == K_DP && !ins[25] && ins[4];
    if (shift_register_d) read_tag[2] = translate({1'b0,ins[11:8]}, cpsr[4:0]);
    if (kind_d == K_BL_SUFFIX) read_tag[1] = translate(5'd14, cpsr[4:0]);
end

always_comb begin
    op_d = ins[24:21];
    shift_type_d = ins[6:5];
    shift_amount_d = ins[11:7];
    value_d = read_value;
    for (int n=0; n<4; n++) begin
        if (read_tag[n] == PHY_PC) value_d[n] = pc8;
        if (read_tag[n] == PHY_CPSR) value_d[n] = cpsr;
    end
    if (shift_register_d) begin
        if (read_tag[0] == PHY_PC) value_d[0] = pc8 + 4;
        if (read_tag[1] == PHY_PC) value_d[1] = pc8 + 4;
    end
    if (thumb_align && read_tag[0] == PHY_PC) value_d[0][1:0] = 0;
    immediate_d = ins[25] && (kind_d == K_DP || kind_d == K_MSR);
    immediate_carry_d = cpsr[29];
    if (immediate_d) begin
        value_d[1] = rotate_right({24'd0,ins[7:0]}, {ins[11:8],1'b0});
        if (ins[11:8] != 0) immediate_carry_d = value_d[1][31];
    end
    if (kind_d == K_MEM) begin
        op_d = ins[23] ? ADD : SUB;
        if (ins[27:26] == 2'b01) begin
            immediate_d = !ins[25];
            if (!ins[25]) value_d[1] = {20'd0,ins[11:0]};
        end else begin
            immediate_d = ins[22];
            shift_type_d = 0;
            shift_amount_d = 0;
            if (ins[22]) value_d[1] = {24'd0,ins[11:8],ins[3:0]};
        end
    end
    if (kind_d == K_BX) begin
        op_d = MOV;
        shift_type_d = 0;
        shift_amount_d = 0;
        immediate_d = 0;
    end
    branch_offset_d = translated[34] ? {{7{ins[23]}},ins[23:0],1'b0} :
                                                     {{6{ins[23]}},ins[23:0],2'b0};
    psr_mask_d = {{8{ins[19]}},{8{ins[18]}},{8{ins[17]}},{8{ins[16]}}} & 32'hf00000ff;
    if (!ins[22]) begin
        psr_mask_d[5] = 0; // ARMv4 MSR never changes instruction state.
        if (cpsr[4:0] == USR) psr_mask_d[27:0] = 0;
    end
end

arm9_execute u_execute (
    .i_valid(state == EXECUTE),
    .i_condition((kind_e == K_BL_PREFIX || kind_e == K_BL_SUFFIX) ? 4'he : ins[31:28]),
    .i_op(op_e), .i_set_flags(kind_e == K_DP && ins[20]), .i_flags(flags_e[31:28]),
    .i_value(value_e), .i_tag('0), .i_used('0), .i_write_value('0),
    .i_write_tag('0), .i_write_valid('0), .i_write_ready('0),
    .i_shift_type(shift_type_e), .i_shift_amount(shift_amount_e),
    .i_shift_register(shift_register_e), .i_immediate(immediate_e),
    .i_shift_carry(immediate_carry_e), .i_pc8(pc8), .i_branch_offset(branch_offset_e),
    .o_result(ex_result), .o_store_data(ex_store), .o_branch_target(ex_branch),
    .o_flags(ex_flags), .o_condition_pass(ex_pass), .o_wait(),
    .o_execute(), .o_write_result(ex_write), .o_write_flags(ex_write_flags)
);

assign updated_base = sequence_active ? sequence_base :
    (ins[23] ? value_e[0] + {25'd0,transfer_count_d,2'b0} :
               value_e[0] - {25'd0,transfer_count_d,2'b0});
assign effective_address = kind_e == K_BLOCK ?
    (sequence_active ? sequence_address :
     (ins[23] ? value_e[0] + (ins[24] ? 4 : 0) :
                updated_base + (ins[24] ? 0 : 4))) :
    (kind_e == K_SWP ? value_e[0] : (ins[24] ? ex_result : value_e[0]));
assign next_pc = w_dabt ? vector_base + 16 :
                 w_fiq ? vector_base + 28 :
                 w_irq ? vector_base + 24 :
                 w_pabt ? vector_base + 12 :
                 w_swi ? vector_base + 8 :
                 w_und ? vector_base + 4 :
                 w_load && m_dst == PHY_PC ? m_read_data :
                 w_redirect ? w_target : pc + (cpsr[5] ? 2 : 4);

// Address launch, RAM pipeline and final request are distinct phases. The
// retained tag/valid/dirty/data RAMs take three enabled edges, not two.
assign o_instr_wb_adr_nxt = fcse(pc);
assign o_instr_wb_adr_check = fcse(pc);
assign o_instr_wb_adr = fcse(pc);
assign o_instr_wb_stb = state == FETCH;
assign o_instr_wb_cyc = o_instr_wb_stb;
assign o_instr_wb_we = 0;
assign o_instr_wb_sel = 4'hf;
assign o_code_stall = 0;
assign o_data_wb_adr_nxt = fcse({m_address[31:2],2'b00});
assign o_data_wb_adr_check = fcse({m_address[31:2],2'b00});
assign o_data_wb_adr = fcse({m_address[31:2],2'b00});
assign o_data_wb_we_check = state == M3 && !m_load;
assign o_data_wb_re_check = state == M3 && m_load;
assign o_data_wb_stb = state == MEMORY;
assign o_data_wb_cyc = o_data_wb_stb;
assign o_data_wb_we = !m_load;
assign o_data_wb_sel = m_sel;
assign o_data_wb_dat = m_write_data;
assign o_data_wb_align_fault = m_align;
assign o_data_wb_va = m_address;
assign o_data_wb_ldfmt = m_format;
assign o_mem_translate = m_user;
assign o_mem_cpsr = flags_e[CPSR_MODE:0];
assign o_cpsr = cpsr[CPSR_MODE:0];
assign o_dc_reg_idx = 64'd1 << m_dst;
assign o_dc_reg_idx_bin = m_dst;

always_ff @(posedge i_clk) begin
    if (i_reset) begin
        state <= F1;
        pc <= RESET_VECTOR;
        raw_ins <= 0;
        fetch_abort <= 0;
        irq_pending <= 0;
        fiq_pending <= 0;
        sequence_active <= 0;
        remaining <= 0;
        sequence_address <= 0;
        sequence_base <= 0;
        w_valid <= 0; w_cfail <= 0; w_last <= 1; w_load <= 0; w_redirect <= 0;
        w_dabt <= 0; w_pabt <= 0; w_irq <= 0; w_fiq <= 0; w_swi <= 0; w_und <= 0;
        w_value <= 0; w_flags <= CPSR_INIT; w_target <= 0; w_dst <= PHY_RAZ_REGISTER;
        m_address <= 0; m_write_data <= 0; m_read_data <= 0; m_sel <= 0;
        m_format <= 0; m_dst <= PHY_RAZ_REGISTER;
        m_load <= 0; m_align <= 0; m_user <= 0; swap_store <= 0;
        kind_e <= K_UND; op_e <= 0; value_e <= '0; flags_e <= CPSR_INIT;
        shift_type_e <= 0; shift_amount_e <= 0; shift_register_e <= 0;
        immediate_e <= 0; immediate_carry_e <= 0; branch_offset_e <= 0;
        dst_e <= PHY_RAZ_REGISTER; base_e <= PHY_RAZ_REGISTER; psr_mask_e <= 0;
    end else case (state)
        F1: state <= F2;
        F2: state <= F3;
        F3: state <= FETCH;
        FETCH: if (i_instr_wb_ack || i_instr_wb_err) begin
            if (i_icache_err2) state <= F1;
            else begin
                raw_ins <= cpsr[5] && pc[1] ? {16'd0,i_instr_wb_dat[31:16]} : i_instr_wb_dat;
                fetch_abort <= i_instr_wb_err;
                state <= i_icache_fill_pending ? FETCH_TAIL : DECODE;
            end
        end
        FETCH_TAIL: if (i_icache_fill_done) begin
            fetch_abort <= fetch_abort || i_icache_fill_fault;
            state <= DECODE;
        end
        DECODE: begin
            kind_e <= kind_d;
            value_e <= value_d;
            op_e <= op_d;
            shift_type_e <= shift_type_d;
            shift_amount_e <= shift_amount_d;
            shift_register_e <= shift_register_d;
            immediate_e <= immediate_d;
            immediate_carry_e <= immediate_carry_d;
            branch_offset_e <= branch_offset_d;
            psr_mask_e <= psr_mask_d;
            flags_e <= cpsr;
            dst_e <= read_tag[3];
            base_e <= read_tag[0];
            fiq_pending <= !sequence_active && i_fiq && !cpsr[6];
            irq_pending <= !sequence_active && i_irq && !cpsr[7];
            state <= shift_register_d && is_cc_satisfied(ins[31:28],cpsr[31:28]) ? SHIFT_WAIT : EXECUTE;
        end
        SHIFT_WAIT: state <= EXECUTE;
        EXECUTE: begin
            state <= WRITEBACK;
            w_valid <= ex_pass;
            w_cfail <= !ex_pass;
            w_last <= 1;
            swap_store <= 0;
            w_load <= 0;
            w_redirect <= 0;
            w_dabt <= 0; w_pabt <= 0; w_irq <= 0; w_fiq <= 0; w_swi <= 0; w_und <= 0;
            w_dst <= PHY_RAZ_REGISTER;
            w_value <= pc + 4; // ARM exception link (Thumb supplied by writeback).
            w_flags <= flags_e;
            if (fiq_pending || irq_pending || fetch_abort) begin
                w_fiq <= fiq_pending;
                w_irq <= !fiq_pending && irq_pending;
                w_pabt <= !fiq_pending && !irq_pending && fetch_abort;
                w_valid <= 0;
                w_cfail <= 0;
            end else if (ex_pass) case (kind_e)
                K_DP: begin
                    if (ex_write) begin
                        w_dst <= dst_e;
                        w_value <= ex_result;
                        if (dst_e == PHY_PC) begin
                            w_redirect <= 1;
                            w_target <= ex_result;
                        end
                    end
                    if (ex_write_flags) w_flags[31:28] <= ex_flags;
                    if (dst_e == PHY_PC && ins[20] && ex_write)
                        w_flags <= value_e[2] & 32'hf00000ff;
                end
                K_MRS: begin
                    w_dst <= dst_e;
                    w_value <= ins[22] ? value_e[2] : flags_e;
                end
                K_MSR: begin
                    if (ins[22] && cpsr[4:0] != USR && cpsr[4:0] != SYS) begin
                        w_dst <= translate(ARCH_CURR_SPSR,cpsr[4:0]);
                        w_value <= (value_e[2] & ~psr_mask_e) | (value_e[1] & psr_mask_e);
                    end else if (!ins[22])
                        w_flags <= (flags_e & ~psr_mask_e) | (value_e[1] & psr_mask_e);
                end
                K_BRANCH: begin
                    w_redirect <= 1;
                    w_target <= ex_branch;
                    if (ins[24]) begin
                        w_dst <= translate(5'd14,cpsr[4:0]);
                        w_value <= pc + 4;
                    end
                end
                K_BX: begin
                    w_redirect <= 1;
                    w_target <= ex_result;
                    w_flags[5] <= ex_result[0];
                end
                K_BL_PREFIX: begin
                    w_dst <= translate(5'd14,cpsr[4:0]);
                    w_value <= pc8 + {{9{raw_ins[10]}},raw_ins[10:0],12'd0};
                end
                K_BL_SUFFIX: begin
                    w_dst <= translate(5'd14,cpsr[4:0]);
                    w_value <= (pc + 2) | 1;
                    w_redirect <= 1;
                    w_target <= value_e[1] + {20'd0,raw_ins[10:0],1'b0};
                end
                K_MEM, K_BLOCK, K_SWP: begin
                    state <= M1;
                    m_address <= effective_address;
                    m_dst <= dst_e;
                    m_load <= kind_e == K_SWP || ins[20];
                    w_load <= kind_e == K_SWP || ins[20];
                    m_user <= kind_e == K_MEM && !ins[24] && ins[21];
                    m_align <= align_en && |effective_address[1:0];
                    m_format <= {effective_address[1:0],4'b0000};
                    m_sel <= 4'hf;
                    m_write_data <= ex_store;
                    if (kind_e == K_SWP) begin
                        m_write_data <= value_e[1];
                        if (ins[22]) begin
                            m_sel <= 4'b0001 << effective_address[1:0];
                            m_write_data <= {4{value_e[1][7:0]}};
                            m_format[2] <= 1;
                            m_align <= 0;
                        end
                    end else if (kind_e == K_MEM) begin
                        if (ins[21] || !ins[24]) begin
                            w_dst <= base_e;
                            w_value <= ex_result;
                        end
                        if (ins[27:26] == 2'b01 && ins[22]) begin
                            m_sel <= 4'b0001 << effective_address[1:0];
                            m_write_data <= {4{ex_store[7:0]}};
                            m_format[2] <= 1;
                            m_align <= 0;
                        end else if (ins[27:26] == 0) begin
                            case (ins[6:5])
                                2'b01: begin
                                    m_sel <= effective_address[1] ? 4'b1100 : 4'b0011;
                                    m_write_data <= {2{ex_store[15:0]}};
                                    m_format[0] <= 1;
                                    m_align <= align_en && effective_address[0];
                                end
                                2'b10: begin
                                    m_sel <= 4'b0001 << effective_address[1:0];
                                    m_format[3] <= 1;
                                    m_align <= 0;
                                end
                                2'b11: begin
                                    m_sel <= effective_address[1] ? 4'b1100 : 4'b0011;
                                    m_format[1] <= 1;
                                    m_align <= align_en && effective_address[0];
                                end
                                default: ;
                            endcase
                        end
                    end else begin
                        remaining <= list_d & ~(16'd1 << transfer_reg_d);
                        sequence_active <= 1;
                        sequence_address <= effective_address + 4;
                        sequence_base <= updated_base;
                        w_last <= (list_d & (list_d - 1)) == 0;
                        if ((list_d & (list_d - 1)) == 0) begin
                            if (ins[21]) begin w_dst <= base_e; w_value <= updated_base; end
                            if (ins[20] && ins[15] && ins[22]) w_flags <= value_e[2];
                        end
                    end
                end
                K_CP: begin w_valid <= 0; state <= COPRO; end
                K_SWI: begin w_valid <= 0; w_swi <= 1; end
                default: begin w_valid <= 0; w_und <= 1; end
            endcase
        end
        M1: state <= M2;
        M2: state <= M3;
        M3: state <= MEMORY;
        MEMORY: if (i_data_wb_ack || i_data_wb_err) begin
            if (i_dcache_err2) state <= M1;
            else if (i_data_wb_err) begin
                w_valid <= 0;
                w_dabt <= 1;
                w_last <= 1;
                state <= WRITEBACK;
            end else begin
                if (m_load) m_read_data <= i_data_wb_dat;
                // A miss sets lock_ff at this edge; inspecting the old lock
                // here would retire the victim's data. Classify one edge later.
                state <= LOAD_CLASSIFY;
            end
        end
        LOAD_CLASSIFY: begin
            if (m_load && i_dc_reg_idx[m_dst]) begin
                m_read_data <= i_dc_reg_dat;
                state <= kind_e == K_SWP ? M1 : WRITEBACK;
                if (kind_e == K_SWP) begin m_load <= 0; swap_store <= 1; end
            end else if (m_load && i_dc_lock[m_dst]) state <= LOAD_WAIT;
            else if (kind_e == K_SWP && !swap_store) begin
                m_load <= 0;
                swap_store <= 1;
                state <= M1;
            end else state <= WRITEBACK;
        end
        LOAD_WAIT: if (i_dc_reg_idx[m_dst]) begin
            m_read_data <= i_dc_reg_dat;
            state <= kind_e == K_SWP ? M1 : WRITEBACK;
            if (kind_e == K_SWP) begin m_load <= 0; swap_store <= 1; end
        end
        COPRO: if (copro_done) begin
            w_valid <= 1;
            // MRC r15 changes flags, never PC. The CP block presents its
            // value while reg_en is asserted earlier; handled separately below.
            state <= WRITEBACK;
        end
        WRITEBACK: begin
            if (!w_last && !w_dabt) state <= DECODE;
            else begin
                sequence_active <= 0;
                pc <= cpsr_next[5] ? (next_pc & 32'hfffffffe) : (next_pc & 32'hfffffffc);
                state <= F1;
            end
        end
        default: state <= F1;
    endcase
end

assign o_dbg_wb_valid = state == WRITEBACK && w_valid;
assign o_dbg_wb_dvalid = state == WRITEBACK && w_cfail;
assign o_dbg_wb_uop_last = w_last;
assign o_dbg_wb_dabt = {1'b0,state == WRITEBACK && w_dabt};
assign o_dbg_wb_pabt = state == WRITEBACK && w_pabt;
assign o_dbg_wb_irq = state == WRITEBACK && w_irq;
assign o_dbg_wb_fiq = state == WRITEBACK && w_fiq;
assign o_dbg_wb_swi = state == WRITEBACK && w_swi;
assign o_dbg_wb_und = state == WRITEBACK && w_und;
assign o_dbg_wb_pc = pc8;
assign o_dbg_wb_cpsr_nxt = cpsr_next;
assign o_dbg_stall = {state == WRITEBACK && (w_dabt || w_pabt || w_irq || w_fiq || w_swi || w_und),
    state == WRITEBACK && w_redirect, state == COPRO || sequence_active,
    state == SHIFT_WAIT, 1'b0, state <= FETCH_TAIL, state == FETCH,
    state == MEMORY || state == LOAD_WAIT};

// Retain ZAP's proven banked state and exception entry logic. Its old fetch
// PC/BTB is disconnected; the new controller owns fetch and has no predictor.
zap_writeback #(.BP_ENTRIES(32), .PHY_REGS(40), .FLAG_WDT(32),
    .RESET_VECTOR(RESET_VECTOR), .CPSR_INIT(CPSR_INIT)) u_zap_writeback (
    .i_clk(i_clk), .i_reset(i_reset), .i_valid(o_dbg_wb_valid),
    .i_decompile('0), .i_decompile_valid(o_dbg_wb_dvalid), .i_uop_last(w_last),
    .o_decompile(), .o_shelve(), .i_cpu_pid(o_pid[6:0]),
    .i_l4_enable(l4_enable), .i_hivecs(hivecs), .i_clear_btb(1'b0),
    .i_code_stall(1'b1), .i_clear_from_alu(1'b0), .i_pc_from_alu(32'd0),
    .i_clear_from_decode(1'b0), .i_pc_from_decode(32'd0),
    .i_clear_from_icache(1'b0), .i_confirm_from_alu(1'b0),
    .i_alu_pc_ff(32'd0), .i_taken(2'd0),
    .i_rd_index_0(read_tag[0]), .i_rd_index_1(read_tag[1]),
    .i_rd_index_2(read_tag[2]), .i_rd_index_3(read_tag[3]),
    .i_mem_load_ff(w_load), .i_wr_index(w_dst), .i_wr_data(w_value),
    .i_flags(w_flags), .i_wr_index_1(m_dst), .i_wr_data_1(m_read_data),
    .i_wr_index_2(40'd0), .i_wr_data_2(32'd0), .i_mode16(cpsr[5]),
    .i_irq(o_dbg_wb_irq), .i_fiq(o_dbg_wb_fiq), .i_instr_abt(o_dbg_wb_pabt),
    .i_data_abt(o_dbg_wb_dabt), .i_swi(o_dbg_wb_swi), .i_und(o_dbg_wb_und),
    .i_pc_plus_8_buf_ff(pc8), .i_copro_reg_en(copro_reg_en),
    .i_copro_reg_wr_index(copro_reg_wr_index),
    .i_copro_reg_rd_index(copro_reg_rd_index), .i_copro_reg_wr_data(copro_reg_wr_data),
    .o_copro_reg_rd_data_ff(copro_reg_rd_data),
    .o_rd_data_0(read_value[0]), .o_rd_data_1(read_value[1]),
    .o_rd_data_2(read_value[2]), .o_rd_data_3(read_value[3]),
    .o_pc(), .o_pc_check(), .o_pc_nxt(), .o_taken(), .o_pred(),
    .o_cpsr_nxt(cpsr_next), .o_dbg_cpsr_ff(o_dbg_wb_cpsr),
    .o_clear_from_writeback(), .o_wb_stb(), .o_wb_cyc(),
    .o_trace(o_trace), .o_trace_valid(o_trace_valid), .o_trace_uop_last(o_trace_uop_last)
);

zap_cp15_cb #(
.BE_32_ENABLE(BE_32_ENABLE),
.PHY_REGS(40),
.CP15_L4_DEFAULT(CP15_L4_DEFAULT),
.V4T(V4T),
.TI925T(TI925T),
.CP15_ID(CP15_ID),
.CP15_CTYPE(CP15_CTYPE),
.HIVECS(HIVECS),
.DATA_CACHE_SIZE(DATA_CACHE_SIZE),
.CODE_CACHE_SIZE(CODE_CACHE_SIZE),
.DATA_CACHE_LINE(DATA_CACHE_LINE),
.DATA_CACHE_WAYS(DATA_CACHE_WAYS),
.CODE_CACHE_LINE(CODE_CACHE_LINE)
) u_zap_cp15_cb (
        .i_clk                  (i_clk),
        .i_reset                (i_reset),
        .i_cp_word              (ins),
        .i_cp_dav               (state == COPRO),
        .o_cp_done              (copro_done),
        .i_cpsr                 (cpsr),
        .o_reg_en               (copro_reg_en),
        .o_reg_wr_data          (copro_reg_wr_data),
        .i_reg_rd_data          (copro_reg_rd_data),
        .o_reg_wr_index         (copro_reg_wr_index),
        .o_reg_rd_index         (copro_reg_rd_index),

        .i_fsr                  (i_fsr),
        .i_far                  (i_far),
        .o_dac                  (o_dac),
        .o_baddr                (o_baddr),
        .o_mmu_en               (o_mmu_en),
        .o_wfi                  (o_dbg_wfi),
        .o_sr                   (o_sr),
        .o_pid                  (o_pid),
        .o_l4_enable            (l4_enable),
        .o_dcache_inv           (o_dcache_inv),
        .o_icache_inv           (o_icache_inv),
        .o_dcache_clean         (o_dcache_clean),
        .o_icache_clean         (o_icache_clean),
        .o_dtlb_inv             (o_dtlb_inv),
        .o_itlb_inv             (o_itlb_inv),
        .o_dcache_en            (o_dcache_en),
        .o_icache_en            (o_icache_en),
        .i_dcache_inv_done      (i_dcache_inv_done),
        .i_icache_inv_done      (i_icache_inv_done),
        .i_dcache_clean_done    (i_dcache_clean_done),
        .i_icache_clean_done    (i_icache_clean_done),
        .i_irq                  (i_irq),
        .i_fiq                  (i_fiq),
        .o_hivecs               (hivecs),
        .o_align_en             (align_en),
        .o_dcache_line_req      (o_dcache_line_req),
        .o_dcache_line_op       (o_dcache_line_op),
        .o_dcache_line_va       (o_dcache_line_va),
        .o_dcache_line_addr     (o_dcache_line_addr),
        .o_dcache_line_way      (o_dcache_line_way),
        .i_dcache_line_done     (i_dcache_line_done)
);


endmodule
