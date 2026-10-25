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
// Flip flop based register files. Good for FPGA where flip-flops are
// plentiful.
//

module zap_register_file #(parameter integer ALLOW_RETIMING=1, parameter logic EARLY_PORT_SELECT=0)
(
        // Clock and reset.
        input logic              i_clk,
        input logic              i_reset,

        // Write enable.
        input logic              i_wen,

        // Write address. Note that _c does not need write enable.
        input logic  [39:0]      i_wr_addr_a,   // ARM925T: decoded before write selection.
        input logic  [39:0]      i_wr_addr_b,   // ARM925T: one-hot, like the background port.
        input logic  [39:0]      i_wr_addr_c,   // 1-Hot address.

        // Write data.
        input logic  [31:0]      i_wr_data_a,
        input logic  [31:0]      i_wr_data_b,
        input logic  [31:0]      i_wr_data_c,

        // Read addresses (All binary).
        input logic  [5:0]       i_rd_addr_a,
        input logic  [5:0]       i_rd_addr_b,
        input logic  [5:0]       i_rd_addr_c,
        input logic  [5:0]       i_rd_addr_d,
        input logic  [5:0]       i_rd_addr_e,   // ARM9V2: the coprocessor's own read port (unused: tie 0)

        // Read data corresponding. Combinationally read via MUX.
        output logic  [31:0]      o_rd_data_a,
        output logic  [31:0]      o_rd_data_b,
        output logic  [31:0]      o_rd_data_c,
        output logic  [31:0]      o_rd_data_d,
        output logic  [31:0]      o_rd_data_e
);

// ARM9V2: keep the RF edge at its architectural write boundary. Otherwise
// physical synthesis can distribute storage across the RF mux network and
// replicate registers without changing the HDL array size.
// ZAP keeps its existing retiming policy (attribute 1 has no effect).
(* syn_allow_retiming = ALLOW_RETIMING *) logic [39:0][31:0] mem;

// 3 write ports. Synchronous reset for the register file.
always_ff @ ( posedge i_clk )
begin
        if ( i_reset )
        begin
                mem <= {32'd40{32'd0}};
        end
        else
        begin
                // ARM925T: per-register enables avoid decoding a muxed
                // binary address. Preserve B over A, and background over
                // both, including writes to the dummy/RAZ storage entries.
                for (int r = 0; r < 40; r++) begin
                        if (EARLY_PORT_SELECT) begin
                                // V2: port priority uses the registered owner
                                // class. Completion only enables the update.
                                if (i_wen && (i_wr_addr_a[r] || i_wr_addr_b[r]))
                                        mem[r] <= i_wr_addr_b[r] ? i_wr_data_b : i_wr_data_a;
                        end else begin
                                if (i_wen && i_wr_addr_a[r]) mem[r] <= i_wr_data_a;
                                if (i_wen && i_wr_addr_b[r]) mem[r] <= i_wr_data_b;
                        end
                        if (i_wr_addr_c[r]) mem[r] <= i_wr_data_c;
                end
        end
end

// 4 read ports.
assign o_rd_data_a = mem [ i_rd_addr_a ];
assign o_rd_data_b = mem [ i_rd_addr_b ];
assign o_rd_data_c = mem [ i_rd_addr_c ];
assign o_rd_data_d = mem [ i_rd_addr_d ];
assign o_rd_data_e = mem [ i_rd_addr_e ];

`ifndef SYNTHESIS

wire [31:0] r0   =  mem[0];
wire [31:0] r1   =  mem[1];
wire [31:0] r2   =  mem[2];
wire [31:0] r3   =  mem[3];
wire [31:0] r4   =  mem[4];
wire [31:0] r5   =  mem[5];
wire [31:0] r6   =  mem[6];
wire [31:0] r7   =  mem[7];
wire [31:0] r8   =  mem[8];
wire [31:0] r9   =  mem[9];
wire [31:0] r10  =  mem[10];
wire [31:0] r11  =  mem[11];
wire [31:0] r12  =  mem[12];
wire [31:0] r13  =  mem[13];
wire [31:0] r14  =  mem[14];
wire [31:0] r15  =  mem[15];
wire [31:0] r16  =  mem[16];
wire [31:0] r17  =  mem[17];
wire [31:0] r18  =  mem[18];
wire [31:0] r19  =  mem[19];
wire [31:0] r20  =  mem[20];
wire [31:0] r21  =  mem[21];
wire [31:0] r22  =  mem[22];
wire [31:0] r23  =  mem[23];
wire [31:0] r24  =  mem[24];
wire [31:0] r25  =  mem[25];
wire [31:0] r26  =  mem[26];
wire [31:0] r27  =  mem[27];
wire [31:0] r28  =  mem[28];
wire [31:0] r29  =  mem[29];
wire [31:0] r30  =  mem[30];
wire [31:0] r31  =  mem[31];
wire [31:0] r32  =  mem[32];
wire [31:0] r33  =  mem[33];
wire [31:0] r34  =  mem[34];
wire [31:0] r35  =  mem[35];
wire [31:0] r36  =  mem[36];
wire [31:0] r37  =  mem[37];
wire [31:0] r38  =  mem[38];
wire [31:0] r39  =  mem[39];

`endif

endmodule

// ----------------------------------------------------------------------------
// EOF
// ----------------------------------------------------------------------------
