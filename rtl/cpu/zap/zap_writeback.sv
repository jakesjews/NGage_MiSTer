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

module zap_writeback #(
        parameter integer RF_ALLOW_RETIMING = 1,
        parameter logic RF_EARLY_SELECT = 0,
        // ARM9V2: the coprocessor reads through a fifth RF port, so the
        // decode-side port A's address never waits for the coprocessor.
        parameter logic COPRO_PORT = 0,
        parameter logic [31:0] BP_ENTRIES   = 32'd1024,  // BP entries.
        parameter logic [31:0] FLAG_WDT     = 32'd32,    // Flags width a.k.a CPSR.
        parameter logic [31:0] PHY_REGS     = 32'd46,    // Number of physical registers.
        parameter logic [31:0] CPSR_INIT    = 32'd0,     // Initial value of CPSR.
        parameter logic [31:0] RESET_VECTOR = 32'd0      // Reset vector.
)
(
        // Decompile.
        input   logic    [64*8-1:0]           i_decompile,
        input   logic                         i_decompile_valid,
        input   logic                         i_uop_last,

        output  logic    [64*8-1:0]           o_decompile,

        // Shelve output.
        output logic                          o_shelve,

        // PID
        input   logic [6:0]                   i_cpu_pid,

        // L4 enable.
        input   logic                         i_l4_enable,

        // ARM925T: control bit V, vectors at 0xFFFF0000.
        input   logic                         i_hivecs,

        // Clear BTB
        input   logic                         i_clear_btb,

        // Clock and reset.
        input logic                           i_clk,
        input logic                           i_reset,

        // Inputs from memory unit valid signal.
        input logic                           i_valid,
        input logic [5:0] i_rf_class, // V2 registered owner class, independent of completion.

        // The PC can either be frozen in place or changed based on signals
        // from other units. If a unit clears the PC, it must provide the
        // appropriate new value.
        input logic                           i_code_stall,
        input logic                           i_clear_from_alu,
        input logic      [31:0]               i_pc_from_alu,
        input logic                           i_clear_from_decode,
        input logic      [31:0]               i_pc_from_decode,
        input logic                           i_clear_from_icache,
        input logic                           i_confirm_from_alu,
        input logic [31:0]                    i_alu_pc_ff,
        input logic [1:0]                     i_taken,

        // 4 read ports for high performance.
        input logic   [$clog2(PHY_REGS)-1:0] i_rd_index_0,
        input logic   [$clog2(PHY_REGS)-1:0] i_rd_index_1,
        input logic   [$clog2(PHY_REGS)-1:0] i_rd_index_2,
        input logic   [$clog2(PHY_REGS)-1:0] i_rd_index_3,

        // Memory load indicator.
        input logic                          i_mem_load_ff,

        // Write index and data and flag updates.
        input   logic [$clog2(PHY_REGS)-1:0] i_wr_index,
        input   logic [31:0]                 i_wr_data,
        input   logic [FLAG_WDT-1:0]         i_flags,
        input   logic [$clog2(PHY_REGS)-1:0] i_wr_index_1,
        input   logic [31:0]                 i_wr_data_1,
        input   logic [PHY_REGS-1:0]         i_wr_index_2,
        input   logic [31:0]                 i_wr_data_2,

        // From active CPSR.
        input   logic                        i_mode16,

        // Interrupt indicators.
        input   logic                         i_irq,
        input   logic                         i_fiq,
        input   logic                         i_instr_abt,
        input   logic [1:0]                   i_data_abt,
        input   logic                         i_swi,
        input   logic                         i_und,

        // Program counter, PC + 8. This value is captured in the fetch
        // stage and is buffered all the way through.
        input   logic    [31:0]               i_pc_plus_8_buf_ff,

        // Coprocessor.
        input logic                              i_copro_reg_en,
        input logic      [$clog2(PHY_REGS)-1:0]  i_copro_reg_wr_index,
        input logic      [$clog2(PHY_REGS)-1:0]  i_copro_reg_rd_index,
        input logic      [31:0]                  i_copro_reg_wr_data,
        output logic      [31:0]                 o_copro_reg_rd_data_ff,

        // Read data from the register file.
        output logic     [31:0]               o_rd_data_0,
        output logic     [31:0]               o_rd_data_1,
        output logic     [31:0]               o_rd_data_2,
        output logic     [31:0]               o_rd_data_3,

        // Program counter (dedicated port).
        output logic     [31:0]               o_pc,
        output logic     [31:0]               o_pc_check,
        output logic     [31:0]               o_pc_nxt,

        // Branch state.
        output logic     [1:0]                o_taken,

        //
        // Predict. MSB is valid indication and the rest indicates the
        // PC predicted. If MSB=0, ignore this.
        //
        output logic     [32:0]               o_pred,

        // CPSR output
        output logic      [31:0]              o_cpsr_nxt,

        // ARM925T: the CPSR as the stage holds it, for the debug trace.
        output logic      [31:0]              o_dbg_cpsr_ff,

        // Clear from writeback
        output logic                         o_clear_from_writeback,

        // STB and CYC
        output logic                         o_wb_stb,
        output logic                         o_wb_cyc,

        // Trace
        output logic [1023:0]                o_trace,
        output logic                         o_trace_valid,
        output logic                         o_trace_uop_last
);

`include "zap_defines.svh"
`include "zap_localparams.svh"

// ----------------------------------------------------------------------------
// Variables
// ----------------------------------------------------------------------------

logic     [31:0]                  cpsr_ff, cpsr_nxt;
logic [$clog2(PHY_REGS)-1:0]      wa1, wa2;
logic [39:0] write_sel1, write_sel2;
// ARM925T: decode each normal write address before the control priority
// mux. CP15/exception selection must not precede the register-file decoder.
(* keep *) wire [39:0] write_alu = 40'b1 << i_wr_index;
(* keep *) wire [39:0] write_load = 40'b1 << i_wr_index_1;
(* keep *) wire [39:0] write_copro = 40'b1 << i_copro_reg_wr_index;
logic [31:0]                      wdata1, wdata2;
logic                             wen;

logic                             shelve_ff, shelve_nxt;
logic [31:0]                      pc_shelve_ff, pc_shelve_nxt;
logic [32:0]                      pc_ff, pc_nxt;
logic [32:0]                      pc_del_ff, pc_del_nxt;
logic [32:0]                      pc_del2_ff, pc_del2_nxt;
logic [32:0]                      pc_del3_ff, pc_del3_nxt;

// ARM925T: read from pc_ff, then register the decision at pc_del2.
// Carry the accepted prediction with the branch into the final fetch slot.
// ARM925T: clear/recovery qualifies one valid bit, not the 32-bit payload.
(* dont_retime *) logic pred_valid_ff;
logic pred_valid_nxt;
(* dont_retime *) logic pred_del2_valid_ff;
logic pred_del2_valid_nxt;
(* dont_retime *) logic [31:0] pred_del2_target_ff;
(* dont_retime *) logic [31:0] pred_target_ff;
logic [1:0]                       btb_taken, taken_del3_ff;

logic                             mode32;
logic                             clear_from_btb;
logic [31:0]                      vector_base;  // ARM925T: 0 or 0xFFFF0000.

assign vector_base = i_hivecs ? 32'hFFFF_0000 : 32'h0000_0000;
logic [31:0]                      pc_from_btb;

assign  mode32     = (cpsr_ff[T] == 1'd0) ? 1'd1 : 1'd0;
assign  o_shelve     = shelve_ff;
assign  o_pc         = pc_del3_ff[31:0];
assign  o_pc_check   = pc_del2_ff[31:0];
assign  o_pc_nxt     = pc_ff[31:0];
assign  o_cpsr_nxt   = cpsr_nxt;
assign  o_dbg_cpsr_ff = cpsr_ff;    // ARM925T: debug trace
assign  o_wb_stb     = pc_del3_ff[32];
assign  o_wb_cyc     = pc_del3_ff[32];
assign  o_pred       = {pred_valid_ff, pred_target_ff & {32{pred_valid_ff}}};
assign  o_taken      = taken_del3_ff;

// ----------------------------------------------------------------------------
// Register file
// ----------------------------------------------------------------------------

// ARM9V2: completion is the write enable, not part of the port's data
// selection. Static exception classes arrived with W; a data abort alone
// overrides them late. The original tree below still controls CPSR, PC,
// trace and wen. ZAP does not use this alternative data-only path.
logic [39:0] rf_sel1,rf_sel2;
logic [31:0] rf_data1,rf_data2;
if (RF_EARLY_SELECT) begin : g_rf_select
    always_comb begin
        rf_sel1=write_alu;
        rf_sel2=i_mem_load_ff?write_load:(40'b1<<PHY_RAZ_REGISTER);
        rf_data1=i_wr_data;rf_data2=i_wr_data_1;
        if(i_copro_reg_en)begin
            rf_sel1=write_copro;rf_sel2=40'b1<<PHY_RAZ_REGISTER;
            rf_data1=i_copro_reg_wr_data;rf_data2=0;
        end
        if(|i_rf_class)begin
            rf_data2=cpsr_ff;
            if(i_rf_class[0])begin
                rf_sel1=40'b1<<PHY_ABT_R14;rf_sel2=40'b1<<PHY_ABT_SPSR;
                rf_data1=mode32?i_pc_plus_8_buf_ff:i_pc_plus_8_buf_ff+32'd4;
            end else if(i_rf_class[1])begin
                rf_sel1=40'b1<<PHY_FIQ_R14;rf_sel2=40'b1<<PHY_FIQ_SPSR;
                rf_data1=mode32?i_wr_data:i_pc_plus_8_buf_ff;
            end else if(i_rf_class[2])begin
                rf_sel1=40'b1<<PHY_IRQ_R14;rf_sel2=40'b1<<PHY_IRQ_SPSR;
                rf_data1=mode32?i_wr_data:i_pc_plus_8_buf_ff;
            end else if(i_rf_class[3])begin
                rf_sel1=40'b1<<PHY_ABT_R14;rf_sel2=40'b1<<PHY_ABT_SPSR;
                rf_data1=mode32?i_wr_data:i_pc_plus_8_buf_ff;
            end else if(i_rf_class[4])begin
                rf_sel1=40'b1<<PHY_SVC_R14;rf_sel2=40'b1<<PHY_SVC_SPSR;
                rf_data1=mode32?i_wr_data:i_pc_plus_8_buf_ff-32'd2;
            end else begin
                rf_sel1=40'b1<<PHY_UND_R14;rf_sel2=40'b1<<PHY_UND_SPSR;
                rf_data1=mode32?i_wr_data:i_pc_plus_8_buf_ff-32'd2;
            end
        end
    end
`ifndef SYNTHESIS
    always_ff @(posedge i_clk) if(!i_reset&&wen)begin
        assert(rf_sel1==write_sel1&&rf_sel2==write_sel2)else $fatal(1,"RF port class");
        assert(rf_data1==wdata1&&rf_data2==wdata2)else $fatal(1,"RF data class");
    end
`endif
end else begin : g_rf_original
    wire unused_class=&{1'b0,i_rf_class};
    assign rf_sel1=write_sel1;assign rf_sel2=write_sel2;
    assign rf_data1=wdata1;assign rf_data2=wdata2;
end

logic [31:0] copro_rd_data;
zap_register_file #(.ALLOW_RETIMING(RF_ALLOW_RETIMING),.EARLY_PORT_SELECT(RF_EARLY_SELECT)) u_zap_register_file
(
.i_clk(i_clk),
 .i_reset        (       i_reset         ),

 .i_wr_addr_a    (       rf_sel1         ),
 .i_wr_addr_b    (       rf_sel2         ),
 .i_wr_addr_c    (     i_wr_index_2      ),

 .i_wr_data_a    (       rf_data1        ),
 .i_wr_data_b    (       rf_data2        ),
 .i_wr_data_c    (     i_wr_data_2       ),

 .i_wen          (       wen             ),

 .i_rd_addr_a    ( !COPRO_PORT && i_copro_reg_en ? i_copro_reg_rd_index : i_rd_index_0 ),
 .i_rd_addr_b    (       i_rd_index_1    ),
 .i_rd_addr_c    (       i_rd_index_2    ),
 .i_rd_addr_d    (       i_rd_index_3    ),
 .i_rd_addr_e    ( COPRO_PORT ? i_copro_reg_rd_index : '0 ),

 .o_rd_data_a    (       o_rd_data_0     ),
 .o_rd_data_b    (       o_rd_data_1     ),
 .o_rd_data_c    (       o_rd_data_2     ),
 .o_rd_data_d    (       o_rd_data_3     ),
 .o_rd_data_e    (       copro_rd_data   )

);

// ----------------------------------------------------------------------------
// Combinational Logic
// ----------------------------------------------------------------------------

// ARM925T: map each candidate before selecting the next PC. A zero-tag
// comparison after the wide priority mux put decode/stall control through
// another compare and mux on its way to pc_ff[31:25].
function automatic [31:0] map_pc(input [31:0] address);
        map_pc = {(address[31:25] == 0) ? i_cpu_pid : address[31:25],
                  address[24:1], 1'b0};
endfunction

always_comb
begin: pc_control_tree
        logic [9:0] recovery_select;
        logic [9:0][31:0] recovery_pc;
        logic [31:0] new_pc, mapped_new_pc;

        recovery_pc[9] = mode32 ? i_pc_plus_8_buf_ff - 8 : i_pc_plus_8_buf_ff - 4;
        recovery_pc[8] = vector_base | DABT_VECTOR;
        recovery_pc[7] = vector_base | FIQ_VECTOR;
        recovery_pc[6] = vector_base | IRQ_VECTOR;
        recovery_pc[5] = vector_base | PABT_VECTOR;
        recovery_pc[4] = vector_base | SWI_VECTOR;
        recovery_pc[3] = vector_base | UND_VECTOR;
        recovery_pc[2] = i_wr_data_1;
        recovery_pc[1] = i_pc_from_alu;
        recovery_pc[0] = i_pc_from_decode;

        // Preserve the architectural redirect priority. The one-hot select
        // drives parallel data muxes for raw (shelved) and mapped PCs.
        casez ({i_data_abt[1], i_data_abt[0], i_fiq, i_irq, i_instr_abt,
                i_swi, i_und,
                (i_valid && i_mem_load_ff && i_wr_index_1 == {2'd0, ARCH_PC}),
                i_clear_from_alu, i_clear_from_decode})
                10'b1?????????: recovery_select = 10'b1000000000;
                10'b01????????: recovery_select = 10'b0100000000;
                10'b001???????: recovery_select = 10'b0010000000;
                10'b0001??????: recovery_select = 10'b0001000000;
                10'b00001?????: recovery_select = 10'b0000100000;
                10'b000001????: recovery_select = 10'b0000010000;
                10'b0000001???: recovery_select = 10'b0000001000;
                10'b00000001??: recovery_select = 10'b0000000100;
                10'b000000001?: recovery_select = 10'b0000000010;
                10'b0000000001: recovery_select = 10'b0000000001;
                default:        recovery_select = 10'b0;
        endcase
        new_pc = 0;
        mapped_new_pc = 0;
        for (int k = 0; k < 10; k++) begin
                new_pc |= recovery_pc[k] & {32{recovery_select[k]}};
                mapped_new_pc |= map_pc(recovery_pc[k]) & {32{recovery_select[k]}};
        end

        shelve_nxt    = shelve_ff;
        pc_shelve_nxt = pc_shelve_ff;
        pc_nxt        = {pc_ff[32], map_pc(pc_ff[31:0])};
        pc_del_nxt    = pc_del_ff;
        pc_del2_nxt   = pc_del2_ff;
        pc_del3_nxt   = pc_del3_ff;
        pred_valid_nxt = 1'b0;
        pred_del2_valid_nxt = 1'b0;

        if (|recovery_select) begin
                if (i_code_stall) begin
                        // Keep the raw address: PID may change before release.
                        shelve_nxt = 1'b1;
                        pc_shelve_nxt = new_pc;
                end else begin
                        pc_nxt = {1'b1, mapped_new_pc};
                        pc_del_nxt  = {1'b0, pc_ff[31:0]};
                        pc_del2_nxt = {1'b0, pc_del_ff[31:0]};
                        pc_del3_nxt = {1'b0, pc_del2_ff[31:0]};
                        shelve_nxt = 1'b0;
                end
        end else if (!i_code_stall) begin
                if (shelve_ff) begin
                        pc_nxt = {1'b1, map_pc(pc_shelve_ff)};
                        pc_del_nxt = 0;
                        pc_del2_nxt = 0;
                        pc_del3_nxt = 0;
                        shelve_nxt = 1'b0;
                end else if (i_clear_from_icache) begin
                        pc_nxt = {1'b1, map_pc(pc_del3_ff[31:0])};
                        pc_del_nxt  = {1'b0, pc_ff[31:0]};
                        pc_del2_nxt = {1'b0, pc_del_ff[31:0]};
                        pc_del3_nxt = {1'b0, pc_del2_ff[31:0]};
                        shelve_nxt = 1'b0;
                end else if (clear_from_btb && pc_del_ff[32] && !i_clear_btb) begin
                        // ARM925T: the RAM read belongs to pc_del. Preserve
                        // it and the older slot; discard just pc_ff.
                        pc_nxt = {1'b1, map_pc(pc_from_btb)};
                        pc_del_nxt  = {1'b0, pc_ff[31:0]};
                        pc_del2_nxt = pc_del_ff;
                        pc_del3_nxt = pc_del2_ff;
                        pred_del2_valid_nxt = 1'b1;
                        pred_valid_nxt = pred_del2_valid_ff;
                end else begin
                        pc_nxt = {pc_ff[32], map_pc(pc_ff[31:0] + (i_mode16 ? 32'd2 : 32'd4))};
                        pc_del_nxt = pc_ff;
                        pc_del2_nxt = pc_del_ff;
                        pc_del3_nxt = pc_del2_ff;
                        pred_valid_nxt = pred_del2_valid_ff;
                end
        end
end: pc_control_tree

// Register file write.
always_comb
begin: register_file_write

        // ================================================
        // Default Values Section (Done to avoid combo loops/incomplete assignments)
        // ================================================

        wen                      = 1'd0;
        wa1                      = PHY_RAZ_REGISTER;
        write_sel1 = 40'b1 << PHY_RAZ_REGISTER;
        wa2                      = PHY_RAZ_REGISTER;
        write_sel2 = 40'b1 << PHY_RAZ_REGISTER;
        wdata1                   = 32'd0;
        wdata2                   = 32'd0;
        o_clear_from_writeback   = 0;
        cpsr_nxt                 = cpsr_ff;

        // ===============================================
        // Code Section
        // ===============================================

        if ( i_data_abt[1] )
        begin
                o_clear_from_writeback = 1'd1;
        end
        else if ( i_data_abt[0] )
        begin
                wen                         = 1;
                wdata1                      = mode32 ?
                                              i_pc_plus_8_buf_ff :
                                              i_pc_plus_8_buf_ff + 4;
                wa1                         = PHY_ABT_R14;
                write_sel1 = 40'b1 << PHY_ABT_R14;
                wa2                         = PHY_ABT_SPSR;
                write_sel2 = 40'b1 << PHY_ABT_SPSR;
                wdata2                      = cpsr_ff;
                cpsr_nxt[ZAP_CPSR_MODE:0]   = ABT;

                //
                // Disable IRQ interrupts when entering exception.
                // Go to 32-bit mode.
                //
                `zap_chmod;
        end
        else if ( i_fiq )
        begin
                wen                     = 1;
                wdata1                  = mode32 ? i_wr_data : i_pc_plus_8_buf_ff ;
                wa1                     = PHY_FIQ_R14;
                write_sel1 = 40'b1 << PHY_FIQ_R14;
                wa2                     = PHY_FIQ_SPSR;
                write_sel2 = 40'b1 << PHY_FIQ_SPSR;
                wdata2                  = cpsr_ff;
                cpsr_nxt[ZAP_CPSR_MODE:0] = FIQ;
                cpsr_nxt[F]             = 1'd1; // Mask FIQ interrupts.

                `zap_chmod;
        end
        else if ( i_irq )
        begin
                wen                     = 1;
                wdata1                  = mode32 ? i_wr_data : i_pc_plus_8_buf_ff ;
                wa1                     = PHY_IRQ_R14;
                write_sel1 = 40'b1 << PHY_IRQ_R14;
                wa2                     = PHY_IRQ_SPSR;
                write_sel2 = 40'b1 << PHY_IRQ_SPSR;
                wdata2                  = cpsr_ff;
                cpsr_nxt[ZAP_CPSR_MODE:0] = IRQ;

                `zap_chmod;
        end
        else if ( i_instr_abt )
        begin
                wen                        = 1;
                wdata1                     = mode32 ? i_wr_data : i_pc_plus_8_buf_ff ;
                wa1                        = PHY_ABT_R14;
                write_sel1 = 40'b1 << PHY_ABT_R14;
                wa2                        = PHY_ABT_SPSR;
                write_sel2 = 40'b1 << PHY_ABT_SPSR;
                wdata2                     = cpsr_ff;
                cpsr_nxt[ZAP_CPSR_MODE:0]  = ABT;

                `zap_chmod;
        end
        else if ( i_swi )
        begin
                wen                       = 1;
                // ARM925T: from Thumb state LR is the next instruction,
                // PC + 2 (PC + 4 - 2); upstream gave the SWI's own address.
                wdata1                    = mode32 ? i_wr_data : i_pc_plus_8_buf_ff - 32'd2;
                wa1                       = PHY_SVC_R14;
                write_sel1 = 40'b1 << PHY_SVC_R14;
                wa2                       = PHY_SVC_SPSR;
                write_sel2 = 40'b1 << PHY_SVC_SPSR;
                wdata2                    = cpsr_ff;
                cpsr_nxt[ZAP_CPSR_MODE:0] = SVC;

                `zap_chmod;
        end
        else if ( i_und )
        begin
                wen                       = 1;
                // ARM925T: as for SWI, PC + 2 from Thumb state.
                wdata1                    = mode32 ? i_wr_data : i_pc_plus_8_buf_ff - 32'd2;
                wa1                       = PHY_UND_R14;
                write_sel1 = 40'b1 << PHY_UND_R14;
                wa2                       = PHY_UND_SPSR;
                write_sel2 = 40'b1 << PHY_UND_SPSR;
                wdata2                    = cpsr_ff;
                cpsr_nxt[ZAP_CPSR_MODE:0] = UND;

                `zap_chmod;
        end
        else if ( i_copro_reg_en )
        begin
               // Write to register (Coprocessor command).
               wen      = 1;
               wa1      = i_copro_reg_wr_index;
               write_sel1 = write_copro;
               wdata1   = i_copro_reg_wr_data;
        end
        else if ( i_valid ) // If valid,
        begin
                // Only then execute the instruction at hand...
                cpsr_nxt = i_flags;

                // Dual write port.
                wen = 1;

                // Port from arithmetic side
                wa1    = i_wr_index;
                write_sel1 = write_alu;
                wdata1 = i_wr_data;

                // Port from memory side.
                wa2    = i_mem_load_ff ? i_wr_index_1 : PHY_RAZ_REGISTER;
                write_sel2 = i_mem_load_ff ? write_load : (40'b1 << PHY_RAZ_REGISTER);
                wdata2 = i_wr_data_1;

                // Load to PC will trigger from writeback.
                if ( i_mem_load_ff && i_wr_index_1 == {2'd0, ARCH_PC})
                begin
                        o_clear_from_writeback  = 1'd1;

                        // Switch state only if this is 0.
                        if ( i_l4_enable == 1'd0 )
                        begin
                                cpsr_nxt[T] = i_wr_data_1[0];
                        end
                end
        end // else not required because defaults are assigned.

end: register_file_write

// ----------------------------------------------------------------------------
// Sequential Logic
// ----------------------------------------------------------------------------

always_ff @ ( posedge i_clk )
begin
        if ( i_reset )
        begin
                // On reset, the CPU starts at 0 in
                // supervisor mode.
                shelve_ff                  <= 1'd0;

                pc_ff                      <= {1'd1, RESET_VECTOR};
                pc_del_ff                  <= 33'd0;
                pc_del2_ff                 <= 33'd0;
                pc_del3_ff                 <= 33'd0;
                pred_valid_ff             <= 1'b0;
                pred_del2_valid_ff          <= 1'b0;
                taken_del3_ff              <= SNT;

                // CPSR reset logic.
                cpsr_ff                    <= CPSR_INIT;
        end
        else
        begin
                shelve_ff                 <= shelve_nxt;
                pc_shelve_ff              <= pc_shelve_nxt;

                pc_ff                     <= pc_nxt;
                pc_del_ff                 <= pc_del_nxt;
                pc_del2_ff                <= pc_del2_nxt;
                pc_del3_ff                <= pc_del3_nxt;

                if ( !i_code_stall )
                begin
                        pred_valid_ff <= pred_valid_nxt;
                        pred_target_ff <= pred_del2_target_ff;
                        pred_del2_target_ff <= pc_from_btb;
                        pred_del2_valid_ff <= pred_del2_valid_nxt;
                        taken_del3_ff <= btb_taken;
                end

                cpsr_ff                   <= cpsr_nxt;
                o_decompile               <= i_decompile;
                o_copro_reg_rd_data_ff    <= COPRO_PORT ? copro_rd_data : o_rd_data_0;
        end
end

// ----------------------------------------------------------------------------
// Instantiations
// ----------------------------------------------------------------------------

zap_btb #(.BP_ENTRIES(BP_ENTRIES)) u_zap_btb (
        .i_clk(i_clk),
        .i_reset(i_reset),
        .i_stall(i_code_stall),
        .i_clear(i_clear_btb),
        .i_fb_ok(i_confirm_from_alu),
        .i_fb_nok(i_clear_from_alu),
        .i_fb_branch_src_address(i_alu_pc_ff),
        .i_fb_branch_dest_address(i_pc_from_alu),
        .i_fb_current_branch_state(i_taken),
        // ARM925T: both lookup stages start at registers. The RAM reads
        // pc_ff; its registered result redirects at pc_del_ff.
        .i_rd_addr(pc_ff[31:0]),
        .i_rd_addr_del(pc_del_ff[31:0]),
        .o_clear_from_btb(clear_from_btb),
        .o_pc_from_btb(pc_from_btb),
        .o_branch_state(btb_taken)
);

`ifndef SYNTHESIS

        // For simulation only

        logic [1023:0] msg_nxt, trace_prev;
        logic          trace_uop_last_nxt;
        logic          trace_valid_nxt;

        always @* // For simulation only / Assertion.
        begin
                msg_nxt            = o_trace;
                trace_uop_last_nxt = 0;

                if ( i_reset )
                begin
                        $sformat(msg_nxt, "%x:<RESET>", i_pc_plus_8_buf_ff - 8);
                end
                else if ( i_data_abt[1] )
                begin
                        // Empty.
                end
                else if ( i_data_abt[0] )
                begin
                        $sformat(msg_nxt, "%x:<DABT>", i_pc_plus_8_buf_ff - 8);
                end
                else if ( i_fiq )
                begin
                        $sformat(msg_nxt, "%x:<FIQ>", i_pc_plus_8_buf_ff - 8);
                end
                else if ( i_irq  )
                begin
                        $sformat(msg_nxt, "%x:<IRQ>", i_pc_plus_8_buf_ff - 8);
                end
                else if ( i_instr_abt  )
                begin
                        $sformat(msg_nxt, "%x:<IABT>", i_pc_plus_8_buf_ff - 8);
                end
                else if ( i_swi )
                begin
                        $sformat(msg_nxt, "%x:<SWI>", i_pc_plus_8_buf_ff - 8);
                end
                else if ( i_und )
                begin
                        assert(1'd0) else
                        $display("Error: Undefined instruction detected at address=%x CPSR=%x",
                        i_pc_plus_8_buf_ff - 8, i_flags);

                        $sformat(msg_nxt, "%x:<UND>", i_pc_plus_8_buf_ff - 8);
                end
                else if ( i_copro_reg_en  )
                begin
                        $sformat(msg_nxt,
                                "CP15_ASYNC_UPDATE:idx=%x data=%x",
                                 i_copro_reg_wr_index, i_copro_reg_wr_data);
                end
                else if ( i_valid )
                begin
                        $sformat(msg_nxt,
                        "%x:<%s> %x@%x %x@%x %x",
                        i_pc_plus_8_buf_ff - 8, i_decompile, wa1, wdata1, wa2, wdata2, i_flags);

                        trace_uop_last_nxt = i_uop_last;
                end
                else if ( i_decompile_valid ) // Condition code failed.
                begin
                         $sformat(msg_nxt,
                        "%x:<%s>*",
                        i_pc_plus_8_buf_ff - 8, i_decompile);

                        trace_uop_last_nxt = i_uop_last;
                end
        end

        // Happens on the same edge as register update.
        always @ ( posedge i_clk ) // For simulation only / Assertion.
        begin
                o_trace          <= msg_nxt;
                o_trace_uop_last <= trace_uop_last_nxt;
                o_trace_valid    <= trace_valid_nxt;
        end

        initial trace_prev       = "";

        // Display message
        always @ ( negedge i_clk ) // Assertion.
        begin
            if ( o_trace_valid )
            begin
                if ( o_trace != trace_prev )
                begin
                    $display("%s", o_trace);
                    trace_prev <= o_trace;
                end
            end
        end

        always@* // For simulation only / Assertion
        begin
                trace_valid_nxt = 0;

                if ( i_reset )
                begin
                        trace_valid_nxt = 1;
                end
                else if ( i_data_abt[1] )
                begin
                        trace_valid_nxt = 0;
                end
                else if ( i_data_abt[0] )
                begin
                        trace_valid_nxt = 1;
                end
                else if ( i_fiq )
                begin
                        trace_valid_nxt = 1;
                end
                else if ( i_irq  )
                begin
                        trace_valid_nxt = 1;
                end
                else if ( i_instr_abt  )
                begin
                        trace_valid_nxt = 1;
                end
                else if ( i_swi )
                begin
                        trace_valid_nxt = 1;
                end
                else if ( i_und )
                begin
                        trace_valid_nxt = 1;
                end
                else if ( i_copro_reg_en  )
                begin
                        trace_valid_nxt = 1;
                end
                else if ( i_valid )
                begin
                        trace_valid_nxt = 1;
                end
                else if ( i_decompile_valid )
                begin
                        trace_valid_nxt = 1;
                end
        end

        // Above block is for simulation only

`else

// Tie off trace to 0.
assign o_trace         = '0;
assign o_trace_valid   = '0;
assign o_trace_uop_last= '0;

logic unused;
assign unused = |{i_decompile_valid, i_uop_last};

`endif

endmodule : zap_writeback

// ----------------------------------------------------------------------------
// END OF FILE
// ----------------------------------------------------------------------------
