//
// (C)2016-2024 Revanth Kamaraj (krevanth) <revanth91kamaraj@gmail.com>
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation; either version 3
// of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
// 02110-1301, USA.
//
// This stage converts register indices into actual values. Register
// indices are also pumped forward to allow resolution in the shift
// stage. PC references must be resolved here since the value gives
// PC + 8. Instructions requiring shifts stall if the target registers
// are in the outputs of this stage. We do not issue a multiply if the
// source is still in the output of this stage just like shifts. That's
// to ensure incorrect registers are not read.
//

module zap_issue_main
#(
        // Parameters.

        // Number of physical registers.
        parameter [31:0] PHY_REGS = 64,

        // Although DDI0100E mentions only 16 ALU operations, the processor
        // internally performs many more operations.
        parameter [31:0] ALU_OPS   = 32,

        // Number of supported shift operations.
        parameter [31:0] SHIFT_OPS = 5
)
(
        // Clock and reset.
        input  logic                             i_clk,
        input  logic                             i_reset,

        // UOP
        input   logic                            i_uop_last,
        output  logic                            o_uop_last,

        // MISC signals.

        input logic       [31:0]                 i_cpu_mode,
        input logic                              i_clear_from_writeback,
        input logic                              i_data_stall,
        input logic                              i_clear_from_alu,
        input logic                              i_stall_from_shifter,

        // ------------------------------------------------------
        // Inputs from decode. Look at the decode stage for the
        // meaning of these ports...
        // ------------------------------------------------------

        input logic  [31:0]                      i_pc_plus_8_ff,
        input logic  [31:0]                      i_pc_ff,
        input logic                              i_switch_ff,
        input logic    [1:0]                     i_taken_ff,
        input logic [33:0] i_link_branch_ff,
        input logic    [31:0]                    i_ppc_ff,
        input logic      [64*8-1:0]              i_decompile,
        input logic      [3:0]                   i_condition_code_ff,
        input logic      [$clog2(PHY_REGS )-1:0] i_destination_index_ff,
        input logic      [32:0]                  i_alu_source_ff,
        input logic      [$clog2(ALU_OPS)-1:0]   i_alu_operation_ff,
        input logic      [32:0]                  i_shift_source_ff,
        input logic      [$clog2(SHIFT_OPS)-1:0] i_shift_operation_ff,
        input logic      [32:0]                  i_shift_length_ff,
        input logic                             i_shift_is_lsl0_ff,
        input logic                              i_flag_update_ff,
        input logic    [$clog2(PHY_REGS )-1:0]   i_mem_srcdest_index_ff,
        input logic                              i_mem_load_ff,
        input logic                              i_mem_store_ff,
        input logic                              i_mem_pre_index_ff,
        input logic                              i_mem_unsigned_byte_enable_ff,
        input logic                              i_mem_signed_byte_enable_ff,
        input logic                              i_mem_signed_halfword_enable_ff,
        input logic                              i_mem_unsigned_halfword_enable_ff,
        input logic                              i_mem_translate_ff,
        input logic                              i_irq_ff,
        input logic                              i_fiq_ff,
        input logic                              i_abt_ff,
        input logic                              i_swi_ff,
        input logic                              i_und_ff,
        input logic                              i_force32align_ff,

        // ---------------------
        // Feedback Network
        // ---------------------

        // Lock
        input logic [63:0]                       i_dc_lock,

        // From register file. Read ports.
        input logic  [31:0]                      i_rd_data_0,
        input logic  [31:0]                      i_rd_data_1,
        input logic  [31:0]                      i_rd_data_2,
        input logic  [31:0]                      i_rd_data_3,

        //
        // Destination index feedback. Each stage is represented as
        // combinational logic followed by flops(FFs).
        //

        // The ALU never changes destination anyway. Destination from shifter.
        input logic  [$clog2(PHY_REGS )-1:0]     i_shifter_destination_index_ff,

        // Flopped destination from the ALU.
        input logic  [$clog2(PHY_REGS )-1:0]     i_alu_destination_index_ff,

        // Flopped destination from the post ALU.
        input logic  [$clog2(PHY_REGS)-1:0]     i_postalu0_destination_index_ff,
        input logic  [$clog2(PHY_REGS)-1:0]     i_postalu1_destination_index_ff,
        input logic  [$clog2(PHY_REGS)-1:0]     i_postalu_destination_index_ff,

        // Flopped destination from the memory stage.
        input logic  [$clog2(PHY_REGS )-1:0]     i_memory_destination_index_ff,

        //
        // Data valid(dav) for each stage in the pipeline. Used to validate the
        // pipeline vector when sniffing for register values yet to be written.
        //

        input logic                              i_shifter_dav_ff,
        input logic                              i_alu_dav_nxt,
        input logic                              i_alu_dav_ff,
        input logic                              i_postalu0_dav_ff,
        input logic                              i_postalu1_dav_ff,
        input logic                              i_postalu_dav_ff,
        input logic                              i_memory_dav_ff,

        //
        // The actual thing we need (i.e. data),
        // the value of stuff we are looking for.
        //

        // Taken from alu_nxt since ALU can change this.
        input logic  [31:0]                      i_alu_destination_value_nxt,

        // ALU flopped result.
        input logic  [31:0]                      i_alu_destination_value_ff,

        // PostALU result
        input logic  [31:0]                      i_postalu0_destination_value_ff,
        input logic  [31:0]                      i_postalu1_destination_value_ff,
        input logic  [31:0]                      i_postalu_destination_value_ff,

        // Result in the memory stage of the pipeline.
        input logic  [31:0]                      i_memory_destination_value_ff,

        //
        // For load-store locks and memory acceleration, we need srcdest
        // index. Memory loads can be accelerated with a direct load from
        // memory stage instead of register stage(WB).
        //
        input logic  [5:0]                       i_shifter_mem_srcdest_index_ff,
        input logic  [5:0]                       i_alu_mem_srcdest_index_ff,
        input logic  [5:0]                       i_postalu0_mem_srcdest_index_ff,
        input logic  [5:0]                       i_postalu1_mem_srcdest_index_ff,
        input logic  [5:0]                       i_postalu_mem_srcdest_index_ff,
        input logic  [5:0]                       i_memory_mem_srcdest_index_ff,

        input logic                              i_shifter_mem_load_ff,
        input logic                              i_alu_mem_load_ff,
        input logic                              i_postalu0_mem_load_ff,
        input logic                              i_postalu1_mem_load_ff,
        input logic                              i_postalu_mem_load_ff,
        input logic                              i_memory_mem_load_ff,
        // ARM925T: the memory stage's loaded value (zap_memory_main o_mem_rd_data), forwarded
        input logic  [31:0]                      i_memory_mem_rd_data,

        // -----------------------------------
        // END OF FEEDBACK NETWORK
        // -----------------------------------

        // mode32 to compressed switch.
        output logic                             o_switch_ff,

        // Outputs to register file.
        output logic      [$clog2(PHY_REGS )-1:0] o_rd_index_0,
        output logic      [$clog2(PHY_REGS )-1:0] o_rd_index_1,
        output logic      [$clog2(PHY_REGS )-1:0] o_rd_index_2,
        output logic      [$clog2(PHY_REGS )-1:0] o_rd_index_3,

        // ARM925T: late load operands: rn, rm, shift amount, store data.
        output logic [3:0]                        o_load_pending_ff,
        output logic [5:0]                        o_shift_length_index_ff,
        (* preserve, dont_retime *) output logic  o_shift_source_pending_ff,
        // ARM925T: o_alu_operation_ff is a multiply (registered with it).
        (* preserve, dont_retime *) output logic  o_alu_is_mult_ff,
        input logic [3:0]                         i_late_ready,
        input logic [127:0]                       i_late_value,

        // Outputs to shifter stage.
        output logic       [3:0]                   o_condition_code_ff,
        output logic       [$clog2(PHY_REGS )-1:0] o_destination_index_ff,
        output logic       [$clog2(ALU_OPS)-1:0]   o_alu_operation_ff,
        output logic       [$clog2(SHIFT_OPS)-1:0] o_shift_operation_ff,
        output logic                               o_flag_update_ff,

        // Memory operation related.
        output logic     [$clog2(PHY_REGS )-1:0]   o_mem_srcdest_index_ff,
        output logic                               o_mem_load_ff,
        output logic                               o_mem_store_ff,
        output logic                               o_mem_pre_index_ff,
        output logic                               o_mem_unsigned_byte_enable_ff,
        output logic                               o_mem_signed_byte_enable_ff,
        output logic                               o_mem_signed_halfword_enable_ff,
        output logic                               o_mem_unsigned_halfword_enable_ff,
        output logic                               o_mem_translate_ff,

        // Interrupts.
        output logic                               o_irq_ff,
        output logic                               o_fiq_ff,
        output logic                               o_abt_ff,
        output logic                               o_swi_ff,

        // Register values are given here.

        // ALU source value would be the value of non-shifted operand in mode32.
        // ARM925T: retain the operand-capture boundary through synthesis;
        // late completion must not be retimed into the shifter/ALU cone.
        (* dont_retime *) output logic [31:0]     o_alu_source_value_ff,

        // Shifter source value would be the value of the operand to be shifted.
        (* dont_retime *) output logic [31:0]     o_shift_source_value_ff,

        // Shift length i.e., amount to shift i.e, shamt.
        (* dont_retime *) output logic [31:0]     o_shift_length_value_ff,

        // For stores, value to be stored.
        (* dont_retime *) output logic [31:0]     o_mem_srcdest_value_ff,

        //
        // Indices/Immeds go here. It might seem odd that we are sending index
        // values and register values (above). The issue stage selects
        // the appropriate value. Note again that while the above are values,
        // these are indexes/immediates.
        //
        output logic      [32:0]                  o_alu_source_ff,
        output logic      [32:0]                  o_shift_source_ff,

        // Stall all stages before this if this is 1.
        (* dont_retime *) output logic              o_stall_from_issue,

        // The PC value.
        output logic     [31:0]                   o_pc_plus_8_ff,

        //
        // Shifter disable. In the next stage, the output
        // will bypass the shifter. Not actually bypass it but will
        // go to the ALU value corrector unit via a MUX essentially bypassing
        // the shifter.
        //
        output logic                              o_shifter_disable_ff,

        // Outputs flopped from decode.
        output  logic     [64*8-1:0]              o_decompile,
        output logic [31:0]                       o_pc_ff,
        output logic   [1:0]                      o_taken_ff,
        (* dont_retime *) output logic [33:0] o_link_branch_ff,
        output logic [31:0]                       o_ppc_ff,
        output logic                              o_force32align_ff,
        output logic                              o_und_ff
);

`include "zap_defines.svh"
`include "zap_localparams.svh"

logic o_shifter_disable_nxt;
logic [32:0] o_alu_source_value_nxt,
           o_shift_source_value_nxt,
           o_shift_length_value_nxt,
           o_mem_srcdest_value_nxt;

logic [32+32+1+2+64*8+1+4+$clog2(PHY_REGS)+33+$clog2(ALU_OPS)+33+$clog2(SHIFT_OPS)
+33+1+$clog2(PHY_REGS)+14+32-1:0] skid;

// Individual lock signals. These are ORed to get the final lock.
logic shift_lock;
logic load_lock;
logic [3:0] operand_load_lock, late_pending;
logic destination_load_lock;
logic lock;

//
// ARM925T: the register file's read indices take their own copy of the
// stall register and of the skid's four index fields. The stall register
// selects the whole skid mux (hundreds of loads), and through it the
// indices reached the register file's read mux late; the copies carry
// the same values (same reset, clear and update) with a fan-out of four
// muxes, and are kept from being merged back (timing).
//
(* preserve, dont_retime *) logic stall_idx_ff;
// ARM925T: late admission compares the same physical tags, but must not
// start at the heavily loaded control/skid stall mux or load the RF mux.
(* preserve, dont_retime *) logic stall_late_ff;
logic [23:0]                late_reg_index;
logic [23:0]                skid_idx;
logic [5:0]                 skid_dest_idx;
(* dont_retime *) logic skid_lsl0_ff;
logic [2:0] skid_late_immediate_ff;
logic skid_late_store_ff;
logic [33:0] skid_link_branch;
wire [33:0] selected_link_branch = stall_late_ff ? skid_link_branch : i_link_branch_ff;

// ARM925T: read the lock bitmap for both possible instruction slots before
// selecting the slot. Selecting the index first puts the high-fanout skid
// selector in front of a 64:1 bitmap mux on the interlock feedback path.
// Keep the two lookup banks distinct so synthesis cannot factor that mux
// back across the bitmap reads. The bitmap is still the live cache lock:
// no lock assertion or completion is delayed by a clock.
(* keep *) wire [4:0] live_locked, skid_locked;
wire [4:0] slot_locked = stall_late_ff ? skid_locked : live_locked;
assign live_locked = {i_dc_lock[i_destination_index_ff],
                      i_dc_lock[i_mem_srcdest_index_ff],
                      i_dc_lock[i_shift_length_ff[5:0]],
                      i_dc_lock[i_shift_source_ff[5:0]],
                      i_dc_lock[i_alu_source_ff[5:0]]};
assign skid_locked = {i_dc_lock[skid_dest_idx],
                      i_dc_lock[skid_idx[5:0]],
                      i_dc_lock[skid_idx[11:6]],
                      i_dc_lock[skid_idx[17:12]],
                      i_dc_lock[skid_idx[23:18]]};

//
// Asserted when an instruction cannot be issued and leads to all stages
// before it stalling.
//

// Skid MUX output.
logic  [31:0]                      skid_pc_plus_8_ff;
logic  [31:0]                      skid_pc_ff;
logic                              skid_switch_ff;
logic    [1:0]                     skid_taken_ff;
logic      [64*8-1:0]              skid_decompile;
logic                              skid_uop_last;
logic      [3:0]                   skid_condition_code_ff;
logic      [$clog2(PHY_REGS )-1:0] skid_destination_index_ff;
logic      [32:0]                  skid_alu_source_ff;
logic      [$clog2(ALU_OPS)-1:0]   skid_alu_operation_ff;
logic      [32:0]                  skid_shift_source_ff;
logic      [$clog2(SHIFT_OPS)-1:0] skid_shift_operation_ff;
logic      [32:0]                  skid_shift_length_ff;
logic                              skid_flag_update_ff;
logic    [$clog2(PHY_REGS )-1:0]   skid_mem_srcdest_index_ff;
logic                              skid_mem_load_ff;
logic                              skid_mem_store_ff;
logic                              skid_mem_pre_index_ff;
logic                              skid_mem_unsigned_byte_enable_ff;
logic                              skid_mem_signed_byte_enable_ff;
logic                              skid_mem_signed_halfword_enable_ff;
logic                              skid_mem_unsigned_halfword_enable_ff;
logic                              skid_mem_translate_ff;
logic                              skid_irq_ff;
logic                              skid_fiq_ff;
logic                              skid_abt_ff;
logic                              skid_swi_ff;
logic                              skid_force32align_ff;
logic                              skid_und_ff;
logic  [31:0]                      skid_ppc_ff;
logic                              clear;
logic                              stall;

assign lock = (shift_lock | load_lock) &
              (skid_condition_code_ff != NV);

assign clear = i_clear_from_writeback | i_clear_from_alu;
assign stall = i_data_stall           | i_stall_from_shifter;

always_ff @ ( posedge i_clk )
begin
        if ( i_reset )
        begin
                o_load_pending_ff                 <= 0;
                o_condition_code_ff               <= NV;
                o_irq_ff                          <= 0;
                o_fiq_ff                          <= 0;
                o_abt_ff                          <= 0;
                o_swi_ff                          <= 0;
                o_und_ff                          <= 0;
                o_flag_update_ff                  <= 0;
                o_stall_from_issue                <= 0;
                stall_idx_ff                      <= 0;
                stall_late_ff <= 0;

                o_destination_index_ff            <= 'x;
                o_alu_operation_ff                <= 'x;
                o_shift_operation_ff              <= 'x;
                o_mem_srcdest_index_ff            <= 'x;
                o_mem_load_ff                     <= 'x;
                o_mem_store_ff                    <= 'x;
                o_mem_pre_index_ff                <= 'x;
                o_mem_unsigned_byte_enable_ff     <= 'x;
                o_mem_signed_byte_enable_ff       <= 'x;
                o_mem_signed_halfword_enable_ff   <= 'x;
                o_mem_unsigned_halfword_enable_ff <= 'x;
                o_mem_translate_ff                <= 'x;
                o_pc_plus_8_ff                    <= 'x;
                o_shifter_disable_ff              <= 'x;
                o_alu_source_ff                   <= 'x;
                o_shift_source_ff                 <= 'x;
                o_switch_ff                       <= 'x;
                o_force32align_ff                 <= 'x;
                o_taken_ff                        <= 'x;
                o_pc_ff                           <= 'x;
                o_decompile                       <= 'x;
                o_ppc_ff                          <= 'x;
                o_link_branch_ff <= 34'b0;
        end
        else if ( clear )
        begin
                o_load_pending_ff    <= 0;
                o_condition_code_ff  <= NV;
                o_irq_ff             <= 0;
                o_fiq_ff             <= 0;
                o_abt_ff             <= 0;
                o_swi_ff             <= 0;
                o_und_ff             <= 0;
                o_flag_update_ff     <= 0;
                o_stall_from_issue   <= 0;
                stall_idx_ff         <= 0;
                stall_late_ff <= 0;

                o_destination_index_ff            <= 'x;
                o_alu_operation_ff                <= 'x;
                o_shift_operation_ff              <= 'x;
                o_mem_srcdest_index_ff            <= 'x;
                o_mem_load_ff                     <= 'x;
                o_mem_store_ff                    <= 'x;
                o_mem_pre_index_ff                <= 'x;
                o_mem_unsigned_byte_enable_ff     <= 'x;
                o_mem_signed_byte_enable_ff       <= 'x;
                o_mem_signed_halfword_enable_ff   <= 'x;
                o_mem_unsigned_halfword_enable_ff <= 'x;
                o_mem_translate_ff                <= 'x;
                o_pc_plus_8_ff                    <= 'x;
                o_shifter_disable_ff              <= 'x;
                o_alu_source_ff                   <= 'x;
                o_shift_source_ff                 <= 'x;
                o_switch_ff                       <= 'x;
                o_force32align_ff                 <= 'x;
                o_taken_ff                        <= 'x;
                o_pc_ff                           <= 'x;
                o_decompile                       <= 'x;
                o_ppc_ff                          <= 'x;
                o_link_branch_ff <= 34'b0;
        end
        else if ( ~stall )
        begin
                o_load_pending_ff                 <= (lock || skid_condition_code_ff == NV) ? 4'b0 : late_pending;
                o_shift_length_index_ff           <= skid_shift_length_ff[5:0];
                o_condition_code_ff               <= lock ? NV : skid_condition_code_ff;
                o_destination_index_ff            <= skid_destination_index_ff;
                o_alu_operation_ff                <= skid_alu_operation_ff;
                o_shift_operation_ff              <= skid_shift_operation_ff;
                o_flag_update_ff                  <= lock ? 1'd0 : skid_flag_update_ff;
                o_mem_srcdest_index_ff            <= skid_mem_srcdest_index_ff;
                o_mem_load_ff                     <= skid_mem_load_ff;
                o_mem_store_ff                    <= skid_mem_store_ff;
                o_mem_pre_index_ff                <= skid_mem_pre_index_ff;
                o_mem_unsigned_byte_enable_ff     <= skid_mem_unsigned_byte_enable_ff;
                o_mem_signed_byte_enable_ff       <= skid_mem_signed_byte_enable_ff;
                o_mem_signed_halfword_enable_ff   <= skid_mem_signed_halfword_enable_ff;
                o_mem_unsigned_halfword_enable_ff <= skid_mem_unsigned_halfword_enable_ff;
                o_mem_translate_ff                <= skid_mem_translate_ff;
                o_irq_ff                          <= lock ? 1'd0 : skid_irq_ff;
                o_fiq_ff                          <= lock ? 1'd0 : skid_fiq_ff;
                o_abt_ff                          <= lock ? 1'd0 : skid_abt_ff;
                o_swi_ff                          <= lock ? 1'd0 : skid_swi_ff;
                o_pc_plus_8_ff                    <= skid_pc_plus_8_ff;
                o_shifter_disable_ff              <= o_shifter_disable_nxt;
                o_alu_source_ff                   <= skid_alu_source_ff;
                o_shift_source_ff                 <= skid_shift_source_ff;
                o_switch_ff                       <= skid_switch_ff;
                o_force32align_ff                 <= skid_force32align_ff;
                o_und_ff                          <= skid_und_ff;
                o_taken_ff                        <= skid_taken_ff;
                o_ppc_ff                          <= skid_ppc_ff;
                o_link_branch_ff <= {selected_link_branch[33:32] & {2{!lock}}, selected_link_branch[31:0]};
                o_pc_ff                           <= skid_pc_ff;
                o_decompile                       <= skid_decompile;
                o_uop_last                        <= skid_uop_last;
                o_stall_from_issue                <= lock;
                stall_idx_ff                      <= lock;
                stall_late_ff <= lock;
        end
        else
        begin
                // Keep transient forwarding results when the late interlock
                // holds this slot. Completion may arrive during a bus stall.
                o_load_pending_ff     <= o_load_pending_ff & ~i_late_ready;
        end
end

// ARM925T: isolate the pending bit that selects the barrel-shifter input
// from the late-admission and completion control fanout. Same D and holds
// as o_load_pending_ff[1], with no extra cycle.
always_ff @(posedge i_clk) begin
        if (i_reset || clear) o_shift_source_pending_ff <= 1'b0;
        else if (!stall)
                o_shift_source_pending_ff <= !(lock || skid_condition_code_ff == NV) && late_pending[1];
        else o_shift_source_pending_ff <= o_shift_source_pending_ff && !i_late_ready[1];
end

// ARM925T: the shifter's multiply classification of o_alu_operation_ff,
// registered with it from the same skid field, so that the shifter's
// operand and late-value selects start at a flop instead of a 24-way
// compare (timing). A cleared slot (operation 'x, condition NV) reads as
// not a multiply; its operand values are never used.
always_ff @(posedge i_clk) begin
        if (i_reset || clear) o_alu_is_mult_ff <= 1'b0;
        else if (!stall)      o_alu_is_mult_ff <= skid_is_mult;
end

// ARM925T: capture register-file, forwarded and held-slot refresh data
// independently at the existing issue edge. Local registered one-hot
// selects keep both the RF read and the cache stall out of wide input
// muxes. Held slots still capture transient completion/ALU forwarding.
(* dont_retime *) logic [31:0] alu_source_normal_ff, alu_source_rf_ff, alu_source_refresh_ff;
(* preserve, dont_retime *) logic [2:0] alu_source_select_ff;
always_ff @(posedge i_clk) begin
        alu_source_normal_ff <= o_alu_source_value_nxt[31:0];
        alu_source_rf_ff <= i_rd_data_0 & ((skid_force32align_ff && !skid_mem_load_ff && !skid_mem_store_ff) ? 32'hffff_fffc : 32'hffff_ffff);
        alu_source_refresh_ff <= i_late_value[0 +: 32];
        alu_source_select_ff <= (i_reset || clear) ? 3'b000 :
                {stall, !stall && o_alu_source_value_nxt[32], !stall && !o_alu_source_value_nxt[32]};
end
assign o_alu_source_value_ff = (alu_source_normal_ff & {32{alu_source_select_ff[0]}}) |
        (alu_source_rf_ff & {32{alu_source_select_ff[1]}}) |
        (alu_source_refresh_ff & {32{alu_source_select_ff[2]}});
(* dont_retime *) logic [31:0] shift_source_normal_ff, shift_source_rf_ff, shift_source_refresh_ff;
(* preserve, dont_retime *) logic [2:0] shift_source_select_ff;
always_ff @(posedge i_clk) begin
        shift_source_normal_ff <= o_shift_source_value_nxt[31:0];
        shift_source_rf_ff <= i_rd_data_1;
        shift_source_refresh_ff <= i_late_value[32 +: 32];
        shift_source_select_ff <= (i_reset || clear) ? 3'b000 :
                {stall, !stall && o_shift_source_value_nxt[32], !stall && !o_shift_source_value_nxt[32]};
end
assign o_shift_source_value_ff = (shift_source_normal_ff & {32{shift_source_select_ff[0]}}) |
        (shift_source_rf_ff & {32{shift_source_select_ff[1]}}) |
        (shift_source_refresh_ff & {32{shift_source_select_ff[2]}});
(* dont_retime *) logic [31:0] shift_length_normal_ff, shift_length_rf_ff, shift_length_refresh_ff;
(* preserve, dont_retime *) logic [2:0] shift_length_select_ff;
always_ff @(posedge i_clk) begin
        shift_length_normal_ff <= o_shift_length_value_nxt[31:0];
        shift_length_rf_ff <= i_rd_data_2;
        shift_length_refresh_ff <= i_late_value[64 +: 32];
        shift_length_select_ff <= (i_reset || clear) ? 3'b000 :
                {stall, !stall && o_shift_length_value_nxt[32], !stall && !o_shift_length_value_nxt[32]};
end
assign o_shift_length_value_ff = (shift_length_normal_ff & {32{shift_length_select_ff[0]}}) |
        (shift_length_rf_ff & {32{shift_length_select_ff[1]}}) |
        (shift_length_refresh_ff & {32{shift_length_select_ff[2]}});
(* dont_retime *) logic [31:0] mem_srcdest_normal_ff, mem_srcdest_rf_ff, mem_srcdest_refresh_ff;
(* preserve, dont_retime *) logic [2:0] mem_srcdest_select_ff;
always_ff @(posedge i_clk) begin
        mem_srcdest_normal_ff <= o_mem_srcdest_value_nxt[31:0];
        mem_srcdest_rf_ff <= i_rd_data_3;
        mem_srcdest_refresh_ff <= i_late_value[96 +: 32];
        mem_srcdest_select_ff <= (i_reset || clear) ? 3'b000 :
                {stall, !stall && o_mem_srcdest_value_nxt[32], !stall && !o_mem_srcdest_value_nxt[32]};
end
assign o_mem_srcdest_value_ff = (mem_srcdest_normal_ff & {32{mem_srcdest_select_ff[0]}}) |
        (mem_srcdest_rf_ff & {32{mem_srcdest_select_ff[1]}}) |
        (mem_srcdest_refresh_ff & {32{mem_srcdest_select_ff[2]}});

// Skid buffer.
always_ff @ ( posedge i_clk )
begin
        if ( ~o_stall_from_issue )
        begin
                skid_idx <= {i_alu_source_ff[5:0], i_shift_source_ff[5:0],
                             i_shift_length_ff[5:0], i_mem_srcdest_index_ff[5:0]};
                skid_dest_idx <= i_destination_index_ff;
                skid_lsl0_ff <= i_shift_is_lsl0_ff;
                skid_late_immediate_ff <= {i_shift_length_ff[32], i_shift_source_ff[32], i_alu_source_ff[32]};
                skid_late_store_ff <= i_mem_store_ff;
                skid_link_branch <= i_link_branch_ff;
                skid <= {
                        i_pc_plus_8_ff,
                        i_pc_ff,
                        i_switch_ff,
                        i_taken_ff,
                        i_decompile,
                        i_uop_last,
                        i_condition_code_ff,
                        i_destination_index_ff,
                        i_alu_source_ff,
                        i_alu_operation_ff,
                        i_shift_source_ff,
                        i_shift_operation_ff,
                        i_shift_length_ff,
                        i_flag_update_ff,
                        i_mem_srcdest_index_ff,
                        i_mem_load_ff,
                        i_mem_store_ff,
                        i_mem_pre_index_ff,
                        i_mem_unsigned_byte_enable_ff,
                        i_mem_signed_byte_enable_ff,
                        i_mem_signed_halfword_enable_ff,
                        i_mem_unsigned_halfword_enable_ff,
                        i_mem_translate_ff,
                        i_irq_ff,
                        i_fiq_ff,
                        i_abt_ff,
                        i_swi_ff,
                        i_force32align_ff,
                        i_und_ff,
                        i_ppc_ff
                };
        end
end

// Get values from the feedback network.
assign  o_alu_source_value_nxt  =
        get_forward_value (    {(stall_late_ff ? skid_late_immediate_ff[0] : i_alu_source_ff[32]),
                                skid_alu_source_ff[31:6], late_reg_index[23:18]},
                                i_shifter_destination_index_ff[5:0],
                                i_alu_dav_nxt,
                                i_alu_destination_value_nxt,
                                i_alu_destination_value_ff,
                                i_alu_destination_index_ff[5:0],
                                i_alu_dav_ff,

                                i_postalu0_destination_index_ff[5:0],
                                i_postalu0_destination_value_ff,
                                i_postalu0_dav_ff,

                                i_postalu1_destination_index_ff[5:0],
                                i_postalu1_destination_value_ff,
                                i_postalu1_dav_ff,

                                i_postalu_destination_index_ff[5:0],
                                i_postalu_destination_value_ff,
                                i_postalu_dav_ff,

                                i_memory_destination_index_ff[5:0],
                                i_memory_destination_value_ff,
                                i_memory_dav_ff,
                                i_memory_mem_srcdest_index_ff[5:0],
                                i_memory_mem_load_ff,
                                i_memory_mem_rd_data,
                                i_cpu_mode,
                                skid_pc_plus_8_ff,
                                skid_force32align_ff
        );


assign  o_shift_source_value_nxt=
        get_forward_value (    {(stall_late_ff ? skid_late_immediate_ff[1] : i_shift_source_ff[32]),
                                skid_shift_source_ff[31:6], late_reg_index[17:12]},
                                i_shifter_destination_index_ff[5:0],
                                i_alu_dav_nxt,
                                i_alu_destination_value_nxt,
                                i_alu_destination_value_ff,
                                i_alu_destination_index_ff[5:0],
                                i_alu_dav_ff,

                                i_postalu0_destination_index_ff[5:0],
                                i_postalu0_destination_value_ff,
                                i_postalu0_dav_ff,

                                i_postalu1_destination_index_ff[5:0],
                                i_postalu1_destination_value_ff,
                                i_postalu1_dav_ff,

                                i_postalu_destination_index_ff[5:0],
                                i_postalu_destination_value_ff,
                                i_postalu_dav_ff,

                                i_memory_destination_index_ff[5:0],
                                i_memory_destination_value_ff,
                                i_memory_dav_ff,
                                i_memory_mem_srcdest_index_ff[5:0],
                                i_memory_mem_load_ff,
                                i_memory_mem_rd_data,
                                i_cpu_mode,
                                skid_pc_plus_8_ff,
                                1'd0
        );

assign  o_shift_length_value_nxt=
        get_forward_value (    {(stall_late_ff ? skid_late_immediate_ff[2] : i_shift_length_ff[32]),
                                skid_shift_length_ff[31:6], late_reg_index[11:6]},
                                i_shifter_destination_index_ff[5:0],
                                i_alu_dav_nxt,
                                i_alu_destination_value_nxt,
                                i_alu_destination_value_ff,
                                i_alu_destination_index_ff[5:0],
                                i_alu_dav_ff,

                                i_postalu0_destination_index_ff[5:0],
                                i_postalu0_destination_value_ff,
                                i_postalu0_dav_ff,

                                i_postalu1_destination_index_ff[5:0],
                                i_postalu1_destination_value_ff,
                                i_postalu1_dav_ff,

                                i_postalu_destination_index_ff[5:0],
                                i_postalu_destination_value_ff,
                                i_postalu_dav_ff,

                                i_memory_destination_index_ff[5:0],
                                i_memory_destination_value_ff,
                                i_memory_dav_ff,
                                i_memory_mem_srcdest_index_ff[5:0],
                                i_memory_mem_load_ff,
                                i_memory_mem_rd_data,
                                i_cpu_mode,
                                skid_pc_plus_8_ff,
                                1'd0
        );

// Value of a register index, never an immediate.
assign  o_mem_srcdest_value_nxt =
        get_forward_value (    {27'd0, late_reg_index[5:0]},

                                i_shifter_destination_index_ff[5:0],
                                i_alu_dav_nxt,
                                i_alu_destination_value_nxt,
                                i_alu_destination_value_ff,
                                i_alu_destination_index_ff[5:0],
                                i_alu_dav_ff,

                                i_postalu0_destination_index_ff[5:0],
                                i_postalu0_destination_value_ff,
                                i_postalu0_dav_ff,

                                i_postalu1_destination_index_ff[5:0],
                                i_postalu1_destination_value_ff,
                                i_postalu1_dav_ff,

                                i_postalu_destination_index_ff[5:0],
                                i_postalu_destination_value_ff,
                                i_postalu_dav_ff,

                                i_memory_destination_index_ff[5:0],
                                i_memory_destination_value_ff,
                                i_memory_dav_ff,
                                i_memory_mem_srcdest_index_ff[5:0],
                                i_memory_mem_load_ff,
                                i_memory_mem_rd_data,
                                i_cpu_mode,
                                skid_pc_plus_8_ff,
                                1'd0
        );

// Apply index to register file.
assign o_rd_index_0 = stall_idx_ff ? skid_idx[23:18] : i_alu_source_ff[5:0];
assign o_rd_index_1 = stall_idx_ff ? skid_idx[17:12] : i_shift_source_ff[5:0];
assign o_rd_index_2 = stall_idx_ff ? skid_idx[11:6]  : i_shift_length_ff[5:0];
assign o_rd_index_3 = stall_idx_ff ? skid_idx[5:0]   : i_mem_srcdest_index_ff[5:0];

always_comb
begin
        if ( o_stall_from_issue )
        begin
                {skid_pc_plus_8_ff,
                 skid_pc_ff,
                 skid_switch_ff,
                 skid_taken_ff,
                 skid_decompile,
                 skid_uop_last,
                 skid_condition_code_ff,
                 skid_destination_index_ff,
                 skid_alu_source_ff,
                 skid_alu_operation_ff,
                 skid_shift_source_ff,
                 skid_shift_operation_ff,
                 skid_shift_length_ff,
                 skid_flag_update_ff,
                 skid_mem_srcdest_index_ff,
                 skid_mem_load_ff,
                 skid_mem_store_ff,
                 skid_mem_pre_index_ff,
                 skid_mem_unsigned_byte_enable_ff,
                 skid_mem_signed_byte_enable_ff,
                 skid_mem_signed_halfword_enable_ff,
                 skid_mem_unsigned_halfword_enable_ff,
                 skid_mem_translate_ff,
                 skid_irq_ff,
                 skid_fiq_ff,
                 skid_abt_ff,
                 skid_swi_ff,
                 skid_force32align_ff,
                 skid_und_ff,
                 skid_ppc_ff} = skid;
        end
        else
        begin
                {skid_pc_plus_8_ff,
                 skid_pc_ff,
                 skid_switch_ff,
                 skid_taken_ff,
                 skid_decompile,
                 skid_uop_last,
                 skid_condition_code_ff,
                 skid_destination_index_ff,
                 skid_alu_source_ff,
                 skid_alu_operation_ff,
                 skid_shift_source_ff,
                 skid_shift_operation_ff,
                 skid_shift_length_ff,
                 skid_flag_update_ff,
                 skid_mem_srcdest_index_ff,
                 skid_mem_load_ff,
                 skid_mem_store_ff,
                 skid_mem_pre_index_ff,
                 skid_mem_unsigned_byte_enable_ff,
                 skid_mem_signed_byte_enable_ff,
                 skid_mem_signed_halfword_enable_ff,
                 skid_mem_unsigned_halfword_enable_ff,
                 skid_mem_translate_ff,
                 skid_irq_ff,
                 skid_fiq_ff,
                 skid_abt_ff,
                 skid_swi_ff,
                 skid_force32align_ff,
                 skid_und_ff,
                 skid_ppc_ff} =
                {i_pc_plus_8_ff,
                 i_pc_ff,
                 i_switch_ff,
                 i_taken_ff,
                 i_decompile,
                 i_uop_last,
                 i_condition_code_ff,
                 i_destination_index_ff,
                 i_alu_source_ff,
                 i_alu_operation_ff,
                 i_shift_source_ff,
                 i_shift_operation_ff,
                 i_shift_length_ff,
                 i_flag_update_ff,
                 i_mem_srcdest_index_ff,
                 i_mem_load_ff,
                 i_mem_store_ff,
                 i_mem_pre_index_ff,
                 i_mem_unsigned_byte_enable_ff,
                 i_mem_signed_byte_enable_ff,
                 i_mem_signed_halfword_enable_ff,
                 i_mem_unsigned_halfword_enable_ff,
                 i_mem_translate_ff,
                 i_irq_ff,
                 i_fiq_ff,
                 i_abt_ff,
                 i_swi_ff,
                 i_force32align_ff,
                 i_und_ff,
                 i_ppc_ff};
        end
end

logic skid_is_lsl_0;
logic skid_is_rori;
logic w_shift_lock;
logic skid_is_mult;

assign skid_is_lsl_0 = stall_late_ff ? skid_lsl0_ff : i_shift_is_lsl0_ff;

assign   skid_is_rori          = skid_shift_operation_ff == RORI;

// Constant RORI #0 were converted to Constant LSL #0 in decode.
assign o_shifter_disable_nxt = skid_is_lsl_0 | skid_is_mult;

assign w_shift_lock =
   shifter_lock_check ( skid_shift_source_ff,
                        o_destination_index_ff, o_condition_code_ff )
|| shifter_lock_check ( skid_shift_length_ff,
                        o_destination_index_ff, o_condition_code_ff )
|| shifter_lock_check ( {skid_alu_source_ff[32:6], late_reg_index[23:18]},
                        o_destination_index_ff, o_condition_code_ff )
|| shifter_lock_check ( {27'd0, skid_mem_srcdest_index_ff},
                        o_destination_index_ff, o_condition_code_ff );


assign skid_is_mult = skid_alu_operation_ff == {1'd0, UMLALL}     ||
                      skid_alu_operation_ff == {1'd0, UMLALH}     ||
                      skid_alu_operation_ff == {1'd0, SMLALL}     ||
                      skid_alu_operation_ff == {1'd0, SMLALH}     ||
                      skid_alu_operation_ff == SMULW0             ||
                      skid_alu_operation_ff == SMULW1             ||
                      skid_alu_operation_ff == SMUL00             ||
                      skid_alu_operation_ff == SMUL01             ||
                      skid_alu_operation_ff == SMUL10             ||
                      skid_alu_operation_ff == SMUL11             ||
                      skid_alu_operation_ff == SMLA00             ||
                      skid_alu_operation_ff == SMLA01             ||
                      skid_alu_operation_ff == SMLA10             ||
                      skid_alu_operation_ff == SMLA11             ||
                      skid_alu_operation_ff == SMLAW0             ||
                      skid_alu_operation_ff == SMLAW1             ||
                      skid_alu_operation_ff == SMLAL00L           ||
                      skid_alu_operation_ff == SMLAL01L           ||
                      skid_alu_operation_ff == SMLAL10L           ||
                      skid_alu_operation_ff == SMLAL11L           ||
                      skid_alu_operation_ff == SMLAL00H           ||
                      skid_alu_operation_ff == SMLAL01H           ||
                      skid_alu_operation_ff == SMLAL10H           ||
                      skid_alu_operation_ff == SMLAL11H;

//
// Look for reads from registers to be loaded from memory. Four
// register sources may cause a load lock.
//
assign operand_load_lock[0] = determine_load_lock
                        ( {skid_alu_source_ff[32:6], late_reg_index[23:18]},
                        slot_locked[0],
                        o_mem_srcdest_index_ff,
                        o_condition_code_ff,
                        o_mem_load_ff,
                        i_shifter_mem_srcdest_index_ff,
                        i_shifter_dav_ff,
                        i_shifter_mem_load_ff,
                        i_alu_mem_srcdest_index_ff,
                        i_alu_dav_ff,
                        i_alu_mem_load_ff,
                        i_postalu0_mem_srcdest_index_ff,
                        i_postalu0_mem_load_ff,
                        i_postalu0_dav_ff,
                        i_postalu1_mem_srcdest_index_ff,
                        i_postalu1_mem_load_ff,
                        i_postalu1_dav_ff,
                        i_postalu_mem_srcdest_index_ff,
                        i_postalu_mem_load_ff,
                        i_postalu_dav_ff,
                        i_memory_mem_srcdest_index_ff,
                        i_memory_mem_load_ff,
                        i_memory_dav_ff,
                        i_dc_lock,
                        i_irq_ff || i_fiq_ff || i_abt_ff || i_swi_ff || i_abt_ff
                        );
assign operand_load_lock[1] = determine_load_lock
                        (
                        {skid_shift_source_ff[32:6], late_reg_index[17:12]},
                        slot_locked[1],
                        o_mem_srcdest_index_ff,
                        o_condition_code_ff,
                        o_mem_load_ff,
                        i_shifter_mem_srcdest_index_ff,
                        i_shifter_dav_ff,
                        i_shifter_mem_load_ff,
                        i_alu_mem_srcdest_index_ff,
                        i_alu_dav_ff,
                        i_alu_mem_load_ff,
                        i_postalu0_mem_srcdest_index_ff,
                        i_postalu0_mem_load_ff,
                        i_postalu0_dav_ff,
                        i_postalu1_mem_srcdest_index_ff,
                        i_postalu1_mem_load_ff,
                        i_postalu1_dav_ff,
                        i_postalu_mem_srcdest_index_ff,
                        i_postalu_mem_load_ff,
                        i_postalu_dav_ff,
                        i_memory_mem_srcdest_index_ff,
                        i_memory_mem_load_ff,
                        i_memory_dav_ff,
                        i_dc_lock,
                        i_irq_ff || i_fiq_ff || i_abt_ff || i_swi_ff || i_abt_ff
                        );
assign operand_load_lock[2] = determine_load_lock
                        ( {skid_shift_length_ff[32:6], late_reg_index[11:6]},
                        slot_locked[2],
                        o_mem_srcdest_index_ff,
                        o_condition_code_ff,
                        o_mem_load_ff,
                        i_shifter_mem_srcdest_index_ff,
                        i_shifter_dav_ff,
                        i_shifter_mem_load_ff,
                        i_alu_mem_srcdest_index_ff,
                        i_alu_dav_ff,
                        i_alu_mem_load_ff,
                        i_postalu0_mem_srcdest_index_ff,
                        i_postalu0_mem_load_ff,
                        i_postalu0_dav_ff,
                        i_postalu1_mem_srcdest_index_ff,
                        i_postalu1_mem_load_ff,
                        i_postalu1_dav_ff,
                        i_postalu_mem_srcdest_index_ff,
                        i_postalu_mem_load_ff,
                        i_postalu_dav_ff,
                        i_memory_mem_srcdest_index_ff,
                        i_memory_mem_load_ff,
                        i_memory_dav_ff,
                        i_dc_lock,
                        i_irq_ff || i_fiq_ff || i_abt_ff || i_swi_ff || i_abt_ff
                        );
assign operand_load_lock[3] = determine_load_lock
                        ( {27'd0, late_reg_index[5:0]},
                        slot_locked[3],
                        o_mem_srcdest_index_ff,
                        o_condition_code_ff,
                        o_mem_load_ff,
                        i_shifter_mem_srcdest_index_ff,
                        i_shifter_dav_ff,
                        i_shifter_mem_load_ff,
                        i_alu_mem_srcdest_index_ff,
                        i_alu_dav_ff,
                        i_alu_mem_load_ff,
                        i_postalu0_mem_srcdest_index_ff,
                        i_postalu0_mem_load_ff,
                        i_postalu0_dav_ff,
                        i_postalu1_mem_srcdest_index_ff,
                        i_postalu1_mem_load_ff,
                        i_postalu1_dav_ff,
                        i_postalu_mem_srcdest_index_ff,
                        i_postalu_mem_load_ff,
                        i_postalu_dav_ff,
                        i_memory_mem_srcdest_index_ff,
                        i_memory_mem_load_ff,
                        i_memory_dav_ff,
                        i_dc_lock,
                        i_irq_ff || i_fiq_ff || i_abt_ff || i_swi_ff || i_abt_ff
                        );
//
// ARM925T: nor an instruction that writes a register that an
// older load still in the pipeline will write. The load may
// miss the D-cache, which then writes the register in the
// background after this instruction (upstream only checked
// the lock, which is set once the load has reached the cache).
//
assign destination_load_lock = determine_load_lock
                        ( {27'd0, skid_destination_index_ff},
                        slot_locked[4],
                        o_mem_srcdest_index_ff,
                        o_condition_code_ff,
                        o_mem_load_ff,
                        i_shifter_mem_srcdest_index_ff,
                        i_shifter_dav_ff,
                        i_shifter_mem_load_ff,
                        i_alu_mem_srcdest_index_ff,
                        i_alu_dav_ff,
                        i_alu_mem_load_ff,
                        i_postalu0_mem_srcdest_index_ff,
                        i_postalu0_mem_load_ff,
                        i_postalu0_dav_ff,
                        i_postalu1_mem_srcdest_index_ff,
                        i_postalu1_mem_load_ff,
                        i_postalu1_dav_ff,
                        i_postalu_mem_srcdest_index_ff,
                        i_postalu_mem_load_ff,
                        i_postalu_dav_ff,
                        i_memory_mem_srcdest_index_ff,
                        i_memory_mem_load_ff,
                        i_memory_dav_ff,
                        i_dc_lock,
                        i_irq_ff || i_fiq_ff || i_abt_ff || i_swi_ff || i_abt_ff
                        )
                        ||
                        //
                        // If a register is locked by load, don't issue an instruction that
                        // writes to that register. Assert load lock. Else, background
                        // load will overwrite the latest value.
                        //
                        (
                          skid_destination_index_ff[5:0] != PHY_RAZ_REGISTER[5:0]
                          &&
                          slot_locked[4]
                        );

// ARM925T: only condition-resolved loads near memory can be deferred.
// Early users need the value in shifter; plain rn/rm need it in ALU.
// Keep all earlier-load, WAW, special-register and multiply interlocks.
assign late_reg_index = stall_late_ff ? skid_idx :
        {i_alu_source_ff[5:0], i_shift_source_ff[5:0],
         i_shift_length_ff[5:0], i_mem_srcdest_index_ff[5:0]};
// ARM925T: compare both live and saved tags before selecting the slot.
// The stall copy now selects four results instead of preceding all of the
// stage-tag comparisons in its own feedback/interlock path.
(* keep *) wire [3:0] late_live, late_saved;
wire late_instruction_ok = !skid_is_mult && !skid_force32align_ff &&
        !(skid_irq_ff || skid_fiq_ff || skid_abt_ff || skid_swi_ff || skid_und_ff);
assign late_live[0] = !i_alu_source_ff[32] && late_load(i_alu_source_ff[5:0], 1'b0, live_locked[0]);
assign late_live[1] = !i_shift_source_ff[32] && late_load(i_shift_source_ff[5:0], !i_shift_is_lsl0_ff, live_locked[1]);
assign late_live[2] = !i_shift_length_ff[32] && late_load(i_shift_length_ff[5:0], 1'b1, live_locked[2]);
assign late_live[3] = i_mem_store_ff && late_load(i_mem_srcdest_index_ff, 1'b1, live_locked[3]);
assign late_saved[0] = !skid_late_immediate_ff[0] && late_load(skid_idx[23:18], 1'b0, skid_locked[0]);
assign late_saved[1] = !skid_late_immediate_ff[1] && late_load(skid_idx[17:12], !skid_lsl0_ff, skid_locked[1]);
assign late_saved[2] = !skid_late_immediate_ff[2] && late_load(skid_idx[11:6], 1'b1, skid_locked[2]);
assign late_saved[3] = skid_late_store_ff && late_load(skid_idx[5:0], 1'b1, skid_locked[3]);
assign late_pending = (stall_late_ff ? late_saved : late_live) & {4{late_instruction_ok}};
assign load_lock = |(operand_load_lock & ~late_pending) || destination_load_lock;

function automatic late_load(input [5:0] r, input early, input reg_locked);
        logic candidate, conflict;
        candidate = (i_postalu_dav_ff && i_postalu_mem_load_ff &&
                     i_postalu_mem_srcdest_index_ff == r) ||
                    (!early && i_postalu1_dav_ff && i_postalu1_mem_load_ff &&
                     i_postalu1_mem_srcdest_index_ff == r);
        // Conservatively reject any ALU writer, including base writeback.
        // The existing load WAW lock prevents a younger load/ALU writer
        // passing the deferred producer; do not change that ordering rule.
        conflict = (o_condition_code_ff != NV && o_destination_index_ff == r) ||
                   (i_shifter_dav_ff && i_shifter_destination_index_ff == r) ||
                   (i_alu_dav_ff && i_alu_destination_index_ff == r) ||
                   (i_postalu0_dav_ff && i_postalu0_destination_index_ff == r) ||
                   (i_postalu1_dav_ff && i_postalu1_destination_index_ff == r) ||
                   (i_postalu_dav_ff && i_postalu_destination_index_ff == r) ||
                   (o_condition_code_ff != NV && o_mem_load_ff && o_mem_srcdest_index_ff == r) ||
                   (i_shifter_dav_ff && i_shifter_mem_load_ff && i_shifter_mem_srcdest_index_ff == r) ||
                   (i_alu_dav_ff && i_alu_mem_load_ff && i_alu_mem_srcdest_index_ff == r) ||
                   (i_postalu0_dav_ff && i_postalu0_mem_load_ff && i_postalu0_mem_srcdest_index_ff == r) ||
                   (early && i_postalu1_dav_ff && i_postalu1_mem_load_ff && i_postalu1_mem_srcdest_index_ff == r);
        late_load = candidate && !conflict &&
                    r != PHY_PC && r != PHY_RAZ_REGISTER && r != PHY_CPSR &&
                    r < PHY_DUMMY_REG0 && !reg_locked;
endfunction

//
// A shift lock occurs if the current instruction requires a shift
// amount as a register other than LSL #0 or RORI if the operands are
// right on the output of this stage because in that case we do not
// have the register value and thus a shift lock.
//
// Another case is when the output of this stage has a flag update, a
// shift operation that is not LSL#0 or RORI cannot be issued since flags are
// not actually available in the next cycle. They are only available in the
// next-2-next cycle.
//
assign shift_lock =
  (((skid_is_mult |   ((~skid_is_lsl_0) & (~skid_is_rori)))) & w_shift_lock)
| (o_flag_update_ff & ((~skid_is_lsl_0) & (~skid_is_rori)));

////////////////////////////////////
// Functions
////////////////////////////////////

// ---------------------------------------------
// Shifter lock check.
// ---------------------------------------------

function automatic shifter_lock_check (
        input [32:0]                 index,
        input [$clog2(PHY_REGS)-1:0] destination_index_ff,
        input [3:0]                  condition_code_ff
);

        logic unused;
        unused = |index[31:6];

        // Simply check if the operand index is on the output of this unit
        // and that the output is valid.
        // If immediate, no lock obviously.

        if ( index[32] == IMMED_EN || index[5:0] == PHY_RAZ_REGISTER )
        begin
                shifter_lock_check = 1'd0;
        end
        else if ( destination_index_ff == index[5:0] && condition_code_ff != NV )
        begin
                shifter_lock_check = 1'd1;
        end
        else
        begin
                shifter_lock_check = 1'd0;
        end

endfunction : shifter_lock_check

// -----------------------------------------------
// Load lock. Activated when a read from a register
// follows a load to that register.
// -----------------------------------------------

function automatic determine_load_lock (
input [32:0]                    index,
input                           reg_locked,
input [$clog2(PHY_REGS)-1:0]    mem_srcdest_index_ff,
input [3:0]                     condition_code_ff,
input                           mem_load_ff,
input  [$clog2(PHY_REGS)-1:0]   shifter_mem_srcdest_index_ff,
input                           alu_dav_nxt,
input                           shifter_mem_load_ff,
input  [$clog2(PHY_REGS)-1:0]   alu_mem_srcdest_index_ff,
input                           alu_dav_ff,
input                           alu_mem_load_ff,
input  [$clog2(PHY_REGS)-1:0]   postalu0_mem_srcdest_index_ff,
input                           postalu0_mem_load_ff,
input                           postalu0_dav_ff,
input  [$clog2(PHY_REGS)-1:0]   postalu1_mem_srcdest_index_ff,
input                           postalu1_mem_load_ff,
input                           postalu1_dav_ff,
input  [$clog2(PHY_REGS)-1:0]   postalu_mem_srcdest_index_ff,
input                           postalu_mem_load_ff,
input                           postalu_dav_ff,
input  [$clog2(PHY_REGS)-1:0]   memory_mem_srcdest_index_ff,
input                           memory_mem_load_ff,
input                           memory_dav_ff,
input  [63:0]                   xlock,
input                           ext_lock
);
        logic unused;

        //
        // Look for that load instruction in the required pipeline stages.
        // If found, we cannot issue the current instruction since old value
        // will be read.
        //

        if ( index[32] == IMMED_EN || index[5:0] == PHY_RAZ_REGISTER[5:0] )
        // Lock only occurs for indices.
        begin
                determine_load_lock = 1'd0;
        end
        else if ( reg_locked || ((|xlock) && ext_lock) )
        begin
                determine_load_lock = 1'd1;
        end
        else if
        (
                ( index[5:0] == mem_srcdest_index_ff          &&
                  condition_code_ff != NV                     &&
                  mem_load_ff )                               || // ISSUE
                ( index[5:0] == shifter_mem_srcdest_index_ff  &&
                   alu_dav_nxt                                &&
                   shifter_mem_load_ff )                      || // SHIFT
                (  index[5:0] == alu_mem_srcdest_index_ff     &&
                   alu_dav_ff                                 &&
                   alu_mem_load_ff )                          || // ALU
                (  index[5:0] == postalu0_mem_srcdest_index_ff&&
                   postalu0_dav_ff                            &&
                   postalu0_mem_load_ff )                     || // Post ALU0
                (  index[5:0] == postalu1_mem_srcdest_index_ff&&
                   postalu1_dav_ff                            &&
                   postalu1_mem_load_ff )                     || // Post ALU1
                (  index[5:0] == postalu_mem_srcdest_index_ff &&
                   postalu_dav_ff                             &&
                   postalu_mem_load_ff )                         // Post ALU
                // ARM925T: no lock on the memory stage's load: its value is
                // forwarded by get_forward_value, and a load that missed has
                // its register locked (xlock) by the time it is there.
        )
        begin
                determine_load_lock = 1'd1;
        end
        else
        begin
                determine_load_lock = 1'd0;
        end

        unused = |{index[31:6], memory_mem_srcdest_index_ff, memory_mem_load_ff, memory_dav_ff};

endfunction : determine_load_lock

// ----------------------------------------------------------------------------

//
// Forwarding result: bit 32 selects the separately captured register-file
// bank; bits 31:0 contain the newest matching pipeline value or special value.
//
function automatic [32:0] get_forward_value (

        // The register index to search for. This might be a constant too.
        input [32:0]                    index,

        // Destination on the output of the shifter stage.
        input [$clog2(PHY_REGS)-1:0]    shifter_destination_index_ff,

        // ALU output is valid.
        input                           alu_dav_nxt,

        // ALU output.
        input [31:0]                    alu_destination_value_nxt,

        // ALU flopped result.
        input [31:0]                    alu_destination_value_ff,

        // ALU flopped destination index.
        input [$clog2(PHY_REGS)-1:0]    alu_destination_index_ff,

        // Valid flopped (EX stage).
        input                           alu_dav_ff,

        input  [$clog2(PHY_REGS)-1:0]   postalu0_destination_index_ff,
        input  [31:0]                   postalu0_destination_value_ff,
        input                           postalu0_dav_ff,

        input  [$clog2(PHY_REGS)-1:0]   postalu1_destination_index_ff,
        input  [31:0]                   postalu1_destination_value_ff,
        input                           postalu1_dav_ff,

        input  [$clog2(PHY_REGS)-1:0]   postalu_destination_index_ff,
        input  [31:0]                   postalu_destination_value_ff,
        input                           postalu_dav_ff,

        // Memory stage destination index (pointer)
        input [$clog2(PHY_REGS)-1:0]    memory_destination_index_ff,
        input [31:0]                    memory_destination_value_ff,
        input                           memory_dav_ff,

        // ARM925T: the memory stage's loaded register and value (upstream
        // held the dependent instruction in issue for this clock instead)
        input [$clog2(PHY_REGS)-1:0]    memory_mem_srcdest_index_ff,
        input                           memory_mem_load_ff,
        input [31:0]                    memory_mem_rd_data,

        // CPU mode and PC.
        input [31:0]                    cpu_mode,
        input [31:0]                    pc_plus_8_ff,

        // PC access control.
        input                           force32_align_ff
);

        logic [31:0] get;
        logic [11:0] match;
        logic [11:0] pick;
        logic [31:0] value [0:10];

        // ARM925T: encode priority on single-bit selects; the 32-bit data
        // sees only parallel masks and an OR tree. Match order is unchanged,
        // including immediates/special registers and the memory load before
        // that instruction's base writeback.
        match[0] = index[32];
        match[1] = index[5:0] == PHY_RAZ_REGISTER[5:0];
        match[2] = index[5:0] == {2'd0, ARCH_PC[3:0]};
        match[3] = index[5:0] == PHY_CPSR[5:0];
        match[4] = index[5:0] == shifter_destination_index_ff && alu_dav_nxt;
        match[5] = index[5:0] == alu_destination_index_ff && alu_dav_ff;
        match[6] = index[5:0] == postalu0_destination_index_ff && postalu0_dav_ff;
        match[7] = index[5:0] == postalu1_destination_index_ff && postalu1_dav_ff;
        match[8] = index[5:0] == postalu_destination_index_ff && postalu_dav_ff;
        match[9] = index[5:0] == memory_mem_srcdest_index_ff && memory_dav_ff && memory_mem_load_ff;
        match[10] = index[5:0] == memory_destination_index_ff && memory_dav_ff;
        match[11] = 1'b1;
        value[0] = index[31:0];
        value[1] = 32'b0;
        value[2] = pc_plus_8_ff;
        value[3] = cpu_mode;
        value[4] = alu_destination_value_nxt;
        value[5] = alu_destination_value_ff;
        value[6] = postalu0_destination_value_ff;
        value[7] = postalu1_destination_value_ff;
        value[8] = postalu_destination_value_ff;
        value[9] = memory_mem_rd_data;
        value[10] = memory_destination_value_ff;
        get = 32'b0;
        for (int k = 0; k < 12; k++) begin
                pick[k] = match[k] && !(|(match & ((12'b1 << k) - 12'b1)));
        end
        for (int k = 0; k < 11; k++)
                get |= value[k] & {32{pick[k]}};

        // If it's not a store or load, then align this to 4 bytes. Use
        // *skid* versions.
        //
        // ARM925T: a Thumb PC-relative load (force32 with PC as the base) gets
        // its PC aligned here too, so its address is aligned from the start
        // and the alignment check in zap_core sees no fault.
        //
        get_forward_value[32] = pick[11]; // Read the separately captured RF bank.
        get_forward_value[31:0] = force32_align_ff &&
                             ((!skid_mem_load_ff && !skid_mem_store_ff) ||
                              (!index[32] && index[5:0] == {2'd0, ARCH_PC[3:0]})) ?
                             (get & 32'hffff_fffc) : get;

endfunction : get_forward_value

endmodule : zap_issue_main

// ----------------------------------------------------------------------------
// END OF FILE
// ----------------------------------------------------------------------------
