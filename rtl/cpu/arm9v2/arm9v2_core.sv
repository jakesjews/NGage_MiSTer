// SPDX-License-Identifier: GPL-3.0-or-later
// ARM9V2 integration. Banked retirement/CP15 reuse ZAP by Revanth Kamaraj.
// See docs/ARM9V2.md for the registered address and completion contracts.
module arm9v2_core #(
        parameter logic ARM9_PREDICTOR = 1'b1,
        // Memory addresses summed in S and registered into A; the D-cache and
        // TLB lookup comes from that register (arm9v2_execute, arm9v2_decode).
        parameter logic S_AGU = 1'b1,
        // Lane B of the 104 MHz plan. FREE_SELECT: S's forward grant and A's
        // late bypass (registered one-hot) select data as if W's load hit;
        // the hit and the trust gate only the waits (arm9v2_execute).
        // TRUST_FF: the trust (the cache FSM's i_data_short_trust) and W's
        // hit candidate are registers of their own. FAST_Z: carry-free Z.
        parameter logic FREE_SELECT = 1'b1,
        parameter logic TRUST_FF = 1'b1,
        parameter logic FAST_Z = 1'b1,
        // Lane C: W's load word has its own rotator in S (arm9v2_execute).
        parameter logic W_ROTATE = 1'b1,
        // Lane E: the fetch queue stores a Thumb pc[1] halfword low
        // (THUMB_HALF); W's redirect compares each load-word source in
        // parallel and selects the result (REDIRECT_EQ).
        parameter logic THUMB_HALF = 1'b1,
        parameter logic REDIRECT_EQ = 1'b1,
        // S's shifter controls registered by decode (arm9v2_decode
        // SHIFT_PRE): zero cycles.
        parameter logic SHIFT_PRE = 1'b1,
        // The D1 queue's and D2's payload enables without the kill
        // (arm9v2_decode PAYLOAD_FREE): zero cycles.
        parameter logic PAYLOAD_FREE = 1'b1,
        // D2's redirect payload loads every edge; only valid waits for S
        // (arm9v2_decode REDIRECT_PAYLOAD): zero cycles.
        parameter logic REDIRECT_PAYLOAD = 1'b1,
        // Decode's write-through from W's binary tags (arm9v2_decode
        // WT_TAGS): zero cycles.
        parameter logic WT_TAGS = 1'b1,
        // The multiplier's partial products without a reset, kept in the
        // DSP blocks' output registers (arm9v2_execute DSP_PRODUCT).
        parameter logic DSP_PRODUCT = 1'b1,
        // The return stack's top as a register (arm9v2_predict RAS_TOP_FF,
        // from codex/arm9v2-c4 50ed1e6): zero cycles.
        parameter logic RAS_TOP_FF = 1'b1,
        // The coprocessor's own register-file read port (zap_writeback
        // COPRO_PORT): zero cycles.
        parameter logic COPRO_PORT = 1'b1,
        // W completion, 104 MHz step 2 (2026-10-25). REG_DONE: an access the
        // D-cache acknowledges for certain from registered predicates
        // (i_data_ack_fast: a cacheable IDLE access, hit or miss, a hit
        // under a miss, or an uncached access's UNC_DONE) completes in its
        // clock as before; any other acknowledge (an MMU or alignment fault,
        // the TLB busy retry) is registered
        // and completes W one clock later, with the request withdrawn from
        // the cache in that clock. Costs cycles on those accesses only.
        parameter logic REG_DONE = 1'b1,
        // The cache request (request_ff, W's flush, the fill end) as one
        // register loaded from their next values: zero cycles.
        parameter logic REQ_FF = 1'b1,
        // The return owner's lock from the cache's registered lookup of
        // lock_nxt (zap_dcache_fsm o_lock_return): zero cycles.
        parameter logic RETURN_READY_FF = 1'b1,
        // No reset term in the forwarding/return combinational logic (the
        // records it reads are reset): zero cycles.
        parameter logic RESET_LEAN = 1'b1,
        // decode's prefix_target without S's acceptance (arm9v2_decode
        // PREFIX_FREE): zero cycles.
        parameter logic PREFIX_FREE = 1'b1,
        // S's operand-1 class (immediate, PC, PSR) registered by decode
        // beside the shift controls (arm9v2_execute OP1_PRE): zero cycles.
        parameter logic OP1_PRE = 1'b1,
        // S's planned writes from decode's registered destination mask
        // (arm9v2_execute WRITES_PRE): zero cycles.
        parameter logic WRITES_PRE = 1'b1,
        // S's PC/PSR source classes registered by decode (arm9v2_execute
        // TAG_PRE): zero cycles.
        parameter logic TAG_PRE = 1'b1,
        // S's held operands and prepared payload without the readiness
        // enables (arm9v2_execute HELD_FREE): zero cycles.
        parameter logic HELD_FREE = 1'b1,
        // The fetch queue's head entry as its own register (arm9v2_fetch
        // HEAD_FF): zero cycles.
        parameter logic HEAD_FF = 1'b1,
        // M/W/skid carry their load-ownership and speculation classes as
        // record bits (ld, sp), set where a record is formed or changed,
        // instead of decoding them from kind/last/dest every clock: zero cycles.
        parameter logic LOAD_CLASS = 1'b1,
        // W's completion class without the defer_load node: request_done &&
        // !retry && !defer_load written out as one equation (an identity),
        // so the completion roots do not wait for defer_load: zero cycles.
        parameter logic COMPLETE_FLAT = 1'b1,
        // A flag-setting multiply's Z without the carry (arm9v2_execute
        // MUL_FAST_Z): zero cycles.
        parameter logic MUL_FAST_Z = 1'b1,
        // W's static completion terms (exception, coprocessor, SWP, block
        // writeback) as registers loaded from M's record when W takes it,
        // instead of decoded from W's fields every clock (W_CLASS): zero cycles.
        parameter logic W_CLASS = 1'b1,
        // S's base forward from A's MEM writeback only for an unconditional
        // writer, so the forward needs no condition evaluation; a dependent
        // of a conditional base writer waits in D2 (AGU_AL): a clock only for
        // a conditional writeback memory access followed by its base's user.
        parameter logic AGU_AL = 1'b1,
        // The predictor's looked-up valid bit as a register (arm9v2_predict
        // VALID_BIT): zero cycles.
        parameter logic VALID_BIT = 1'b1,

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
        parameter logic [31:0] CP15_ID          = 32'h0005AAA0,
        parameter logic [31:0] CP15_CTYPE       = 32'd0,
        parameter logic        HIVECS           = 1'd0
)
(

// ------------------------------------------------
// Trace port
// ------------------------------------------------


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
input logic [31:0] i_data_short_data,
input logic i_data_short_hit,
input logic i_data_short_live,
input logic i_data_ack_fast,      // zap_dcache_fsm o_ack_fast (REG_DONE)
input logic i_data_err_fast,      // zap_dcache_fsm o_err_fast: UNC_DONE's bus error
input logic i_data_short_trust,   // i_data_short_live && !fill_ended, registered in the cache FSM
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
output logic [5:0]                       o_data_wb_ldfmt_check,

// ARM925T: single-line D-cache operation (zap_cp15_cb).
output logic                             o_dcache_line_req,
output logic [1:0]                       o_dcache_line_op,
output logic                             o_dcache_line_va,
output logic [31:0]                      o_dcache_line_addr,
output logic                             o_dcache_line_way,   // ARM925T
input  logic                             i_dcache_line_done,
input  logic                             i_dcache_writeback_busy,

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
input logic [31:0]                       i_instr_data_early,
input logic                              i_instr_hit,
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
input logic                              i_data_fill_busy_nxt,   // REQ_FF
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
input   logic                            i_dc_lock_any, i_dc_lock_owner,
input   logic                            i_dc_lock_return,       // RETURN_READY_FF
output logic [5:0] o_dc_lock_owner_hold, o_dc_lock_owner_advance,
output logic o_dc_lock_owner_move,
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
output  logic [7:0]                      o_dbg_stall,
output logic [1:0] o_dbg_fetch

);


    logic d_ready;
    logic d_valid;
    logic [31:0] d_pc;
    logic [31:0] d_instruction;
    logic [31:0] d_pc_base;
    logic [31:0] d_next_pc;
    logic [15:0] d_raw;
    logic [4:0] d_mode;
    logic d_thumb;
    logic d_fault;
    logic d_force_align;
    logic d_reg_shift;
    logic [18:0] d_shift_pre;
    logic [3:0] d_kind;
    logic [3:0] d_condition;
    logic [3:0][5:0] d_tag;
    logic [3:0] d_used,d_early;
    logic d_self_dep;
    logic [3:0][1:0][1:0] d_forward_match;
    logic [1:0][3:0][4:0] d_forward_grant;
    logic [1:0][1:0][5:0] forward_tag;
    logic [1:0][1:0] forward_write;
    logic [31:0] a_btb_pc;
    logic a_btb_thumb,a_record_pred_hit,a_record_thumb;
    logic [2:0] a_record_pointer;
    logic [3:0] a_record_count;
    logic [1:0] a_record_pred_state;
    logic [3:0][31:0] d_value;
    logic [1:0][5:0] d_dest;
    logic d_first;
    logic d_last;
    logic [4:0] d_reg_count;
    logic signed [7:0] d_offset;
    logic signed [7:0] d_writeback_offset;
    logic [3:0] d_transfer_reg;
    logic [31:0] d_branch_target;
    logic d_direct;
    logic d_match_taken;
    logic d_match_fallthrough;
    logic d_predicted;
    logic d_pred_hit;
    logic [31:0] d_pred_target;
    logic [1:0] d_pred_state;
    logic [1:0] d_pred_kind;
    logic [2:0] d_ras_pointer;
    logic [3:0] d_ras_count;
    logic d_hazard;
    logic a_execute_ready,a_execute_ready_payload;
    logic [1:0] d_writes;   // WRITES_PRE
    logic [3:0][1:0] d_tag_class;   // TAG_PRE
    logic a_valid;
    logic [31:0] a_pc;
    logic [31:0] a_instruction;
    logic [31:0] a_cpsr;
    logic [31:0] a_cpsr_next;
    logic [3:0] a_kind;
    logic a_thumb;
    logic a_fault;
    logic a_first;
    logic a_last;
    logic a_condition_pass;
    logic [1:0][5:0] a_dest;
    logic [1:0][31:0] a_result;
    logic [1:0] a_write;
    logic a_write_flags;
    logic a_pc_write;
    logic a_memory;
    logic a_store;
    logic [31:0] a_data_address,a_alu_address;
    logic [3:0] early_agu;
    logic a_a_cond_al;   // AGU_AL: A's record is unconditional
    logic [31:0] a_store_data;
    logic [3:0] a_flags;
    logic a_redirect;
    logic a_redirect_thumb;
    logic [31:0] a_redirect_target;
    logic [31:0] a_redirect_link;
    logic [2:0] a_redirect_pointer;
    logic [3:0] a_redirect_count;
    logic [1:0] a_redirect_action;
    logic a_btb_update;
    logic a_btb_taken;
    logic a_btb_hit;
    logic [31:0] a_btb_target;
    logic [1:0] a_btb_state;
    logic [1:0] a_btb_kind;
    logic a_a_valid;
    logic a_a_can_finish;
    logic [1:0] a_s_write;
    logic [1:0][5:0] a_a_dest;
    logic [1:0] a_a_write;
    logic a_shift_wait;
    logic a_multiply_wait;
    logic a_a_load,a_predicted;
    logic [31:0] a_psr_source,a_saved_psr,a_original_base,a_next_pc,a_prediction_target;
    logic [5:0] a_spsr_tag;
    localparam logic [3:0] DP=0,MRS=1,MSR=2,BR=3,BX=4,MEM=5,BLOCK=6,
        CP=7,UND=8,SWI=9,PREFIX=10,SUFFIX=11,SWP=12,MUL=13,MULL=14;
    typedef struct packed {
        logic valid,pass,thumb,fault,first,last,memory,store,pc_write,predicted;
        logic irq,fiq,align_fault,user_access,load_writer;
        logic [31:0] pc,ins,flags,next_flags,address,fcse_address,store_data,original_base;
        logic [31:0] psr_source,saved_psr,next_pc,pred_target,resolved_target;
        logic resolved_thumb;
        logic [5:0] spsr_tag;
        logic [1:0][5:0] dest;
        logic [1:0][31:0] result;
        logic [1:0] writes;
        logic [5:0] format;
        logic [3:0] sel;
        logic [2:0] ras_pointer;
        logic [3:0] ras_count;
        logic [3:0] kind;
        logic pred_hit;
        logic [1:0] pred_state;
        logic ld,sp;   // LOAD_CLASS: ld_of and sp_of of the record's own fields
    } record_t;
    // LOAD_CLASS: a record owns a load result (ld) / is a speculative load
    // (sp), the terms load_valid and load_speculate use.
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic ld_of(input record_t r);
        ld_of=(r.memory&&!r.store)||r.load_writer;
    endfunction
    function automatic logic sp_of(input record_t r);
        sp_of=(r.kind==MEM||(r.kind==BLOCK&&r.last))&&r.dest[0]!=15;
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */
    // W_CLASS: W's static completion terms.
    typedef struct packed {logic exc,cp,swp,blkwb;} w_cls_t;
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic w_cls_t w_cls_of(input record_t r);
        w_cls_of.exc=r.fault||r.irq||r.fiq||(r.pass&&(r.kind==SWI||r.kind==UND));
        w_cls_of.cp=r.pass&&r.kind==CP;
        w_cls_of.swp=r.kind==SWP;
        w_cls_of.blkwb=r.kind==BLOCK&&r.ins[21];
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */
    (* dont_retime *) w_cls_t w_cls;
    w_cls_t w_cls_next,w_cls_ref;
    assign w_cls_ref=w_cls_of(w);
    wire w_cp=W_CLASS?w_cls.cp:w_cls_ref.cp;
    wire w_swp=W_CLASS?w_cls.swp:w_cls_ref.swp;
    wire w_blkwb=W_CLASS?w_cls.blkwb:w_cls_ref.blkwb;
    typedef enum logic [3:0] {RUN,HOLD,RELOAD0,RELOAD1,RETRY0,RETRY1,
        LOAD_RETURN,SWAP0,SWAP1,RESTORE,ABORT} memory_state_t;
    (* dont_retime *) record_t m,w,skid;
    record_t input_record;
    /* verilator lint_off UNUSEDSIGNAL */
    record_t check_record;
    /* verilator lint_on UNUSEDSIGNAL */
    record_t m_next,w_next,skid_next,next_check_record;
    memory_state_t memory_state_next;
    typedef struct packed {
        logic [31:0] address;
        logic [4:0] mode;
        logic user_access;
        logic [5:0] format;
        logic rd,wr;
    } check_t;
    (* dont_retime *) check_t check_ff;
    (* dont_retime, maxfan = 32 *) logic request_ff;
    (* dont_retime, maxfan = 32 *) logic request_live;   // REQ_FF
    (* dont_retime *) logic late_done,late_err,late_err2;  // REG_DONE
    (* dont_retime *) logic [31:0] late_dat;
    logic resp_err,resp_err2;
    logic [31:0] resp_dat;
    logic next_check_enable;

    (* dont_retime *) memory_state_t memory_state;
    (* dont_retime *) logic [31:0] saved_load;
    (* dont_retime *) logic [63:0] w_load_select;
    (* dont_retime *) logic w_waited;
    // TRUST_FF: w.memory&&!w_waited in a register of its own, loaded from
    // the next state of both; it starts W's short-hit terms without
    // w.memory's fanout. Equal to that term on every clock.
    (* dont_retime *) logic w_hit_candidate;
    wire w_locked=i_dc_lock_owner;
    // The query owner follows the exact W capture schedule. The cache
    // samples this owner against lock_nxt, including a simultaneous clear
    // and new miss installation. No stale lock_ff summary is acceptable.
    assign o_dc_lock_owner_hold=w.dest[0];
    assign o_dc_lock_owner_advance=m.dest[0];
    assign o_dc_lock_owner_move=(memory_state==RUN&&done)||memory_state==RELOAD1||quick_reload;
`ifndef SYNTHESIS
    always_ff @(posedge i_clk) if(!i_reset) begin
        assert(i_dc_lock_any == (|i_dc_lock)) else $fatal(1,"global lock summary");
        assert(w_locked == (|(i_dc_lock&w_load_select))) else $fatal(1,"W lock summary");
    end
`endif
    wire w_return=|(i_dc_reg_idx&w_load_select);
    wire scalar_replay=1'b0; // Retain consumers; scalar completion never flushes independent work.
    (* dont_retime *) logic [5:0] return_tag;
    (* dont_retime *) logic [31:0] return_data;
    logic return_next_valid,return_ready;
    logic [3:0] d_return_match;
    logic [1:0][31:0] operand_return_data;
    logic [1:0] forward_load;
    // Normal completion is qualified against the lock installed on its
    // accepting edge. A miss ACK installs a lock, not a usable data word.
    assign return_next_valid=(RESET_LEAN||!i_reset)&&wb_complete&&w.memory&&w.load_writer&&!wb_exception;
    // The accepting edge can install a miss lock. Test the registered
    // return owner after that edge; never qualify it with the old lock.
    // Only this one ready bit fans out to the eight registered matches.
    assign return_ready=RETURN_READY_FF?!i_dc_lock_return:!i_dc_lock[return_tag];
`ifndef SYNTHESIS
    always_ff @(posedge i_clk) if(!i_reset)
        assert(i_dc_lock_return==i_dc_lock[return_tag]) else $fatal(1,"return owner lock register");
`endif
    assign operand_return_data={i_dc_reg_dat,return_data};
    always_ff @(posedge i_clk) begin
        return_tag<=w.dest[0];return_data<=load_data;
    end
    (* dont_retime *) logic swap_write,cp_seen,cp_finished;
    (* dont_retime *) logic [3:0] cp_flags;
    (* dont_retime, maxfan = 32 *) logic wb_flush;
    (* dont_retime *) logic wb_thumb;
    // maxfan: the clear reaches the predictor's 256-entry valid bitmap.
    (* dont_retime, maxfan = 32 *) logic predictor_clear;
    (* dont_retime *) logic [31:0] wb_target,wb_repair_link;
    (* dont_retime *) logic [2:0] wb_repair_pointer;
    (* dont_retime *) logic [3:0] wb_repair_count;
    (* dont_retime *) logic [1:0] wb_repair_action;
    (* dont_retime *) logic w_train,w_train_thumb,w_train_hit;
    (* dont_retime *) logic [31:0] w_train_pc,w_train_target;
    (* dont_retime *) logic [1:0] w_train_state,w_train_kind;
    logic train,train_thumb,train_taken,train_hit;
    logic [31:0] train_pc,train_target;
    logic [1:0] train_state,train_kind;
    logic [31:0] f_address_nxt,f_address_check,f_address;
    logic [31:0] cpsr,cpsr_next,wb_flags,wb_data0,wb_data1,return_target,psr_mask;
    logic [5:0] wb_tag0,wb_tag1;
    logic wb_valid,wb_cfail,wb_pair,wb_last,wb_complete,wb_redirect;
    logic wb_dabt,wb_pabt,wb_irq,wb_fiq,wb_swi,wb_und,wb_exception;
    logic w_exception,w_serial,request,request_done,retry,defer_load,done;
    /* verilator lint_off UNUSEDSIGNAL */
    logic check_enable;
    /* verilator lint_on UNUSEDSIGNAL */
    logic backend_ready,wb_restore,return_event,return_thumb,return_kind;
    logic fill_was_busy;
    wire fill_ended=fill_was_busy&&!i_data_fill_busy;
    always_ff @(posedge i_clk) fill_was_busy<=!i_reset&&i_data_fill_busy;
    logic [39:0] wa,wb,wc,locked;
    logic [3:0][5:0] rf_tag,early_tag;
    logic [3:0][31:0] rf_value;
    logic [3:0] early_valid;
    logic [5:0][5:0] load_tag;
    logic [5:0] load_valid,load_speculate;
    logic [1:0][5:0] next_load_tag;
    logic [1:0] next_load_valid;
    logic d_load_wait;
    logic [3:0] d_pending;
    logic [1:0][1:0][31:0] mw_value;
    logic [1:0][1:0][5:0] mw_tag;
    logic [1:0][1:0] mw_write;
    logic [31:0] copro_reg_wr_data,copro_reg_rd_data;
    logic [5:0] copro_reg_wr_index,copro_reg_rd_index;
    logic copro_done,copro_reg_en,align_en,hivecs,l4_enable;
    logic cp_request;
    logic a_serial_continue;
    (* dont_retime *) logic w_serial_continue;
    wire cp_read=w.kind==CP&&w.ins[20]&&w.ins[19:16]!=7;
    logic [31:0] load_data;
    wire [31:0] vector_base=hivecs?32'hffff0000:32'd0;
    function automatic [31:0] fcse(input logic [31:0] address);
        return address[31:25]==0?{o_pid[6:0],address[24:0]}:address;
    endfunction
    assign cpsr=o_dbg_wb_cpsr;
    assign backend_ready=memory_state==RUN&&!wb_flush;
    // No cache response belongs to either reserved younger record here.
    // Resume them directly; the two RAM-lookup reload clocks serve memory
    // records only. This decision updates registered capacity, never issue.
    wire quick_reload=memory_state==HOLD&&done&&
        !(m.valid&&m.memory)&&!(skid.valid&&skid.memory);
    assign early_tag={a_a_dest,d_dest};
    // The writeback lane (1) of a scalar MEM in S or A is an S-AGU sum: a
    // memory base consumer takes it from A's register, without the D2 hold.
    assign early_agu={a_kind==MEM&&(!AGU_AL||a_a_cond_al),1'b0,d_kind==MEM&&(!AGU_AL||d_condition==4'hE),1'b0};
    assign early_valid={a_a_write&{2{a_a_valid&&!a_a_can_finish}},a_s_write}&
        {early_tag[3]!=15,early_tag[2]!=15,early_tag[1]!=15,early_tag[0]!=15};
    // Pipeline load ownership and the cache's registered background lock are
    // separate. No cache ACK or producer readiness is searched in forwarding.
    assign load_tag={skid.dest[0],w.dest[0],m.dest[0],a_dest[0],a_a_dest[0],d_dest[0]};
    assign load_valid={skid.valid&&(LOAD_CLASS?skid.ld:(skid.memory&&!skid.store)||skid.load_writer),
        w.valid&&(LOAD_CLASS?w.ld:(w.memory&&!w.store)||w.load_writer),m.valid&&(LOAD_CLASS?m.ld:(m.memory&&!m.store)||m.load_writer),
        1'b0,a_a_load,
        d_valid&&!d_fault&&((d_kind==MEM||d_kind==BLOCK)?d_instruction[20]:d_kind==SWP||(d_kind==CP&&d_instruction[20]&&d_dest[0]!=15))};
    // Scalar consumers may enter S/A before the result is known; their
    // registered operand locks retain them until a hit or completion.
    // Only the final non-PC block word may use the scalar schedule. Earlier
    // words retain partial-LDM protection; an abort restores Rn and kills
    // younger records before any can retire. SWP/PC retain their interlock.
    assign load_speculate={LOAD_CLASS?skid.sp:sp_of(skid),LOAD_CLASS?w.sp:sp_of(w),
        LOAD_CLASS?m.sp:sp_of(m),1'b0,(a_kind==MEM||(a_kind==BLOCK&&a_last))&&a_dest[0]!=15,(d_kind==MEM||(d_kind==BLOCK&&d_last))&&d_dest[0]!=15};
    assign locked=i_dc_lock[39:0];
    assign mw_tag={w.dest,m.dest};
    assign mw_value[0]=m.result;
    // FREE_SELECT: a W load word is consumed only with W's hit (otherwise
    // its consumers wait), so it needs no hit gate of its own.
    assign mw_value[1]={w.result[1],w.load_writer?
        (FREE_SELECT||i_data_short_hit?i_data_short_data:32'd0):w.result[0]};
    // Producer masks travel with the registered records. Load ownership
    // produces a match even before data is ready; execute retains the
    // operand instead of selecting the unavailable word. An empty,
    // killed or condition-failed record has no writers; S never qualifies
    // the mask through the record's live valid/pass/fault cone.
    assign mw_write[0]=m.writes|{1'b0,m.load_writer};
    assign mw_write[1]=w.writes|{1'b0,w.load_writer};
    // Keep class roots visible to Quartus's fanout duplication. Identical
    // equations preserve retirement/reload timing; no delayed completion.
    (* keep, maxfan = 32 *) logic [2:0] complete_class;
    (* keep, maxfan = 32 *) wire done_forward=!w.valid||complete_class[2];
    wire quick_forward=memory_state==HOLD&&done_forward&&
        !(m.valid&&m.memory)&&!(skid.valid&&skid.memory);
    always_comb for(int consumer=0;consumer<3;consumer++)begin
        complete_class[consumer]=0;
        if(w.valid&&!wb_flush)begin
            if(memory_state==ABORT)complete_class[consumer]=1;
            else if(w_exception)complete_class[consumer]=!i_dc_lock_any;
            else if(w_cp)complete_class[consumer]=cp_finished;
            else if(memory_state==LOAD_RETURN)complete_class[consumer]=!w_locked&&!w_swp;
            else if(memory_state==RUN||memory_state==HOLD)
                complete_class[consumer]=!w.memory||(request_done&&!retry&&(COMPLETE_FLAT?
                    resp_err||w.store||(!w_swp&&(w.dest[0]!=15||fast_pc_hit)):!defer_load));
        end
        // Restore Rn on an aborting block before the exception writes ABT LR.
        if(request_done&&resp_err&&w_blkwb)complete_class[consumer]=0;
    end
    logic [1:0][1:0][5:0] advance_tag;
    (* keep, maxfan = 32 *) wire forward_advance=(memory_state==RUN&&done_forward)||memory_state==RELOAD1||quick_forward;
    assign advance_tag={m.dest,(memory_state==RELOAD1||memory_state==HOLD)?skid.dest:input_record.dest};
    always_comb begin
        forward_tag={w.dest,m.dest};
        forward_write={mw_write[1],mw_write[0]};
        forward_load={w.load_writer,m.load_writer};
        if(memory_state==RUN&&done_forward)begin
            forward_tag[0]=input_record.dest;forward_write[0]=input_record.writes|{1'b0,input_record.load_writer};
            forward_load={m.load_writer,input_record.load_writer};
            forward_tag[1]=m.dest;forward_write[1]=m.writes|{1'b0,m.load_writer};
        end
        if(memory_state==RELOAD1||quick_forward)begin
            forward_tag[0]=skid.dest;forward_write[0]=skid.writes|{1'b0,skid.load_writer};
            forward_load={m.load_writer,skid.load_writer};
            forward_tag[1]=m.dest;forward_write[1]=m.writes|{1'b0,m.load_writer};
        end
        if((memory_state==HOLD&&done_forward&&!quick_forward)||(memory_state==ABORT&&done_forward)||
            (memory_state==LOAD_RETURN&&!w_locked&&w.kind!=SWP&&done_forward))begin forward_write[1]=0;forward_load[1]=0;end
        next_load_tag={forward_tag[0][0],a_a_dest[0]};
        next_load_valid={m.load_writer,a_a_load&&!a_a_can_finish};
        if(d_valid&&a_execute_ready)begin
            next_load_tag[0]=d_dest[0];
            next_load_valid[0]=!d_fault&&((d_kind==MEM||d_kind==BLOCK)?d_instruction[20]:d_kind==SWP||(d_kind==CP&&d_instruction[20]&&d_dest[0]!=15));
        end
        if(memory_state==RUN&&done_forward)next_load_valid[1]=input_record.load_writer;
        if(memory_state==RELOAD1||quick_forward)next_load_valid[1]=skid.load_writer;
        if(a_redirect)next_load_valid[0]=0;
        if((!RESET_LEAN&&i_reset)||wb_flush)begin forward_write=0;forward_load=0;next_load_valid=0;end
    end
`ifndef SYNTHESIS
    always_ff @(posedge i_clk) if(!i_reset&&LOAD_CLASS)begin
        if(m.valid)assert(m.ld==ld_of(m)&&m.sp==sp_of(m)) else $fatal(1,"M load class");
        if(w.valid)assert(w.ld==ld_of(w)&&w.sp==sp_of(w)) else $fatal(1,"W load class");
        if(skid.valid)assert(skid.ld==ld_of(skid)&&skid.sp==sp_of(skid)) else $fatal(1,"skid load class");
    end
    always_ff @(posedge i_clk) if(!i_reset&&W_CLASS&&w.valid)
        assert(w_cls==w_cls_ref) else $fatal(1,"W completion class");
    always_ff @(posedge i_clk) if(!i_reset&&COMPLETE_FLAT)
        assert((request_done&&!retry&&!defer_load)==(request_done&&!retry&&
            (resp_err||w.store||(w.kind!=SWP&&(w.dest[0]!=15||fast_pc_hit))))) else $fatal(1,"flat completion");
    always_ff @(posedge i_clk) if(!i_reset)begin
        assert(complete_class=={3{wb_complete}});
        assert((forward_advance?advance_tag:mw_tag)==forward_tag);
    end
`endif
    assign wa=wb_valid&&wb_tag0!=16?40'd1<<wb_tag0:40'd0;
    assign wb=wb_valid&&wb_pair&&wb_tag1!=16?40'd1<<wb_tag1:40'd0;
    assign wc=i_dc_reg_idx[39:0];
    assign train=w_train||a_btb_update;
    assign train_pc=w_train?w_train_pc:a_btb_pc;
    assign train_target=w_train?w_train_target:a_btb_target;
    assign train_thumb=w_train?w_train_thumb:a_btb_thumb;
    assign train_taken=w_train||a_btb_taken;
    assign train_hit=w_train?w_train_hit:a_btb_hit;
    assign train_state=w_train?w_train_state:a_btb_state;
    assign train_kind=w_train?w_train_kind:a_btb_kind;

    // Format beside M's registered address, never after S forwarding/ALU.
    always_comb begin
        input_record='0;
        input_record.valid=a_valid&&backend_ready;
        input_record.pc=a_pc;input_record.ins=a_instruction;input_record.kind=a_kind;
        input_record.pass=a_condition_pass;input_record.thumb=a_thumb;input_record.fault=a_fault;
        input_record.first=a_first;input_record.last=a_last;input_record.pc_write=a_pc_write;
        input_record.flags=a_cpsr;input_record.next_flags=a_cpsr_next;
        input_record.dest=a_dest;input_record.result=a_result;
        input_record.writes=a_write&{2{input_record.valid}};
        input_record.load_writer=(a_memory&&!a_store||(a_kind==CP&&a_instruction[20]&&a_condition_pass))&&a_dest[0]!=15&&input_record.valid;
        // Scalar Rd == Rn writeback: the load (RF port B) wins over the
        // address update (port A). Expose only that architectural writer to
        // M/W forwarding, including a permission-qualified short hit.
        if(a_kind==MEM&&input_record.load_writer&&a_dest[0]==a_dest[1])input_record.writes[1]=0;
        input_record.memory=a_memory;input_record.store=a_store&&a_kind!=SWP;
        input_record.address=S_AGU&&a_kind==SUFFIX?a_alu_address:a_data_address;
        input_record.fcse_address=fcse(a_data_address);input_record.store_data=a_store_data;
        input_record.original_base=a_original_base;input_record.psr_source=a_psr_source;
        input_record.saved_psr=a_saved_psr;input_record.spsr_tag=a_spsr_tag;
        input_record.next_pc=a_next_pc;input_record.predicted=a_predicted;
        input_record.pred_target=a_prediction_target;
        input_record.resolved_target=a_redirect_target;input_record.resolved_thumb=a_record_thumb;
        input_record.ras_pointer=a_record_pointer;input_record.ras_count=a_record_count;
        input_record.pred_hit=a_record_pred_hit;input_record.pred_state=a_record_pred_state;
        input_record.irq=a_first&&i_irq&&!a_cpsr[7];
        input_record.fiq=a_first&&i_fiq&&!a_cpsr[6];
        input_record.sel=15;input_record.format={a_data_address[1:0],4'b0};
        input_record.align_fault=align_en&&|a_data_address[1:0];
        input_record.user_access=a_kind==MEM&&!a_instruction[24]&&a_instruction[21];
        if((a_kind==MEM&&a_instruction[27:26]==1&&a_instruction[22])||
           (a_kind==SWP&&a_instruction[22]))begin
            input_record.sel=4'b1<<a_data_address[1:0];
            input_record.store_data={4{a_store_data[7:0]}};
            input_record.format[2]=1;input_record.align_fault=0;
        end else if(a_kind==MEM&&a_instruction[27:26]==0)case(a_instruction[6:5])
            1:begin input_record.sel=a_data_address[1]?4'b1100:4'b0011;
                input_record.store_data={2{a_store_data[15:0]}};
                input_record.format[0]=1;input_record.align_fault=align_en&&a_data_address[0];end
            2:begin input_record.sel=4'b1<<a_data_address[1:0];
                input_record.format[3]=1;input_record.align_fault=0;end
            3:begin input_record.sel=a_data_address[1]?4'b1100:4'b0011;
                input_record.format[1]=1;input_record.align_fault=align_en&&a_data_address[0];end
            default:;
        endcase
        if(a_kind==BLOCK)input_record.format=0;
        input_record.ld=ld_of(input_record);input_record.sp=sp_of(input_record);
    end
    always_comb begin
        m_next=m;w_next=w;skid_next=skid;memory_state_next=memory_state;w_cls_next=w_cls;
            case(memory_state)
                RUN:if(done)begin m_next=input_record;w_next=m;w_cls_next=w_cls_of(m);end
                    else begin skid_next=input_record;memory_state_next=HOLD;end
                HOLD:if(done)begin
                    if(quick_reload)begin w_next=m;w_cls_next=w_cls_of(m);m_next=skid;skid_next.valid=0;skid_next.writes=0;skid_next.load_writer=0;memory_state_next=RUN;end
                    else begin w_next.valid=0;w_next.writes=0;w_next.load_writer=0;memory_state_next=RELOAD0;end
                end
                RELOAD0:memory_state_next=RELOAD1;
                RELOAD1:begin w_next=m;w_cls_next=w_cls_of(m);m_next=skid;skid_next.valid=0;skid_next.writes=0;memory_state_next=RUN;end
                RETRY0:memory_state_next=RETRY1;
                RETRY1:memory_state_next=HOLD;
                LOAD_RETURN:if(!w_locked)begin
                    if(w.kind==SWP)begin w_next.store=1;w_next.ld=w_next.load_writer;memory_state_next=SWAP0;end
                    else if(done)begin w_next.valid=0;w_next.writes=0;w_next.load_writer=0;memory_state_next=RELOAD0;end
                end
                SWAP0:memory_state_next=SWAP1;
                SWAP1:memory_state_next=HOLD;
                RESTORE:memory_state_next=ABORT;
                ABORT:if(done)begin w_next.valid=0;w_next.writes=0;w_next.load_writer=0;memory_state_next=RELOAD0;end
                default:memory_state_next=RUN;
            endcase
            // A request arriving immediately after installation has a response
            // captured before the new tag/data existed. Re-read that owner
            // before exposing it to IDLE; otherwise a false miss can evict
            // the freshly installed dirty store line.
            if(retry||(fill_ended&&!late_done&&w.valid&&w.memory&&
                (memory_state==RUN||memory_state==HOLD)))memory_state_next=RETRY0;
            if(defer_load)begin memory_state_next=LOAD_RETURN;end
            if(request_done&&resp_err&&w_blkwb)memory_state_next=RESTORE;
            if(wb_flush)begin
                m_next.valid=0;w_next.valid=0;skid_next.valid=0;
                m_next.writes=0;w_next.writes=0;skid_next.writes=0;
                m_next.load_writer=0;w_next.load_writer=0;skid_next.load_writer=0;memory_state_next=RUN;

            end
    end
    // Capture the complete translation owner beside the existing cache
    // lookup ownership transitions. FCSE was applied when A entered M.
    always_comb begin
        next_check_record=(memory_state_next==HOLD||memory_state_next==RETRY1||memory_state_next==SWAP1)?w_next:m_next;
        next_check_enable=memory_state_next==RUN||memory_state_next==HOLD||memory_state_next==RELOAD1||memory_state_next==RETRY1||memory_state_next==SWAP1;
    end
    always_ff @(posedge i_clk) begin
        if(i_reset)begin check_ff<='0;request_ff<=0;request_live<=0;end
        else begin
            check_ff.address<={next_check_record.fcse_address[31:2],2'b0};
            check_ff.mode<=next_check_record.flags[CPSR_MODE:0];
            check_ff.user_access<=next_check_record.user_access;
            check_ff.format<=next_check_record.format;
            check_ff.rd<=next_check_enable&&next_check_record.valid&&next_check_record.memory&&!next_check_record.store;
            check_ff.wr<=next_check_enable&&next_check_record.valid&&next_check_record.memory&&next_check_record.store;
            request_ff<=w_next.valid&&w_next.memory&&
                !(w_next.fault||w_next.irq||w_next.fiq||(w_next.pass&&(w_next.kind==SWI||w_next.kind==UND)))&&
                (memory_state_next==RUN||memory_state_next==HOLD);
            request_live<=(w_next.valid&&w_next.memory&&
                !(w_next.fault||w_next.irq||w_next.fiq||(w_next.pass&&(w_next.kind==SWI||w_next.kind==UND)))&&
                (memory_state_next==RUN||memory_state_next==HOLD))&&!wb_redirect&&!(i_data_fill_busy&&!i_data_fill_busy_nxt);
        end
    end
`ifndef SYNTHESIS
    logic request_reset_done;
    always_ff @(posedge i_clk) request_reset_done<=!i_reset;
    // Compare with the original schedule at every edge, including holds,
    // relookup, SWP, abort restoration, flush, and fill installation.
    always_ff @(posedge i_clk) if(!i_reset)begin
        assert(o_data_wb_re_check==(check_enable&&check_record.valid&&check_record.memory&&!check_record.store&&!wb_flush));
        assert(o_data_wb_we_check==(check_enable&&check_record.valid&&check_record.memory&&check_record.store&&!wb_flush));
        if(o_data_wb_re_check||o_data_wb_we_check)begin
            assert({o_data_wb_adr_check,o_mem_cpsr,o_mem_translate,o_data_wb_ldfmt_check}==
                {fcse({check_record.address[31:2],2'b0}),check_record.flags[CPSR_MODE:0],check_record.user_access,check_record.format});
        end
        assert(request_raw==(w.valid&&w.memory&&!w_exception&&!wb_flush&&!fill_ended&&
            (memory_state==RUN||memory_state==HOLD)));
        if(REQ_FF&&request_reset_done)assert(request_live==(request_ff&&!wb_flush&&!fill_ended)) else $fatal(1,"request register");
        if(request)assert(o_data_wb_adr==fcse({w.address[31:2],2'b0}));
    end
`endif
    assign check_record=(memory_state==HOLD||memory_state==RETRY1||memory_state==SWAP1)?w:m;
    assign check_enable=memory_state==RUN||memory_state==HOLD||memory_state==RELOAD1||memory_state==RETRY1||memory_state==SWAP1;
    wire [31:2] lookup_address=memory_state==RELOAD0?m.address[31:2]:
        memory_state==RELOAD1?skid.address[31:2]:
        (memory_state==HOLD||memory_state==RETRY0||memory_state==RETRY1||memory_state==SWAP0||memory_state==SWAP1)?w.address[31:2]:a_data_address[31:2];
    assign o_data_wb_adr_nxt={lookup_address[31:25]==0?o_pid[6:0]:lookup_address[31:25],lookup_address[24:2],2'b0};
    assign o_data_wb_adr_check=check_ff.address;
    assign o_data_wb_adr={w.fcse_address[31:2],2'b0};
    assign o_data_wb_re_check=check_ff.rd&&!wb_flush;
    assign o_data_wb_we_check=check_ff.wr&&!wb_flush;
    assign o_data_wb_ldfmt_check=check_ff.format;
    assign o_mem_cpsr=check_ff.mode;
    assign o_mem_translate=check_ff.user_access;
    assign o_data_wb_cyc=request;assign o_data_wb_stb=request;assign o_data_wb_we=w.store;
    assign o_data_wb_dat=w.store_data;assign o_data_wb_sel=w.sel;
    assign o_data_wb_va=w.address;assign o_data_wb_ldfmt=w.format;
    assign o_data_wb_align_fault=w.align_fault;
    assign o_dc_reg_idx_bin=w.dest[0];assign o_dc_reg_idx=w_load_select;
    assign o_data_stall=0;
    assign o_instr_wb_adr_nxt=fcse(f_address_nxt);
    assign o_instr_wb_adr_check=fcse(f_address_check);
    assign o_instr_wb_adr=fcse(f_address);assign o_instr_wb_cyc=o_instr_wb_stb;
    assign o_instr_wb_we=0;assign o_instr_wb_sel=15;assign o_cpsr=cpsr[CPSR_MODE:0];

    assign w_serial=(w.kind==CP&&!cp_read)||
        (w.kind==MSR&&(w.ins[22]||(w.pass&&w.ins[16]&&w.flags[4:0]!=5'h10&&w.psr_source[4:0]!=w.flags[4:0])))||w.kind==SWP||w.kind==SWI||w.kind==UND||w.fault||
        (w.kind==DP&&w.ins[20]&&w.dest[0]==15)||
        (w.kind==BLOCK&&w.ins[22]&&w.ins[20]&&w.ins[15]&&w.last);
    assign w_exception=W_CLASS?w_cls.exc:w_cls_ref.exc;
    assign cp_request=w.valid&&w_cp&&!w_exception&&(cp_read||(!i_dc_lock_any&&!i_data_fill_busy))&&!wb_flush;
    // REQ_FF: request_ff&&!wb_flush&&!fill_ended as one register.
    wire request_raw=REQ_FF?request_live:request_ff&&!wb_flush&&!fill_ended;
    // REG_DONE: a non-fast acknowledge waits in late_done for one clock;
    // the request is withdrawn from the cache in that clock.
    assign request=request_raw&&!(REG_DONE&&late_done);
    wire ack_now=REG_DONE?request&&i_data_ack_fast:request&&(i_data_wb_ack||i_data_wb_err);
    assign request_done=ack_now||(REG_DONE&&late_done);
    assign resp_err=REG_DONE?(late_done?late_err:ack_now&&i_data_err_fast):i_data_wb_err;
    assign resp_err2=REG_DONE?late_done&&late_err2:i_dcache_err2;
    assign resp_dat=REG_DONE&&late_done?late_dat:i_data_wb_dat;
    assign retry=request_done&&resp_err2;
    always_ff @(posedge i_clk)begin
        late_done<=!i_reset&&REG_DONE&&request&&(i_data_wb_ack||i_data_wb_err)&&!i_data_ack_fast;
        late_err<=i_data_wb_err;late_err2<=i_dcache_err2;late_dat<=i_data_wb_dat;
    end
`ifndef SYNTHESIS
    always_ff @(posedge i_clk) if(!i_reset)begin
        if(REG_DONE&&request&&i_data_ack_fast)assert(i_data_wb_ack&&!i_dcache_err2&&i_data_wb_err==i_data_err_fast)
            else $fatal(1,"fast acknowledge without the cache's");
        if(REG_DONE&&late_done)assert(!wb_flush&&w.valid&&w.memory&&(memory_state==RUN||memory_state==HOLD))
            else $fatal(1,"registered completion lost its owner");
    end
`endif
    // A first-pass PC hit is already permission-qualified and formatted in
    // the M/W short-response register. Retire it once here; W's registered
    // recovery owns any redirect. Miss/hold/retry/SWP still use LOAD_RETURN.
    wire fast_pc_hit=w.memory&&!w.store&&w.dest[0]==15&&w.kind!=SWP&&i_data_short_hit&&!w_waited;
    assign defer_load=request_done&&!retry&&!resp_err&&!w.store&&((w.dest[0]==15&&!fast_pc_hit)||w.kind==SWP);
    assign load_data=(memory_state==LOAD_RETURN||swap_write)?saved_load:fast_pc_hit?i_data_short_data:resp_dat;
`ifndef SYNTHESIS
    always_ff @(posedge i_clk)if(!i_reset&&fast_pc_hit&&request_done&&!retry&&!resp_err)
        assert(i_data_short_data==resp_dat) else $fatal(1,"PC hit short/normal word mismatch");
`endif
    // Raw write-port class follows the W owner, independently of its
    // eventual completion. A data abort is the only late class override.
    // Architectural write enable, CPSR/exception control and trace remain
    // qualified by completion in the original writeback control tree.
    (* dont_retime *) logic [5:1] rf_static_class;
    logic [5:0] rf_class;
    always_ff @(posedge i_clk) begin
        if(i_reset)rf_static_class<=0;
        else begin
            rf_static_class[1]<=w_next.valid&&w_next.fiq;
            rf_static_class[2]<=w_next.valid&&w_next.irq;
            rf_static_class[3]<=w_next.valid&&w_next.fault;
            rf_static_class[4]<=w_next.valid&&w_next.pass&&w_next.kind==SWI;
            rf_static_class[5]<=w_next.valid&&w_next.pass&&w_next.kind==UND;
        end
    end
    assign rf_class=memory_state==RESTORE?6'd0:{rf_static_class,(memory_state==ABORT)||(request_done&&resp_err)};
    assign wb_restore=memory_state==RESTORE;
    // REDIRECT_EQ: the return target's upper 30 bits against the prediction,
    // once per source, in parallel; the load-word select then picks one bit.
    logic [4:0] target_hi_eq;
    logic target_mismatch,target_mismatch_ref;
    logic target_raw_bit1;
    always_comb begin
        target_hi_eq[0]=w.pred_target[31:2]==saved_load[31:2];
        target_hi_eq[1]=w.pred_target[31:2]==i_data_short_data[31:2];
        target_hi_eq[2]=w.pred_target[31:2]==resp_dat[31:2];
        target_hi_eq[3]=w.pred_target[31:2]==w.address[31:2];
        target_hi_eq[4]=w.pred_target[31:2]==w.result[0][31:2];
    end
    wire [2:0] target_source=!w.memory?(w.kind==SUFFIX?3'd3:3'd4):
        (memory_state==LOAD_RETURN||swap_write)?3'd0:fast_pc_hit?3'd1:3'd2;
    always_comb begin
        wb_complete=complete_class[0];
        done=!w.valid||complete_class[1];
        wb_dabt=wb_complete&&(memory_state==ABORT||(request_done&&resp_err));
        wb_fiq=wb_complete&&!wb_dabt&&w.fiq;
        wb_irq=wb_complete&&!wb_dabt&&!wb_fiq&&w.irq;
        wb_pabt=wb_complete&&!wb_dabt&&!wb_fiq&&!wb_irq&&w.fault;
        wb_swi=wb_complete&&!wb_dabt&&!wb_fiq&&!wb_irq&&!wb_pabt&&w.pass&&w.kind==SWI;
        wb_und=wb_complete&&!wb_dabt&&!wb_fiq&&!wb_irq&&!wb_pabt&&w.pass&&w.kind==UND;
        wb_exception=wb_dabt||wb_fiq||wb_irq||wb_pabt||wb_swi||wb_und;
        wb_valid=(wb_complete&&w.pass&&!wb_exception)||wb_restore;
        wb_cfail=wb_complete&&!w.pass&&!wb_exception;
        wb_last=w.last&&!wb_restore;
        wb_flags=w.next_flags;wb_tag0=w.writes[0]?w.dest[0]:6'd16;
        wb_data0=w.result[0];wb_tag1=w.dest[1];wb_data1=w.result[1];wb_pair=w.writes[1];
        psr_mask={{8{w.ins[19]}},{8{w.ins[18]}},{8{w.ins[17]}},{8{w.ins[16]}}}&32'hf00000ff;
        if(!w.ins[22])begin psr_mask[5]=0;if(w.flags[4:0]==5'h10)psr_mask[27:0]=0;end
        if(w.memory)begin
            wb_tag0=w.writes[1]?w.dest[1]:6'd16;wb_data0=w.result[1];
            wb_pair=!w.store||w.kind==SWP;wb_tag1=w.dest[0];wb_data1=load_data;
            if(w.kind==BLOCK&&w.ins[22]&&w.ins[20]&&w.dest[0]==15)wb_flags=w.saved_psr&32'hf00000ff;
        end
        if(w.kind==BX&&w.pass)wb_flags[5]=w.resolved_thumb;
        if(w.kind==DP&&w.pc_write&&w.ins[20])wb_flags=w.saved_psr&32'hf00000ff;
        if(w.kind==MSR)begin
            if(w.ins[22]&&w.flags[4:0]!=5'h10&&w.flags[4:0]!=5'h1f)begin
                wb_tag0=w.spsr_tag;wb_data0=(w.saved_psr&~psr_mask)|(w.psr_source&psr_mask);
            end else if(!w.ins[22])wb_flags=(w.flags&~psr_mask)|(w.psr_source&psr_mask);
        end
        if(w.kind==CP&&w.pass)wb_flags[31:28]=cp_flags;
        if(|rf_class)begin wb_data0=w.pc+32'd4;wb_pair=0;end
        if(wb_exception)wb_flags=w.flags;
        if(wb_restore)begin wb_tag0=w.dest[1];wb_data0=w.original_base;wb_pair=0;wb_flags=w.flags;end
        return_event=w.pass&&(w.pc_write||(w.memory&&!w.store&&w.dest[0]==15));
        return_target=w.memory?load_data:w.kind==SUFFIX?w.address:w.result[0];
        target_raw_bit1=return_target[1];
        return_thumb=wb_flags[5];
        if(w.memory&&w.dest[0]==15&&!l4_enable)return_thumb=return_target[0];
        return_target=return_thumb?{return_target[31:1],1'b0}:{return_target[31:2],2'b0};
        target_mismatch_ref=w.pred_target!={return_target[31:1],return_thumb};
        target_mismatch=REDIRECT_EQ?!target_hi_eq[target_source]||
            w.pred_target[1]!=(return_thumb&&target_raw_bit1)||w.pred_target[0]!=return_thumb:
            target_mismatch_ref;
        return_kind=(w.kind==BLOCK&&w.dest[0]==15)||((w.ins&32'h0fffffff)==32'h01a0f00e);
        wb_redirect=wb_complete&&(wb_exception||w_serial||scalar_replay||
            (return_event&&(!w.predicted||target_mismatch||
             (w.kind==DP&&w.ins[20])||(w.kind==BLOCK&&w.ins[22])))||
            (w.pass&&w.kind==SWP));
    end

`ifndef SYNTHESIS
    always_ff @(posedge i_clk) if(!i_reset&&w.valid)
        assert(target_mismatch==target_mismatch_ref) else $fatal(1,"W return-target compare");
`endif
    always_ff @(posedge i_clk)begin
        if(i_reset)begin
            m<='0;w<='0;skid<='0;memory_state<=RUN;saved_load<=0;swap_write<=0;w_cls<=0;
            w_load_select<=1;w_waited<=0;w_hit_candidate<=0;
            wb_flush<=0;wb_target<=RESET_VECTOR;wb_thumb<=0;predictor_clear<=0;
            wb_repair_pointer<=0;wb_repair_count<=0;wb_repair_action<=0;wb_repair_link<=0;
            cp_seen<=0;cp_finished<=0;cp_flags<=0;w_serial_continue<=0;
            w_train<=0;w_train_pc<=0;w_train_target<=0;w_train_thumb<=0;w_train_hit<=0;w_train_state<=0;w_train_kind<=0;
        end else begin
            w_serial_continue<=wb_complete&&cp_read&&w.dest[0]==15&&!wb_exception;
            wb_flush<=wb_redirect;predictor_clear<=wb_redirect&&w.pass&&(w.kind==CP||w.kind==MSR);
            // W's pre-instruction checkpoint owns this recovery. Restore it
            // and apply only the retiring instruction's actual action once.
            // An exception cancels that instruction; it has no RAS action.
            wb_repair_pointer<=w.ras_pointer;wb_repair_count<=w.ras_count;
            wb_repair_link<={w.next_pc[31:1],w.thumb};
            wb_repair_action<=wb_exception||!w.pass?2'd0:
                (w.kind==BR&&w.ins[24])||w.kind==SUFFIX?2'd1:
                return_event&&return_kind?2'd2:2'd0;
            wb_thumb<=wb_exception?1'b0:cpsr_next[5];
            wb_target<=wb_dabt?vector_base+16:wb_fiq?vector_base+28:wb_irq?vector_base+24:
                wb_pabt?vector_base+12:wb_swi?vector_base+8:wb_und?vector_base+4:
                return_event?return_target:w.next_pc;
            w_train<=wb_complete&&return_event&&!wb_exception;
            w_train_pc<=w.pc;w_train_target<={return_target[31:1],return_thumb};
            w_train_thumb<=w.thumb;w_train_hit<=w.pred_hit;w_train_state<=w.pred_state;
            w_train_kind<=return_kind?2'd2:2'd0;
            if(cp_request&&!cp_seen)begin cp_seen<=1;cp_flags<=w.flags[31:28];end
            if(cp_request&&copro_reg_en&&copro_reg_wr_index==15)cp_flags<=copro_reg_wr_data[31:28];
            if(cp_request&&copro_done)cp_finished<=1;
            if(wb_complete)begin cp_seen<=0;cp_finished<=0;swap_write<=0;end
            if(w_return)saved_load<=i_dc_reg_dat;
            if(w.valid&&!done)w_waited<=1;
            if((memory_state==RUN&&done)||memory_state==RELOAD1||quick_reload)begin
                w_load_select<=64'd1<<m.dest[0];w_waited<=0;
            end
            m<=m_next;w<=w_next;skid<=skid_next;memory_state<=memory_state_next;w_cls<=w_cls_next;
            if(memory_state==LOAD_RETURN&&!w_locked&&w.kind==SWP)swap_write<=1;
            if(defer_load)saved_load<=resp_dat;
            if(wb_flush)begin w_waited<=0;swap_write<=0;cp_seen<=0;cp_finished<=0;end
            // w_waited's next value, from the three assignments above.
            w_hit_candidate<=w_next.memory&&(wb_flush||(memory_state==RUN&&done)||memory_state==RELOAD1||quick_reload||
                !((w.valid&&!done)||w_waited));

        end
    end
    assign o_dbg_wb_valid=wb_valid;assign o_dbg_wb_dvalid=wb_cfail;
    assign o_dbg_wb_uop_last=wb_last;assign o_dbg_wb_dabt={1'b0,wb_dabt};
    assign o_dbg_wb_pabt=wb_pabt;assign o_dbg_wb_fiq=wb_fiq;assign o_dbg_wb_irq=wb_irq;
    assign o_dbg_wb_swi=wb_swi;assign o_dbg_wb_und=wb_und;
    assign o_dbg_wb_pc=w.pc+(w.thumb?32'd4:32'd8);assign o_dbg_wb_cpsr_nxt=cpsr_next;
    assign o_dbg_stall={wb_flush,a_redirect,w.valid&&w.kind==CP,a_multiply_wait||a_shift_wait,
        d_hazard||!a_execute_ready,!d_valid,o_code_stall,memory_state!=RUN};
    wire [31:0] data_pc8=w.pc+(w.thumb?32'd4:32'd8);
    wire [31:0] pc=d_pc,ins=d_instruction,ex_result=a_result[0];
    wire load_capture=|i_dc_reg_idx;
    wire [63:0] load_commit=0;
    wire [31:0] load_value=load_data;
    wire unused=&{1'b0,LOAD_FORMATTED,BP_ENTRIES,FIFO_DEPTH,RAS_DEPTH,CP,UND,SWI,MRS,BR,PREFIX,MUL,MULL,
        i_instr_data_early,i_instr_hit,cp_seen,d_ready,d_raw,d_mode,d_reg_count,d_transfer_reg,d_pred_kind,
        a_flags,a_write_flags,a_store,a_btb_kind,a_predicted,a_psr_source,a_saved_psr,a_spsr_tag,
        d_early,data_pc8,pc,ins,ex_result,load_capture,load_commit,load_value};

    // A first-clock W short hit is trusted as a load that completes now.
    // A short hit on a fill's departing victim is not accepted
    // (i_data_short_live low); after installation the load misses and
    // only then locks its register. The fill-end clock's response predates
    // installation and W re-reads it (RETRY0), typically for the first
    // load after a W flush. Neither may be trusted where completion order
    // matters:
    // - D2's WAW check: an independent younger writer passed before the
    //   lock existed, hit and retired first; the older load's background
    //   return then overwrote it (the EKA1 kernel's ip, 0x50321574).
    // - S/A, for a younger writer that READS the destination (ldr r2,[r2]):
    //   D2 passes it on the premise that it waits for the older load's
    //   data. Taking the departing line's word early let it retire before
    //   the background return, which overwrote it (the handle lookup's r2
    //   at 0x503CBDC6, the user data abort at 25 s). arm9v2_execute
    //   applies i_load_trust only to such writers (d_self_dep); other
    //   readers may take the word, the departing line's current data.
    wire load_trust=TRUST_FF?i_data_short_trust:i_data_short_live&&!fill_ended;
`ifndef SYNTHESIS
    // The FSM loads its trust register from the next state: no clock is
    // added or lost against the departing-victim and fill-end terms.
    logic fill_reset_done;
    always_ff @(posedge i_clk) fill_reset_done<=!i_reset;
    always_ff @(posedge i_clk) if(!i_reset&&fill_reset_done)
        assert(i_data_short_trust==(i_data_short_live&&!fill_ended))
            else $fatal(1,"short-hit trust register");
`endif
    wire w_hit=TRUST_FF?w_hit_candidate:w.memory&&!w_waited;
`ifndef SYNTHESIS
    always_ff @(posedge i_clk) if(!i_reset)
        assert(w_hit_candidate==(w.memory&&!w_waited)) else $fatal(1,"W hit candidate register");
`endif
    wire w_load_hit=w_hit&&i_data_short_hit&&load_trust;
    arm9v2_front_decode #(.RESET_VECTOR(RESET_VECTOR),.PREDICTOR(ARM9_PREDICTOR),.S_AGU(S_AGU),.THUMB_HALF(THUMB_HALF),.SHIFT_PRE(SHIFT_PRE),.PAYLOAD_FREE(PAYLOAD_FREE),.REDIRECT_PAYLOAD(REDIRECT_PAYLOAD),.WT_TAGS(WT_TAGS),.RAS_TOP_FF(RAS_TOP_FF),.PREFIX_FREE(PREFIX_FREE),.VALID_BIT(VALID_BIT),.HEAD_FF(HEAD_FF)) u_front_decode (
        .i_w_load_hit(w_load_hit),.o_self_dep(d_self_dep),.o_pending(d_pending),.o_writes(d_writes),.o_early(d_early),.i_forward_tag(mw_tag),.i_advance_tag(advance_tag),.i_forward_advance(forward_advance),
        .i_forward_load(forward_load),.o_forward_grant(d_forward_grant),.i_forward_write(forward_write),.o_forward_match(d_forward_match),.i_clk(i_clk),
        .i_return_next_valid(return_next_valid),.i_return_next_tag(w.dest[0]),.o_return_match(d_return_match),
        .i_reset(i_reset),
        .i_flush(wb_flush||a_redirect),
        .i_serial_continue(a_serial_continue||w_serial_continue),
        .i_mode(cpsr[4:0]),
        .i_wen(wb_valid),
        .i_wr_addr_a(wa),
        .i_wr_tag_a(wb_tag0),.i_wr_tag_b(wb_tag1),.i_wr_pair(wb_pair),
        .i_wr_addr_b(wb),
        .i_wr_addr_c(wc),
        .i_locked(locked),
        .i_rf_value(rf_value),.o_rf_tag(rf_tag),.i_load_tag(load_tag),.i_load_valid(load_valid),.i_load_speculate(load_speculate),.i_next_load_tag(next_load_tag),.i_next_load_valid(next_load_valid),.o_load_wait(d_load_wait),
        .i_early_tag(early_tag),
        .i_early_valid(early_valid),
        .i_early_agu(early_agu),
        .i_wr_data_a(wb_data0),
        .i_wr_data_b(wb_data1),
        .i_wr_data_c(i_dc_reg_dat),
        .i_ready(a_execute_ready),
        .i_ready_payload(a_execute_ready_payload),
        .i_backend_target(wb_flush?wb_target:a_redirect_target),
        .i_backend_link(wb_flush?wb_repair_link:a_redirect_link),
        .i_backend_thumb(wb_flush?wb_thumb:a_redirect_thumb),
        .i_backend_pointer(wb_flush?wb_repair_pointer:a_redirect_pointer),
        .i_backend_count(wb_flush?wb_repair_count:a_redirect_count),
        .i_backend_action(wb_flush?wb_repair_action:a_redirect_action),
        .i_predictor_clear(predictor_clear),
        .i_update(train),
        .i_update_pc(train_pc),
        .i_update_target(train_target),
        .i_update_thumb(train_thumb),
        .i_update_taken(train_taken),
        .i_update_hit(train_hit),
        .i_update_state(train_state),
        .i_update_kind(train_kind),
        .i_data(i_instr_wb_dat),
        .i_ack(i_instr_wb_ack),
        .i_error(i_instr_wb_err),
        .i_retry(i_icache_err2),
        .i_fill_pending(i_icache_fill_pending),
        .i_fill_done(i_icache_fill_done),
        .i_fill_fault(i_icache_fill_fault),
        .o_ready(d_ready),
        .o_valid(d_valid),
        .o_pc(d_pc),
        .o_instruction(d_instruction),
        .o_pc_base(d_pc_base),
        .o_next_pc(d_next_pc),
        .o_raw(d_raw),
        .o_mode(d_mode),
        .o_thumb(d_thumb),
        .o_fault(d_fault),
        .o_force_align(d_force_align),
        .o_reg_shift(d_reg_shift),
        .o_shift_pre(d_shift_pre),.o_tag_class(d_tag_class),
        .o_kind(d_kind),
        .o_condition(d_condition),
        .o_tag(d_tag),
        .o_used(d_used),
        .o_value(d_value),
        .o_dest(d_dest),
        .o_first(d_first),
        .o_last(d_last),
        .o_reg_count(d_reg_count),
        .o_offset(d_offset),
        .o_writeback_offset(d_writeback_offset),
        .o_transfer_reg(d_transfer_reg),
        .o_branch_target(d_branch_target),
        .o_direct(d_direct),
        .o_match_taken(d_match_taken),
        .o_match_fallthrough(d_match_fallthrough),
        .o_predicted(d_predicted),
        .o_pred_hit(d_pred_hit),
        .o_pred_target(d_pred_target),
        .o_pred_state(d_pred_state),
        .o_pred_kind(d_pred_kind),
        .o_ras_pointer(d_ras_pointer),
        .o_ras_count(d_ras_count),
        .o_hazard(d_hazard),
        // D2's redirect is applied inside front_decode (fetch); not used here.
        .o_redirect(),.o_redirect_thumb(),.o_redirect_target(),.o_redirect_link(),
        .o_redirect_pointer(),.o_redirect_count(),.o_redirect_action(),
        .o_address_nxt(f_address_nxt),
        .o_address_check(f_address_check),
        .o_address(f_address),
        .o_request(o_instr_wb_stb),
        .o_stall(o_code_stall),.o_dbg_fetch(o_dbg_fetch)
    );
    arm9v2_execute #(.S_AGU(S_AGU),.FREE_SELECT(FREE_SELECT),.FAST_Z(FAST_Z),.W_ROTATE(W_ROTATE),.SHIFT_PRE(SHIFT_PRE),.PAYLOAD_FREE(PAYLOAD_FREE),.DSP_PRODUCT(DSP_PRODUCT),.OP1_PRE(OP1_PRE),.WRITES_PRE(WRITES_PRE),.TAG_PRE(TAG_PRE),.HELD_FREE(HELD_FREE),.MUL_FAST_Z(MUL_FAST_Z),.AGU_AL(AGU_AL)) u_execute (
        .i_pending(d_pending),.i_admit(backend_ready),.i_load_wait(d_load_wait),
        .i_load_owner({w.load_writer,m.load_writer}),.i_next_load_owner(forward_load),
        .i_load_hit(w_hit&&i_data_short_hit),.i_load_trust(load_trust),.i_self_dep(d_self_dep),
        .i_return_select(i_dc_reg_idx),.i_return_data(operand_return_data),
        .i_return_next_valid(return_next_valid),.i_return_next_tag(w.dest[0]),
        .i_return_ready(return_ready),.i_return_s_match(d_return_match),.i_forward_grant(d_forward_grant),.i_forward_match(d_forward_match),.i_next_tag(mw_tag),.i_advance_tag(advance_tag),.i_next_advance(forward_advance),.i_next_write(forward_write),.i_early(d_early),
        .o_btb_pc(a_btb_pc),.o_btb_thumb(a_btb_thumb),
        .o_record_pointer(a_record_pointer),.o_record_count(a_record_count),
        .o_record_pred_hit(a_record_pred_hit),.o_record_pred_state(a_record_pred_state),.o_record_thumb(a_record_thumb),
        .o_a_load(a_a_load),.o_psr_source(a_psr_source),.o_saved_psr(a_saved_psr),.o_original_base(a_original_base),.o_next_pc(a_next_pc),.o_prediction_target(a_prediction_target),.o_spsr_tag(a_spsr_tag),.o_predicted(a_predicted),
        .i_clk(i_clk),
        .i_reset(i_reset),
        .i_flush(wb_flush),
        .i_flags_refresh(w_serial_continue),.o_serial_continue(a_serial_continue),
        .i_cpsr({cpsr[31:6],d_thumb,cpsr[4:0]}),
        .i_valid(d_valid),
        .i_pc(d_pc),
        .i_instruction(d_instruction),
        .i_pc_base(d_pc_base),
        .i_next_pc(d_next_pc),
        .i_thumb(d_thumb),
        .i_fault(d_fault),
        .i_force_align(d_force_align),
        .i_reg_shift(d_reg_shift),
        .i_shift_pre(d_shift_pre),.i_tag_class(d_tag_class),
        .i_first(d_first),
        .i_last(d_last),
        .i_kind(d_kind),.i_writes(d_writes),
        .i_condition(d_condition),
        .i_tag(d_tag),
        .i_used(d_used),
        .i_value(d_value),
        .i_dest(d_dest),
        .i_offset(d_offset),
        .i_writeback_offset(d_writeback_offset),
        .i_branch_target(d_branch_target),
        .i_pred_target(d_pred_target),
        .i_direct(d_direct),
        .i_predicted(d_predicted),
        .i_match_taken(d_match_taken),
        .i_match_fallthrough(d_match_fallthrough),
        .i_pred_hit(d_pred_hit),
        .i_pred_state(d_pred_state),
        .i_ras_pointer(d_ras_pointer),
        .i_ras_count(d_ras_count),
        .i_mw_value(mw_value),
        .i_mw_tag(mw_tag),
        .i_mw_valid(mw_write),
        .i_ready(backend_ready),
        .o_ready(a_execute_ready),.o_ready_payload(a_execute_ready_payload),
        .o_valid(a_valid),
        .o_pc(a_pc),
        .o_instruction(a_instruction),
        .o_cpsr(a_cpsr),
        .o_cpsr_next(a_cpsr_next),
        .o_kind(a_kind),
        .o_thumb(a_thumb),
        .o_fault(a_fault),
        .o_first(a_first),
        .o_last(a_last),
        .o_condition_pass(a_condition_pass),
        .o_dest(a_dest),
        .o_result(a_result),
        .o_write(a_write),
        .o_write_flags(a_write_flags),
        .o_pc_write(a_pc_write),
        .o_memory(a_memory),
        .o_store(a_store),
        .o_address(a_data_address),.o_alu_address(a_alu_address),
        .o_store_data(a_store_data),
        .o_flags(a_flags),
        .o_redirect(a_redirect),
        .o_redirect_thumb(a_redirect_thumb),
        .o_redirect_target(a_redirect_target),
        .o_redirect_link(a_redirect_link),
        .o_redirect_pointer(a_redirect_pointer),
        .o_redirect_count(a_redirect_count),
        .o_redirect_action(a_redirect_action),
        .o_btb_update(a_btb_update),
        .o_btb_taken(a_btb_taken),
        .o_btb_hit(a_btb_hit),
        .o_btb_target(a_btb_target),
        .o_btb_state(a_btb_state),
        .o_btb_kind(a_btb_kind),
        .o_a_valid(a_a_valid),
        .o_a_can_finish(a_a_can_finish),.o_a_cond_al(a_a_cond_al),
        .o_s_write(a_s_write),
        .o_a_dest(a_a_dest),
        .o_a_write(a_a_write),
        .o_shift_wait(a_shift_wait),
        .o_multiply_wait(a_multiply_wait)
    );

    zap_writeback #(.COPRO_PORT(COPRO_PORT),.PHY_REGS(40),.FLAG_WDT(32),.CPSR_INIT(CPSR_INIT)) u_zap_writeback (
        .i_rf_class(rf_class),.i_clk(i_clk),.i_reset(i_reset),.i_valid(wb_valid),
        .i_l4_enable(l4_enable),
        .i_rd_index_0(rf_tag[0]),.i_rd_index_1(rf_tag[1]),
        .i_rd_index_2(rf_tag[2]),.i_rd_index_3(rf_tag[3]),
        .i_mem_load_ff(wb_pair),.i_wr_index(wb_tag0),.i_wr_data(wb_data0),
        .i_flags(wb_flags),.i_wr_index_1(wb_tag1),.i_wr_data_1(wb_data1),
        .i_wr_index_2(i_dc_reg_idx[39:0]),.i_wr_data_2(i_dc_reg_dat),
        .i_irq(wb_irq),.i_fiq(wb_fiq),.i_instr_abt(wb_pabt),
        .i_data_abt({1'b0,wb_dabt}),.i_swi(wb_swi),.i_und(wb_und),
        .i_pc_plus_8_buf_ff(o_dbg_wb_pc),.i_copro_reg_en(copro_reg_en),
        // MRC only writes the RF. Without COPRO_PORT the coprocessor shares
        // port A: preserve D2's read address there; only the fenced MCR may
        // borrow it. With COPRO_PORT, port E is the coprocessor's alone.
        .i_copro_reg_wr_index(copro_reg_wr_index),.i_copro_reg_rd_index(COPRO_PORT?copro_reg_rd_index:w.ins[20]?rf_tag[0]:copro_reg_rd_index),
        .i_copro_reg_wr_data(copro_reg_wr_data),.o_copro_reg_rd_data_ff(copro_reg_rd_data),
        .o_rd_data_0(rf_value[0]),.o_rd_data_1(rf_value[1]),
        .o_rd_data_2(rf_value[2]),.o_rd_data_3(rf_value[3]),
        .o_cpsr_nxt(cpsr_next),.o_dbg_cpsr_ff(o_dbg_wb_cpsr)
    );

zap_cp15_cb #(
.BE_32_ENABLE(BE_32_ENABLE),
.PHY_REGS(40),
.CP15_L4_DEFAULT(CP15_L4_DEFAULT),
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
        .i_cp_word              (w.ins),
        .i_cp_dav               (cp_request && !cp_seen),
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
        .i_dcache_line_done     (i_dcache_line_done),
        .i_dcache_writeback_busy (i_dcache_writeback_busy)
);



endmodule
