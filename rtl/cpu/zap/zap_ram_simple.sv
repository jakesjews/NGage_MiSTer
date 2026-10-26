//
// (C)2016-2024 Revanth Kamaraj (krevanth) <revanth91kamaraj@gmail.com>
//
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
// This is a pipelined memory macro for high performance. This memory
// has a 3 cycle read latency, but can operate at high speeds. The core
// SRAM inferred is a read-first memory. Match logic is provided to ensure
// the latest write data to a colliding address is picked up onto the
// output.
//

module zap_ram_simple #(
        parameter logic [31:0] WIDTH = 32'd32,
        parameter logic [31:0] DEPTH = 32'd32,
        // Cache-level descriptor owns the short-port collision bypass.
        parameter logic SHORT_RAW = 1'b0
)
(
        // Clock.
        input logic                          i_clk,

        // SRAM clock enable/read enable.
        input logic                          i_clken,

        // Write enable. Needs i_clken=1 to actually write.
        input logic                          i_wr_en,

        // Write data and address.
        input logic [WIDTH-1:0]              i_wr_data,
        input logic[$clog2(DEPTH)-1:0]       i_wr_addr,

        // Read address and data.
        input logic [$clog2(DEPTH)-1:0]      i_rd_addr,

        // 2 cycle delayed read data.
        output logic [WIDTH-1:0]             o_rd_data_pre,

        // 3 cycle delayed read data.
        output logic [WIDTH-1:0]             o_rd_data
);
// ARM9: one enabled RAM edge. Capture the colliding write on that edge;
// the next edge belongs to the caller's compare/select/format register.
// Data and enables hold together, including across cache/core stalls.
if (1) begin : g_short
    logic [WIDTH-1:0] mem [DEPTH-1:0];
    logic [WIDTH-1:0] read_data, write_data;
    logic forward_write;
    always_ff @(posedge i_clk) if (i_clken) begin
        if (i_wr_en) mem[i_wr_addr] <= i_wr_data;
        read_data <= mem[i_rd_addr];
        write_data <= i_wr_data;
        forward_write <= i_wr_en && i_wr_addr == i_rd_addr;
    end
    assign o_rd_data = SHORT_RAW ? read_data : forward_write ? write_data : read_data;
    assign o_rd_data_pre = o_rd_data;
end : g_short

endmodule : zap_ram_simple

// ----------------------------------------------------------------------------
// END OF FILE
// ----------------------------------------------------------------------------

// ARM9V2 (zap_cache_tag_ram DATA_PACK): BYTES byte-wide RAMs with shared
// clock enable and addresses as one RAM with byte enables, so Quartus puts
// two or four lanes in an M10K. Equal to BYTES zap_ram_simple instances with
// SHORT_RAW: one enabled edge writes the enabled bytes and
// registers the read word.
module zap_ram_bytes #(
        parameter integer BYTES = 16,
        parameter integer DEPTH = 32
) (
        input logic                          i_clk,
        input logic                          i_clken,
        input logic [BYTES-1:0]              i_wr_en,
        input logic [8*BYTES-1:0]            i_wr_data,
        input logic [$clog2(DEPTH)-1:0]      i_wr_addr,
        input logic [$clog2(DEPTH)-1:0]      i_rd_addr,
        output logic [8*BYTES-1:0]           o_rd_data
);
`ifdef SYNTHESIS
        // Intel's primitive directly: Quartus 17 does not infer byte enables
        // from sv2v's form of the array below (it became flip-flops).
        localparam integer W = 8*BYTES;
        wire [$clog2(DEPTH)-1:0] i_wr_addr_x = i_wr_addr, i_rd_addr_x = i_rd_addr;
        altsyncram #(
                .operation_mode("DUAL_PORT"), .ram_block_type("M10K"), .intended_device_family("Cyclone V"),
                .lpm_type("altsyncram"), .power_up_uninitialized("FALSE"),
                .width_a(W), .widthad_a($clog2(DEPTH)), .numwords_a(DEPTH),
                .width_b(W), .widthad_b($clog2(DEPTH)), .numwords_b(DEPTH),
                .width_byteena_a(BYTES), .byte_size(8),
                .address_reg_b("CLOCK0"), .outdata_reg_b("UNREGISTERED"),
                .clock_enable_input_a("NORMAL"), .clock_enable_input_b("NORMAL"),
                .clock_enable_output_b("BYPASS"), .rdcontrol_reg_b("CLOCK0"),
                .read_during_write_mode_mixed_ports("OLD_DATA"),
                .address_aclr_b("NONE"), .outdata_aclr_b("NONE")
        ) u_ram (
                .clock0(i_clk), .clocken0(i_clken), .wren_a(|i_wr_en), .address_a(i_wr_addr_x), .data_a(i_wr_data),
                .byteena_a(i_wr_en), .address_b(i_rd_addr_x), .rden_b(1'b1), .q_b(o_rd_data)
        );
`else
        logic [BYTES-1:0][7:0] mem [DEPTH-1:0];
        logic [BYTES-1:0][7:0] q;
        always_ff @(posedge i_clk) if (i_clken) begin
                for (int b = 0; b < BYTES; b++)
                        if (i_wr_en[b]) mem[i_wr_addr][b] <= i_wr_data[8*b +: 8];
                q <= mem[i_rd_addr];
        end
        assign o_rd_data = q;
`endif
endmodule

