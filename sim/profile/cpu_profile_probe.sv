// SPDX-License-Identifier: GPL-3.0-or-later
// Simulation-only bound observations. Not in files.qip or gen_cpu.sh.
// Bit definitions and attribution priority live in cpu_profile.h.
module cpu_profile_probe #(parameter CORE="ZAP") ();
    wire [63:0] flags /* verilator public_flat_rd */;
    wire [31:0] decode_pc /* verilator public_flat_rd */;
    wire [31:0] decode_ins /* verilator public_flat_rd */;
    wire [31:0] retire_ins /* verilator public_flat_rd */;
    wire [31:0] recovery_target /* verilator public_flat_rd */;
    wire [7:0] raw_stall /* verilator public_flat_rd */;
    wire [7:0] raw_icache /* verilator public_flat_rd */;
    wire [3:0] raw_dcache /* verilator public_flat_rd */;
    `define TOP arm925t.u_zap
    `define DC `TOP.l_generate_with_cache_mmu.u_data_cache.u_zap_cache_fsm
    `define IC `TOP.l_generate_with_cache_mmu.u_code_cache.u_zap_cache_fsm
    assign raw_stall=`TOP.o_dbg_stall;
    assign raw_icache=`TOP.o_dbg_icache;
    assign raw_dcache=`TOP.o_dbg_dcache;
    assign flags[0]=arm925t.reset;
    assign flags[2]=`IC.state_ff==4 || `IC.state_ff==8;
    assign flags[3]=`TOP.l_generate_with_cache_mmu.u_code_cache.tlb_busy;
    assign flags[4]=`DC.o_fill_busy;
    assign flags[5]=`TOP.l_generate_with_cache_mmu.u_data_cache.tlb_busy;
    assign flags[7]=(`DC.state_ff[1]||`DC.state_ff[2]||`DC.state_ff[9])&&`DC.uncached_ff;
    assign flags[8]=(`DC.state_ff[1]||`DC.state_ff[2]||`DC.state_ff[9])&&!`DC.uncached_ff;
    assign flags[29]=raw_dcache[0];
    assign flags[30]=raw_dcache[1];
    assign flags[31]=raw_icache[2];
    assign flags[45]=`DC.o_lock_any;
    assign flags[63:46]=0;
    if(CORE=="ARM9")begin:g_v2
        `define C `TOP.g_arm9.u_arm9_core
        `define D `C.u_front_decode.u_decode
        `define F `C.u_front_decode.u_fetch
        `define E `C.u_execute
        // Packed S12 record layout, identical in source and sv2v netlist.
        // Avoid adding instrumentation fields or registers to the CPU.
        wire [539:0] w=`C.w;
        wire [3:0] kind=w[6:3];
        wire d_lock;
        assign d_lock=`D.d2_valid && (
            (`D.d2[96]&&`D.i_locked[`D.o_rf_tag[0*6+:6]])||
            (`D.d2[97]&&`D.i_locked[`D.o_rf_tag[1*6+:6]])||
            (`D.d2[98]&&`D.i_locked[`D.o_rf_tag[2*6+:6]])||
            (`D.d2[99]&&`D.i_locked[`D.o_rf_tag[3*6+:6]])||
            (`D.d2[78]&&`D.i_locked[`D.d2[80+:6]])||
            (`D.d2[79]&&`D.i_locked[`D.d2[86+:6]]));
        assign flags[1]=`F.count==0 || !`F.o_valid;
        assign flags[6]=`C.request&&!`C.request_done;
        wire [3:0] operand_locked;
        for(genvar src=0;src<4;src++)begin:g_lock
            assign operand_locked[src]=(`E.a_valid&&`E.a_wait[src]&&`C.i_dc_lock[`E.a[16+src*6+:6]])||
                (`E.i_valid&&`E.s_wait[src]&&`C.i_dc_lock[`E.i_tag[src*6+:6]]);
        end
        assign flags[9]=d_lock || (`C.w_locked&&w[539]&&!`C.wb_complete) || (|operand_locked);
        assign flags[10]=(`D.d2_valid&&`D.load_hazard)||`C.d_load_wait;
        assign flags[11]=`C.a_shift_wait || (`D.d2_valid&&(|`D.early_hazard));
        assign flags[12]=`C.a_multiply_wait;
        assign flags[13]=`C.d_hazard || (`C.d_valid&&!`C.a_execute_ready) || (|`E.a_wait);
        assign flags[14]=`D.fenced || (w[539]&&kind==7&&!`C.wb_complete);
        assign flags[15]=`C.scalar_replay&&`C.wb_complete;
        assign flags[16]=`C.memory_state==2||`C.memory_state==3||`C.memory_state==4||`C.memory_state==5||`C.fill_ended;
        assign flags[17]=`C.a_redirect;
        assign flags[18]=`C.u_front_decode.o_redirect;
        assign flags[19]=`C.wb_redirect&&`C.return_event&&!`C.wb_exception;
        assign flags[20]=`C.wb_redirect&&`C.wb_exception;
        assign flags[21]=`C.wb_redirect&&!`C.return_event&&!`C.wb_exception;
        assign flags[22]=`C.wb_valid||`C.wb_cfail;
        assign flags[23]=`C.wb_last;
        assign flags[24]=`C.wb_valid;
        assign flags[25]=w[537];
        assign flags[26]=`C.d_valid&&`C.d_kind==6;
        assign flags[27]=`F.o_request&&!`F.i_ack;
        assign flags[28]=`F.advance&&`F.predicted;
        assign flags[32]=`C.a_btb_update;
        assign flags[33]=`C.a_btb_update&&`C.a_btb_hit;
        assign flags[34]=`C.a_redirect;
        assign flags[35]=`C.wb_complete&&w[533]&&w[538]&&!`C.wb_exception;
        assign flags[36]=w[539];
        assign flags[37]=`C.a_a_valid;
        assign flags[38]=`C.d_valid;
        assign flags[39]=`C.o_dbg_wfi;
        assign flags[40]=`C.d_valid;
        assign flags[44]=`C.wb_flush&&`C.wb_repair_action==2;
        assign flags[41]=`C.wb_flush;
        assign flags[42]=`C.d_thumb;
        assign flags[43]=0;
        assign recovery_target=`C.wb_flush?`C.wb_target:`C.a_redirect?`C.a_redirect_target:`C.u_front_decode.o_redirect_target;
        assign decode_pc=`C.d_pc;
        assign decode_ins=`C.d_instruction;
        assign retire_ins=w[492-:32];
        initial assert($bits(`C.w)==540) else $fatal(1,"profile W layout changed");
        `undef C
        `undef D
        `undef F
        `undef E
    end else begin:g_zap
        `define C `TOP.g_zap.u_zap_core
        `define D `C.u_zap_predecode
        `define I `C.u_zap_issue_main
        assign flags[1]=!`C.fifo_valid;
        assign flags[6]=`C.data_stall;
        assign flags[9]=`C.stall_from_issue&&((|(`I.operand_load_lock&`I.slot_locked[3:0]))||(`I.destination_load_lock&&`I.slot_locked[4]));
        assign flags[10]=`C.stall_from_issue&&`I.load_lock;
        assign flags[11]=`C.stall_from_issue&&`I.shift_lock;
        assign flags[12]=`C.u_zap_shifter_main.multiply_busy;
        assign flags[13]=`C.stall_from_issue||`C.stall_from_shifter;
        assign flags[14]=`D.cp_stall;
        assign flags[15]=`C.u_zap_writeback.i_data_abt[1];
        assign flags[16]=`DC.state_ff[11]||`DC.state_ff[12]||`DC.state_ff[13];
        assign flags[17]=`C.alu_redirect&&!`C.data_stall;
        assign flags[18]=`C.clear_from_decode&&!`D.stall;
        // ZAP has no separate W RAS-repair event. W PC writes share this
        // class, excluding explicit faults/interrupts and CP15 releases.
        assign flags[19]=`C.clear_from_writeback&&!flags[15]&&!flags[20]&&!flags[21];
        assign flags[20]=`C.o_dbg_wb_dabt[0]||`C.o_dbg_wb_pabt||`C.o_dbg_wb_irq||`C.o_dbg_wb_fiq||`C.o_dbg_wb_swi||`C.o_dbg_wb_und;
        assign flags[21]=`D.cp15_release;
        assign flags[22]=`C.o_dbg_wb_valid||`C.o_dbg_wb_dvalid;
        assign flags[23]=`C.o_dbg_wb_uop_last;
        assign flags[24]=`C.o_dbg_wb_valid;
        assign flags[25]=`C.o_dbg_wb_cpsr[5];
        assign flags[26]=`D.mem_fetch_stall;
        assign flags[27]=raw_icache[1];
        assign flags[28]=0; // ZAP's speculative fetch accepts are not a V2-equivalent event.
        assign flags[32]=0;
        assign flags[33]=0;
        assign flags[34]=`C.clear_from_alu&&!`C.data_stall;
        assign flags[35]=`C.o_dbg_wb_valid&&`C.memory_mem_load_ff;
        assign flags[36]=flags[22];
        assign flags[37]=`C.alu_dav_ff;
        assign flags[38]=`C.decode_condition_code!=15;
        assign flags[39]=`C.o_dbg_wfi;
        assign flags[40]=`D.skid_instruction_valid;
        assign flags[44]=0; // ZAP exposes no separate W RAS repair.
        assign flags[41]=0;
        assign flags[42]=`D.i_cpu_mode_t;
        assign flags[43]=`C.shifter_redirect&&!`C.data_stall;
        assign recovery_target=`C.u_zap_writeback.pc_control_tree.new_pc;
        assign decode_pc=`D.skid_pc_ff;
        assign decode_ins=`D.skid_instruction[31:0];
        assign retire_ins=0; // The bench remembers the decoded original by PC.
        `undef C
        `undef D
        `undef I
    end
    `undef TOP
    `undef DC
    `undef IC
endmodule
bind arm925t cpu_profile_probe #(.CORE(CORE)) profile_probe();
