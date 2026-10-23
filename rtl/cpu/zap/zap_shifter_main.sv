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
//  The ZAP shift unit. Apart from shift, it does value restoration and
//  multiplication. Value restoration is needed since the ALU (Shift+Op)
//  is pipelined and we want back to back instructions to execute correctly
//  without losing throughput. Note that there are 3 execution pathways
//  in this unit but a given time, only one pathway may be active. The 3
//  execution pathways are: shifter, multiplier, value feedback network.
//

module zap_shifter_main
#(
        parameter logic [31:0] PHY_REGS  = 32'd46,
        parameter logic [31:0] ALU_OPS   = 32'd32,
        parameter logic [31:0] SHIFT_OPS = 32'd5
)
(
        // For debug
        input   logic    [64*8-1:0]              i_decompile,
        output  logic    [64*8-1:0]              o_decompile,

        input   logic                            i_uop_last,
        output  logic                            o_uop_last,

        // Clock and reset.
        input logic                               i_clk,
        input logic                               i_reset,

        // PC
        input logic  [31:0]                       i_pc_ff,
        output logic [31:0]                       o_pc_ff,

        // Taken.
        input logic    [1:0]                       i_taken_ff,
        output logic   [1:0]                       o_taken_ff,

        // Predicted PC
        input logic [3:0] i_flags_ff,
        input logic i_thumb_ff,
        (* dont_retime *) output logic o_early_redirect_ff,
        (* dont_retime *) output logic [31:0] o_early_target_ff,
        input logic [33:0] i_link_branch_ff,
        input logic     [31:0]                     i_ppc_ff,
        (* dont_retime *) output logic [33:0] o_link_branch_ff,
        output logic    [31:0]                     o_ppc_ff,

        // Stall and clear. Hi to low priority.
        input logic                               i_clear_from_writeback, // | High Priority.
        input logic                               i_data_stall,           // |
        input logic                               i_clear_from_alu,       // V Low Priority.

        // ARM925T: late load completion and ALU backpressure.
        input logic [3:0] i_load_pending_ff,
        input logic [5:0] i_shift_length_index_ff,
        input logic i_memory_load_valid,
        input logic [5:0] i_memory_load_index,
        input logic [31:0] i_memory_load_value,
        input logic i_shift_source_pending_ff,
        input logic i_shift_length_pending_ff,
        input logic [5:0] i_dc_reg_idx_bin,
        input logic i_dc_reg_valid,
        input logic [31:0] i_dc_reg_dat,
        input logic i_stall_from_alu,
        input logic [1:0] i_alu_late_ready,
        input logic [63:0] i_alu_late_value,
        output logic [3:0] o_late_ready,
        output logic [127:0] o_late_value,
        output logic [1:0] o_load_pending_ff,
        output logic [11:0] o_load_index_ff,

        // Next CPSR and FF CPSR.
        input logic                              i_cpsr_nxt_29,
        input logic                              i_cpsr_ff_29,

        //
        // Things from Issue. Please see issue stage for signal details.
        //

        input logic       [3:0]                   i_condition_code_ff,
        input logic       [$clog2(PHY_REGS )-1:0] i_destination_index_ff,
        input logic       [$clog2(ALU_OPS)-1:0]   i_alu_operation_ff,
        input logic       [$clog2(SHIFT_OPS)-1:0] i_shift_operation_ff,
        input logic                               i_flag_update_ff,

        input logic     [$clog2(PHY_REGS )-1:0]   i_mem_srcdest_index_ff,
        input logic                               i_mem_load_ff,
        input logic                               i_mem_store_ff,
        input logic                               i_mem_pre_index_ff,
        input logic                               i_mem_unsigned_byte_enable_ff,
        input logic                               i_mem_signed_byte_enable_ff,
        input logic                               i_mem_signed_halfword_enable_ff,
        input logic                               i_mem_unsigned_halfword_enable_ff,
        input logic                               i_mem_translate_ff,

        input logic                               i_irq_ff,
        input logic                               i_fiq_ff,
        input logic                               i_abt_ff,
        input logic                               i_swi_ff,

        // Indices/immediates enter here.
        input logic      [32:0]                  i_alu_source_ff,
        input logic                              i_alu_dav_nxt,
        input logic      [32:0]                  i_shift_source_ff,

        // Values are obtained here.
        input logic      [31:0]                  i_alu_source_value_ff,
        input logic      [31:0]                  i_shift_source_value_ff,
        input logic      [31:0]                  i_shift_length_value_ff,
        input logic      [31:0]                  i_mem_srcdest_value_ff, // This too has to be resolved.
                                                // For stores.

        // The PC value.
        input logic     [31:0]                   i_pc_plus_8_ff,

        // Shifter disable indicator. In the next stage, the output
        // will bypass the shifter. Not actually bypass it but will
        // go to the ALU value corrector unit via a MUX.
        input logic                              i_disable_shifter_ff,

        // undefined instr.
        input logic                           i_und_ff,
        output logic                          o_und_ff,

        // Value from ALU for resolver.
        input logic   [31:0]                  i_alu_value_nxt,

        // Force 32.
        input logic                         i_force32align_ff,
        output logic                        o_force32align_ff,

        // mode32 <-> Compressed switch indicator.
        input logic                         i_switch_ff,
        output logic                        o_switch_ff,

        //
        // Outputs.
        //

        // Specific to this stage.
        output logic      [31:0]                  o_mem_srcdest_value_ff,
        // ARM925T: retain the operand-capture boundary through synthesis;
        // late completion must not be retimed into the shifter/ALU cone.
        (* dont_retime *) output logic [31:0]     o_alu_source_value_ff,
        (* dont_retime *) output logic [31:0]     o_shifted_source_value_ff,
        output logic                              o_shift_carry_ff,
        output logic                              o_shift_sat_ff,
        output logic                              o_nozero_ff,

        // Send all other outputs.

        // PC+8
        output logic      [31:0]                  o_pc_plus_8_ff,

        // Interrupts.
        output logic                              o_irq_ff,
        output logic                              o_fiq_ff,
        output logic                              o_abt_ff,
        output logic                              o_swi_ff,

        // Memory related outputs.
        output logic [$clog2(PHY_REGS )-1:0]      o_mem_srcdest_index_ff,
        output logic                              o_mem_load_ff,
        output logic                              o_mem_store_ff,
        output logic                              o_mem_pre_index_ff,
        output logic                              o_mem_unsigned_byte_enable_ff,
        output logic                              o_mem_signed_byte_enable_ff,
        output logic                              o_mem_signed_halfword_enable_ff,
        output logic                              o_mem_unsigned_halfword_enable_ff,
        output logic                              o_mem_translate_ff,

        // Other stuff.
        output logic       [3:0]                   o_condition_code_ff,
        output logic       [$clog2(PHY_REGS )-1:0] o_destination_index_ff,
        output logic       [$clog2(ALU_OPS)-1:0]   o_alu_operation_ff,
        output logic                               o_flag_update_ff,

        // Stall from shifter.
        output logic                               o_stall_from_shifter
);

///////////////////////////////////////////////////////////////////////////////

`include "zap_defines.svh"
`include "zap_localparams.svh"
`include "zap_functions.svh"

///////////////////////////////////////////////////////////////////////////////

logic nozero_nxt;
logic [31:0] shout;
logic shcarry, shsat;
logic [31:0] mem_srcdest_value;
logic [31:0] rm, rn;
logic shift_carry_nxt;
logic shift_sat_nxt;
logic mult_sat_nxt;
logic [31:0] mult_out;
logic shifter_enabled;
// ARM925T: resolve only direct branches with an already stable flags
// register. A flag writer immediately ahead falls back to normal ALU
// resolution. The branch itself still executes/retires in order in ALU.
wire early_condition = is_cc_satisfied(i_condition_code_ff, i_flags_ff);
wire early_flags_ready = o_condition_code_ff == NV ||
        (!o_flag_update_ff && o_alu_operation_ff != FMOV);
wire early_wrong = early_condition ?
        (!i_taken_ff[1] || i_ppc_ff != i_link_branch_ff[31:0]) : i_taken_ff[1];
wire early_branch = i_link_branch_ff[33] && early_flags_ready && early_wrong &&
        !(i_irq_ff || i_fiq_ff || i_abt_ff || i_swi_ff || i_und_ff) &&
        !o_stall_from_shifter;

logic multiply_busy, late_wait, is_multiply;
assign is_multiply = i_alu_operation_ff == {1'd0, UMLALL} ||
             i_alu_operation_ff == {1'd0, UMLALH} ||
             i_alu_operation_ff == {1'd0, SMLALL} ||
             i_alu_operation_ff == {1'd0, SMLALH} ||
             i_alu_operation_ff == SMULW0         ||
             i_alu_operation_ff == SMULW1         ||
             i_alu_operation_ff == SMUL00         ||
             i_alu_operation_ff == SMUL01         ||
             i_alu_operation_ff == SMUL10         ||
             i_alu_operation_ff == SMUL11         ||
             i_alu_operation_ff == SMLA00         ||
             i_alu_operation_ff == SMLA01         ||
             i_alu_operation_ff == SMLA10         ||
             i_alu_operation_ff == SMLA11         ||
             i_alu_operation_ff == SMLAW0         ||
             i_alu_operation_ff == SMLAW1         ||
             i_alu_operation_ff == SMLAL00L       ||
             i_alu_operation_ff == SMLAL01L       ||
             i_alu_operation_ff == SMLAL10L       ||
             i_alu_operation_ff == SMLAL11L       ||
             i_alu_operation_ff == SMLAL00H       ||
             i_alu_operation_ff == SMLAL01H       ||
             i_alu_operation_ff == SMLAL10H       ||
             i_alu_operation_ff == SMLAL11H;
logic [3:0] memory_match, background_match;
logic [23:0] load_index;
logic [127:0] original_value, pickup_value;
logic [31:0] shift_source;
assign load_index = {i_mem_srcdest_index_ff, i_shift_length_index_ff,
                     i_shift_source_ff[5:0], i_alu_source_ff[5:0]};
assign original_value = {i_mem_srcdest_value_ff, i_shift_length_value_ff,
                         i_shift_source_value_ff, i_alu_source_value_ff};
for (genvar k = 0; k < 4; k = k + 1) begin : g_load_pickup
        assign memory_match[k] = i_load_pending_ff[k] && i_memory_load_valid &&
                                 load_index[k*6 +: 6] == i_memory_load_index;
        assign background_match[k] = i_load_pending_ff[k] &&
                                     i_dc_reg_valid && load_index[k*6 +: 6] == i_dc_reg_idx_bin;
        assign o_late_ready[k] = memory_match[k] || background_match[k];
        assign pickup_value[k*32 +: 32] = background_match[k] ? i_dc_reg_dat :
                                         memory_match[k] ? i_memory_load_value :
                                         original_value[k*32 +: 32];
end
// ARM925T: execution selects only the registered memory snapshot, using
// registered pending bits (one mux), never the background/match mux tree.
// Background results must first be captured in issue's operand registers.
assign late_wait = (i_load_pending_ff[2] && !memory_match[2]) ||
                   (i_load_pending_ff[3] && !memory_match[3]) ||
                   (i_load_pending_ff[1] && shifter_enabled && !memory_match[1]);
assign o_stall_from_shifter = multiply_busy || late_wait || i_stall_from_alu;
assign shift_source = shifter_enabled ?
        (i_shift_source_pending_ff ? i_memory_load_value : i_shift_source_value_ff) :
        resolve_conflict(i_shift_source_ff, i_shift_source_value_ff,
                         o_destination_index_ff, i_alu_value_nxt, i_alu_dav_nxt, 1'b0);
// Multiply's two uops use raw accumulator operands throughout its FSM.
// They are deliberately excluded from late issue; do not refresh them.
assign o_late_value = is_multiply ? original_value :
        {i_load_pending_ff[3] ? pickup_value[96 +: 32] : mem_srcdest_value,
         pickup_value[64 +: 32],
         i_load_pending_ff[1] ? pickup_value[32 +: 32] : shift_source,
         i_load_pending_ff[0] ? pickup_value[0 +: 32] : rn};

///////////////////////////////////////////////////////////////////////////////

assign shifter_enabled = ~i_disable_shifter_ff;

///////////////////////////////////////////////////////////////////////////////

// The MAC unit.
zap_shifter_multiply
#(
        .PHY_REGS(PHY_REGS),
        .ALU_OPS(ALU_OPS)
)
u_zap_multiply
(
        .i_clk(i_clk),
        .i_reset(i_reset),

        .i_data_stall(i_data_stall || i_stall_from_alu),
        .i_clear_from_writeback(i_clear_from_writeback),
        .i_clear_from_alu(i_clear_from_alu),

        .i_alu_operation_ff(i_alu_operation_ff),

        .i_cc_satisfied (i_condition_code_ff == 4'd15 ? 1'd0 : 1'd1),

        .i_rm(i_alu_source_value_ff),
        .i_rn(i_shift_length_value_ff),
        .i_rs(i_shift_source_value_ff), // rm.rs + {rh,rn}
        .i_rh(i_mem_srcdest_value_ff),

        .o_rd(mult_out),
        .o_busy(multiply_busy),
        .o_sat(mult_sat_nxt),
        .o_nozero(nozero_nxt)
);

///////////////////////////////////////////////////////////////////////////////

always_ff @ (posedge i_clk)
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
                o_uop_last                        <= 0;

                o_destination_index_ff            <= 'x; //
                o_alu_operation_ff                <= 'x; //
                o_flag_update_ff                  <= 'x; //
                o_mem_srcdest_index_ff            <= 'x; //
                o_mem_load_ff                     <= 'x; //
                o_mem_store_ff                    <= 'x; //
                o_mem_pre_index_ff                <= 'x; //
                o_mem_unsigned_byte_enable_ff     <= 'x; //
                o_mem_signed_byte_enable_ff       <= 'x; //
                o_mem_signed_halfword_enable_ff   <= 'x; //
                o_mem_unsigned_halfword_enable_ff <= 'x; //
                o_mem_translate_ff                <= 'x; //
                o_pc_plus_8_ff                    <= 'x; //
                o_mem_srcdest_value_ff            <= 'x; //
                o_alu_source_value_ff             <= 'x; //
                o_shifted_source_value_ff         <= 'x; //
                o_shift_carry_ff                  <= 'x; //
                o_shift_sat_ff                    <= 'x; //
                o_switch_ff                       <= 'x; //
                o_force32align_ff                 <= 'x; //
                o_taken_ff                        <= 'x; //
                o_link_branch_ff <= 34'b0;
                o_early_redirect_ff <= 1'b0;
                o_ppc_ff                          <= 'x; //
                o_pc_ff                           <= 'x; //
                o_nozero_ff                       <= 'x; //
        end
        else if ( i_clear_from_writeback || ( i_clear_from_alu && !i_data_stall ) )
        begin
                o_load_pending_ff                 <= 0;
                o_condition_code_ff               <= NV;
                o_irq_ff                          <= 0;
                o_fiq_ff                          <= 0;
                o_abt_ff                          <= 0;
                o_swi_ff                          <= 0;
                o_und_ff                          <= 0;
                o_uop_last                        <= 0;

                o_destination_index_ff            <= 'x; //
                o_alu_operation_ff                <= 'x; //
                o_flag_update_ff                  <= 'x; //
                o_mem_srcdest_index_ff            <= 'x; //
                o_mem_load_ff                     <= 'x; //
                o_mem_store_ff                    <= 'x; //
                o_mem_pre_index_ff                <= 'x; //
                o_mem_unsigned_byte_enable_ff     <= 'x; //
                o_mem_signed_byte_enable_ff       <= 'x; //
                o_mem_signed_halfword_enable_ff   <= 'x; //
                o_mem_unsigned_halfword_enable_ff <= 'x; //
                o_mem_translate_ff                <= 'x; //
                o_pc_plus_8_ff                    <= 'x; //
                o_mem_srcdest_value_ff            <= 'x; //
                o_alu_source_value_ff             <= 'x; //
                o_shifted_source_value_ff         <= 'x; //
                o_shift_carry_ff                  <= 'x; //
                o_shift_sat_ff                    <= 'x; //
                o_switch_ff                       <= 'x; //
                o_force32align_ff                 <= 'x; //
                o_taken_ff                        <= 'x; //
                o_link_branch_ff <= 34'b0;
                o_early_redirect_ff <= 1'b0;
                o_ppc_ff                          <= 'x; //
                o_pc_ff                           <= 'x; //
                o_nozero_ff                       <= 'x; //
        end
        else if ( i_data_stall || i_stall_from_alu )
        begin
                // A completion is transient even while the pipeline is held.
                o_load_pending_ff <= o_load_pending_ff & ~i_alu_late_ready;
                if (i_alu_late_ready[0])
                        o_alu_source_value_ff <= i_alu_late_value[0 +: 32];
                if (i_alu_late_ready[1])
                        o_shifted_source_value_ff <= i_alu_late_value[32 +: 32];
        end
        else
        begin
           o_load_pending_ff <= o_stall_from_shifter ? 2'b0 :
                                (i_load_pending_ff[1:0] & ~o_late_ready[1:0]);
           o_load_index_ff <= load_index[11:0];
           o_condition_code_ff               <= o_stall_from_shifter ? NV : i_condition_code_ff;
           o_destination_index_ff            <= i_destination_index_ff;
           o_alu_operation_ff                <= (
                                                 i_alu_operation_ff == {1'd0, UMLALL} ||
                                                 i_alu_operation_ff == {1'd0, UMLALH} ||
                                                 i_alu_operation_ff == {1'd0, SMLALL} ||
                                                 i_alu_operation_ff == {1'd0, SMLALH}
                                                ) ? {2'd0, MOV} :
                                                (
                                                i_alu_operation_ff == SMULW0     ||
                                                i_alu_operation_ff == SMULW1     ||
                                                i_alu_operation_ff == SMUL00     ||
                                                i_alu_operation_ff == SMUL01     ||
                                                i_alu_operation_ff == SMUL10     ||
                                                i_alu_operation_ff == SMUL11     ||
                                                i_alu_operation_ff == SMLA00     ||
                                                i_alu_operation_ff == SMLA01     ||
                                                i_alu_operation_ff == SMLA10     ||
                                                i_alu_operation_ff == SMLA11     ||
                                                i_alu_operation_ff == SMLAW0     ||
                                                i_alu_operation_ff == SMLAW1     ||
                                                i_alu_operation_ff == SMLAL00L   ||
                                                i_alu_operation_ff == SMLAL01L   ||
                                                i_alu_operation_ff == SMLAL10L   ||
                                                i_alu_operation_ff == SMLAL11L   ||
                                                i_alu_operation_ff == SMLAL00H   ||
                                                i_alu_operation_ff == SMLAL01H   ||
                                                i_alu_operation_ff == SMLAL10H   ||
                                                i_alu_operation_ff == SMLAL11H
                                                ) ?
                                                 SAT_MOV :
                                                 i_alu_operation_ff;

           o_flag_update_ff                  <= i_flag_update_ff;
           o_mem_srcdest_index_ff            <= i_mem_srcdest_index_ff;
           o_mem_load_ff                     <= i_mem_load_ff;
           o_mem_store_ff                    <= i_mem_store_ff;
           o_mem_pre_index_ff                <= i_mem_pre_index_ff;
           o_mem_unsigned_byte_enable_ff     <= i_mem_unsigned_byte_enable_ff;
           o_mem_signed_byte_enable_ff       <= i_mem_signed_byte_enable_ff;
           o_mem_signed_halfword_enable_ff   <= i_mem_signed_halfword_enable_ff;
           o_mem_unsigned_halfword_enable_ff <= i_mem_unsigned_halfword_enable_ff;
           o_mem_translate_ff                <= i_mem_translate_ff;
           o_irq_ff                          <= o_stall_from_shifter ? '0 : i_irq_ff;
           o_fiq_ff                          <= o_stall_from_shifter ? '0 : i_fiq_ff;
           o_abt_ff                          <= o_stall_from_shifter ? '0 : i_abt_ff;
           o_swi_ff                          <= o_stall_from_shifter ? '0 : i_swi_ff;
           o_pc_plus_8_ff                    <= i_pc_plus_8_ff;
           o_mem_srcdest_value_ff            <= mem_srcdest_value;
           o_alu_source_value_ff             <= i_load_pending_ff[0] ? pickup_value[0 +: 32] : rn;
           o_shifted_source_value_ff         <= (i_load_pending_ff[1] && !shifter_enabled) ?
                                                pickup_value[32 +: 32] : rm;
           o_shift_carry_ff                  <= shift_carry_nxt;
           o_shift_sat_ff                    <= shift_sat_nxt | mult_sat_nxt;
           o_switch_ff                       <= i_switch_ff;
           o_und_ff                          <= i_und_ff;
           o_force32align_ff                 <= i_force32align_ff;
           o_taken_ff                        <= i_taken_ff;
           o_ppc_ff                          <= i_ppc_ff;
           o_early_redirect_ff <= early_branch;
           o_early_target_ff <= early_condition ? i_link_branch_ff[31:0] :
                   i_pc_ff + (i_thumb_ff ? 32'd2 : 32'd4);
           o_link_branch_ff <= {i_link_branch_ff[33:32] & {2{!o_stall_from_shifter}}, i_link_branch_ff[31:0]};
           o_pc_ff                           <= i_pc_ff;
           o_nozero_ff                       <= nozero_nxt;

           // For debug
           o_decompile                       <= i_decompile;
           o_uop_last                        <= i_uop_last;
   end
end

///////////////////////////////////////////////////////////////////////////////

// Barrel shifter.
zap_shifter_shift  #(
        .SHIFT_OPS(SHIFT_OPS)
)
U_SHIFT
(
        // ARM925T: forwarding is only used by the unshifted bypass. Do not
        // route it through the barrel shifter as well: that creates an
        // ALU -> forwarding -> barrel path whose output is never selected.
        // Local issue-register copies select the registered memory snapshot.
        .i_source       ( i_shift_source_pending_ff ? i_memory_load_value : i_shift_source_value_ff ),
        .i_amount       ( i_shift_length_pending_ff ? i_memory_load_value[7:0] : i_shift_length_value_ff[7:0] ),
        .i_shift_type   ( i_shift_operation_ff ),
        .i_carry        ( i_cpsr_ff_29 ),
        .o_result       ( shout ),
        .o_carry        ( shcarry ),
        .o_sat          ( shsat )
);

///////////////////////////////////////////////////////////////////////////////

// Resolve conflict for ALU source value (rn)
assign rn = resolve_conflict ( i_alu_source_ff, i_alu_source_value_ff,
                         o_destination_index_ff, i_alu_value_nxt, i_alu_dav_nxt,
                         i_force32align_ff ); // Needed to pass force32align.

///////////////////////////////////////////////////////////////////////////////

// Resolve conflict for shifter source value.
always_comb
begin
        // If we issue a multiply.
        if ( is_multiply )
        begin
                // Get result from multiplier.
                rm              = mult_out;
        end
        else if( shifter_enabled ) // Shifter enabled if valid shift is asked for.
        begin
                // Get result from shifter.
                rm              = shout;
        end
        else
        begin
                // Resolve conflict.
                rm = shift_source;
        end
end

assign shift_carry_nxt = shifter_enabled ? shcarry : i_cpsr_nxt_29;
assign shift_sat_nxt   = shifter_enabled ? shsat   : 1'd0;

///////////////////////////////////////////////////////////////////////////////

//
// Mem srcdest index. Used for stores. Resolve conflict.
//
assign  mem_srcdest_value = resolve_conflict (
                {27'd0, i_mem_srcdest_index_ff},
                i_load_pending_ff[3] ? i_memory_load_value : i_mem_srcdest_value_ff,
                o_destination_index_ff,
                i_alu_value_nxt,
                i_alu_dav_nxt,
                1'd0
                );

///////////////////////////////////////////////////////////////////////////////

//
// This will resolve conflicts for back to back instruction execution.
// The function entirely depends only on the inputs to the function.
//
function automatic [31:0] resolve_conflict (
        input    [32:0]                  index_from_issue,       // Index from issue stage. Could have immed too.
        input    [31:0]                  value_from_issue,       // Issue speculatively read value.
        input    [$clog2(PHY_REGS)-1:0]  index_from_this_stage,  // From shift (This) stage output flops.
        input    [31:0]                  result_from_alu,        // From ALU output directly.
        input                            result_from_alu_valid,  // Result from ALU is VALID.
        input                            align32                 // Force 32-bit align on PC read
);
        if ( index_from_issue[32] == IMMED_EN )
        begin
                resolve_conflict = index_from_issue[31:0];
        end
        else if ( index_from_issue[5:0] == PHY_PC )
        begin
                resolve_conflict = i_pc_plus_8_ff;
        end
        else if ( index_from_this_stage == index_from_issue[$clog2(PHY_REGS)-1:0] && result_from_alu_valid )
        begin
                resolve_conflict = result_from_alu;
        end
        else
        begin
                resolve_conflict = value_from_issue[31:0];
        end

        // If not load or store, align to 4 bytes. All i_ signals
        // for this.
        // ARM925T: and PC as the base of a load or store (Thumb PC-relative).
        if ( align32 && ((!i_mem_load_ff && !i_mem_store_ff) ||
                         (index_from_issue[32] != IMMED_EN && index_from_issue[5:0] == PHY_PC)) )
        begin
                resolve_conflict[1:0] = 2'b00;
        end
endfunction : resolve_conflict

endmodule : zap_shifter_main

// ----------------------------------------------------------------------------
// EOF
// ----------------------------------------------------------------------------
