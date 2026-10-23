// SPDX-License-Identifier: GPL-3.0-or-later
// ARM9 bring-up controller. Interface derived from ZAP by Revanth Kamaraj.
// See docs/ARM9.md for overlap, forwarding and serialized-operation boundaries.
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
output logic                             o_instr_wb_cyc, // Qualified fetch request.
output logic                             o_instr_wb_stb, // Qualified fetch request.
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
output logic                             o_data_stall,
input logic                              i_data_fill_busy,
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

// D is the fetch queue head; E owns decoded operands and control. Arithmetic,
// branches and memory share ordered records across the three native cache RAM
// edges and W. Block transfers feed one register per enabled edge into the same
// pipeline. State operations and SWP drain it before using the slow context.
typedef enum logic [3:0] {
    IDLE,
    M1, M2, M3, MEMORY, LOAD_CLASSIFY, LOAD_WAIT, WRITEBACK, COPRO, RESTORE_BASE, MUL_ADD, MUL_WAIT
} state_t;
typedef enum logic [3:0] {
    K_DP, K_MRS, K_MSR, K_BRANCH, K_BX, K_MEM, K_BLOCK, K_CP,
    K_UND, K_SWI, K_BL_PREFIX, K_BL_SUFFIX, K_SWP, K_MUL, K_MULL
} kind_t;
state_t state;
kind_t kind_d, kind_e;
logic [31:0] pc, pc8, raw_ins, ins, cpsr, cpsr_next;
logic [31:0] d_pc, d_pc8, d_raw, d_ins;
logic [3:0][5:0] tag_e;
logic [3:0] used_e;
logic fast_d, fast_e, issue, execute_fast, early_redirect;
logic e_valid, e_shifted, execute_wait;
logic wb_cycle;
logic retire_fast, pipe_hold, pipe_fault;
logic [1:0] data_reload;
logic fast_load_ready, block_issue, block_restore_fault, pipe_pc_redirect;
logic [31:0] sequence_flags;
logic [3:0][31:0] held_value;
logic [3:0] held_wait;
// No state after E may read a younger instruction's live E metadata.
// The data request, its fault and its retirement all belong to this record.
typedef struct packed {
    logic [31:0] pc, pc8, ins, raw, flags;
    logic [5:0] base, dst;
    kind_t kind;
} slow_t;
slow_t slow;
wire [31:0] data_pc8 = state == IDLE ? fast_m.pc8 : slow.pc8;
logic [31:0] execute_flags;
typedef struct packed {
    logic present, pass;
    logic [5:0] dst;
    logic [31:0] value, flags, pc8;
    logic memory, load, align_fault, user_access, fault, block_transfer, last;
    logic [5:0] load_dst, format;
    logic [4:0] access_mode;
    logic [3:0] sel;
    logic [31:0] address, store_data, load_data;
} result_t;
result_t fast_1, fast_2, fast_m, fast_w, fast_input;
result_t [3:0] producers;
logic [7:0][31:0] forward_value;
logic [7:0][5:0] forward_tag;
logic [7:0] forward_valid, forward_ready;
logic [3:0][31:0] forwarded_read;
logic [3:0] unused_read_wait;
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
logic [31:0] branch_offset_d, branch_offset_e;
logic [5:0] dst_e, base_e;
logic [31:0] psr_mask_d, psr_mask_e;
logic [31:0] m_address, m_write_data, m_read_data;
logic [3:0] m_sel;
logic [5:0] m_format, m_dst;
logic m_load, m_align, m_user;
logic swap_store;
logic [31:0] w_value, w_flags, w_target;
logic [5:0] w_dst;
logic w_valid, w_cfail, w_load, w_redirect;
logic w_dabt, w_pabt, w_irq, w_fiq, w_swi, w_und;
logic [15:0] remaining, list_d;
logic [3:0] transfer_reg_d;
logic [4:0] transfer_count_d, transfer_count_e;
logic [7:0] block_delta_e;
logic [15:0] list_e;
logic sequence_active;
logic [31:0] sequence_address, sequence_base, sequence_original;
logic [63:0] multiply_product, multiply_accumulator, multiply_result;
logic [2:0] multiply_delay;
logic [31:0] copro_reg_wr_data, copro_reg_rd_data;
logic [5:0] copro_reg_wr_index, copro_reg_rd_index;
logic copro_done, copro_reg_en, align_en, hivecs, l4_enable;
logic [31:0] effective_address, updated_base, next_pc;
logic [31:0] vector_base;

// A hit's data is registered before classification. With no new lock it
// can retire on that edge; a miss captures its critical word before W.
assign wb_cycle = (state == WRITEBACK) ||
    (state == LOAD_CLASSIFY && !i_dc_lock[m_dst] && slow.kind != K_SWP);

// The common top supplies already formatted D-cache data. Parameters retained
// for the drop-in core interface that do not apply to this controller.
    wire load_capture = (state == LOAD_CLASSIFY || state == LOAD_WAIT) &&
                           m_load && i_dc_reg_idx[m_dst] ||
                           (fast_w.present && fast_w.load && i_dc_reg_idx[fast_w.load_dst]);
    wire [31:0] load_value = fast_w.present ? fast_w.load_data : m_read_data;
    wire [63:0] load_commit = retire_fast && fast_w.pass && fast_w.load && !fast_w.fault ?
                          (64'd1 << fast_w.load_dst) : wb_cycle && w_valid && w_load &&
                          (slow.kind == K_MEM || slow.kind == K_SWP) ?
                          (64'd1 << m_dst) : 64'd0;

wire unused = &{1'b0, LOAD_FORMATTED, BP_ENTRIES, FIFO_DEPTH, RAS_DEPTH, translated[33:32], load_capture, load_commit, unused_read_wait, held_wait, data_pc8, load_value};
assign cpsr = o_dbg_wb_cpsr;
assign pc8 = pc + (cpsr[5] ? 32'd4 : 32'd8);
assign vector_base = hivecs ? 32'hffff0000 : 32'd0;
assign d_ins = sequence_active ? slow.ins : translated[31:0];
assign d_pc = sequence_active ? slow.pc : f_pc;
assign d_pc8 = d_pc + (cpsr[5] ? 32'd4 : 32'd8);
assign d_raw = sequence_active ? slow.raw : f_instruction;
// Thumb translation is registered in the fetch queue. BL halves still use
// the original encoding and remain separate, interruptible instructions.

function automatic [31:0] fcse(input [31:0] address);
    return address[31:25] == 0 ? {o_pid[6:0], address[24:0]} : address;
endfunction
function automatic [2:0] multiply_iterations(input [31:8] rs, input signed_end);
    if (rs[31:8] == 0 || (signed_end && (&rs[31:8]))) return 1;
    if (rs[31:16] == 0 || (signed_end && (&rs[31:16]))) return 2;
    if (rs[31:24] == 0 || (signed_end && (&rs[31:24]))) return 3;
    return 4;
endfunction
function automatic [31:0] rotate_right(input [31:0] v, input [4:0] n);
    return (v >> n) | (v << ((32 - {1'b0,n}) & 63));
endfunction

always_comb begin
    kind_d = K_UND;
    if (d_ins[27:24] == 4'hf) kind_d = K_SWI;
    else if (d_ins[27:25] == 3'b101) kind_d = K_BRANCH;
    else if (d_ins[27:25] == 3'b100) kind_d = K_BLOCK;
    else if (d_ins[27:26] == 2'b01 && !(d_ins[25] && d_ins[4])) kind_d = K_MEM;
    else if ((d_ins & 32'h0fc000f0) == 32'h00000090) kind_d = K_MUL;
    else if ((d_ins & 32'h0f8000f0) == 32'h00800090) kind_d = K_MULL;
    else if ((d_ins & 32'h0fb00ff0) == 32'h01000090) kind_d = K_SWP;
    else if ((d_ins & 32'h0ffffff0) == 32'h012fff10) kind_d = K_BX;
    else if ((d_ins & 32'h0fbf0fff) == 32'h010f0000) kind_d = K_MRS;
    else if ((d_ins & 32'h0fb0fff0) == 32'h0120f000 ||
             (d_ins & 32'h0fb0f000) == 32'h0320f000) kind_d = K_MSR;
    else if (d_ins[27:24] == 4'he && d_ins[4] && d_ins[11:8] == 4'hf)
        kind_d = cpsr[4:0] == USR ? K_UND : K_CP;
    else if (d_ins[27:25] == 0 && d_ins[7] && d_ins[4] && d_ins[6:5] != 0)
        kind_d = K_MEM;
    else if (d_ins[27:26] == 0 && !(d_ins[7] && d_ins[4] && !d_ins[25]) &&
             !(!d_ins[20] && d_ins[24:23] == 2'b10)) kind_d = K_DP;
    if (cpsr[5] && d_raw[15:11] == 5'b11110) kind_d = K_BL_PREFIX;
    if (cpsr[5] && d_raw[15:11] == 5'b11111) kind_d = K_BL_SUFFIX;
    // ARMv4T treats condition NV and ARMv5 doubleword transfers as undefined.
    if ((!cpsr[5] && d_ins[31:28] == 4'hf) ||
        (kind_d == K_MEM && d_ins[27:26] == 0 && !d_ins[20] && d_ins[6]) ||
        (cpsr[5] && d_raw[15:11] == 5'b11101) || (!sequence_active && thumb_und))
        kind_d = K_UND;

    list_d = sequence_active ? remaining : d_ins[15:0];
    // Empty register lists are deliberately undefined until their ARM9
    // writeback semantics have directed coverage.
    if (kind_d == K_BLOCK && list_d == 0) kind_d = K_UND;
    transfer_reg_d = 0;
    transfer_count_d = 0;
    for (int n=15; n>=0; n--) begin
        if (list_d[n]) transfer_reg_d = 4'(n);
        transfer_count_d = transfer_count_d + {4'd0, d_ins[n]};
    end
    read_tag[0] = translate({1'b0, d_ins[19:16]}, cpsr[4:0]);
    read_tag[1] = translate({1'b0, d_ins[3:0]}, cpsr[4:0]);
    read_tag[2] = translate(ARCH_CURR_SPSR, cpsr[4:0]);
    read_tag[3] = translate({1'b0, d_ins[15:12]}, cpsr[4:0]);
    // A flag-restoring PC write needs SPSR in addition to Rn/Rm/Rs. The
    // fourth port is otherwise unused by data processing, even with Rs.
    if (kind_d == K_DP && d_ins[20] && d_ins[15:12] == 15)
        read_tag[3] = translate(ARCH_CURR_SPSR, cpsr[4:0]);
    if (kind_d == K_BLOCK)
        read_tag[3] = translate({1'b0, transfer_reg_d},
            d_ins[22] && !(d_ins[20] && d_ins[15]) ? USR : cpsr[4:0]);
    shift_register_d = kind_d == K_DP && !d_ins[25] && d_ins[4];
    if (kind_d == K_MUL || kind_d == K_MULL) read_tag[2] = translate({1'b0,d_ins[11:8]}, cpsr[4:0]);
    if (shift_register_d) read_tag[2] = translate({1'b0,d_ins[11:8]}, cpsr[4:0]);
    if (kind_d == K_BL_SUFFIX) read_tag[1] = translate(5'd14, cpsr[4:0]);
end

always_comb begin
    op_d = d_ins[24:21];
    shift_type_d = d_ins[6:5];
    shift_amount_d = d_ins[11:7];
    value_d = forwarded_read;
    for (int n=0; n<4; n++) begin
        if (read_tag[n] == PHY_PC) value_d[n] = d_pc8;
        if (read_tag[n] == PHY_CPSR) value_d[n] = cpsr;
    end
    if (shift_register_d) begin
        if (read_tag[0] == PHY_PC) value_d[0] = d_pc8 + 4;
        if (read_tag[1] == PHY_PC) value_d[1] = d_pc8 + 4;
    end
    if (!sequence_active && thumb_align && read_tag[0] == PHY_PC) value_d[0][1:0] = 0;
    immediate_d = d_ins[25] && (kind_d == K_DP || kind_d == K_MSR);
    immediate_carry_d = cpsr[29];
    if (immediate_d) begin
        value_d[1] = rotate_right({24'd0,d_ins[7:0]}, {d_ins[11:8],1'b0});
        if (d_ins[11:8] != 0) immediate_carry_d = value_d[1][31];
    end
    if (kind_d == K_MEM) begin
        op_d = d_ins[23] ? ADD : SUB;
        if (d_ins[27:26] == 2'b01) begin
            immediate_d = !d_ins[25];
            if (!d_ins[25]) value_d[1] = {20'd0,d_ins[11:0]};
        end else begin
            immediate_d = d_ins[22];
            shift_type_d = 0;
            shift_amount_d = 0;
            if (d_ins[22]) value_d[1] = {24'd0,d_ins[11:8],d_ins[3:0]};
        end
    end
    if (kind_d == K_BX) begin
        op_d = MOV;
        shift_type_d = 0;
        shift_amount_d = 0;
        immediate_d = 0;
    end
    branch_offset_d = translated[34] ? {{7{d_ins[23]}},d_ins[23:0],1'b0} :
                                                     {{6{d_ins[23]}},d_ins[23:0],2'b0};
    psr_mask_d = {{8{d_ins[19]}},{8{d_ins[18]}},{8{d_ins[17]}},{8{d_ins[16]}}} & 32'hf00000ff;
    if (!d_ins[22]) begin
        psr_mask_d[5] = 0; // ARMv4 MSR never changes instruction state.
        if (cpsr[4:0] == USR) psr_mask_d[27:0] = 0;
    end
end

arm9_execute #(.PRODUCERS(8)) u_execute (
    .i_valid(e_valid),
    .i_condition((kind_e == K_BL_PREFIX || kind_e == K_BL_SUFFIX || (kind_e == K_UND && cpsr[5]) || (!cpsr[5] && ins[31:28] == 4'hf)) ? 4'he : ins[31:28]),
    .i_op(op_e), .i_set_flags(kind_e == K_DP && ins[20]), .i_flags(execute_flags[31:28]),
    .i_value(value_e), .i_tag(tag_e), .i_used(used_e), .i_write_value(forward_value),
    .i_write_tag(forward_tag), .i_write_valid(forward_valid), .i_write_ready(forward_ready),
    .i_shift_type(shift_type_e), .i_shift_amount(shift_amount_e),
    .i_shift_register(shift_register_e), .i_immediate(immediate_e),
    .i_shift_carry(ins[11:8] == 0 ? execute_flags[29] : immediate_carry_e), .i_pc8(pc8), .i_branch_offset(branch_offset_e),
    .o_result(ex_result), .o_store_data(ex_store), .o_branch_target(ex_branch),
    .o_flags(ex_flags), .o_condition_pass(ex_pass), .o_wait(execute_wait),
    .o_execute(), .o_write_result(ex_write), .o_write_flags(ex_write_flags)
);

// All in-flight instructions retain program order through the native RAM
// edges. Each record has two producers: load destination first, then base/ALU.
// Cache data is registered in W; it never feeds the execute mux directly.
assign producers = {fast_w,fast_m,fast_2,fast_1};
always_comb begin
    for (int n=0; n<4; n++) begin
        forward_value[2*n] = producers[n].load_data;
        forward_tag[2*n] = producers[n].load_dst;
        forward_valid[2*n] = producers[n].present && producers[n].pass &&
                            producers[n].load && !producers[n].fault;
        forward_ready[2*n] = n == 3 && fast_load_ready;
        forward_value[2*n+1] = producers[n].value;
        forward_tag[2*n+1] = producers[n].dst;
        forward_valid[2*n+1] = producers[n].present && producers[n].pass &&
                              producers[n].dst != PHY_RAZ_REGISTER && !producers[n].fault;
        forward_ready[2*n+1] = 1;
    end
end
arm9_forward #(.PRODUCERS(8)) u_decode_forward (
    .i_value(read_value), .i_tag(read_tag), .i_used(4'b1111),
    .i_write_value(forward_value), .i_write_tag(forward_tag),
    .i_write_valid(forward_valid), .i_write_ready(forward_ready),
    .o_value(forwarded_read), .o_wait(unused_read_wait)
);
// An E consumer may outlive a producer while waiting for a different source
// or a full result queue. Retain every bypass before that producer disappears.
arm9_forward #(.PRODUCERS(8)) u_held_forward (
    .i_value(value_e), .i_tag(tag_e), .i_used(used_e),
    .i_write_value(forward_value), .i_write_tag(forward_tag),
    .i_write_valid(forward_valid), .i_write_ready(forward_ready),
    .o_value(held_value), .o_wait(held_wait)
);
assign execute_flags = fast_1.present ? fast_1.flags :
    fast_2.present ? fast_2.flags : fast_m.present ? fast_m.flags :
    fast_w.present ? fast_w.flags : cpsr;
assign fast_d = (kind_d == K_DP && d_ins[15:12] != 15) || kind_d == K_BRANCH ||
               (kind_d == K_MEM && !(d_ins[19:16] == 15 && (d_ins[21] || !d_ins[24])));
wire shift_hold = e_valid && !e_shifted && shift_register_e && ex_pass && !execute_wait;
assign fast_load_ready = !fast_w.load || !i_dc_lock[fast_w.load_dst];
assign retire_fast = fast_w.present && fast_load_ready;
assign pipe_fault = retire_fast && fast_w.fault;
assign block_restore_fault = pipe_fault && fast_w.block_transfer && slow.ins[21];
assign pipe_pc_redirect = retire_fast && fast_w.pass && !fast_w.fault &&
                          fast_w.load && fast_w.load_dst == PHY_PC;
assign block_issue = sequence_active && remaining != 0 && state == IDLE &&
                     !pipe_hold && !pipe_fault;
wire pipe_request = state == IDLE && fast_m.present && fast_m.pass && fast_m.memory &&
                    !i_data_fill_busy && data_reload == 0 && !pipe_fault && !pipe_pc_redirect;
assign pipe_hold = i_data_fill_busy || data_reload != 0 ||
    (fast_w.present && !fast_load_ready) ||
    (pipe_request && (!i_data_wb_ack || i_dcache_err2));
// The cache owns RAM clocks while servicing a miss/uncached request. During
// refill its RAM writes must run. After refill or a TLB retry, reload every
// held lookup in order before issuing another request.
assign o_data_stall = state == IDLE && pipe_hold && !i_data_fill_busy &&
                      data_reload == 0 && !pipe_request;
assign execute_fast = e_valid && fast_e && !shift_hold && !execute_wait &&
                      !pipe_hold && !pipe_fault && !pipe_pc_redirect;
assign early_redirect = execute_fast && kind_e == K_BRANCH && ex_pass;
assign issue = f_valid && !sequence_active && !f_redirect && state == IDLE &&
    (!e_valid || execute_fast) &&
    ((fast_d && !f_abort && !(i_irq && !cpsr[7]) && !(i_fiq && !cpsr[6])) ||
     (!e_valid && !(|unused_read_wait)));

always_comb begin
    fast_input = '0;
    fast_input.present = execute_fast;
    fast_input.last = 1;
    fast_input.pass = ex_pass;
    fast_input.pc8 = pc8;
    fast_input.access_mode = execute_flags[4:0];
    fast_input.flags = kind_e == K_DP ? {ex_flags,execute_flags[27:0]} : execute_flags;
    fast_input.dst = kind_e == K_BRANCH ?
        (ins[24] ? translate(5'd14,cpsr[4:0]) : PHY_RAZ_REGISTER) :
        kind_e == K_MEM ? ((ins[21] || !ins[24]) ? base_e : PHY_RAZ_REGISTER) :
        ex_write ? dst_e : PHY_RAZ_REGISTER;
    fast_input.value = kind_e == K_BRANCH ? pc + 4 : ex_result;
    fast_input.memory = kind_e == K_MEM;
    fast_input.load = kind_e == K_MEM && ins[20];
    fast_input.load_dst = dst_e;
    fast_input.address = effective_address;
    fast_input.store_data = ex_store;
    fast_input.user_access = !ins[24] && ins[21];
    fast_input.align_fault = align_en && |effective_address[1:0];
    fast_input.format = {effective_address[1:0],4'b0000};
    fast_input.sel = 4'hf;
    if (ins[27:26] == 2'b01 && ins[22]) begin
        fast_input.sel = 4'b0001 << effective_address[1:0];
        fast_input.store_data = {4{ex_store[7:0]}};
        fast_input.format[2] = 1;
        fast_input.align_fault = 0;
    end else if (ins[27:26] == 0) begin
        case (ins[6:5])
            2'b01: begin
                fast_input.sel = effective_address[1] ? 4'b1100 : 4'b0011;
                fast_input.store_data = {2{ex_store[15:0]}};
                fast_input.format[0] = 1;
                fast_input.align_fault = align_en && effective_address[0];
            end
            2'b10: begin
                fast_input.sel = 4'b0001 << effective_address[1:0];
                fast_input.format[3] = 1;
                fast_input.align_fault = 0;
            end
            2'b11: begin
                fast_input.sel = effective_address[1] ? 4'b1100 : 4'b0011;
                fast_input.format[1] = 1;
                fast_input.align_fault = align_en && effective_address[0];
            end
            default: ;
        endcase
    end
    if (sequence_active) begin
        fast_input = '0;
        fast_input.present = block_issue;
        fast_input.pass = 1;
        fast_input.memory = 1;
        fast_input.block_transfer = 1;
        fast_input.last = (remaining & (remaining - 16'd1)) == 0;
        fast_input.pc8 = slow.pc8;
        fast_input.flags = fast_input.last && slow.ins[20] && slow.ins[15] && slow.ins[22] ?
                           sequence_flags : slow.flags;
        fast_input.access_mode = slow.flags[4:0];
        fast_input.load = slow.ins[20];
        fast_input.load_dst = read_tag[3];
        fast_input.dst = fast_input.last && slow.ins[21] &&
                        !(slow.ins[20] && slow.ins[{1'b0,slow.ins[19:16]}]) ? slow.base : PHY_RAZ_REGISTER;
        fast_input.value = sequence_base;
        fast_input.address = sequence_address;
        fast_input.store_data = value_d[3];
        fast_input.sel = 4'hf;
        fast_input.align_fault = align_en && |sequence_address[1:0];
        // LDM reads aligned words; low address bits remain available to FAR.
        fast_input.format = 0;
    end

end
always_ff @(posedge i_clk) begin
    if (i_reset || (f_redirect && !early_redirect) || pipe_fault) begin
        fast_1 <= '0; fast_2 <= '0; fast_m <= '0; fast_w <= '0;
        data_reload <= 0;
    end else begin
        if (state == IDLE && (i_data_fill_busy ||
            (pipe_request && i_data_wb_ack && i_dcache_err2))) data_reload <= 3;
        else if (data_reload != 0) data_reload <= data_reload - 1'b1;
        if (retire_fast) fast_w.present <= 0;
        if (fast_w.present && fast_w.load && i_dc_reg_idx[fast_w.load_dst])
            fast_w.load_data <= i_dc_reg_dat;
        if (!pipe_hold) begin
            fast_w <= fast_m;
            fast_w.fault <= pipe_request && i_data_wb_err;
            fast_w.load_data <= i_data_wb_dat;
            fast_m <= fast_2;
            fast_2 <= fast_1;
            fast_1 <= fast_input;
        end
    end
end

assign updated_base = (ins[23] ? value_e[0] + {25'd0,transfer_count_e,2'b0} :
               value_e[0] - {25'd0,transfer_count_e,2'b0});
assign effective_address = kind_e == K_BLOCK ?
    value_e[0] + {{24{block_delta_e[7]}},block_delta_e} :
    (kind_e == K_SWP ? value_e[0] : (ins[24] ? ex_result : held_value[0]));
assign next_pc = w_dabt ? vector_base + 16 :
                 w_fiq ? vector_base + 28 :
                 w_irq ? vector_base + 24 :
                 w_pabt ? vector_base + 12 :
                 w_swi ? vector_base + 8 :
                 w_und ? vector_base + 4 :
                 w_load && m_dst == PHY_PC ? m_read_data :
                 w_redirect ? w_target : slow.pc + (slow.flags[5] ? 2 : 4);

// Independent, epoch-cancelled fetch continues while the backend is busy.
logic f_valid, f_abort, f_ready, f_redirect;
logic [31:0] f_pc, f_instruction, f_address_nxt, f_address_check, f_address;
assign f_ready = issue;
assign f_redirect = (pipe_fault && !block_restore_fault) || pipe_pc_redirect || early_redirect || (wb_cycle &&
    (w_redirect || (w_load && m_dst == PHY_PC) || w_dabt || w_pabt ||
     w_irq || w_fiq || w_swi || w_und || slow.kind == K_CP || slow.kind == K_MSR));
arm9_fetch #(.RESET_VECTOR(RESET_VECTOR)) u_fetch (
    .i_clk(i_clk), .i_reset(i_reset), .i_redirect(f_redirect),
    .i_target(pipe_fault ? vector_base + 16 : pipe_pc_redirect ?
        (cpsr_next[5] ? (fast_w.load_data & 32'hfffffffe) : (fast_w.load_data & 32'hfffffffc)) : early_redirect ? ex_branch : cpsr_next[5] ? (next_pc & 32'hfffffffe) : (next_pc & 32'hfffffffc)),
    .i_thumb(cpsr_next[5]), .i_data(i_instr_wb_dat), .i_ack(i_instr_wb_ack),
    .i_error(i_instr_wb_err), .i_retry(i_icache_err2),
    .i_fill_pending(i_icache_fill_pending), .i_fill_done(i_icache_fill_done),
    .i_fill_fault(i_icache_fill_fault), .o_address_nxt(f_address_nxt),
    .o_address_check(f_address_check), .o_address(f_address),
    .o_request(o_instr_wb_stb), .o_stall(o_code_stall),
    .o_valid(f_valid), .o_pc(f_pc), .o_instruction(f_instruction),
    .o_abort(f_abort), .i_ready(f_ready), .o_decoded(translated),
    .o_thumb_und(thumb_und), .o_thumb_align(thumb_align)
);
assign o_instr_wb_adr_nxt = fcse(f_address_nxt);
assign o_instr_wb_adr_check = fcse(f_address_check);
assign o_instr_wb_adr = fcse(f_address);
assign o_instr_wb_cyc = o_instr_wb_stb;
assign o_instr_wb_we = 0;
assign o_instr_wb_sel = 4'hf;
wire [31:0] pipe_nxt_address = data_reload == 3 ? fast_m.address :
    data_reload == 2 ? fast_2.address : data_reload == 1 ? fast_1.address : sequence_active ? sequence_address : effective_address;
wire reload_check = data_reload == 1;
assign o_data_wb_adr_nxt = fcse({(state == IDLE ? pipe_nxt_address[31:2] : m_address[31:2]),2'b00});
assign o_data_wb_adr_check = fcse({(state == IDLE ?
    (reload_check ? fast_m.address[31:2] : fast_2.address[31:2]) : m_address[31:2]),2'b00});
assign o_data_wb_adr = fcse({(state == IDLE ? fast_m.address[31:2] : m_address[31:2]),2'b00});
assign o_data_wb_we_check = state == IDLE ? (reload_check ?
    fast_m.present && fast_m.pass && fast_m.memory && !fast_m.load :
    fast_2.present && fast_2.pass && fast_2.memory && !fast_2.load) : state == M3 && !m_load;
assign o_data_wb_re_check = state == IDLE ? (reload_check ?
    fast_m.present && fast_m.pass && fast_m.memory && fast_m.load :
    fast_2.present && fast_2.pass && fast_2.memory && fast_2.load) : state == M3 && m_load;
assign o_data_wb_stb = state == IDLE ? pipe_request : state == MEMORY;
assign o_data_wb_cyc = o_data_wb_stb;
assign o_data_wb_we = state == IDLE ? !fast_m.load : !m_load;
assign o_data_wb_sel = state == IDLE ? fast_m.sel : m_sel;
assign o_data_wb_dat = state == IDLE ? fast_m.store_data : m_write_data;
assign o_data_wb_align_fault = state == IDLE ? fast_m.align_fault : m_align;
assign o_data_wb_va = state == IDLE ? fast_m.address : m_address;
assign o_data_wb_ldfmt = state == IDLE ? fast_m.format : m_format;
assign o_mem_translate = state == IDLE ? (reload_check ? fast_m.user_access : fast_2.user_access) : m_user;
assign o_mem_cpsr = state == IDLE ? (reload_check ? fast_m.access_mode[CPSR_MODE:0] : fast_2.access_mode[CPSR_MODE:0]) : slow.flags[CPSR_MODE:0];
assign o_cpsr = cpsr[CPSR_MODE:0];
assign o_dc_reg_idx = 64'd1 << o_dc_reg_idx_bin;
assign o_dc_reg_idx_bin = state == IDLE ? fast_m.load_dst : m_dst;

always_ff @(posedge i_clk) begin
    if (i_reset) begin
        state <= IDLE;
        e_valid <= 0; e_shifted <= 0; slow <= '0;
        pc <= RESET_VECTOR;
        raw_ins <= 0; ins <= 0; tag_e <= '0; used_e <= 0; fast_e <= 0;
        fetch_abort <= 0;
        irq_pending <= 0;
        fiq_pending <= 0;
        sequence_active <= 0;
        remaining <= 0;
        sequence_address <= 0;
        sequence_base <= 0; sequence_original <= 0; sequence_flags <= 0;
        multiply_product <= 0; multiply_accumulator <= 0; multiply_result <= 0; multiply_delay <= 0;
        w_valid <= 0; w_cfail <= 0; w_load <= 0; w_redirect <= 0;
        w_dabt <= 0; w_pabt <= 0; w_irq <= 0; w_fiq <= 0; w_swi <= 0; w_und <= 0;
        w_value <= 0; w_flags <= CPSR_INIT; w_target <= 0; w_dst <= PHY_RAZ_REGISTER;
        m_address <= 0; m_write_data <= 0; m_read_data <= 0; m_sel <= 0;
        m_format <= 0; m_dst <= PHY_RAZ_REGISTER;
        m_load <= 0; m_align <= 0; m_user <= 0; swap_store <= 0;
        block_delta_e <= 0; transfer_count_e <= 0; list_e <= 0;
        kind_e <= K_UND; op_e <= 0; value_e <= '0;
        shift_type_e <= 0; shift_amount_e <= 0; shift_register_e <= 0;
        immediate_e <= 0; immediate_carry_e <= 0; branch_offset_e <= 0;
        dst_e <= PHY_RAZ_REGISTER; base_e <= PHY_RAZ_REGISTER; psr_mask_e <= 0;
    end else begin
      if (e_valid) begin
        value_e <= held_value;
        if (shift_hold) e_shifted <= 1;
        if (execute_fast) e_valid <= 0;
      end
      if (e_valid && !fast_e && !shift_hold && !execute_wait &&
          !fast_1.present && !fast_2.present && !fast_m.present &&
          (!fast_w.present || retire_fast) && !pipe_hold && !pipe_fault && !pipe_pc_redirect) begin
            e_valid <= 0;
            slow.pc <= pc;
            slow.pc8 <= pc8;
            slow.ins <= ins;
            slow.raw <= raw_ins;
            slow.dst <= dst_e;
            slow.flags <= execute_flags;
            slow.base <= base_e;
            slow.kind <= kind_e;
            state <= WRITEBACK;
            w_valid <= ex_pass;
            w_cfail <= !ex_pass;
            swap_store <= 0;
            w_load <= 0;
            w_redirect <= 0;
            w_dabt <= 0; w_pabt <= 0; w_irq <= 0; w_fiq <= 0; w_swi <= 0; w_und <= 0;
            w_dst <= PHY_RAZ_REGISTER;
            w_value <= pc + 4; // ARM exception link (Thumb supplied by writeback).
            w_flags <= execute_flags;
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
                        w_flags <= value_e[3] & 32'hf00000ff;
                end
                K_MRS: begin
                    w_dst <= dst_e;
                    w_value <= ins[22] ? value_e[2] : execute_flags;
                end
                K_MSR: begin
                    if (ins[22] && cpsr[4:0] != USR && cpsr[4:0] != SYS) begin
                        w_dst <= translate(ARCH_CURR_SPSR,cpsr[4:0]);
                        w_value <= (value_e[2] & ~psr_mask_e) | (value_e[1] & psr_mask_e);
                    end else if (!ins[22])
                        w_flags <= (execute_flags & ~psr_mask_e) | (value_e[1] & psr_mask_e);
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
                K_MEM, K_SWP: begin
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
                    end
                end
                K_BLOCK: begin
                    // E captures the immutable block context once. The D read
                    // port and address counter then launch one register per
                    // enabled clock into the same ordered memory pipeline.
                    state <= IDLE;
                    w_valid <= 0;
                    sequence_active <= 1;
                    remaining <= list_e;
                    sequence_address <= effective_address;
                    sequence_base <= updated_base;
                    sequence_original <= value_e[0];
                    sequence_flags <= value_e[2];
                end
                K_MUL, K_MULL: begin
                    // Dedicated registered multiplier, outside the fitted E ALU
                    // cone. Truncation gives the correct modulo-2^64 product.
                    multiply_product <= $signed({kind_e == K_MULL && ins[22] && value_e[1][31], value_e[1]}) *
                                        $signed({kind_e == K_MULL && ins[22] && value_e[2][31], value_e[2]});
                    multiply_accumulator <= !ins[21] ? 64'd0 :
                        {kind_e == K_MULL ? value_e[0] : 32'd0, value_e[3]};
                    multiply_delay <= multiply_iterations(value_e[2][31:8],kind_e == K_MUL || ins[22]) -
                                      (kind_e == K_MUL ? 3'd1 : 3'd0);
                    state <= MUL_ADD;
                end
                K_CP: begin w_valid <= 0; state <= COPRO; end
                K_SWI: begin w_valid <= 0; w_swi <= 1; end
                default: begin w_valid <= 0; w_und <= 1; end
            endcase
        end
      case (state)
        M1: state <= M2;
        M2: state <= M3;
        M3: state <= MEMORY;
        MEMORY: if (i_data_wb_ack || i_data_wb_err) begin
            if (i_dcache_err2) state <= M1;
            else if (i_data_wb_err) begin
                w_valid <= 0;
                w_dabt <= 1;
                    state <= WRITEBACK;
            end else begin
                if (m_load) m_read_data <= i_data_wb_dat;
                // A miss sets lock_ff at this edge; inspecting the old lock
                // here would retire the victim's data. Classify one edge later.
                state <= m_load ? LOAD_CLASSIFY : WRITEBACK;
            end
        end
        LOAD_CLASSIFY: begin
            if (wb_cycle) begin
                state <= IDLE;
            end else if (m_load && i_dc_reg_idx[m_dst]) begin
                m_read_data <= i_dc_reg_dat;
                state <= slow.kind == K_SWP ? M1 : WRITEBACK;
                if (slow.kind == K_SWP) begin m_load <= 0; swap_store <= 1; end
            end else if (m_load && i_dc_lock[m_dst]) state <= LOAD_WAIT;
            else if (slow.kind == K_SWP && !swap_store) begin
                m_load <= 0;
                swap_store <= 1;
                state <= M1;
            end else state <= WRITEBACK;
        end
        LOAD_WAIT: if (i_dc_reg_idx[m_dst]) begin
            m_read_data <= i_dc_reg_dat;
            state <= slow.kind == K_SWP ? M1 : WRITEBACK;
            if (slow.kind == K_SWP) begin m_load <= 0; swap_store <= 1; end
        end
        RESTORE_BASE: state <= WRITEBACK;
        MUL_ADD: begin
            multiply_result <= multiply_product + multiply_accumulator;
            state <= MUL_WAIT;
        end
        MUL_WAIT: begin
            if (multiply_delay != 0) multiply_delay <= multiply_delay - 1'b1;
            else begin
                w_dst <= slow.kind == K_MULL ? slow.dst : slow.base;
                w_value <= multiply_result[31:0];
                if (slow.kind == K_MULL) begin
                    m_dst <= slow.base;
                    m_read_data <= multiply_result[63:32];
                    w_load <= 1;
                end
                if (slow.ins[20]) begin
                    w_flags[31] <= slow.kind == K_MULL ? multiply_result[63] : multiply_result[31];
                    w_flags[30] <= slow.kind == K_MULL ? multiply_result == 0 : multiply_result[31:0] == 0;
                end
                state <= WRITEBACK;
            end
        end
        COPRO: begin
            if (copro_reg_en && copro_reg_wr_index == PHY_PC)
                w_flags[31:28] <= copro_reg_wr_data[31:28];
            if (copro_done) begin w_valid <= 1; state <= WRITEBACK; end
        end
        WRITEBACK: begin
            state <= IDLE;
        end
        default: ;
      endcase
        if (block_issue) begin
            remaining <= remaining & ~(16'd1 << transfer_reg_d);
            sequence_address <= sequence_address + 4;
        end
        if (retire_fast && fast_w.block_transfer && fast_w.last)
            sequence_active <= 0;
        if (pipe_fault) begin
            sequence_active <= 0;
            remaining <= 0;
            if (block_restore_fault) begin
                // A completed earlier LDM transfer may have overwritten Rn.
                // Restore its original physical register before exception entry,
                // including when Rn aliases the abort bank's link register.
                state <= RESTORE_BASE;
                w_valid <= 0; w_cfail <= 0;
                w_load <= 0; w_redirect <= 0; w_dabt <= 1;
                w_flags <= slow.flags;
            end
        end
        if (issue) begin
            if (issue) begin
                pc <= f_pc;
                raw_ins <= f_instruction;
                ins <= d_ins;
                fetch_abort <= f_abort;
            end
            fast_e <= issue && fast_d && !f_abort &&
                      !(i_irq && !cpsr[7]) && !(i_fiq && !cpsr[6]);
            tag_e <= read_tag;
            // DP/scalar memory use E forwarding. Slow operations capture
            // ready D operands, then wait in E for ordered retirement.
            used_e <= kind_d == K_MEM ?
                {!d_ins[20],1'b0,!immediate_d,1'b1} :
                kind_d == K_DP ? {1'b0,shift_register_d,!immediate_d,
                 op_d != MOV && op_d != MVN} : {2'b11,!immediate_d,1'b1};
            block_delta_e <= d_ins[23] ? (d_ins[24] ? 8'd4 : 8'd0) :
                (d_ins[24] ? 8'd0 : 8'd4) - {1'b0,transfer_count_d,2'b0};
            transfer_count_e <= transfer_count_d;
            list_e <= list_d;
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
            dst_e <= kind_d == K_DP ? translate({1'b0,d_ins[15:12]},cpsr[4:0]) : read_tag[3];
            base_e <= read_tag[0];
            fiq_pending <= !sequence_active && i_fiq && !cpsr[6];
            irq_pending <= !sequence_active && i_irq && !cpsr[7];
            e_valid <= 1;
            e_shifted <= 0;
        end
        if (f_redirect && !early_redirect) e_valid <= 0;
    end
end

assign o_dbg_wb_valid = (retire_fast && fast_w.pass && !fast_w.fault) || (wb_cycle && w_valid) || state == RESTORE_BASE;
assign o_dbg_wb_dvalid = (retire_fast && !fast_w.pass) || (wb_cycle && w_cfail);
assign o_dbg_wb_uop_last = retire_fast ? fast_w.last : (state != RESTORE_BASE);
assign o_dbg_wb_dabt = {1'b0,(pipe_fault && !block_restore_fault) || (wb_cycle && w_dabt)};
assign o_dbg_wb_pabt = wb_cycle && w_pabt;
assign o_dbg_wb_irq = wb_cycle && w_irq;
assign o_dbg_wb_fiq = wb_cycle && w_fiq;
assign o_dbg_wb_swi = wb_cycle && w_swi;
assign o_dbg_wb_und = wb_cycle && w_und;
assign o_dbg_wb_pc = retire_fast ? fast_w.pc8 : slow.pc8;
assign o_dbg_wb_cpsr_nxt = cpsr_next;
assign o_dbg_stall = {pipe_fault || (wb_cycle && (w_dabt || w_pabt || w_irq || w_fiq || w_swi || w_und)),
    early_redirect || pipe_pc_redirect || (wb_cycle && w_redirect), state == COPRO || sequence_active,
    shift_hold || state == MUL_ADD || state == MUL_WAIT,
    execute_wait || (f_valid && !issue && (!e_valid || execute_fast)), !f_valid, o_code_stall,
    pipe_hold || state == MEMORY || state == LOAD_WAIT};

// Retain ZAP's proven banked state and exception entry logic. Its old fetch
// PC/BTB is disconnected; the new controller owns fetch and has no predictor.
zap_writeback #(.BP_ENTRIES(32), .PHY_REGS(40), .FLAG_WDT(32),
    .RESET_VECTOR(RESET_VECTOR), .CPSR_INIT(CPSR_INIT)) u_zap_writeback (
    .i_clk(i_clk), .i_reset(i_reset), .i_valid(o_dbg_wb_valid),
    .i_decompile('0), .i_decompile_valid(o_dbg_wb_dvalid), .i_uop_last(o_dbg_wb_uop_last),
    .o_decompile(), .o_shelve(), .i_cpu_pid(o_pid[6:0]),
    .i_l4_enable(l4_enable), .i_hivecs(hivecs), .i_clear_btb(1'b0),
    .i_code_stall(1'b1), .i_clear_from_alu(1'b0), .i_pc_from_alu(32'd0),
    .i_clear_from_decode(1'b0), .i_pc_from_decode(32'd0),
    .i_clear_from_icache(1'b0), .i_confirm_from_alu(1'b0),
    .i_alu_pc_ff(32'd0), .i_taken(2'd0),
    .i_rd_index_0(read_tag[0]), .i_rd_index_1(read_tag[1]),
    .i_rd_index_2(read_tag[2]), .i_rd_index_3(read_tag[3]),
    .i_mem_load_ff(retire_fast ? fast_w.load : w_load && state != RESTORE_BASE),
    .i_wr_index(retire_fast ? fast_w.dst : state == RESTORE_BASE ? slow.base : w_dst),
    .i_wr_data(retire_fast ? fast_w.value : state == RESTORE_BASE ? sequence_original : w_value),
    .i_flags(retire_fast ? (fast_w.fault && fast_w.block_transfer ? slow.flags : fast_w.flags) : state == RESTORE_BASE ? cpsr : w_flags), .i_wr_index_1(retire_fast ? fast_w.load_dst : m_dst), .i_wr_data_1(retire_fast ? fast_w.load_data : m_read_data),
    .i_wr_index_2(40'd0), .i_wr_data_2(32'd0), .i_mode16(cpsr[5]),
    .i_irq(o_dbg_wb_irq), .i_fiq(o_dbg_wb_fiq), .i_instr_abt(o_dbg_wb_pabt),
    .i_data_abt(o_dbg_wb_dabt), .i_swi(o_dbg_wb_swi), .i_und(o_dbg_wb_und),
    .i_pc_plus_8_buf_ff(o_dbg_wb_pc), .i_copro_reg_en(copro_reg_en),
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
        .i_cp_word              (slow.ins),
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
