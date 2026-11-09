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

// ARM9V2's writeback: the register file, its write-port selection and the
// CPSR. From ZAP's writeback stage; its fetch PC, branch predictor, shelve,
// decompile and trace (V2 has its own front end) were removed on 2026-10-25.
module zap_writeback #(
        // ARM9V2: the coprocessor reads through the register file's own
        // port E, so D2's port A address is d2.tag[0] alone (no mux on
        // i_copro_reg_en in front of the operand read). Zero cycles.
        parameter logic COPRO_PORT = 0,
        parameter logic [31:0] FLAG_WDT     = 32'd32,    // Flags width a.k.a CPSR.
        parameter logic [31:0] PHY_REGS     = 32'd46,    // Number of physical registers.
        parameter logic [31:0] CPSR_INIT    = 32'd0      // Initial value of CPSR.
)
(
        // L4 enable.
        input   logic                         i_l4_enable,

        // Clock and reset.
        input logic                           i_clk,
        input logic                           i_reset,

        // Inputs from memory unit valid signal.
        input logic                           i_valid,
        input logic [5:0] i_rf_class, // V2 registered owner class, independent of completion.

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

        // Interrupt indicators.
        input   logic                         i_irq,
        input   logic                         i_fiq,
        input   logic                         i_instr_abt,
        input   logic [1:0]                   i_data_abt,
        input   logic                         i_swi,
        input   logic                         i_und,

        // Program counter, PC + 8, of the retiring instruction.
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

        // CPSR output
        output logic      [31:0]              o_cpsr_nxt,

        // ARM925T: the CPSR as the stage holds it, for the debug trace.
        output logic      [31:0]              o_dbg_cpsr_ff
);

`include "zap_defines.svh"
`include "zap_localparams.svh"

// An exception's mode change: IRQs masked, ARM state.
`define v2_chmod \
begin \
        cpsr_nxt[I]             = 1'd1; \
        cpsr_nxt[T]             = 1'd0; \
end

// ----------------------------------------------------------------------------
// Variables
// ----------------------------------------------------------------------------

logic     [31:0]                  cpsr_ff, cpsr_nxt;
logic [39:0] write_sel1, write_sel2;
// ARM925T: decode each normal write address before the control priority
// mux. CP15/exception selection must not precede the register-file decoder.
(* keep *) wire [39:0] write_alu = 40'b1 << i_wr_index;
(* keep *) wire [39:0] write_load = 40'b1 << i_wr_index_1;
(* keep *) wire [39:0] write_copro = 40'b1 << i_copro_reg_wr_index;
logic [31:0]                      wdata1, wdata2;
logic                             wen;
logic                             mode32;

assign  mode32        = (cpsr_ff[T] == 1'd0) ? 1'd1 : 1'd0;
assign  o_cpsr_nxt    = cpsr_nxt;
assign  o_dbg_cpsr_ff = cpsr_ff;    // ARM925T: debug trace

// ----------------------------------------------------------------------------
// Register file
// ----------------------------------------------------------------------------

// ARM9V2: completion is the write enable, not part of the port's data
// selection. Static exception classes arrived with W; a data abort alone
// overrides them late. The original tree below still controls CPSR and
// wen, and the assertion checks the ports against it.
logic [39:0] rf_sel1,rf_sel2;
logic [5:0] rf_index1,rf_index2;
logic [31:0] rf_data1,rf_data2;
if (1) begin : g_rf_select
    always_comb begin
        rf_index1=i_wr_index; rf_index2=i_mem_load_ff?i_wr_index_1:6'(PHY_RAZ_REGISTER);
        rf_sel1=write_alu;
        rf_sel2=i_mem_load_ff?write_load:(40'b1<<PHY_RAZ_REGISTER);
        rf_data1=i_wr_data;rf_data2=i_wr_data_1;
        if(i_copro_reg_en)begin
            rf_index1=i_copro_reg_wr_index;rf_index2=6'(PHY_RAZ_REGISTER);
            rf_sel1=write_copro;rf_sel2=40'b1<<PHY_RAZ_REGISTER;
            rf_data1=i_copro_reg_wr_data;rf_data2=0;
        end
        if(|i_rf_class)begin
            rf_data2=cpsr_ff;
            if(i_rf_class[0])begin
                rf_index1=6'(PHY_ABT_R14);rf_index2=6'(PHY_ABT_SPSR);
                rf_sel1=40'b1<<PHY_ABT_R14;rf_sel2=40'b1<<PHY_ABT_SPSR;
                rf_data1=mode32?i_pc_plus_8_buf_ff:i_pc_plus_8_buf_ff+32'd4;
            end else if(i_rf_class[1])begin
                rf_index1=6'(PHY_FIQ_R14);rf_index2=6'(PHY_FIQ_SPSR);
                rf_sel1=40'b1<<PHY_FIQ_R14;rf_sel2=40'b1<<PHY_FIQ_SPSR;
                rf_data1=mode32?i_wr_data:i_pc_plus_8_buf_ff;
            end else if(i_rf_class[2])begin
                rf_index1=6'(PHY_IRQ_R14);rf_index2=6'(PHY_IRQ_SPSR);
                rf_sel1=40'b1<<PHY_IRQ_R14;rf_sel2=40'b1<<PHY_IRQ_SPSR;
                rf_data1=mode32?i_wr_data:i_pc_plus_8_buf_ff;
            end else if(i_rf_class[3])begin
                rf_index1=6'(PHY_ABT_R14);rf_index2=6'(PHY_ABT_SPSR);
                rf_sel1=40'b1<<PHY_ABT_R14;rf_sel2=40'b1<<PHY_ABT_SPSR;
                rf_data1=mode32?i_wr_data:i_pc_plus_8_buf_ff;
            end else if(i_rf_class[4])begin
                rf_index1=6'(PHY_SVC_R14);rf_index2=6'(PHY_SVC_SPSR);
                rf_sel1=40'b1<<PHY_SVC_R14;rf_sel2=40'b1<<PHY_SVC_SPSR;
                rf_data1=mode32?i_wr_data:i_pc_plus_8_buf_ff-32'd2;
            end else begin
                rf_index1=6'(PHY_UND_R14);rf_index2=6'(PHY_UND_SPSR);
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
end

logic [31:0] copro_rd_data;
`ifndef SYNTHESIS
// COPRO_PORT: in every clock the coprocessor reads, port E returns what
// port A returned to it in the original form.
always_ff @(posedge i_clk) if (!i_reset && COPRO_PORT && i_copro_reg_en)
        assert (copro_rd_data == u_zap_register_file.mem[i_copro_reg_rd_index]) else $fatal(1, "coprocessor read port");
`endif
zap_register_file #(.DIRECT_INDEX(1)) u_zap_register_file
(
.i_clk(i_clk),
 .i_reset        (       i_reset         ),

 .i_wr_index_a(rf_index1), .i_wr_index_b(rf_index2),
 .i_wr_addr_a    (       rf_sel1         ),
 .i_wr_addr_b    (       rf_sel2         ),
 .i_wr_addr_c    (     i_wr_index_2      ),

 .i_wr_data_a    (       rf_data1        ),
 .i_wr_data_b    (       rf_data2        ),
 .i_wr_data_c    (     i_wr_data_2       ),

 .i_wen          (       wen             ),

 .i_rd_addr_a    ( COPRO_PORT ? i_rd_index_0 : i_copro_reg_en ? i_copro_reg_rd_index : i_rd_index_0 ),
 .i_rd_addr_b    (       i_rd_index_1    ),
 .i_rd_addr_c    (       i_rd_index_2    ),
 .i_rd_addr_d    (       i_rd_index_3    ),
 .i_rd_addr_e    (  i_copro_reg_rd_index ),

 .o_rd_data_a    (       o_rd_data_0     ),
 .o_rd_data_b    (       o_rd_data_1     ),
 .o_rd_data_c    (       o_rd_data_2     ),
 .o_rd_data_d    (       o_rd_data_3     ),
 .o_rd_data_e    (       copro_rd_data   )

);

// ----------------------------------------------------------------------------
// Combinational Logic
// ----------------------------------------------------------------------------

// Register file write.
always_comb
begin: register_file_write

        // ================================================
        // Default Values Section (Done to avoid combo loops/incomplete assignments)
        // ================================================

        wen                      = 1'd0;
        write_sel1 = 40'b1 << PHY_RAZ_REGISTER;
        write_sel2 = 40'b1 << PHY_RAZ_REGISTER;
        wdata1                   = 32'd0;
        wdata2                   = 32'd0;
        cpsr_nxt                 = cpsr_ff;

        // ===============================================
        // Code Section
        // ===============================================

        if ( i_data_abt[1] )
        begin
                // An external abort with no register write: nothing here.
        end
        else if ( i_data_abt[0] )
        begin
                wen                         = 1;
                wdata1                      = mode32 ?
                                              i_pc_plus_8_buf_ff :
                                              i_pc_plus_8_buf_ff + 4;
                write_sel1 = 40'b1 << PHY_ABT_R14;
                write_sel2 = 40'b1 << PHY_ABT_SPSR;
                wdata2                      = cpsr_ff;
                cpsr_nxt[ZAP_CPSR_MODE:0]   = ABT;

                //
                // Disable IRQ interrupts when entering exception.
                // Go to 32-bit mode.
                //
                `v2_chmod;
        end
        else if ( i_fiq )
        begin
                wen                     = 1;
                wdata1                  = mode32 ? i_wr_data : i_pc_plus_8_buf_ff ;
                write_sel1 = 40'b1 << PHY_FIQ_R14;
                write_sel2 = 40'b1 << PHY_FIQ_SPSR;
                wdata2                  = cpsr_ff;
                cpsr_nxt[ZAP_CPSR_MODE:0] = FIQ;
                cpsr_nxt[F]             = 1'd1; // Mask FIQ interrupts.

                `v2_chmod;
        end
        else if ( i_irq )
        begin
                wen                     = 1;
                wdata1                  = mode32 ? i_wr_data : i_pc_plus_8_buf_ff ;
                write_sel1 = 40'b1 << PHY_IRQ_R14;
                write_sel2 = 40'b1 << PHY_IRQ_SPSR;
                wdata2                  = cpsr_ff;
                cpsr_nxt[ZAP_CPSR_MODE:0] = IRQ;

                `v2_chmod;
        end
        else if ( i_instr_abt )
        begin
                wen                        = 1;
                wdata1                     = mode32 ? i_wr_data : i_pc_plus_8_buf_ff ;
                write_sel1 = 40'b1 << PHY_ABT_R14;
                write_sel2 = 40'b1 << PHY_ABT_SPSR;
                wdata2                     = cpsr_ff;
                cpsr_nxt[ZAP_CPSR_MODE:0]  = ABT;

                `v2_chmod;
        end
        else if ( i_swi )
        begin
                wen                       = 1;
                // ARM925T: from Thumb state LR is the next instruction,
                // PC + 2 (PC + 4 - 2); upstream gave the SWI's own address.
                wdata1                    = mode32 ? i_wr_data : i_pc_plus_8_buf_ff - 32'd2;
                write_sel1 = 40'b1 << PHY_SVC_R14;
                write_sel2 = 40'b1 << PHY_SVC_SPSR;
                wdata2                    = cpsr_ff;
                cpsr_nxt[ZAP_CPSR_MODE:0] = SVC;

                `v2_chmod;
        end
        else if ( i_und )
        begin
                wen                       = 1;
                // ARM925T: as for SWI, PC + 2 from Thumb state.
                wdata1                    = mode32 ? i_wr_data : i_pc_plus_8_buf_ff - 32'd2;
                write_sel1 = 40'b1 << PHY_UND_R14;
                write_sel2 = 40'b1 << PHY_UND_SPSR;
                wdata2                    = cpsr_ff;
                cpsr_nxt[ZAP_CPSR_MODE:0] = UND;

                `v2_chmod;
        end
        else if ( i_copro_reg_en )
        begin
               // Write to register (Coprocessor command).
               wen      = 1;
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
                write_sel1 = write_alu;
                wdata1 = i_wr_data;

                // Port from memory side.
                write_sel2 = i_mem_load_ff ? write_load : (40'b1 << PHY_RAZ_REGISTER);
                wdata2 = i_wr_data_1;

                // A load to the PC switches state from its bit 0, unless L4.
                if ( i_mem_load_ff && i_wr_index_1 == {2'd0, ARCH_PC})
                begin
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
                cpsr_ff                <= CPSR_INIT;
        else
        begin
                cpsr_ff                <= cpsr_nxt;
                o_copro_reg_rd_data_ff <= COPRO_PORT ? copro_rd_data : o_rd_data_0;
        end
end

`undef v2_chmod

endmodule // zap_writeback

// ----------------------------------------------------------------------------
// EOF
// ----------------------------------------------------------------------------
