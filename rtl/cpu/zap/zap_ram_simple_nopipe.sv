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
//  Synthesizes to standard 1R + 1W block RAM. The read and write addresses
//  may be specified separately. This synthesizes as a single cycle
//  memory, which behaves as a write first memory, even though the macro
//  is a standard read first memory. This memory provides a read latency
//  of 1 cycle.
//

module zap_ram_simple_nopipe #(
        parameter logic [31:0] WIDTH = 32'd32,
        parameter logic [31:0] DEPTH = 32'd32,
        // ARM9V2 keeps a predictor entry stable across a held fetch, including
        // a write-first collision. Default preserves existing callers.
        parameter logic HOLD_READ = 1'b0,
        // ARM9V2: compare registered addresses on the response side. This
        // keeps a late predicted read address out of a compare before the
        // next edge. Same write-first/held-read contract, default unchanged.
        parameter logic REGISTER_COLLISION = 1'b0
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

generate if (REGISTER_COLLISION) begin : g_registered_collision
        (* dont_retime *) logic [$clog2(DEPTH)-1:0] rd_addr_ff, wr_addr_ff;
        (* dont_retime *) logic concurrent_ff;
        always_ff @(posedge i_clk) begin
                if (!HOLD_READ || i_rd_en) begin
                        rd_addr_ff <= i_rd_addr;
                        wr_addr_ff <= i_wr_addr;
                        concurrent_ff <= concurrent_access;
                        buffer_ff <= i_wr_data;
                end
        end
        assign hazard_ff = concurrent_ff && rd_addr_ff == wr_addr_ff;
end else begin : g_original_collision
        wire hazard_nxt = (i_wr_addr == i_rd_addr) && concurrent_access;
        wire [WIDTH-1:0] buffer_nxt = hazard_nxt ? i_wr_data : {WIDTH{1'dx}};
        always_ff @(posedge i_clk) begin
                if (!HOLD_READ || i_rd_en) begin
                        hazard_ff <= hazard_nxt;
                        buffer_ff <= buffer_nxt;
                end
        end
end endgenerate

// And forward it to the output in case of hazard.
assign o_rd_data = hazard_ff ? buffer_ff : mem_rd_data;

endmodule

// ----------------------------------------------------------------------------
// EOF
// ----------------------------------------------------------------------------
