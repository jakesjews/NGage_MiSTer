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

// ARM9V2 (WRITE_FF): the write port is registered. Each clock's writes are
// held in three one-hot masks and three words and reach the flip-flops one
// clock later; every read port bypasses the held write, so a read sees
// exactly what it saw with the direct write (the same clock, the same
// priority C > B > A). The write data and enables then travel to the 40
// registers from these few flops instead of from W's completion logic.
// mem is the architectural contents in both forms (the benches read it);
// with WRITE_FF the storage is store and mem its view with the held write
// applied, which no synthesised logic reads.
// ARM9V2: the write port is registered (the held writes) and the reads
// bypass a held write; the direct-write form ZAP used was removed on
// 2026-10-25 with its EARLY_PORT_SELECT and ALLOW_RETIMING options.
module zap_register_file
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
        input logic  [5:0]       i_rd_addr_e,   // ARM9V2: the coprocessor's own read port

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
// The architectural view: read by the simulation taps below (not under SYNTHESIS).
/* verilator lint_off UNUSEDSIGNAL */
logic [39:0][31:0] mem;
/* verilator lint_on UNUSEDSIGNAL */

if (1) begin : g_write_ff

(* syn_allow_retiming = 0 *) logic [39:0][31:0] store;
(* dont_retime *) logic [39:0] held_a, held_b, held_c;
(* dont_retime *) logic [31:0] held_data_a, held_data_b, held_data_c;
// The read bypass compares the read address with each held write's binary
// index (a 6-bit compare beside the storage read) instead of selecting the
// held one-hot mask's bit with a 40-way mux. The write ports are one-hot.
(* dont_retime *) logic [5:0] held_index_a, held_index_b, held_index_c;
(* dont_retime *) logic held_any_a, held_any_b, held_any_c;
function automatic [5:0] onehot_index (input logic [39:0] m);
        onehot_index = 6'd0;
        for (int r = 0; r < 40; r++) if (m[r]) onehot_index = onehot_index | 6'(r);
endfunction

always_ff @ ( posedge i_clk )
begin
        if ( i_reset )
        begin
                store <= {32'd40{32'd0}};
                held_a <= 0; held_b <= 0; held_c <= 0;
                held_any_a <= 0; held_any_b <= 0; held_any_c <= 0;
                held_index_a <= 0; held_index_b <= 0; held_index_c <= 0;
                held_data_a <= 0; held_data_b <= 0; held_data_c <= 0;
        end
        else
        begin
                held_a <= i_wen ? i_wr_addr_a : 40'd0;
                held_b <= i_wen ? i_wr_addr_b : 40'd0;
                held_c <= i_wr_addr_c;
                held_data_a <= i_wr_data_a; held_data_b <= i_wr_data_b; held_data_c <= i_wr_data_c;
                held_any_a <= i_wen && |i_wr_addr_a; held_any_b <= i_wen && |i_wr_addr_b; held_any_c <= |i_wr_addr_c;
                held_index_a <= onehot_index(i_wr_addr_a); held_index_b <= onehot_index(i_wr_addr_b);
                held_index_c <= onehot_index(i_wr_addr_c);
                for (int r = 0; r < 40; r++)
                        if (held_a[r] || held_b[r] || held_c[r])
                                store[r] <= held_c[r] ? held_data_c : held_b[r] ? held_data_b : held_data_a;
        end
end

// One register's architectural value: the held write, else the storage.
// Indexed like the direct form (an address above 39 reads nothing defined).
function automatic [31:0] view (input logic [5:0] r);
        if (held_any_c && held_index_c == r) view = held_data_c;
        else if (held_any_b && held_index_b == r) view = held_data_b;
        else if (held_any_a && held_index_a == r) view = held_data_a;
        else view = store[r];
endfunction
`ifndef SYNTHESIS
always_ff @ ( posedge i_clk ) if ( !i_reset ) begin
        assert ($onehot0(i_wr_addr_a) && $onehot0(i_wr_addr_b) && $onehot0(i_wr_addr_c))
                else $fatal(1, "register file: a write port is not one-hot");
        for (int r = 0; r < 40; r++)
                assert ((held_any_c && held_index_c == 6'(r)) == held_c[r] &&
                        (held_any_b && held_index_b == 6'(r)) == held_b[r] &&
                        (held_any_a && held_index_a == 6'(r)) == held_a[r])
                        else $fatal(1, "register file: held index");
end
`endif

always_comb for (int r = 0; r < 40; r++) mem[r] = view(6'(r));
assign o_rd_data_a = view(i_rd_addr_a);
assign o_rd_data_b = view(i_rd_addr_b);
assign o_rd_data_c = view(i_rd_addr_c);
assign o_rd_data_d = view(i_rd_addr_d);
assign o_rd_data_e = view(i_rd_addr_e);

end

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
