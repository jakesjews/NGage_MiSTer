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
// This RTL describes RAM with single cycle invalidate via flip-flops. The
// valid bits per memory row are maintained using flip-flops. This avoids
// having to do an actual memory write to invalidate the memory. This allows
// bulk invalidation to happen in a single cycle.
//

module zap_mem_inv_block #(
        parameter [31:0] DEPTH = 32,
        parameter [31:0] WIDTH = 32,  // Not including valid bit.
        // ARM925T: read (and write) every clock, ignoring
        // i_clken, so the data follows the read address through a hold.
        parameter logic READ_THROUGH = 1'b0
)(


        input logic                           i_clk,
        input logic                           i_reset,

        // Read enable/Clock enable.
        input logic                           i_clken,

        // Write data.
        input logic   [WIDTH-1:0]             i_wdata,

        // Write enable. Also required i_clken.
        input logic                           i_wen,

        // Invalidate entries in 1 cycle.
        input logic                           i_inv,

        // Read and write address.
        input logic   [$clog2(DEPTH)-1:0]     i_raddr,
        input logic   [$clog2(DEPTH)-1:0]     i_waddr,

        // Read data and valid.
        output logic [WIDTH-1:0]              o_rdata_pre,
        output logic                          o_rdav_pre,

        // Read data and valid.
        output logic [WIDTH-1:0]              o_rdata,
        output logic                          o_rdav
);

// ARM9: the pre output is the synchronous RAM read, including a same-edge
// collision bypass. The caller still registers the translation/permission
// check. Invalidation clears the valid array and its read even while held.
if (1) begin : g_short
    logic [DEPTH-1:0] valid;
    // The valid bits are flip-flops (one clock clears them all). The bit
    // of the entry read is chosen AFTER the edge that takes the read
    // address, from a copy of that address: until 2026-11-16 it was chosen
    // before the edge, a DEPTH:1 multiplexer behind the address adder and
    // the end of many of the core's worst paths. The value is the same in
    // every clock: a write on the read's own edge is already in the bits,
    // and the bits change only where the old register was loaded or
    // cleared too.
    logic [$clog2(DEPTH)-1:0] read_addr;
    zap_ram_simple #(.WIDTH(WIDTH), .DEPTH(DEPTH)) u_ram (
        .i_clk(i_clk), .i_clken(READ_THROUGH || i_clken), .i_wr_en(i_wen),
        .i_wr_data(i_wdata), .i_wr_addr(i_waddr), .i_rd_addr(i_raddr),
        .o_rd_data_pre(), .o_rd_data(o_rdata_pre)
    );
    always_ff @(posedge i_clk) begin
        if (i_reset || i_inv) begin
            valid <= '0;
        end else if (READ_THROUGH || i_clken) begin
            if (i_wen) valid[i_waddr] <= 1;
        end
        if (READ_THROUGH || i_clken) read_addr <= i_raddr;
    end
    assign o_rdav_pre = valid[read_addr];
`ifndef SYNTHESIS
    // the register this replaced, kept for the comparison
    logic read_valid_ref;
    always_ff @(posedge i_clk) begin
        if (i_reset || i_inv) read_valid_ref <= 0;
        else if (READ_THROUGH || i_clken)
            read_valid_ref <= (i_wen && i_raddr == i_waddr) || valid[i_raddr];
        if (!i_reset && !$isunknown(read_valid_ref))
            assert (o_rdav_pre == read_valid_ref) else $fatal(1, "TLB valid bit read after the edge");
    end
`endif
    // The TLB consumes only the pre outputs. Keep the unused full outputs
    // defined as the same read instead of retaining dead pipeline registers.
    assign o_rdata = o_rdata_pre;
    assign o_rdav = o_rdav_pre;
end : g_short

endmodule

// ----------------------------------------------------------------------------
// EOF
// ----------------------------------------------------------------------------
