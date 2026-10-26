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
// This RTL describes the CP15 register block. The ports go to the MMU and
// cache unit. This block connects to the CPU core. Coprocessor operations
// supported are read from coprocessor and write to CPU registers or vice
// versa. This is integrated within the processor. The MMU unit can easily
// interface with this block.
//

module zap_cp15_cb

#(
        parameter logic CP15_L4_DEFAULT          = 1'd0,
        parameter logic BE_32_ENABLE             = 1'd0,

        parameter logic [31:0] PHY_REGS          = 32'd64,
        parameter logic [31:0] CODE_CACHE_LINE   = 32'd64,
        parameter logic [31:0] DATA_CACHE_LINE   = 32'd64,
        parameter logic [31:0] CODE_CACHE_SIZE   = 32'd1024,
        parameter logic [31:0] DATA_CACHE_SIZE   = 32'd1024,
        parameter logic [31:0] DATA_CACHE_WAYS   = 32'd1,     // ARM925T: 1 or 2 (zap_cache_tag_ram).

        // ARM925T options (see zap_top). The TI925T register set is
        // described in research/arm925t/CP15.md and docs/CPU.md.
        parameter logic [31:0] CP15_ID           = 32'h0005AAA0,
        parameter logic [31:0] CP15_CTYPE        = 32'd0,
        parameter logic        HIVECS            = 1'd0,

        localparam type t_cp_instruction =
                        struct packed   {
                        logic [11:0]  cp_rsvd_fld_1;          // 31:20 - 12 (32)
                        logic [3:0]  ZAP_CRN;                 // 19:16 - 4 (20)
                        logic [3:0]  cp_srvd_fld_0;           // 15:12 - 4 (16)
                        logic [3:0]  ZAP_CP_ID;               // 11:8 - 4 (12)
                        logic [2:0]  ZAP_OPCODE_2;            // 7:5 - 3 (8)
                        logic [0:0]  cp_rsvd_fld;             // 4   - 1 (5)
                        logic [3:0]  ZAP_CRM;                 // 3:0 - 4 (4)
                        }
)
(
        // ----------------------------------------------------------------
        // Clock and reset.
        // ----------------------------------------------------------------

        input logic                              i_clk,
        input logic                              i_reset,

        // ----------------------------------------------------------------
        // Coprocessor instruction and done signal.
        // ----------------------------------------------------------------

        input t_cp_instruction                   i_cp_word,
        input logic                              i_cp_dav,
        output logic                             o_cp_done,

        // ----------------------------------------------------------------
        // CPSR from processor.
        // ----------------------------------------------------------------

        input  logic     [31:0]                  i_cpsr,

        // ----------------------------------------------------------------
        // Register file RW interface
        // ----------------------------------------------------------------

        // Asserted if we want to control of the register file.
        // Controls a MUX that selects signals.
        output logic                              o_reg_en,

        // Data to write to the register file.
        output logic [31:0]                       o_reg_wr_data,

        // Data read from the register file.
        input logic [31:0]                        i_reg_rd_data,

        // Write and read index for the register file.
        output logic [$clog2(PHY_REGS)-1:0]       o_reg_wr_index,
                                                  o_reg_rd_index,

        // ----------------------------------------------------------------
        // From MMU.
        // ----------------------------------------------------------------

        input logic      [31:0]                  i_fsr,
        input logic      [31:0]                  i_far,

        // -----------------------------------------------------------------
        // MMU configuration signals.
        // -----------------------------------------------------------------

        // Domain Access Control Register.
        output logic      [31:0]                  o_dac,

        // Base address of page table.
        output logic      [31:0]                  o_baddr,

        // MMU enable.
        output logic                              o_mmu_en,
        output logic                              o_wfi,       // ARM925T: waiting for an interrupt (debug)

        // SR register.
        output logic      [1:0]                   o_sr,

        // FCSE register.
        output logic      [7:0]                   o_pid,

        // L4 Enable
        output logic                              o_l4_enable,

        // -----------------------------------------------------------------
        // Invalidate and clean controls.
        // -----------------------------------------------------------------

        // Cache invalidate signal.
        output logic                              o_dcache_inv,
        output logic                              o_icache_inv,

        // Cache clean signal.
        output logic                              o_dcache_clean,
        output logic                              o_icache_clean,

        // TLB invalidate signal - single cycle.
        output logic                              o_dtlb_inv,
        output logic                              o_itlb_inv,

        // Cache enable.
        output logic                              o_dcache_en,
        output logic                              o_icache_en,

        // From MMU. Specify that cache invalidation is done.
        input   logic                            i_dcache_inv_done,
        input   logic                            i_icache_inv_done,

        // From MMU. Specify that cache clean is done.
        input   logic                            i_dcache_clean_done,
        input   logic                            i_icache_clean_done,

        // ARM925T: interrupt lines (after the synchroniser, not masked by the
        // CPSR) end a wait for interrupt.
        input   logic                            i_irq,
        input   logic                            i_fiq,

        // ARM925T: control register V (vectors at 0xFFFF0000) and A
        // (alignment faults).
        output  logic                            o_hivecs,
        output  logic                            o_align_en,

        // ARM925T: single-line D-cache operation (TI925T c7 entry ops):
        // op[0] clean, op[1] invalidate; va = match the tag of addr, else
        // the line of way o_dcache_line_way at addr's index.
        output  logic                            o_dcache_line_req,
        output  logic     [1:0]                  o_dcache_line_op,
        output  logic                            o_dcache_line_va,
        output  logic     [31:0]                 o_dcache_line_addr,
        output  logic                            o_dcache_line_way,
        input   logic                            i_dcache_writeback_busy, // ARM925T: saved victim drain
        input   logic                            i_dcache_line_done
);

`include "zap_localparams.svh"
`include "zap_defines.svh"
`include "zap_functions.svh"

// ---------------------------------------------
// Variables
// ---------------------------------------------

// ARM925T: 16 entries; upstream had 14, so writes to c14/c15 went out of range
// and reads of them returned X.
logic [31:0] r [15:0];// Coprocessor registers. R7, R8 is write-only.
logic [3:0]    state; // State variable.

// ARM925T: TI925T registers (CP15.md section 9).
logic [7:0]  ti_config;   // c15,c1,0: S R O W W C T L, kept as value & 0xE7
logic [31:0] ti_imax;     // c15,c2,0
logic [31:0] ti_imin;     // c15,c3,0
logic [15:0] ti_thread;   // c15,c4,0
logic [31:0] ti_lock_d;   // c10,c0,0 D-TLB lockdown (stored only)
logic [31:0] ti_lock_i;   // c10,c0,1 I-TLB lockdown (stored only)
logic [31:0] ti_rd_data;  // MRC result
logic [2:0]  cp_op1;      // opcode_1 of the current instruction
logic        line_both;   // ARM925T: index op on both "ways" (TI config C = 0)

// ARM925T: line address for an index operand (the set); with one way the
// operand's way w selects one of the two lines that stand in for a set.
function automatic [31:0] index_line ( input [31:0] d, input logic w );
        logic [31:0] a;
        a = '0;
        a[DLINE_LO +: DSET_W] = d[DLINE_LO +: DSET_W];
        if ( DATA_CACHE_WAYS == 1 )
        begin
                a[DLINE_LO + DSET_W] = w;
        end
        return a;
endfunction

// ---------------------------------------------
// Localparams
// ---------------------------------------------

// States.
localparam [3:0] IDLE                 = 0;
localparam [3:0] ACTIVE               = 1;
localparam [3:0] DONE                 = 2;
localparam [3:0] READ                 = 3;
localparam [3:0] READ_DLY             = 4;
localparam [3:0] TERM                 = 5;
localparam [3:0] CLR_D_CACHE_AND      = 6;
localparam [3:0] CLR_D_CACHE          = 7;
localparam [3:0] CLR_I_CACHE          = 8;
localparam [3:0] CLEAN_D_CACHE        = 9;
localparam [3:0] CLFLUSH_ID_CACHE     = 10;
localparam [3:0] CLFLUSH_D_CACHE      = 11;
localparam [3:0] WFI                  = 12; // ARM925T: wait for interrupt.
localparam [3:0] LINE_D               = 13; // ARM925T: single-line D-cache operation.
localparam [3:0] LINE_GAP             = 14; // ARM925T: between the two ways' lines.

// ARM925T: index operands (TI format: way in bit 31, set from bit
// log2(line) up, the part's 256 sets of two ways). With two ways the way
// goes out as o_dcache_line_way; with one, into the line index.
localparam [31:0] DLINE_LO = $clog2(DATA_CACHE_LINE);
localparam [31:0] DSET_W   = $clog2(DATA_CACHE_SIZE / 2 / DATA_CACHE_LINE);

// Register numbers.
localparam [3:0] FSR_REG              = 5;
localparam [3:0] FAR_REG              = 6;
localparam [3:0] CACHE_REG            = 7;
localparam [3:0] TLB_REG              = 8;

//{OPCODE_2, CRM} values that are valid for this implementation.
localparam [6:0] CASE_FLUSH_ID_CACHE       = 7'b000_0111;
localparam [6:0] CASE_FLUSH_I_CACHE        = 7'b000_0101;
localparam [6:0] CASE_FLUSH_D_CACHE        = 7'b000_0110;
localparam [6:0] CASE_CLEAN_ID_CACHE       = 7'b000_1011;
localparam [6:0] CASE_CLEAN_D_CACHE        = 7'b000_1010;
localparam [6:0] CASE_CLFLUSH_ID_CACHE     = 7'b000_1111;
localparam [6:0] CASE_CLFLUSH_D_CACHE      = 7'b000_1110;
localparam [6:0] CASE_FLUSH_ID_TLB         = 7'b00?_0111;
localparam [6:0] CASE_FLUSH_I_TLB          = 7'b00?_0101;
localparam [6:0] CASE_FLUSH_D_TLB          = 7'b00?_0110;

logic [1:0][11:0] xCACHE_TYPE_WORD;
logic [31:0]      CACHE_TYPE_WORD ; // Provides cache info.
logic [31:0]      CTYPE_BUILT;      // ARM925T: built from the cache parameters.

assign xCACHE_TYPE_WORD[0][1:0]  = CODE_CACHE_LINE == 16 ? 2'd1 :
                                   CODE_CACHE_LINE == 32 ? 2'd2 : 2'd3;

assign xCACHE_TYPE_WORD[0][2]    = 1'd0;

assign xCACHE_TYPE_WORD[0][5:3]  = '0;

always_comb
begin
        case(CODE_CACHE_SIZE)
        512  : xCACHE_TYPE_WORD[0][8:6] = 3'd0;
        1024 : xCACHE_TYPE_WORD[0][8:6] = 3'd1;
        2048 : xCACHE_TYPE_WORD[0][8:6] = 3'd2;
        4096 : xCACHE_TYPE_WORD[0][8:6] = 3'd3;
        8192 : xCACHE_TYPE_WORD[0][8:6] = 3'd4;
        16384: xCACHE_TYPE_WORD[0][8:6] = 3'd5;
        32768: xCACHE_TYPE_WORD[0][8:6] = 3'd6;
        65536: xCACHE_TYPE_WORD[0][8:6] = 3'd7;
        default:
        begin
                // Cannot happen - assign X to OPTIMIZE. OK to do for FPGA synth.
                xCACHE_TYPE_WORD[0][8:6] = {3{1'dx}};
                $fatal(2, "Code cache size not in range.");
        end
        endcase
end

assign xCACHE_TYPE_WORD[0][11:9] = '0;

assign xCACHE_TYPE_WORD[1][1:0]  = DATA_CACHE_LINE == 16 ? 2'd1 :
                                   DATA_CACHE_LINE == 32 ? 2'd2 : 2'd3;

assign xCACHE_TYPE_WORD[1][2]    = 1'd0;

assign xCACHE_TYPE_WORD[1][5:3]  = '0;

always_comb
begin
        case(DATA_CACHE_SIZE)
        512  : xCACHE_TYPE_WORD[1][8:6] = 3'd0;
        1024 : xCACHE_TYPE_WORD[1][8:6] = 3'd1;
        2048 : xCACHE_TYPE_WORD[1][8:6] = 3'd2;
        4096 : xCACHE_TYPE_WORD[1][8:6] = 3'd3;
        8192 : xCACHE_TYPE_WORD[1][8:6] = 3'd4;
        16384: xCACHE_TYPE_WORD[1][8:6] = 3'd5;
        32768: xCACHE_TYPE_WORD[1][8:6] = 3'd6;
        65536: xCACHE_TYPE_WORD[1][8:6] = 3'd7;
        default:
        begin
                // Cannot happen - assign X to OPTIMIZE. OK to do for FPGA synth.
                xCACHE_TYPE_WORD[1][8:6] = {3{1'dx}};
                $fatal(2, "Data cache size not in range.");
        end
        endcase
end

assign xCACHE_TYPE_WORD[1][11:9] = '0;

////////////////////////////////////////////////////////////////////////////

// Build the CACHE_TYPE word.
assign CTYPE_BUILT[23:0]         = xCACHE_TYPE_WORD;
assign CTYPE_BUILT[24]           = 1'd1;     // S = 1, split cache.
assign CTYPE_BUILT[31:25]        = 7'h1;     // Block replacement policy = 0x1.

// ARM925T: CP15_CTYPE, when given, is reported instead (the ARM925T's
// 0x05109149: 2-way, 16-byte lines, 16 KB I, 8 KB D).
assign CACHE_TYPE_WORD           = CP15_CTYPE != 32'd0 ? CP15_CTYPE : CTYPE_BUILT;

assign cp_op1 = i_cp_word[23:21];

//
// ARM925T: what MRC reads. Registers without contents read 0
// (CP15.md: c4, c7, c8, c9, c11, c12, c14 and unused c15 entries are UNP or
// write-only); the ID depends on the TI configuration O bit (part 0x915 when
// set, as QEMU's ti925t does).
//
always_comb
begin
        case ( i_cp_word.ZAP_CRN )
        4'd0:    ti_rd_data = i_cp_word.ZAP_OPCODE_2 == 3'd1 ? CACHE_TYPE_WORD :
                              ti_config[5] ? (CP15_ID ^ 32'h0000_0300) : CP15_ID;
        4'd1,
        4'd2,
        4'd3,
        4'd5,
        4'd6,
        4'd13:   ti_rd_data = r[ i_cp_word.ZAP_CRN ];
        4'd10:   ti_rd_data = i_cp_word.ZAP_OPCODE_2[0] ? ti_lock_i : ti_lock_d;
        4'd15:
        begin
                if ( cp_op1 != 3'd0 )
                        ti_rd_data = 32'd0;
                else
                case ( i_cp_word.ZAP_CRM )
                4'd1:    ti_rd_data = {24'd0, ti_config};
                4'd2:    ti_rd_data = ti_imax;
                4'd3:    ti_rd_data = ti_imin;
                4'd4:    ti_rd_data = {16'd0, ti_thread};
                default: ti_rd_data = 32'd0; // c15,c8,0 status: nothing to report.
                endcase
        end
        default: ti_rd_data = 32'd0;
        endcase
end

// ---------------------------------------------
// Sequential Logic
// ---------------------------------------------

// Ties registers to output ports via a register.
always_ff @ ( posedge i_clk )
begin
        if ( i_reset )
        begin
                o_dcache_en <= 1'd0;
                o_icache_en <= 1'd0;
                o_mmu_en    <= 1'd0;
                o_pid       <= 8'd0;
                o_l4_enable <= 1'd1;
                o_hivecs    <= HIVECS;
                o_align_en  <= 1'd0;
        end
        else
        begin
                o_dcache_en <= r[1][2];              // Data cache enable.
                o_icache_en <= r[1][12];             // Instruction cache enable.
                o_mmu_en    <= r[1][0];              // MMU enable.
                o_pid       <= {1'd0, r[13][31:25]}; // PID register.

                // ARM925T: ARMv4T interworking is fixed with V4T (no L4 bit).
                o_l4_enable <= 1'd1; // ARMv4T: no L4 (loads to PC interwork).
                o_hivecs    <= r[1][13];
                o_align_en  <= r[1][1];
        end
end

// Ties register ports via register.
always_ff @ ( posedge i_clk )
begin
        o_dac       <= r[3];                     // DAC register.
        o_baddr     <= r[2];                     // Base address.
        o_sr        <= {r[1][8],r[1][9]};        // SR register.
end

// Core logic.
always_ff @ ( posedge i_clk )
begin
        if ( i_reset )
        begin
                state          <= IDLE;
                o_dcache_inv   <= 1'd0;
                o_icache_inv   <= 1'd0;
                o_dcache_clean <= 1'd0;
                o_icache_clean <= 1'd0;
                o_dtlb_inv     <= 1'd0;
                o_itlb_inv     <= 1'd0;
                o_reg_en       <= 1'd0;
                o_cp_done      <= 1'd0;
                o_reg_wr_data  <= 0;
                o_reg_wr_index <= 0;
                o_reg_rd_index <= 0;
                r[0]           <= 0;
                r[1]           <= 0;
                r[1][14]       <= CP15_L4_DEFAULT;
                r[2]           <= 32'd0;
                r[3]           <= 32'd0;
                r[4]           <= 32'd0;
                r[5]           <= 32'd0;
                r[6]           <= 32'd0;
                r[13]          <= 32'd0;
                r[0][15:4]     <= 12'hAAA;
                r[0][19:16]    <= 4'h5;
                r[1][7]        <= BE_32_ENABLE;
                r[1][6:3]      <= 4'b1111;
                r[1][11]       <= 1'd1;

                // ARM925T: control register 0x70 with V from HIVECS; TI config
                // with L (SWP lock) set; I_min/I_max as after a flush.
                r[1]   <= {18'd0, HIVECS, 13'h0070};

                ti_config      <= 8'h01;
                ti_imax        <= 32'd0;
                ti_imin        <= 32'h0000_0FF0;
                ti_thread      <= 16'd0;
                ti_lock_d      <= 32'd0;
                ti_lock_i      <= 32'd0;
                o_dcache_line_req  <= 1'd0;
                o_dcache_line_op   <= 2'd0;
                o_dcache_line_va   <= 1'd0;
                o_dcache_line_addr <= 32'd0;
                o_dcache_line_way  <= 1'd0;
                line_both          <= 1'd0;
        end
        else
        begin
                // ====================================
                // Default values section.
                // ====================================

                o_itlb_inv      <= 1'd0;
                o_dtlb_inv      <= 1'd0;
                o_dcache_inv    <= 1'd0;
                o_icache_inv    <= 1'd0;
                o_icache_clean  <= 1'd0;
                o_dcache_clean  <= 1'd0;
                o_reg_en        <= 1'd0;
                o_cp_done       <= 1'd0;

                // ===================================
                // FSM Code
                // ===================================

                case ( state )
                IDLE: // Idle state.
                begin
                        o_cp_done <= 1'd0;

                        // Keep monitoring FSR and FAR from MMU unit. If
                        // produced, clock them in.
                        if ( i_fsr[3:0] != 4'd0 )
                        begin
                                r[FSR_REG] <= i_fsr;
                                r[FAR_REG] <= i_far;
                        end

                        // Coprocessor instruction.
                        if ( i_cp_dav && i_cp_word.ZAP_CP_ID == 15 )
                        begin
                                if ( i_cpsr[ZAP_CPSR_MODE:0] != USR )
                                begin
                                        // ACTIVATE this block.
                                        state     <= ACTIVE;
                                        o_cp_done <= 1'd0;
                                end
                                else
                                begin
                                        // No permissions in USR land.
                                        // Pretend to be done and go ahead.
                                        o_cp_done <= 1'd1;
                                end
                        end
                end

                DONE: // Complete transaction.
                begin
                        // Tell that we are done.
                        o_cp_done    <= 1'd1;
                        state        <= TERM;
                end

                TERM: // Wait state before going to IDLE.
                begin
                        state <= IDLE;
                end

                READ_DLY: // Register data is clocked out in this stage.
                begin
                        state <= READ;
                end

                READ: // Write value read from CPU register to coprocessor.
                begin
                        state <= DONE;

                        begin
                                //
                                // ARM925T: TI925T register writes. c0, c4, c9, c11,
                                // c12, c14 ignore writes; c7/c8 are operations.
                                //
                                case ( i_cp_word.ZAP_CRN )
                                4'd1:
                                begin
                                        // M A C W, S R, I V are writable; 6:4 read 1,
                                        // B (7) reads 0 (little-endian only).
                                        r[1] <= {18'd0, i_reg_rd_data[13:12], 2'b00,
                                                 i_reg_rd_data[9:8], 1'b0, 3'b111,
                                                 i_reg_rd_data[3:0]};
                                end
                                4'd2, 4'd3, 4'd5, 4'd6:
                                begin
                                        r[ i_cp_word.ZAP_CRN ] <= i_reg_rd_data;
                                end
                                4'd13:
                                begin
                                        r[13] <= i_reg_rd_data & 32'hFE00_0000; // PID 31:25
                                end
                                4'd10:
                                begin
                                        // Base 31:26, victim 25:20, P 0. Stored only:
                                        // the TLBs here are direct-mapped.
                                        if ( i_cp_word.ZAP_OPCODE_2[0] )
                                                ti_lock_i <= i_reg_rd_data & 32'hFFF0_0001;
                                        else
                                                ti_lock_d <= i_reg_rd_data & 32'hFFF0_0001;
                                end
                                4'd15:
                                begin
                                        if ( cp_op1 == 3'd0 )
                                        begin
                                                case ( i_cp_word.ZAP_CRM )
                                                4'd1: ti_config <= i_reg_rd_data[7:0] & 8'hE7;
                                                4'd2: ti_imax   <= i_reg_rd_data;
                                                4'd3: ti_imin   <= i_reg_rd_data;
                                                4'd4: ti_thread <= i_reg_rd_data[15:0];
                                                4'd8:
                                                begin
                                                        // c15,c8,2 is the legacy WFI;
                                                        // QEMU's ti925t takes c15,c8,0.
                                                        if ( i_cp_word.ZAP_OPCODE_2 == 3'd0 ||
                                                             i_cp_word.ZAP_OPCODE_2 == 3'd2 )
                                                        begin
                                                                state <= WFI;
                                                        end
                                                end
                                                default: ;
                                                endcase
                                        end
                                        // op1 = 7, c15,c0,0 (Linux "write-back off"): ignored.
                                end
                                default: ;
                                endcase
                        end

                        if
                        (
                                i_cp_word.ZAP_CRN == TLB_REG  // TLB control.
                        )
                        begin
                                casez({i_cp_word.ZAP_OPCODE_2,
                                       i_cp_word.ZAP_CRM})

                                CASE_FLUSH_ID_TLB:
                                begin
                                        o_itlb_inv  <= 1'd1;
                                        o_dtlb_inv  <= 1'd1;
                                end

                                CASE_FLUSH_I_TLB:
                                begin
                                        o_itlb_inv <= 1'd1;
                                end

                                CASE_FLUSH_D_TLB:
                                begin
                                        o_dtlb_inv <= 1'd1;
                                end

                                default:
                                begin
                                        o_itlb_inv <= 1'd1;
                                        o_dtlb_inv <= 1'd1;
                                end

                                endcase
                        end
                        else if ( i_cp_word.ZAP_CRN == CACHE_REG )
                        // ARM925T: TI925T cache operations (CP15.md section 6).
                        // D-cache entry operations act on one line (LINE_D);
                        // invalidating an I-cache entry invalidates the whole
                        // I-cache, which is safe (it holds no dirty data).
                        begin
                                // Any cache operation resets the dirty-index
                                // registers, as QEMU's ti925t does.
                                ti_imax <= 32'd0;
                                ti_imin <= 32'h0000_0FF0;

                                casez({i_cp_word.ZAP_OPCODE_2,
                                       i_cp_word.ZAP_CRM})

                                7'b000_0111: // c7,c7,0: flush I and D
                                begin
                                        o_dcache_inv    <= 1'd1;
                                        state           <= CLR_D_CACHE_AND;
                                end

                                7'b0??_0101: // c7,c5,0/1: flush I (entry)
                                begin
                                        o_icache_inv    <= 1'd1;
                                        state           <= CLR_I_CACHE;
                                end

                                7'b000_0110: // c7,c6,0: flush D (no clean)
                                begin
                                        o_dcache_inv    <= 1'd1;
                                        state           <= CLR_D_CACHE;
                                end

                                7'b000_1010: // c7,c10,0: clean D
                                begin
                                        o_dcache_clean  <= 1'd1;
                                        state           <= CLEAN_D_CACHE;
                                end

                                //
                                // Single-line D-cache operations: by VA (op2 1:
                                // the line is touched only if it holds that VA)
                                // and by index (op2 2: TI operand; with TI
                                // config C = 0 both "ways" of the set, i.e. both
                                // lines here, with C = 1 the way in bit 31).
                                //
                                7'b001_0110, 7'b010_0110, // c7,c6,1/2: flush (discard)
                                7'b001_1010, 7'b010_1010, // c7,c10,1/2: clean
                                7'b001_1110, 7'b010_1110: // c7,c14,1/2: clean and flush
                                begin
                                        o_dcache_line_op   <= { i_cp_word.ZAP_CRM[2],     // 0110, 1110: flush
                                                                i_cp_word.ZAP_CRM[3] };   // 1010, 1110: clean
                                        o_dcache_line_va   <= i_cp_word.ZAP_OPCODE_2[0];
                                        o_dcache_line_addr <= i_cp_word.ZAP_OPCODE_2[0] ? i_reg_rd_data :
                                                              index_line ( i_reg_rd_data,
                                                                           ti_config[2] ? i_reg_rd_data[31] : 1'd0 );
                                        o_dcache_line_way  <= DATA_CACHE_WAYS == 1 ? 1'd0 :
                                                              ti_config[2] ? i_reg_rd_data[31] : 1'd0;
                                        line_both          <= !i_cp_word.ZAP_OPCODE_2[0] && !ti_config[2];
                                        o_dcache_line_req  <= 1'd1;
                                        state              <= LINE_D;
                                end

                                7'b000_1110: // c7,c14,0 (not ARM925T): clean+flush D
                                begin
                                        o_dcache_clean  <= 1'd1;
                                        state           <= CLFLUSH_D_CACHE;
                                end

                                7'b100_1010: // c7,c10,4: drain the saved dirty victim.
                                begin
                                        // No added cycle when the buffer is empty.
                                        state <= i_dcache_writeback_busy ? ACTIVE : DONE;
                                end

                                7'b001_1101: // c7,c13,1: prefetch I-cache line
                                begin
                                        state           <= DONE;
                                end

                                7'b100_0000: // c7,c0,4: wait for interrupt
                                begin
                                        state           <= WFI;
                                end

                                default: // Not an ARM925T operation: clean+flush both.
                                begin
                                        o_dcache_clean  <= 1'd1;
                                        state           <= CLFLUSH_ID_CACHE;
                                end
                                endcase
                        end
                        else if ( i_cp_word.ZAP_CRN == CACHE_REG )
                        // Cache control selected.
                        begin
                                casez({i_cp_word.ZAP_OPCODE_2,
                                       i_cp_word.ZAP_CRM})

                                CASE_FLUSH_ID_CACHE:
                                begin
                                        // Invalidate ALL caches.
                                        o_dcache_inv    <= 1'd1;
                                        state           <= CLR_D_CACHE_AND;
                                end

                                CASE_FLUSH_D_CACHE:
                                begin

                                        // Invalidate data cache.
                                        o_dcache_inv    <= 1'd1;
                                        state           <= CLR_D_CACHE;
                                end

                                CASE_FLUSH_I_CACHE:
                                begin

                                        // Invalidate instruction cache.
                                        o_icache_inv    <= 1'd1;
                                        state           <= CLR_I_CACHE;
                                end

                                CASE_CLEAN_ID_CACHE, CASE_CLEAN_D_CACHE:
                                begin
                                        // Clean D cache.
                                        o_dcache_clean <= 1'd1;
                                        state          <= CLEAN_D_CACHE;
                                end

                                CASE_CLFLUSH_D_CACHE:
                                begin
                                        // Clean D cache.
                                        o_dcache_clean <= 1'd1;
                                        state          <= CLFLUSH_D_CACHE;
                                end

                                CASE_CLFLUSH_ID_CACHE:
                                begin
                                        // Clean D cache.
                                        o_dcache_clean <= 1'd1;
                                        state          <= CLFLUSH_ID_CACHE;
                                end

                                default:
                                begin
                                        // Clean D cache.
                                        o_dcache_clean <= 1'd1;
                                        state          <= CLFLUSH_ID_CACHE;
                                end

                                endcase
                        end
                end

                CLEAN_D_CACHE,
                CLFLUSH_ID_CACHE,
                CLFLUSH_D_CACHE:
                begin
                        o_dcache_clean <= 1'd1;

                        if ( i_dcache_clean_done )
                        begin
                                o_dcache_clean <= 1'd0;

                                if ( state == CLFLUSH_D_CACHE )
                                begin
                                        o_dcache_inv    <= 1'd1;
                                        state           <= CLR_D_CACHE;
                                end
                                else if ( state == CLFLUSH_ID_CACHE )
                                begin
                                        o_dcache_inv    <= 1'd1;
                                        state           <= CLR_D_CACHE_AND;
                                end
                                else // Clean D cache alone.
                                begin
                                        state <= DONE;
                                end
                        end
                end

                CLR_D_CACHE, CLR_D_CACHE_AND: // Clear data cache.
                begin
                        o_dcache_inv <= 1'd1;

                        // Wait for cache invalidation to complete.
                        if ( i_dcache_inv_done && state == CLR_D_CACHE )
                        begin
                                o_dcache_inv <= 1'd0;
                                state        <= DONE;
                        end
                        else if ( state == CLR_D_CACHE_AND && i_dcache_inv_done )
                        begin
                                o_dcache_inv <= 1'd0;
                                o_icache_inv <= 1'd1;
                                state        <= CLR_I_CACHE;
                        end
                end

                CLR_I_CACHE: // Clear instruction cache.
                begin
                        o_icache_inv <= 1'd1;

                        if ( i_icache_inv_done )
                        begin
                                o_icache_inv <= 1'd0;
                                state        <= DONE;
                        end
                end

                LINE_D: // ARM925T: single-line operation in progress.
                begin
                        o_dcache_line_req <= 1'd1;

                        if ( i_dcache_line_done )
                        begin
                                o_dcache_line_req <= 1'd0;

                                if ( line_both )
                                begin
                                        // and the other way's line
                                        line_both <= 1'd0;
                                        if ( DATA_CACHE_WAYS == 1 )
                                        begin
                                                o_dcache_line_addr[DLINE_LO + DSET_W] <= 1'd1;
                                        end
                                        else
                                        begin
                                                o_dcache_line_way <= 1'd1;
                                        end
                                        state     <= LINE_GAP;
                                end
                                else
                                begin
                                        state                                      <= DONE;
                                end
                        end
                end

                LINE_GAP: // ARM925T: request low for a cycle between two lines.
                begin
                        o_dcache_line_req <= 1'd1;
                        state             <= LINE_D;
                end

                WFI: // ARM925T: wait until IRQ or FIQ is asserted (masked or not).
                begin
                        if ( i_irq || i_fiq )
                        begin
                                state        <= DONE;
                        end
                end

                ACTIVE: // Access processor registers.
                begin
                        if ( is_cc_satisfied ( i_cp_word[31:28], i_cpsr[31:28] ) ||
                             i_cp_word ==? MRC2 ||
                             i_cp_word ==? MCR2 ||
                             i_cp_word ==? LDC2 ||
                             i_cp_word ==? STC2 )
                        begin
                                        if ( i_cp_word[20] ) // Load to CPU reg.
                                        begin
                                                // Register write command.
                                                o_reg_en        <= 1'd1;
                                                o_reg_wr_index  <= translate( {1'd0, i_cp_word[15:12]}, i_cpsr[ZAP_CPSR_MODE:0] );
                                                o_reg_wr_data   <= ti_rd_data;
                                                state           <= DONE;
                                        end
                                        else // Store from CPU register.
                                        begin
                                                // Generate CPU register read command. CP write.
                                                o_reg_en        <= 1'd1;
                                                o_reg_rd_index  <= translate({1'd0, i_cp_word[15:12]}, i_cpsr[ZAP_CPSR_MODE:0]);
                                                o_reg_wr_index  <= 16;
                                                state <= READ_DLY;
                                        end
                        end
                        else
                        begin
                                state <= DONE;
                        end
                end

                // ======================================
                // Default Section (For Better Synth)
                // ======================================

                default: // X propagate
                begin
                        state          <= 'x; //
                        o_dcache_inv   <= 'x; //
                        o_icache_inv   <= 'x; //
                        o_dcache_clean <= 'x; //
                        o_icache_clean <= 'x; //
                        o_dtlb_inv     <= 'x; //
                        o_itlb_inv     <= 'x; //
                        o_reg_en       <= 'x; //
                        o_cp_done      <= 'x; //
                        o_reg_wr_data  <= 'x; //
                        o_reg_wr_index <= 'x; //
                        o_reg_rd_index <= 'x; //

                        foreach(r[i])
                                r[i] <= 'x;
                end

                endcase

                // ======================================
                // Constants Section
                // ======================================

                r[0][3:0]   <= 4'd0;
                r[0][15:4]  <= 12'hAAA;
                r[0][19:16] <= 4'h5;
                r[0][23:20] <= 4'd0;
                r[0][31:24] <= 8'd0;

                        // ARM925T: bits 31:14, 11:10 and 7 read 0, 6:4 read 1.
                r[1][31:14] <= 18'd0;
                r[1][11:10] <= 2'd0;
                r[1][7:4]   <= 4'b0111;


        end
end

// For debugging.

logic [31:0] r0;
logic [31:0] r1;
logic [31:0] r2;
logic [31:0] r3;
logic [31:0] r4;
logic [31:0] r5;
logic [31:0] r6;

assign r0 = r[0];
assign r1 = r[1];
assign r2 = r[2];
assign r3 = r[3];
assign r4 = r[4];
assign r5 = r[5];
assign r6 = r[6];

logic unused;

assign unused = |{r0, r1, r2, r3, r4, r5, r6, i_cpsr[27:5],
                  i_icache_clean_done, r[14], r[15], r[4], r[7], r[8], r[9],
                  r[10], r[11], r[12]};

// ARM925T: the wait-for-interrupt state, for the debug counters.
assign o_wfi = state == WFI;

endmodule : zap_cp15_cb

// ============================================================================
// END OF FILE
// ============================================================================
