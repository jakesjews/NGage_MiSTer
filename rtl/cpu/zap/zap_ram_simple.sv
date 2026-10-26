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
        parameter logic SHORT_READ = 1'b0,
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
if (SHORT_READ) begin : g_short
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
end else begin : g_three_edge


// ----------------------------------------------------------------------------
// Stage 1
// ----------------------------------------------------------------------------

logic [WIDTH-1:0]         mem [DEPTH-1:0];
logic [WIDTH-1:0]         mem_data_st1, mem_data_st2;
logic [WIDTH-1:0]         buffer_st1, buffer_st2, buffer_st2_x;
logic [1:0]               sel_st1;
logic [2:0]               sel_st2;
logic [$clog2(DEPTH)-1:0] rd_addr_st1, rd_addr_st2;

// ----------------------------------------------------------------------------
// Write RAM
// ----------------------------------------------------------------------------

always_ff @ (posedge i_clk)
begin
        if ( i_clken )
        begin
                if ( i_wr_en )
                begin
                        mem [ i_wr_addr ] <= i_wr_data;
                end
        end
end

// ----------------------------------------------------------------------------
// Stage 1
// ----------------------------------------------------------------------------

// Memory read. Direct output from block RAM.
always_ff @ (posedge i_clk)
begin
        if ( i_clken )
        begin
                mem_data_st1 <= mem [ i_rd_addr ];
        end
end

//
// Hazard Detection Logic. If the read data from this stage should be modified
// mark it as such. This happens when write address collides with read
// address.
//
always_ff @ ( posedge i_clk )
begin
        if ( i_clken )
        begin
                //
                // If 2, then collision occured, else it did not.
                // We encode as 1-hot.
                //
                if ( i_wr_addr == i_rd_addr && i_wr_en )
                begin
                        sel_st1 <= 2'b10;
                end
                else
                begin
                        sel_st1 <= 2'b01;
                end
        end
end

// Buffer update logic.
always_ff @ ( posedge i_clk )
begin
        if ( i_clken )
        begin
                // Take a copy of the write data. We will need it if sel = 1.
                buffer_st1  <= i_wr_data;

                // Keep pumping address down.
                rd_addr_st1 <= i_rd_addr;
        end
end

// ----------------------------------------------------------------------------
// Stage 2
// ----------------------------------------------------------------------------

// Delay the memory read for another cycle to deal with slow SRAMs.
always_ff @ (posedge i_clk)
begin
        if ( i_clken )
        begin
                mem_data_st2 <= mem_data_st1;
        end
end

//
// Hazard detection logic. If the data in this stage needs to be modified
// with current write data mark it as such. Else, Pass the previous
// stage modifier signal too.
//
always_ff @ ( posedge i_clk )
begin
        if ( i_clken )
        begin
                //
                // If a collision occured here, give priority to this
                // replacement for the address - even if the address
                // is associated with a data replacement in the previous
                // stages. Think about writes to the same address happening
                // over 3 cycles :
                // W1    W2     W3 (Write to same address)
                // <-- Read Lat.--> Read trig. at W1 reads W3
                //
                if ( i_wr_addr == rd_addr_st1 && i_wr_en )
                begin
                        sel_st2       <= 3'b100;
                end
                else
                begin
                        sel_st2       <= {1'd0, sel_st1};
                end
        end
end

// Keep passing the address down.
always_ff @ ( posedge i_clk )
begin
        if ( i_clken )
        begin
                rd_addr_st2 <= rd_addr_st1;
        end
end

// Take a copy of the write data and pass the buffer down.
always_ff @ ( posedge i_clk )
begin
        if ( i_clken )
        begin
                buffer_st2   <= i_wr_data;
                buffer_st2_x <= buffer_st1;
        end
end

//
// If the read data should be overriden in st2, then do that. Is fast to do
// as the encoding is 1-hot. Default case is assigned X for synthesis to
// OPTIMIZE. This is OK for FPGA synthesis.
//
always_comb
begin
        case (sel_st2)
        3'b100  : o_rd_data_pre = buffer_st2;
        3'b010  : o_rd_data_pre = buffer_st2_x;
        3'b001  : o_rd_data_pre = mem_data_st2;
        default : o_rd_data_pre = {WIDTH{1'dx}}; // Synthesis will OPTIMIZE.
                                                 // OK for FPGA synthesis.
        endcase
end

// ----------------------------------------------------------------------------
// Stage 3
// ----------------------------------------------------------------------------

//
// We want a purely registered output. Once again check for collisions. This
// will override any replacements done in the previous stages for this
// read packet.
//
//
// ARM925T: the last collision check is registered (fwd_st3) together with
// the write data and the read data, and the choice is made after the
// registers. Upstream chose before them, so the late write enable from the
// cache FSM went through a mux into every output flop (timing). Same
// values: when i_clken is 0, all three hold.
//
logic             fwd_st3;
logic [WIDTH-1:0] fwd_data_st3, rd_data_st3;

always_ff @ ( posedge i_clk )
begin
        if ( i_clken )
        begin
                fwd_st3      <= i_wr_addr == rd_addr_st2 && i_wr_en;
                fwd_data_st3 <= i_wr_data;
                rd_data_st3  <= o_rd_data_pre;
        end
end

assign o_rd_data = fwd_st3 ? fwd_data_st3 : rd_data_st3;

end

endmodule : zap_ram_simple

// ----------------------------------------------------------------------------
// END OF FILE
// ----------------------------------------------------------------------------

// ARM9V2 (zap_cache_tag_ram DATA_PACK): BYTES byte-wide RAMs with shared
// clock enable and addresses as one RAM with byte enables, so Quartus puts
// two or four lanes in an M10K. Equal to BYTES zap_ram_simple instances with
// SHORT_READ and SHORT_RAW: one enabled edge writes the enabled bytes and
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

