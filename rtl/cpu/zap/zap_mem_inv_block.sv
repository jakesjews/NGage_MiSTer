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
// This RTL describes RAM with single cycle invalidate. Which rows are valid
// is kept as a generation number beside each row (see below), so bulk
// invalidation happens in a single cycle without a memory write.
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
// check. Invalidation clears every entry in one clock, also while held.
//
// Which entries are valid is kept as a generation number. gen counts the
// invalidations (and resets); a write stores gen beside the entry, in a
// RAM of its own with the entry's addresses and enables, and the entry
// read is valid if it was ever written and its number is still gen. An
// invalidation in the clock of a write wins: the write stores the number
// that the same edge makes old.
//
// Until 2026-11-16 the valid bits were DEPTH flip-flops and the entry's bit
// was a DEPTH:1 choice among them: before the read edge it hung behind the
// address adder, after it (4e6c677) in front of the TLB check, and either
// way it led the core's failing paths. The number's compare runs beside
// the tag's. The value is the same in every clock (a simulation-only copy
// of the flip-flops is compared), with one bound: gen must not come round.
// At GEN_W = 48 that takes 2^48 invalidations, 31 days of one in every
// clock; the firmware makes a few thousand a second.
if (1) begin : g_short
    localparam int GEN_W = 48;
    logic [GEN_W-1:0] gen = '0;
    logic [GEN_W:0]   gen_q;     // the entry read: {written, its generation}
    logic             fwd;       // the read's own edge wrote its entry ...
    logic             fwd_ok;    // ... and nothing has invalidated it since
    wire              en = READ_THROUGH || i_clken;
    zap_ram_simple #(.WIDTH(WIDTH), .DEPTH(DEPTH)) u_ram (
        .i_clk(i_clk), .i_clken(en), .i_wr_en(i_wen),
        .i_wr_data(i_wdata), .i_wr_addr(i_waddr), .i_rd_addr(i_raddr),
        .o_rd_data_pre(), .o_rd_data(o_rdata_pre)
    );
    // read-first, without the RAM's own bypass: a colliding write is
    // answered from fwd_ok, so the number read goes straight to its compare
    zap_ram_simple #(.WIDTH(GEN_W + 1), .DEPTH(DEPTH), .SHORT_RAW(1'b1)) u_gen (
        .i_clk(i_clk), .i_clken(en), .i_wr_en(i_wen),
        .i_wr_data({1'b1, gen}), .i_wr_addr(i_waddr), .i_rd_addr(i_raddr),
        .o_rd_data_pre(), .o_rd_data(gen_q)
    );
    always_ff @(posedge i_clk) begin
        if (i_reset || i_inv) gen <= gen + 1'd1;
        if (en) fwd <= i_wen && i_waddr == i_raddr;
        if (i_reset || i_inv) fwd_ok <= 1'b0;
        else if (en) fwd_ok <= 1'b1;
    end
    assign o_rdav_pre = fwd ? fwd_ok : (gen_q[GEN_W] && gen_q[GEN_W-1:0] == gen);
`ifndef SYNTHESIS
    // the flip-flops this replaced, kept for the comparison
    logic [DEPTH-1:0] valid_ref;
    logic [$clog2(DEPTH)-1:0] read_addr_ref;
    logic seen_reset = 1'b0;
    always_ff @(posedge i_clk) begin
        if (i_reset || i_inv) valid_ref <= '0;
        else if (en) begin
            if (i_wen) valid_ref[i_waddr] <= 1;
        end
        if (en) read_addr_ref <= i_raddr;
        if (i_reset) seen_reset <= 1'b1;
        if (!i_reset && seen_reset && !$isunknown(valid_ref[read_addr_ref]))
            assert (o_rdav_pre == valid_ref[read_addr_ref]) else $fatal(1, "TLB valid bit by generation");
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
