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
// zap_tlb_check.sv; the changes made for this core are marked "ARM925T:"
// and are listed in rtl/cpu/NOTICE and docs/CPU.md.
//
// Examines TLB entries to authorize access.
//

`include "arm925t_defines.svh"

module arm925t_tlb_check #(

        parameter logic [31:0] LPAGE_TLB_ENTRIES   = 32'd32,
        parameter logic [31:0] SPAGE_TLB_ENTRIES   = 32'd256,
        parameter logic [31:0] SECTION_TLB_ENTRIES = 32'd64,
        parameter logic [31:0] FPAGE_TLB_ENTRIES   = 32'd64,
        parameter logic [31:0] CPSR_MODE           = 32'd4,
        // ARM925T: ways of the small-page TLB (1, 2 or 4), each of
        // SPAGE_TLB_ENTRIES sets (arm925t_tlb).
        parameter logic [31:0] SPAGE_TLB_WAYS      = 32'd2,
        // ARM925T: accesses with the MMU off are cacheable (1 for the
        // instruction side: with the MMU off and the I-cache on, every
        // instruction fetch is cacheable; data accesses are not).
        parameter logic        MMU_OFF_CACHEABLE   = 1'd0

)
(
input logic                              i_clk,          // Clock signal.
input logic                              i_clkena,       // Clock enable.

input logic                              i_mmu_en,       // MMU enable.

input logic [31:0]                       i_va,           // Virtual address.
input logic                              i_rd,           // Read request.
input logic                              i_wr,           // Write request.

input logic [CPSR_MODE:0]                i_cpsr,         // CPSR.
input logic [1:0]                        i_sr,           // Status Register.
input logic [31:0]                       i_dac_reg,      // Domain Access Control Register.

input logic [SPAGE_TLB_WAYS-1:0][`ARM925T_SPAGE_TLB_WDT-1:0] i_sptlb_rdata, // Small page TLB, a read per way.
input logic [SPAGE_TLB_WAYS-1:0]         i_sptlb_rdav,   // TLB entry valid, per way.

input logic [`ARM925T_LPAGE_TLB_WDT  -1:0]   i_lptlb_rdata,  // Large page TLB read data.
input logic                              i_lptlb_rdav,   // Large page TLB valid.

input logic [`ARM925T_SECTION_TLB_WDT-1:0]   i_setlb_rdata,  // Small page TLB read data.
input logic                              i_setlb_rdav,   // Small page TLB valid.

input logic [`ARM925T_FPAGE_TLB_WDT-1:0]     i_fptlb_rdata,  // Fine page TLB read data.
input logic                              i_fptlb_rdav,   // Fine page TLB valid.

output logic                            o_hit_ok,       // ARM925T: translated, permitted cache hit (WB stores only).
// ARM925T: o_hit_ok's copy for the D-cache's short hit, kept a register of
// its own (no retiming, no merging): the CPU's W hit starts at a flop.
(* dont_retime, preserve *) output logic o_hit_ok_short,
output logic                            o_walk,         // Signal page walk.
output logic [31:0]                     o_walk_va,      // ARM925T: the address o_walk is for.
output logic [7:0]                      o_fsr,          // FSR. 0 means all OK.
output logic [31:0]                     o_far,          // Fault Address Register.
output logic                            o_cacheable,    // Cacheble stats of the PTE.
output logic                            o_bufferable,
output logic                            o_wt,           // ARM925T: C=1 B=0, write-through.
output logic [31:0]                     o_phy_addr      // Physical address.
);

`include "arm925t_localparams.svh"

localparam logic APSR_BAD = 1'd0;
localparam logic APSR_OK  = 1'd1;

logic [3:1] match;
logic dummy;
logic unused;

assign unused = |dummy;

// 0: Small Page. ARM925T: one match and one set of results per way; the
// ways of a set never hold the same page (a page is installed only after
// a miss in every way), so at most one of them matches.
logic [SPAGE_TLB_WAYS-1:0]       match_sp;
logic [SPAGE_TLB_WAYS-1:0][7:0]  fsr_sp;
logic [SPAGE_TLB_WAYS-1:0][31:0] phy_sp;
logic [SPAGE_TLB_WAYS-1:0]       cacheable_sp, wt_sp, bufferable_sp;

for (genvar w = 0; w < SPAGE_TLB_WAYS; w++) begin : g_sp_way
        assign match_sp[w] = (i_sptlb_rdata[w][`ARM925T_SPAGE_TLB__TAG] == i_va[`ARM925T_VA__SPAGE_TAG]) && i_sptlb_rdav[w];
        assign fsr_sp[w] = get_fsr_spage
        (
                i_va[`ARM925T_VA__SPAGE_AP_SEL],
                i_cpsr[ARM925T_CPSR_MODE:0] == USR,
                i_rd,
                i_wr,
                i_sr,
                i_dac_reg,
                i_sptlb_rdata[w][15:0]
        );
        assign phy_sp[w]        = {i_sptlb_rdata[w][`ARM925T_SPAGE_TLB__BASE], i_va[11:0]};
        assign cacheable_sp[w]  = i_sptlb_rdata[w][3];
        assign wt_sp[w]         = i_sptlb_rdata[w][3:2] == 2'b10;
        assign bufferable_sp[w] = i_sptlb_rdata[w][2];
end : g_sp_way

// 1: Large Page
assign  match[1] = (i_lptlb_rdata[`ARM925T_LPAGE_TLB__TAG] == i_va[`ARM925T_VA__LPAGE_TAG]) && i_lptlb_rdav;

// 2: Section
assign  match[2] = (i_setlb_rdata[`ARM925T_SECTION_TLB__TAG] == i_va[`ARM925T_VA__SECTION_TAG]) && i_setlb_rdav;

// 3: Fine Page
assign  match[3] = (i_fptlb_rdata[`ARM925T_FPAGE_TLB__TAG] == i_va[`ARM925T_VA__FPAGE_TAG]) && i_fptlb_rdav;

logic [7:0] fsr_nxt;
logic [31:0] far_nxt, phy_addr_nxt;
logic walk_nxt, cacheable_nxt, wt_nxt, bufferable_nxt, dummy_nxt;

// ARM925T: the background-hit permission is registered with the normal
// TLB check. It remains meaningful while the walker waits for cache IDLE.
always_ff @(posedge i_clk)
        if (i_clkena) begin
                o_fsr <= fsr_nxt;
                o_far <= far_nxt;
                o_phy_addr <= phy_addr_nxt;
                o_walk <= walk_nxt;
                o_walk_va <= i_va;
                o_cacheable <= cacheable_nxt;
                o_wt <= wt_nxt;
                o_bufferable <= bufferable_nxt;
                dummy <= dummy_nxt;
                o_hit_ok <= !walk_nxt && !(|fsr_nxt[3:0]) &&
                            cacheable_nxt && !(i_wr && wt_nxt);
                o_hit_ok_short <= !walk_nxt && !(|fsr_nxt[3:0]) &&
                            cacheable_nxt && !(i_wr && wt_nxt);
        end

always_comb
begin : tlb_match_logic

                // ============================================
                // Default Values Section
                // ============================================

                dummy_nxt  = 1'd0;

                // Default values. Taken for MMU disabled esp.
                fsr_nxt       = 0;        // No fault.
                far_nxt       = i_va;     // Fault address.
                phy_addr_nxt  = i_va;     // VA = PA
                walk_nxt      = 0;        // Walk disabled.
                cacheable_nxt = MMU_OFF_CACHEABLE; // ARM925T: was 0 (uncacheable).
                wt_nxt        = 0;
                bufferable_nxt = 0;

                // ==========================================
                // Code Section
                // ==========================================

                if ( i_mmu_en && (i_rd || i_wr) ) // MMU enabled and R/W operation.
                begin
                        if ( !(|match_sp) && !(|match) )
                        begin
                                // No match. Trigger TLB walk.
                                walk_nxt = 1'd1;
                        end
                        else
                        begin
                                // ARM925T: the buffers hold different page
                                // sizes and the small-page ways different
                                // pages, so one source matches: its results
                                // are selected by AND-OR, without a
                                // priority among the sources.
                                fsr_nxt        = '0;
                                phy_addr_nxt   = '0;
                                cacheable_nxt  = 1'b0;
                                wt_nxt         = 1'b0;
                                bufferable_nxt = 1'b0;

                                // Entry found in a way of the small page TLB.
                                for ( int unsigned w = 0 ; w < SPAGE_TLB_WAYS ; w++ )
                                begin
                                        if ( match_sp[w] )
                                        begin
                                                fsr_nxt        |= fsr_sp[w];
                                                phy_addr_nxt   |= phy_sp[w];
                                                cacheable_nxt  |= cacheable_sp[w];
                                                wt_nxt         |= wt_sp[w];
                                                bufferable_nxt |= bufferable_sp[w];
                                        end
                                end

                                if ( match[1] )
                                begin
                                        // Entry found in large page TLB.
                                        fsr_nxt |= get_fsr_lpage
                                        (
                                                i_va[`ARM925T_VA__LPAGE_AP_SEL],
                                                i_cpsr[ARM925T_CPSR_MODE:0] == USR,
                                                i_rd,
                                                i_wr,
                                                i_sr,
                                                i_dac_reg,
                                                i_lptlb_rdata[15:0]
                                        ) ;

                                        phy_addr_nxt   |= {i_lptlb_rdata[`ARM925T_LPAGE_TLB__BASE], i_va[15:0]};
                                        cacheable_nxt  |= i_lptlb_rdata[3];
                                        wt_nxt         |= i_lptlb_rdata[3:2] == 2'b10;
                                        bufferable_nxt |= i_lptlb_rdata[2];
                                end

                                if ( match[2] )
                                begin
                                        // Entry found in section TLB.
                                        fsr_nxt |= get_fsr_section
                                        (
                                                i_cpsr[ARM925T_CPSR_MODE:0] == USR,
                                                i_rd,
                                                i_wr,
                                                i_sr,
                                                i_dac_reg,
                                                i_setlb_rdata[19:0]
                                        ) ;

                                        phy_addr_nxt   |= {i_setlb_rdata[`ARM925T_SECTION_TLB__BASE], i_va[19:0]};
                                        cacheable_nxt  |= i_setlb_rdata[3];
                                        wt_nxt         |= i_setlb_rdata[3:2] == 2'b10;
                                        bufferable_nxt |= i_setlb_rdata[2];
                                end

                                if ( match[3] )
                                begin
                                        // Entry found in fine page TLB.
                                        fsr_nxt |= get_fsr_fpage
                                        (
                                                i_cpsr[ARM925T_CPSR_MODE:0] == USR,
                                                i_rd,
                                                i_wr,
                                                i_sr,
                                                i_dac_reg,
                                                i_fptlb_rdata[9:0]
                                        );

                                        phy_addr_nxt   |= {i_fptlb_rdata[`ARM925T_FPAGE_TLB__BASE], i_va[9:0]};
                                        cacheable_nxt  |= i_fptlb_rdata[3];
                                        wt_nxt         |= i_fptlb_rdata[3:2] == 2'b10;
                                        bufferable_nxt |= i_fptlb_rdata[2];
                                end
                        end
                end // Else MMU disabled.
end : tlb_match_logic

////////////////
// Functions
////////////////

function automatic [7:0] get_fsr_fpage (           // Return 0 means OK to access else is a valid FSR.
input                   user, rd, wr,              // Access properties.
input [1:0]             sr,                        // S and R bits.
input [15:0][1:0]       dac_reg,                   // DAC register.
input [9:0]             tlb                        // TLB entry.
);

          logic [3:0]  apsr; // Concat of AP and SR.
          logic [1:0]  dac;  // DAC bits.

          /* verilator lint_off VARHIDDEN */
          logic        unused;
          /* verilator lint_on VARHIDDEN */

         unused = |{tlb[1:0], tlb[`ARM925T_FPAGE_TLB__CB]};

         apsr[3:2] = tlb [ `ARM925T_FPAGE_TLB__AP ];
          dac[1:0] = dac_reg[tlb [ `ARM925T_FPAGE_TLB__DAC_SEL ]];
         apsr[1:0] = sr[1:0];

        case(dac)

        DAC_MANAGER: return '0; // No fault.

        DAC_CLIENT:
                if ( is_apsr_ok ( user, rd, wr, apsr ) == APSR_OK )
                begin
                        return '0; // No fault.
                end
                else
                begin
                        return {tlb[`ARM925T_FPAGE_TLB__DAC_SEL]  , FSR_PAGE_PERMISSION_FAULT};
                end

        default: return {tlb[`ARM925T_FPAGE_TLB__DAC_SEL],   FSR_PAGE_DOMAIN_FAULT   };

        endcase
endfunction : get_fsr_fpage

function automatic [7:0] get_fsr_section (             // Return 0 means OK to access else is a valid FSR.
input                   user, rd, wr,                  // Access properties.
input [1:0]             sr,                            // S and R bits.
input [15:0][1:0]       dac_reg,                       // DAC register.
input [19:0]            tlb                            // TLB entry.
);

         logic [3:0]  apsr; // Concat of AP and SR.
         logic [1:0]  dac;  // DAC bits.

         /* verilator lint_off VARHIDDEN */
         logic        unused;
         /* verilator lint_on VARHIDDEN */

        unused = |{tlb[19:12], tlb[9], tlb[4], tlb[`ARM925T_SECTION_TLB__CB]};

        // Get AP and DAC.
        apsr[3:2]  = tlb     [ `ARM925T_SECTION_TLB__AP ];
        dac[1:0]   = dac_reg [tlb [ `ARM925T_SECTION_TLB__DAC_SEL ]];
        apsr[1:0]  = sr      [1:0];

        // Generate error based on DAC.
        if ( tlb[1:0] == 2'b00 )
        begin
                return {tlb[`ARM925T_L1_SECTION__DAC_SEL], FSR_SECTION_TRANSLATION_FAULT};
        end
        else if ( tlb[1:0] == 2'b11 )
        begin
                return {tlb[`ARM925T_L1_SECTION__DAC_SEL], FSR_L1_EXTERNAL_ABORT};
        end
        else
        begin
                case(dac)
                DAC_MANAGER: return '0; // No fault.
                DAC_CLIENT:
                        if ( is_apsr_ok ( user, rd, wr, apsr ) == APSR_OK )
                        begin
                                return '0; // No fault.
                        end
                        else
                        begin
                                 return {tlb[`ARM925T_SECTION_TLB__DAC_SEL], FSR_SECTION_PERMISSION_FAULT};
                        end
                default: return {tlb[`ARM925T_SECTION_TLB__DAC_SEL], FSR_SECTION_DOMAIN_FAULT};
                endcase
        end

endfunction : get_fsr_section

function automatic [7:0] get_fsr_spage (               // Return 0 means OK to access else is a valid FSR.
input   [1:0]           ap_sel,                        // AP sel bits. dont care for sections or fine pages.
input                   user, rd, wr,                  // Access properties.
input [1:0]             sr,                            // S and R bits.
input [15:0][1:0]       dac_reg,                       // DAC register.
input [15:0]            tlb                            // TLB entry.
);

         logic [3:0]  apsr; // Concat of AP and SR.
         logic [1:0]  dac;  // DAC bits.

         /* verilator lint_off VARHIDDEN */
         logic  [5:0] unused;
         /* verilator lint_on VARHIDDEN */

        // Get AP and DAC.
        {unused, apsr[3:2]}     = (tlb  [ `ARM925T_SPAGE_TLB__AP ]) >> ({30'd0, ap_sel} << 32'd1);
        dac[1:0]                = dac_reg [tlb[ `ARM925T_SPAGE_TLB__DAC_SEL ]];
        apsr[1:0]               = sr[1:0];

        unused[1:0]            |= tlb[`ARM925T_SPAGE_TLB__CB];

        // ARM925T: the domain of a small-page TLB entry is in its own field
        // (15:12); upstream took bits 8:5, part of the AP bits, so a page
        // translation fault reported the wrong domain.
        if ( tlb[1:0] == 2'b00 ) // Check needed only for section and small page.
        begin
                return {tlb[`ARM925T_SPAGE_TLB__DAC_SEL], FSR_PAGE_TRANSLATION_FAULT};
        end
        else if ( tlb[1:0] == 2'b11 )
        begin
                return {tlb[`ARM925T_SPAGE_TLB__DAC_SEL], FSR_L2_EXTERNAL_ABORT};
        end
        else
        begin
                case(dac)

                DAC_MANAGER: return '0; // No fault.

                DAC_CLIENT:
                        if ( is_apsr_ok ( user, rd, wr, apsr ) == APSR_OK )
                        begin
                                return '0; // No fault.
                        end
                        else
                        begin
                                return {tlb[`ARM925T_SPAGE_TLB__DAC_SEL]  , FSR_PAGE_PERMISSION_FAULT};
                        end

                default: return {tlb[`ARM925T_SPAGE_TLB__DAC_SEL],   FSR_PAGE_DOMAIN_FAULT};

                endcase
        end
endfunction : get_fsr_spage

function automatic [7:0] get_fsr_lpage (               // Return 0 means OK to access else is a valid FSR.
input   [1:0]           ap_sel,                        // AP sel bits. dont care for sections or fine pages.
input                   user, rd, wr,                  // Access properties.
input [1:0]             sr,                            // S and R bits.
input [15:0][1:0]       dac_reg,                       // DAC register.
input [15:0]            tlb                            // TLB entry.
);

         logic [3:0]  apsr; // Concat of AP and SR.
         logic [1:0]  dac;  // DAC bits.

         /* verilator lint_off VARHIDDEN */
         logic [5:0]  dummy;// 30-bit dummy variable. UNUSED.
         logic        unused;
         /* verilator lint_on VARHIDDEN */

        unused = |{dummy, tlb[1:0], tlb[`ARM925T_LPAGE_TLB__CB]};

        // Get AP and DAC.

        {dummy, apsr[3:2]} = (tlb[ `ARM925T_LPAGE_TLB__AP ]) >> ({30'd0, ap_sel} << 32'd1);
        dac[1:0]           = dac_reg[tlb[ `ARM925T_LPAGE_TLB__DAC_SEL ]];
        apsr[1:0]          = sr[1:0];

        case(dac)

        DAC_MANAGER:return '0; // No fault.

        DAC_CLIENT:
                if ( is_apsr_ok ( user, rd, wr, apsr ) == APSR_OK )
                begin
                        return '0; // No fault.
                end
                else
                begin
                        return {tlb[`ARM925T_LPAGE_TLB__DAC_SEL]  , FSR_PAGE_PERMISSION_FAULT};
                end

        default:return {tlb[`ARM925T_LPAGE_TLB__DAC_SEL],   FSR_PAGE_DOMAIN_FAULT   };

        endcase

endfunction : get_fsr_lpage

//
// Function to check APSR bits.
//
// Returns 0 for failure, 1 for okay.
// Checks AP and SR bits.
//

function automatic is_apsr_ok ( input user, input rd, input wr, input [3:0] apsr);
        casez (apsr)
                APSR_NA_NA: return APSR_BAD;               // No access.
                APSR_RO_RO: return !wr;                    // Reads allowed for all.
                APSR_RO_NA: return !user && rd;            // Only kernel reads.
                APSR_RW_NA: return !user;                  // Only kernel access.
                APSR_RW_RO: return !user | (user && rd);   // User RO, Kernel RW.
                APSR_RW_RW: return APSR_OK;                // Grant all the time.
                default   : return APSR_BAD;               // Deny all the time.
        endcase
endfunction : is_apsr_ok

endmodule : arm925t_tlb_check

// ----------------------------------------------------------------------------
// END OF FILE
// ----------------------------------------------------------------------------
