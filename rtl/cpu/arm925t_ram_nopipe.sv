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
// zap_ram_simple_nopipe.sv; the changes made for this core are marked "ARM925T:"
// and are listed in rtl/cpu/NOTICE and docs/CPU.md.
//
//  Synthesizes to standard 1R + 1W block RAM. The read and write addresses
//  may be specified separately. This synthesizes as a single cycle
//  memory, which behaves as a write first memory, even though the macro
//  is a standard read first memory. This memory provides a read latency
//  of 1 cycle.
//

module arm925t_ram_nopipe #(
        parameter logic [31:0] WIDTH = 32'd60,
        parameter logic [31:0] DEPTH = 32'd256
)
(
        // Clock
        input logic                          i_clk,

        // Write and read enable.
        input logic                          i_wr_en,
        input logic                          i_rd_en,

        // Write data and address.
        input logic [WIDTH-1:0]              i_wr_data,
        input logic[$clog2(DEPTH)-1:0]       i_wr_addr,

        // Read address and data.
        input logic [$clog2(DEPTH)-1:0]      i_rd_addr,
        output logic [WIDTH-1:0]             o_rd_data
);

/////////////////////////////////
// SRAM (Read First)
/////////////////////////////////

// Memory array.
logic [WIDTH-1:0] mem [DEPTH-1:0];
(* dont_retime *) logic [WIDTH-1:0] mem_rd_data;

always_ff @ (posedge i_clk) if ( i_rd_en ) mem_rd_data <= mem [ i_rd_addr ];
always_ff @ (posedge i_clk) if ( i_wr_en ) mem [ i_wr_addr ] <= i_wr_data;

/////////////////////////////////
// Steering logic.
/////////////////////////////////

(* dont_retime *) logic [WIDTH-1:0] buffer_ff;
(* dont_retime *) logic hazard_ff;
logic             concurrent_access;

assign concurrent_access = i_wr_en & i_rd_en;

// ARM925T: the read holds while i_rd_en is low (the predictor keeps an entry
// stable across a held fetch, including a write-first collision), and the
// collision is a compare of registered addresses on the response side, which
// keeps a late read address out of a compare before the edge.
(* dont_retime *) logic [$clog2(DEPTH)-1:0] rd_addr_ff, wr_addr_ff;
(* dont_retime *) logic concurrent_ff;
always_ff @(posedge i_clk) begin
        if (i_rd_en) begin
                rd_addr_ff <= i_rd_addr;
                wr_addr_ff <= i_wr_addr;
                concurrent_ff <= concurrent_access;
                buffer_ff <= i_wr_data;
        end
end
assign hazard_ff = concurrent_ff && rd_addr_ff == wr_addr_ff;

// And forward it to the output in case of hazard.
assign o_rd_data = hazard_ff ? buffer_ff : mem_rd_data;

endmodule

// ----------------------------------------------------------------------------
// EOF
// ----------------------------------------------------------------------------
