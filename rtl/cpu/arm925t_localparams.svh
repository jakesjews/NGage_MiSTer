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
// Part of the N-Gage QD core's ARM925T (rtl/cpu). Derived from ZAP's
// zap_localparams.svh; the changes made for this core are marked "ARM925T:"
// and are listed in rtl/cpu/NOTICE and docs/CPU.md.
//

// We can safely turn of UNSED warnings since this file is a common include file, so some local params will end being
// unused in some files anyway.

/* verilator lint_off UNUSED */

// Identifier for L1
localparam [1:0] SECTION_ID = 2'b10;
localparam [1:0] PAGE_ID    = 2'b01;
localparam [1:0] FINE_ID    = 2'b11; // Fine page.

// Identifier for L2
localparam [1:0] SPAGE_ID   = 2'b10;
localparam [1:0] LPAGE_ID   = 2'b01;
localparam [1:0] FPAGE_ID   = 2'b11; // Fine page.

// APSR bits.
// K  U (kernel user) permissions.
localparam [3:0] APSR_NA_NA = 4'b00_00;
localparam [3:0] APSR_RO_RO = 4'b00_01;
localparam [3:0] APSR_RO_NA = 4'b00_10;
localparam [3:0] APSR_RW_NA = 4'b01_??;
localparam [3:0] APSR_RW_RO = 4'b10_??;
localparam [3:0] APSR_RW_RW = 4'b11_??;

// DAC bits.
localparam [1:0] DAC_MANAGER = 2'b11;
localparam [1:0] DAC_CLIENT  = 2'b01;

// Section.
localparam [3:0] FSR_SECTION_DOMAIN_FAULT      = 4'b1001;
localparam [3:0] FSR_SECTION_TRANSLATION_FAULT = 4'b0101;
localparam [3:0] FSR_SECTION_PERMISSION_FAULT  = 4'b1101;
localparam [3:0] FSR_L1_EXTERNAL_ABORT         = 4'b1100;

// Page.
localparam [3:0] FSR_PAGE_TRANSLATION_FAULT    = 4'b0111;
localparam [3:0] FSR_PAGE_DOMAIN_FAULT         = 4'b1011;
localparam [3:0] FSR_PAGE_PERMISSION_FAULT     = 4'b1111;
localparam [3:0] FSR_L2_EXTERNAL_ABORT         = 4'b1110;

// Terminal exception
parameter [3:0] TERMINAL_EXCEPTION              = 4'b0010;

//////////////////////
// Opcodes
//////////////////////

// Standard opcodes.
// These map to the opcode map in the spec.
localparam [3:0] AND   = 4'd0;
localparam [3:0] EOR   = 4'd1;
localparam [3:0] SUB   = 4'd2;
localparam [3:0] RSB   = 4'd3;
localparam [3:0] ADD   = 4'd4;
localparam [3:0] ADC   = 4'd5;
localparam [3:0] SBC   = 4'd6;
localparam [3:0] RSC   = 4'd7;
localparam [3:0] TST   = 4'd8;
localparam [3:0] CMP   = 4'd10;
localparam [3:0] CMN   = 4'd11;
localparam [3:0] ORR   = 4'd12;
localparam [3:0] MOV   = 4'd13;
localparam [3:0] BIC   = 4'd14;
localparam [3:0] MVN   = 4'd15;

// Internal opcodes used to
// implement some instructions.
localparam [4:0] MUL   = 5'd16; // Multiply ( 32 x 32 = 32 ) -> Translated to MAC.
localparam [4:0] MLA   = 5'd17; // Multiply-Accumulate ( 32 x 32 + 32 = 32 ).

// Flag MOV. Will write upper 4-bits to flags if mask bit [3] is set to 1.
// Also writes to target register similarly.
// Mask bit comes from non-shift operand.
localparam [4:0] FMOV  = 5'd18;

localparam [4:0] CLZ    = 5'd24; // Count Leading zeros.

// FADD - Directly access flags.
localparam [5:0] FADD     = 6'd62;

// Conditionals defined as per v5T spec.
localparam [3:0] EQ =  4'h0;
localparam [3:0] NE =  4'h1;
localparam [3:0] CS =  4'h2;
localparam [3:0] CC =  4'h3;
localparam [3:0] MI =  4'h4;
localparam [3:0] PL =  4'h5;
localparam [3:0] VS =  4'h6;
localparam [3:0] VC =  4'h7;
localparam [3:0] HI =  4'h8;
localparam [3:0] LS =  4'h9;
localparam [3:0] GE =  4'hA;
localparam [3:0] LT =  4'hB;
localparam [3:0] GT =  4'hC;
localparam [3:0] LE =  4'hD;
localparam [3:0] AL =  4'hE;
localparam [3:0] NV =  4'hF; // NeVer execute!

// CPSR flags.
localparam [31:0] N             = 32'd31;
localparam [31:0] Z             = 32'd30;
localparam [31:0] C             = 32'd29;
localparam [31:0] V             = 32'd28;
localparam [31:0] Q             = 32'd27;
localparam [31:0] I             = 32'd7;
localparam [31:0] F             = 32'd6;
localparam [31:0] T             = 32'd5;
localparam [31:0] ARM925T_CPSR_MODE = 32'd4;

// Processor Modes
localparam [4:0] FIQ = 5'b10_001;
localparam [4:0] IRQ = 5'b10_010;
localparam [4:0] ABT = 5'b10_111;
localparam [4:0] SVC = 5'b10_011;
localparam [4:0] USR = 5'b10_000;
localparam [4:0] SYS = 5'b11_111;
localparam [4:0] UND = 5'b11_011;

// PLD (NOP)
localparam      [31:0]  PLD                                             =  32'b1111_01?1?101_????_1111_????????????;

// BL never reaches the unit.

localparam      [31:0]  MRS                                             =  32'b????_00010_?_001111_????_????_????_????;

localparam      [31:0]  MSR                                             =  32'b????_00_0_10?10_????_1111_????_????_????;

// Write to coprocessor.
localparam      [31:0]  MCR                                             =  32'b????_1110_???_0_????_????_1111_???_1_????;
localparam      [31:0]  MCR2                                            =  32'b1111_1110???0_????????????_???1_????;

// Read from coprocessor.
localparam      [31:0]  MRC                                             =  32'b????_1110_???_1_????_????_1111_???_1_????;
localparam      [31:0]  MRC2                                            =  32'b1111_1110???1_????????????_???1_????;

// LDC, STC
localparam      [31:0]  LDC                                             =  32'b????_110_????1_????_????_????_????????;
localparam      [31:0]  STC                                             =  32'b????_110_????0_????_????_????_????????;

// LDC2, STC2
localparam      [31:0]  LDC2                                            =  32'b1111_110????1_????????????_????_????;
localparam      [31:0]  STC2                                            =  32'b1111_110????0_????????????_????_????;

// CDP
localparam      [31:0]  CDP                                             =  32'b????_1110_????????_????????_????????;

// BLX(1)
localparam      [31:0] BLX1                                             =  32'b1111_101_?_????????_????????_????????;

// BKPT
localparam      [31:0] BKPT                                             =  32'b1110_00010010_????_????_????_0111_????;

//B
localparam      [15:0]  T_BRANCH_COND                                   =  16'b1101_????_????????; // Overlaps with SWI.
localparam      [15:0]  T_BRANCH_NOCOND                                 =  16'b11100_???????????;
localparam      [15:0]  T_BL                                            =  16'b1111_?_???????????;
localparam      [15:0]  T_BLX1                                          =  16'b11101_???????????;
localparam      [15:0]  T_BLX2                                          =  16'b010001111_?_???_000;
localparam      [15:0]  T_BX                                            =  16'b010001110_?_???_000;

// SWI
localparam      [15:0]  T_SWI                                           =  16'b1101_1111_????????;

// Shifts.
localparam      [15:0]  T_SHIFT                                         =  16'b000_??_?????_???_???;

// Add sub LO.
localparam      [15:0]  T_ADD_SUB_LO                                    =  16'b00011_?_?_???_???_???;

// MCAS Imm.
localparam      [15:0]  T_MCAS_IMM                                      =  16'b001_??_???_????????;

// ALU Lo.
localparam      [15:0]  T_ALU_LO                                        =  16'b010000_????_???_???;

// ALU hi.
localparam      [15:0]  T_ALU_HI                                        =  16'b010001_??_?_?_???_???;

// Get address.
localparam      [15:0]  T_GET_ADDR                                      =  16'b1010_?_???_????????;

// Add offset to SP.
localparam      [15:0]  T_MOD_SP                                        =  16'b10110000_?_????_???;

// PC relative load.
localparam      [15:0]  T_PC_REL_LOAD                                   =  16'b01001_???_????????;

// LDR_STR_5BIT_OFF
localparam      [15:0] T_LDR_STR_5BIT_OFF                               =  16'b011_?_?_?????_???_???;

// LDRH_STRH_5BIT_OFF
localparam      [15:0] T_LDRH_STRH_5BIT_OFF                             =  16'b1000_?_?????_???_???;

// Signed LDR/STR
localparam      [15:0]  T_LDRH_STRH_REG                                 =  16'b0101_???_???_???_???;

// SP relative LDR/STR
localparam      [15:0]  T_SP_REL_LDR_STR                                =  16'b1001_?_???_????????;

// LDMIA/STMIA
localparam      [15:0]  T_LDMIA_STMIA                                   =  16'b1100_?_???_????????;

// PUSH POP
localparam      [15:0]  T_POP_PUSH                                      =  16'b1011_?_10_?_????????;

// BKPT
localparam      [15:0]  T_BKPT                                          =  16'b10111110_????????;

///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

//
// Architectural Registers.
// Architectural registers are registered defined by the architecture plus
// a few more. Basically instructions index into architectural registers.
//

localparam [31:0] TOTAL_ARCH_REGS = 28;
localparam [3:0] ARCH_SP                                 = 13;
localparam [3:0] ARCH_PC                                 = 15;
localparam [$clog2(TOTAL_ARCH_REGS)-1:0] RAZ_REGISTER    = 16; // Serves as $0 does on MIPS.
localparam [$clog2(TOTAL_ARCH_REGS)-1:0] ARCH_USR2_R8    = 18;
localparam [$clog2(TOTAL_ARCH_REGS)-1:0] ARCH_USR2_R9    = 19;
localparam [$clog2(TOTAL_ARCH_REGS)-1:0] ARCH_USR2_R10   = 20;
localparam [$clog2(TOTAL_ARCH_REGS)-1:0] ARCH_USR2_R11   = 21;
localparam [$clog2(TOTAL_ARCH_REGS)-1:0] ARCH_USR2_R12   = 22;
localparam [$clog2(TOTAL_ARCH_REGS)-1:0] ARCH_USR2_R13   = 23;
localparam [$clog2(TOTAL_ARCH_REGS)-1:0] ARCH_USR2_R14   = 24;
localparam [$clog2(TOTAL_ARCH_REGS)-1:0] ARCH_DUMMY_REG0 = 25;
localparam [$clog2(TOTAL_ARCH_REGS)-1:0] ARCH_DUMMY_REG1 = 26;
localparam [$clog2(TOTAL_ARCH_REGS)-1:0] ARCH_CPSR       = 17;
localparam [$clog2(TOTAL_ARCH_REGS)-1:0] ARCH_CURR_SPSR  = 27; // Alias to real SPSR.

//
// Physical registers.
// Physical registers can be mapped directly into the internal
// register file.
//

localparam [31:0] TOTAL_PHY_REGS                           = 40;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_PC            = 15; // DO NOT CHANGE!
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_RAZ_REGISTER  = 16; // DO NOT CHANGE!
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_CPSR          = 17; // DO NOT CHANGE!
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_USR_R0        = 0;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_USR_R1        = 1;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_USR_R2        = 2;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_USR_R3        = 3;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_USR_R4        = 4;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_USR_R5        = 5;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_USR_R6        = 6;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_USR_R7        = 7;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_USR_R8        = 8;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_USR_R9        = 9;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_USR_R10       = 10;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_USR_R11       = 11;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_USR_R12       = 12;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_USR_R13       = 13;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_USR_R14       = 14;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_FIQ_R8        = 18;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_FIQ_R9        = 19;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_FIQ_R10       = 20;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_FIQ_R11       = 21;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_FIQ_R12       = 22;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_FIQ_R13       = 23;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_FIQ_R14       = 24;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_IRQ_R13       = 25;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_IRQ_R14       = 26;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_SVC_R13       = 27;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_SVC_R14       = 28;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_UND_R13       = 29;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_UND_R14       = 30;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_ABT_R13       = 31;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_ABT_R14       = 32;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_DUMMY_REG0    = 33;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_DUMMY_REG1    = 34;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_FIQ_SPSR      = 35;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_IRQ_SPSR      = 36;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_SVC_SPSR      = 37;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_UND_SPSR      = 38;
localparam  [$clog2(TOTAL_PHY_REGS)-1:0] PHY_ABT_SPSR      = 39;

// Shift type.
localparam [1:0] LSL     = 0;
localparam [1:0] LSR     = 1;
localparam [1:0] ASR     = 2;
localparam [1:0] ROR     = 3;
localparam [2:0] RRC     = 4; // Encoded as ROR #0.
localparam [2:0] ROR_1   = 6; // ROR with instruction specified shift.

// Wishbone CTI.
localparam [2:0] CTI_BURST    = 3'b010;
localparam [2:0] CTI_EOB      = 3'b111;

// Branches
localparam  [1:0]    WT      =       2'b10; // Weakly Taken.

// Extension field bits.

/* verilator lint_on UNUSED */
