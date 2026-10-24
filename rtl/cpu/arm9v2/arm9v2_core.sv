// SPDX-License-Identifier: GPL-3.0-or-later
// ARM9V2 integration. Banked retirement/CP15 reuse ZAP by Revanth Kamaraj.
// See docs/ARM9V2.md for the registered address and completion contracts.
module arm9v2_core #(
        parameter logic ARM9_PREDICTOR = 1'b1,

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
input logic [31:0] i_data_short_data,
input logic i_data_short_hit,
input logic i_data_short_live,
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
    logic [3:0] d_kind;
    logic [3:0] d_condition;
    logic [3:0][5:0] d_tag;
    logic [3:0] d_used,d_early;
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
    logic d_redirect;
    logic d_redirect_thumb;
    logic [31:0] d_redirect_target;
    logic [31:0] d_redirect_link;
    logic [2:0] d_redirect_pointer;
    logic [3:0] d_redirect_count;
    logic [1:0] d_redirect_action;
    logic a_execute_ready;
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
    logic [31:0] a_data_address;
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
    } record_t;
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
    logic next_check_enable;

    (* dont_retime *) memory_state_t memory_state;
    (* dont_retime *) logic [31:0] saved_load;
    (* dont_retime *) logic [63:0] w_load_select;
    (* dont_retime *) logic w_waited;
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
    assign return_next_valid=!i_reset&&wb_complete&&w.memory&&w.load_writer&&!wb_exception;
    // The accepting edge can install a miss lock. Test the registered
    // return owner after that edge; never qualify it with the old lock.
    // Only this one ready bit fans out to the eight registered matches.
    assign return_ready=!i_dc_lock[return_tag];
    assign operand_return_data={i_dc_reg_dat,return_data};
    always_ff @(posedge i_clk) begin
        return_tag<=w.dest[0];return_data<=load_data;
    end
    (* dont_retime *) logic swap_write,cp_seen,cp_finished;
    (* dont_retime *) logic [3:0] cp_flags;
    (* dont_retime *) logic wb_flush,wb_thumb,predictor_clear;
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
    assign early_valid={a_a_write&{2{a_a_valid&&!a_a_can_finish}},a_s_write}&
        {early_tag[3]!=15,early_tag[2]!=15,early_tag[1]!=15,early_tag[0]!=15};
    // Pipeline load ownership and the cache's registered background lock are
    // separate. No cache ACK or producer readiness is searched in forwarding.
    assign load_tag={skid.dest[0],w.dest[0],m.dest[0],a_dest[0],a_a_dest[0],d_dest[0]};
    assign load_valid={skid.valid&&((skid.memory&&!skid.store)||skid.load_writer),
        w.valid&&((w.memory&&!w.store)||w.load_writer),m.valid&&((m.memory&&!m.store)||m.load_writer),
        1'b0,a_a_load,
        d_valid&&!d_fault&&((d_kind==MEM||d_kind==BLOCK)?d_instruction[20]:d_kind==SWP||(d_kind==CP&&d_instruction[20]&&d_dest[0]!=15))};
    // Scalar consumers may enter S/A before the result is known; their
    // registered operand locks retain them until a hit or completion.
    // Only the final non-PC block word may use the scalar schedule. Earlier
    // words retain partial-LDM protection; an abort restores Rn and kills
    // younger records before any can retire. SWP/PC retain their interlock.
    assign load_speculate={(skid.kind==MEM||(skid.kind==BLOCK&&skid.last))&&skid.dest[0]!=15,(w.kind==MEM||(w.kind==BLOCK&&w.last))&&w.dest[0]!=15,
        (m.kind==MEM||(m.kind==BLOCK&&m.last))&&m.dest[0]!=15,1'b0,(a_kind==MEM||(a_kind==BLOCK&&a_last))&&a_dest[0]!=15,(d_kind==MEM||(d_kind==BLOCK&&d_last))&&d_dest[0]!=15};
    assign locked=i_dc_lock[39:0];
    assign mw_tag={w.dest,m.dest};
    assign mw_value[0]=m.result;
    assign mw_value[1]={w.result[1],w.load_writer?
        (i_data_short_hit?i_data_short_data:32'd0):w.result[0]};
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
            else if(w.pass&&w.kind==CP)complete_class[consumer]=cp_finished;
            else if(memory_state==LOAD_RETURN)complete_class[consumer]=!w_locked&&w.kind!=SWP;
            else if(memory_state==RUN||memory_state==HOLD)
                complete_class[consumer]=!w.memory||(request_done&&!retry&&!defer_load);
        end
        // Restore Rn on an aborting block before the exception writes ABT LR.
        if(request_done&&i_data_wb_err&&w.kind==BLOCK&&w.ins[21])complete_class[consumer]=0;
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
        if(i_reset||wb_flush)begin forward_write=0;forward_load=0;next_load_valid=0;end
    end
`ifndef SYNTHESIS
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
        input_record.address=a_data_address;input_record.fcse_address=fcse(a_data_address);input_record.store_data=a_store_data;
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
    end
    always_comb begin
        m_next=m;w_next=w;skid_next=skid;memory_state_next=memory_state;
            case(memory_state)
                RUN:if(done)begin m_next=input_record;w_next=m;end
                    else begin skid_next=input_record;memory_state_next=HOLD;end
                HOLD:if(done)begin
                    if(quick_reload)begin w_next=m;m_next=skid;skid_next.valid=0;skid_next.writes=0;skid_next.load_writer=0;memory_state_next=RUN;end
                    else begin w_next.valid=0;w_next.writes=0;w_next.load_writer=0;memory_state_next=RELOAD0;end
                end
                RELOAD0:memory_state_next=RELOAD1;
                RELOAD1:begin w_next=m;m_next=skid;skid_next.valid=0;skid_next.writes=0;memory_state_next=RUN;end
                RETRY0:memory_state_next=RETRY1;
                RETRY1:memory_state_next=HOLD;
                LOAD_RETURN:if(!w_locked)begin
                    if(w.kind==SWP)begin w_next.store=1;memory_state_next=SWAP0;end
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
            if(retry||(fill_ended&&w.valid&&w.memory&&
                (memory_state==RUN||memory_state==HOLD)))memory_state_next=RETRY0;
            if(defer_load)begin memory_state_next=LOAD_RETURN;end
            if(request_done&&i_data_wb_err&&w.kind==BLOCK&&w.ins[21])memory_state_next=RESTORE;
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
        if(i_reset)begin check_ff<='0;request_ff<=0;end
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
        end
    end
`ifndef SYNTHESIS
    // Compare with the original schedule at every edge, including holds,
    // relookup, SWP, abort restoration, flush, and fill installation.
    always_ff @(posedge i_clk) if(!i_reset)begin
        assert(o_data_wb_re_check==(check_enable&&check_record.valid&&check_record.memory&&!check_record.store&&!wb_flush));
        assert(o_data_wb_we_check==(check_enable&&check_record.valid&&check_record.memory&&check_record.store&&!wb_flush));
        if(o_data_wb_re_check||o_data_wb_we_check)begin
            assert({o_data_wb_adr_check,o_mem_cpsr,o_mem_translate,o_data_wb_ldfmt_check}==
                {fcse({check_record.address[31:2],2'b0}),check_record.flags[CPSR_MODE:0],check_record.user_access,check_record.format});
        end
        assert(request==(w.valid&&w.memory&&!w_exception&&!wb_flush&&!fill_ended&&
            (memory_state==RUN||memory_state==HOLD)));
        if(request)assert(o_data_wb_adr==fcse({w.address[31:2],2'b0}));
    end
`endif
    assign check_record=(memory_state==HOLD||memory_state==RETRY1||memory_state==SWAP1)?w:m;
    assign check_enable=memory_state==RUN||memory_state==HOLD||memory_state==RELOAD1||memory_state==RETRY1||memory_state==SWAP1;
    wire [31:0] lookup_address=memory_state==RELOAD0?m.address:
        memory_state==RELOAD1?skid.address:
        (memory_state==HOLD||memory_state==RETRY0||memory_state==RETRY1||memory_state==SWAP0||memory_state==SWAP1)?w.address:a_data_address;
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
    assign w_exception=w.fault||w.irq||w.fiq||(w.pass&&(w.kind==SWI||w.kind==UND));
    assign cp_request=w.valid&&w.pass&&w.kind==CP&&!w_exception&&(cp_read||(!i_dc_lock_any&&!i_data_fill_busy))&&!wb_flush;
    assign request=request_ff&&!wb_flush&&!fill_ended;
    assign request_done=request&&(i_data_wb_ack||i_data_wb_err);
    assign retry=request_done&&i_dcache_err2;
    // A first-pass PC hit is already permission-qualified and formatted in
    // the M/W short-response register. Retire it once here; W's registered
    // recovery owns any redirect. Miss/hold/retry/SWP still use LOAD_RETURN.
    wire fast_pc_hit=w.memory&&!w.store&&w.dest[0]==15&&w.kind!=SWP&&i_data_short_hit&&!w_waited;
    assign defer_load=request_done&&!retry&&!i_data_wb_err&&!w.store&&((w.dest[0]==15&&!fast_pc_hit)||w.kind==SWP);
    assign load_data=(memory_state==LOAD_RETURN||swap_write)?saved_load:fast_pc_hit?i_data_short_data:i_data_wb_dat;
`ifndef SYNTHESIS
    always_ff @(posedge i_clk)if(!i_reset&&fast_pc_hit&&request_done&&!retry&&!i_data_wb_err)
        assert(i_data_short_data==i_data_wb_dat) else $fatal(1,"PC hit short/normal word mismatch");
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
    assign rf_class=memory_state==RESTORE?6'd0:{rf_static_class,(memory_state==ABORT)||(request_done&&i_data_wb_err)};
    assign wb_restore=memory_state==RESTORE;
    always_comb begin
        wb_complete=complete_class[0];
        done=!w.valid||complete_class[1];
        wb_dabt=wb_complete&&(memory_state==ABORT||(request_done&&i_data_wb_err));
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
        return_thumb=wb_flags[5];
        if(w.memory&&w.dest[0]==15&&!l4_enable)return_thumb=return_target[0];
        return_target=return_thumb?{return_target[31:1],1'b0}:{return_target[31:2],2'b0};
        return_kind=(w.kind==BLOCK&&w.dest[0]==15)||((w.ins&32'h0fffffff)==32'h01a0f00e);
        wb_redirect=wb_complete&&(wb_exception||w_serial||scalar_replay||
            (return_event&&(!w.predicted||w.pred_target!={return_target[31:1],return_thumb}||
             (w.kind==DP&&w.ins[20])||(w.kind==BLOCK&&w.ins[22])))||
            (w.pass&&w.kind==SWP));
    end

    always_ff @(posedge i_clk)begin
        if(i_reset)begin
            m<='0;w<='0;skid<='0;memory_state<=RUN;saved_load<=0;swap_write<=0;
            w_load_select<=1;w_waited<=0;
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
            m<=m_next;w<=w_next;skid<=skid_next;memory_state<=memory_state_next;
            if(memory_state==LOAD_RETURN&&!w_locked&&w.kind==SWP)swap_write<=1;
            if(defer_load)saved_load<=i_data_wb_dat;
            if(wb_flush)begin w_waited<=0;swap_write<=0;cp_seen<=0;cp_finished<=0;end

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

    // D2's WAW check lets a younger writer of W's load destination pass on
    // a first-clock short hit (S's pending bit trusts it the same way): that
    // hit must complete now. A short hit on a fill's departing victim is not
    // accepted (i_data_short_live low); after installation the load misses
    // and only then locks its register. The fill-end clock's response
    // predates installation and W re-reads it (RETRY0), so a departing line
    // can hit there too, typically for the first load after a W flush's
    // refetch. Trusting either let the younger writer pass D2 before the
    // lock existed; it hit and retired first, and the older load's
    // background return then overwrote it (the EKA1 kernel's ip). Such a
    // load is a pending owner. Readers may still take the word in S/A: it
    // is the departing line's current data, and the return rewrites it.
    arm9v2_front_decode #(.RESET_VECTOR(RESET_VECTOR),.PREDICTOR(ARM9_PREDICTOR),.EXTERNAL_RF(1)) u_front_decode (
        .i_w_load_hit(w.memory&&i_data_short_hit&&i_data_short_live&&!w_waited&&!fill_ended),.o_pending(d_pending),.o_writes(),.o_early(d_early),.i_forward_tag(mw_tag),.i_advance_tag(advance_tag),.i_forward_advance(forward_advance),
        .i_forward_load(forward_load),.o_forward_grant(d_forward_grant),.i_forward_write(forward_write),.o_forward_match(d_forward_match),.i_clk(i_clk),
        .i_return_next_valid(return_next_valid),.i_return_next_tag(w.dest[0]),.o_return_match(d_return_match),
        .i_reset(i_reset),
        .i_flush(wb_flush||a_redirect),
        .i_serial_continue(a_serial_continue||w_serial_continue),
        .i_mode(cpsr[4:0]),
        .i_wen(wb_valid),
        .i_wr_addr_a(wa),
        .i_wr_addr_b(wb),
        .i_wr_addr_c(wc),
        .i_locked(locked),
        .i_rf_value(rf_value),.o_rf_tag(rf_tag),.i_load_tag(load_tag),.i_load_valid(load_valid),.i_load_speculate(load_speculate),.i_next_load_tag(next_load_tag),.i_next_load_valid(next_load_valid),.o_load_wait(d_load_wait),
        .i_early_tag(early_tag),
        .i_early_valid(early_valid),
        .i_wr_data_a(wb_data0),
        .i_wr_data_b(wb_data1),
        .i_wr_data_c(i_dc_reg_dat),
        .i_ready(a_execute_ready),
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
        .o_redirect(d_redirect),
        .o_redirect_thumb(d_redirect_thumb),
        .o_redirect_target(d_redirect_target),
        .o_redirect_link(d_redirect_link),
        .o_redirect_pointer(d_redirect_pointer),
        .o_redirect_count(d_redirect_count),
        .o_redirect_action(d_redirect_action),
        .o_address_nxt(f_address_nxt),
        .o_address_check(f_address_check),
        .o_address(f_address),
        .o_request(o_instr_wb_stb),
        .o_stall(o_code_stall),.o_dbg_fetch(o_dbg_fetch)
    );
    arm9v2_execute u_execute (
        .i_pending(d_pending),.i_admit(backend_ready),.i_load_wait(d_load_wait),
        .i_load_owner({w.load_writer,m.load_writer}),.i_next_load_owner(forward_load),
        .i_load_hit(w.memory&&i_data_short_hit&&!w_waited),
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
        .i_first(d_first),
        .i_last(d_last),
        .i_kind(d_kind),
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
        .o_ready(a_execute_ready),
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
        .o_address(a_data_address),
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
        .o_a_can_finish(a_a_can_finish),
        .o_s_write(a_s_write),
        .o_a_dest(a_a_dest),
        .o_a_write(a_a_write),
        .o_shift_wait(a_shift_wait),
        .o_multiply_wait(a_multiply_wait)
    );

    zap_writeback #(.RF_EARLY_SELECT(1),.RF_ALLOW_RETIMING(0),.BP_ENTRIES(32),.PHY_REGS(40),.FLAG_WDT(32),
        .RESET_VECTOR(RESET_VECTOR),.CPSR_INIT(CPSR_INIT)) u_zap_writeback (
        .i_rf_class(rf_class),.i_clk(i_clk),.i_reset(i_reset),.i_valid(wb_valid),
        .i_decompile('0),.i_decompile_valid(wb_cfail),.i_uop_last(wb_last),
        .o_decompile(),.o_shelve(),.i_cpu_pid(o_pid[6:0]),
        .i_l4_enable(l4_enable),.i_hivecs(hivecs),.i_clear_btb(1'b0),
        .i_code_stall(1'b1),.i_clear_from_alu(1'b0),.i_pc_from_alu(32'd0),
        .i_clear_from_decode(1'b0),.i_pc_from_decode(32'd0),
        .i_clear_from_icache(1'b0),.i_confirm_from_alu(1'b0),
        .i_alu_pc_ff(32'd0),.i_taken(2'd0),
        .i_rd_index_0(rf_tag[0]),.i_rd_index_1(rf_tag[1]),
        .i_rd_index_2(rf_tag[2]),.i_rd_index_3(rf_tag[3]),
        .i_mem_load_ff(wb_pair),.i_wr_index(wb_tag0),.i_wr_data(wb_data0),
        .i_flags(wb_flags),.i_wr_index_1(wb_tag1),.i_wr_data_1(wb_data1),
        .i_wr_index_2(i_dc_reg_idx[39:0]),.i_wr_data_2(i_dc_reg_dat),.i_mode16(cpsr[5]),
        .i_irq(wb_irq),.i_fiq(wb_fiq),.i_instr_abt(wb_pabt),
        .i_data_abt({1'b0,wb_dabt}),.i_swi(wb_swi),.i_und(wb_und),
        .i_pc_plus_8_buf_ff(o_dbg_wb_pc),.i_copro_reg_en(copro_reg_en),
        // MRC only writes the RF. Preserve D2's read address on shared port A;
        // only the fenced MCR may borrow that port for its source read.
        .i_copro_reg_wr_index(copro_reg_wr_index),.i_copro_reg_rd_index(w.ins[20]?rf_tag[0]:copro_reg_rd_index),
        .i_copro_reg_wr_data(copro_reg_wr_data),.o_copro_reg_rd_data_ff(copro_reg_rd_data),
        .o_rd_data_0(rf_value[0]),.o_rd_data_1(rf_value[1]),
        .o_rd_data_2(rf_value[2]),.o_rd_data_3(rf_value[3]),
        .o_pc(),.o_pc_check(),.o_pc_nxt(),.o_taken(),.o_pred(),
        .o_cpsr_nxt(cpsr_next),.o_dbg_cpsr_ff(o_dbg_wb_cpsr),
        .o_clear_from_writeback(),.o_wb_stb(),.o_wb_cyc(),
        .o_trace(o_trace),.o_trace_valid(o_trace_valid),.o_trace_uop_last(o_trace_uop_last)
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
