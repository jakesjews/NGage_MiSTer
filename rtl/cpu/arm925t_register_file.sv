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
// Part of the N-Gage QD core's ARM925T (rtl/cpu). Derived from ZAP's
// zap_register_file.sv; the changes made for this core are marked "ARM925T:"
// and are listed in rtl/cpu/NOTICE and docs/CPU.md.
//
// Flip flop based register files. Good for FPGA where flip-flops are
// plentiful.
//

// ARM925T (WRITE_FF): the write port is registered. Each clock's writes are
// held in three one-hot masks and three words and reach the flip-flops one
// clock later; every read port bypasses the held write, so a read sees
// exactly what it saw with the direct write (the same clock, the same
// priority C > B > A). The write data and enables then travel to the 40
// registers from these few flops instead of from W's completion logic.
// ARM925T: the write port is registered (the held writes) and the reads
// bypass a held write; the direct-write form ZAP used was removed on
// 2026-10-25 with its EARLY_PORT_SELECT and ALLOW_RETIMING options.
module arm925t_register_file 
(
        // Clock and reset.
        input logic              i_clk,
        input logic              i_reset,

        // Write enable.
        input logic              i_wen,

        // Write address. Note that _c does not need write enable.
        input logic  [39:0]      i_wr_addr_c,   // 1-Hot address.

        input logic [5:0] i_wr_index_a, i_wr_index_b,

        // Write data.
        input logic  [31:0]      i_wr_data_a,
        input logic  [31:0]      i_wr_data_b,
        input logic  [31:0]      i_wr_data_c,

        // Read addresses (All binary).
        input logic  [5:0]       i_rd_addr_a,
        input logic  [5:0]       i_rd_addr_b,
        input logic  [5:0]       i_rd_addr_c,
        input logic  [5:0]       i_rd_addr_d,
        input logic  [5:0]       i_rd_addr_e,   // ARM925T: the coprocessor's own read port

        // Read data corresponding. Combinationally read via MUX.
        output logic  [31:0]      o_rd_data_a,
        output logic  [31:0]      o_rd_data_b,
        output logic  [31:0]      o_rd_data_c,
        output logic  [31:0]      o_rd_data_d,
        output logic  [31:0]      o_rd_data_e
);

// ARM925T: keep the RF edge at its architectural write boundary. Otherwise
// physical synthesis can distribute storage across the RF mux network and
// replicate registers without changing the HDL array size.

if (1) begin : g_write_ff

// Each write port owns a bank; a small table names the latest writer
// of each architectural register. Each read port has a physical replica
// of all three banks, allowing five asynchronous reads without a mux over
// forty 32-bit flip-flop words. Reset invalidates the words, not the RAM.
(* dont_retime, ramstyle="logic" *) logic [39:0][1:0] latest;
(* dont_retime *) logic [39:0] initialized;
logic [4:0][5:0] read_index;
logic [4:0][31:0] bank_value, read_value;
assign read_index={i_rd_addr_e,i_rd_addr_d,i_rd_addr_c,i_rd_addr_b,i_rd_addr_a};
(* dont_retime *) logic [31:0] held_data_a, held_data_b, held_data_c;
// The read bypass compares the read address with each held write's binary
// index (a 6-bit compare beside the storage read) instead of selecting the
// held one-hot mask's bit with a 40-way mux. The write ports are one-hot.
(* dont_retime *) logic [5:0] held_index_a, held_index_b, held_index_c;
(* dont_retime *) logic held_any_a, held_any_b, held_any_c;
// Which register each held write names, from its index and its flag. Until
// 2026-11-16 the one-hot masks were registers of their own, ports A and B
// gated by i_wen: eighty flip-flops behind the write enable, which hangs on
// the data cache's answer in the same clock and crossed the core to reach
// them (77 failing endpoints at seed 5, to -1.5 ns). The flag and the index
// say the same, and only the two flags are left behind i_wen.
logic [39:0] held_a, held_b, held_c;
always_comb for (int r = 0; r < 40; r++) begin
        held_a[r] = held_any_a && held_index_a == 6'(r);
        held_b[r] = held_any_b && held_index_b == 6'(r);
        held_c[r] = held_any_c && held_index_c == 6'(r);
end
// Mask both the active write and the write just committed to each bank.
// RAM collision data is never consumed, so asynchronous MLAB read-during-
// write behavior can be unspecified without changing an architectural read.
(* dont_retime *) logic [2:0] committed_any;
(* dont_retime *) logic [2:0][5:0] committed_index;
(* dont_retime *) logic [2:0][31:0] committed_data;
always_ff @(posedge i_clk)begin
        if(i_reset)begin committed_any<=0;committed_index<=0;committed_data<=0;end
        else begin
                committed_any<={held_any_c,held_any_b,held_any_a};
                committed_index<={held_index_c,held_index_b,held_index_a};
                committed_data<={held_data_c,held_data_b,held_data_a};
        end
end

function automatic [5:0] onehot_index (input logic [39:0] m);
        onehot_index = 6'd0;
        for (int r = 0; r < 40; r++) if (m[r]) onehot_index = onehot_index | 6'(r);
endfunction

always_ff @ ( posedge i_clk )
begin
        if ( i_reset )
        begin
                initialized <= 0; latest <= 0;
                held_any_a <= 0; held_any_b <= 0; held_any_c <= 0;
                held_index_a <= 0; held_index_b <= 0; held_index_c <= 0;
                held_data_a <= 0; held_data_b <= 0; held_data_c <= 0;
        end
        else
        begin
                held_data_a <= i_wr_data_a; held_data_b <= i_wr_data_b; held_data_c <= i_wr_data_c;
                held_any_a <= i_wen && (i_wr_index_a < 40); held_any_b <= i_wen && (i_wr_index_b < 40); held_any_c <= |i_wr_addr_c;
                held_index_a <= i_wr_index_a; held_index_b <= i_wr_index_b;
                held_index_c <= onehot_index(i_wr_addr_c);
                for (int r = 0; r < 40; r++)
                        if (held_a[r] || held_b[r] || held_c[r]) begin
                                initialized[r] <= 1'b1;
                                latest[r] <= held_c[r] ? 2'd2 : held_b[r] ? 2'd1 : 2'd0;
                        end
        end
end

for(genvar port=0;port<5;port++)begin : g_read
        wire [31:0] bank_a_q,bank_b_q,bank_c_q;
        altdpram #(.width(32),.widthad(6),.numwords(64),
                .intended_device_family("Cyclone V"),.ram_block_type("MLAB"),
                .indata_reg("INCLOCK"),.wraddress_reg("INCLOCK"),.wrcontrol_reg("INCLOCK"),
                .rdaddress_reg("UNREGISTERED"),.rdcontrol_reg("UNREGISTERED"),.outdata_reg("UNREGISTERED"),
                .indata_aclr("OFF"),.wraddress_aclr("OFF"),.wrcontrol_aclr("OFF"),
                .rdaddress_aclr("OFF"),.rdcontrol_aclr("OFF"),.outdata_aclr("OFF"),.outdata_sclr("OFF"),
                .read_during_write_mode_mixed_ports("DONT_CARE")) ram_a (
                .inclock(i_clk),.inclocken(1'b1),.outclock(1'b0),.outclocken(1'b1),
                .aclr(1'b0),.sclr(1'b0),.wren(held_any_a),.rden(1'b1),.byteena(1'b1),
                .wraddressstall(1'b0),.rdaddressstall(1'b0),
                .wraddress(held_index_a),.data(held_data_a),.rdaddress(read_index[port]),.q(bank_a_q));
        altdpram #(.width(32),.widthad(6),.numwords(64),
                .intended_device_family("Cyclone V"),.ram_block_type("MLAB"),
                .indata_reg("INCLOCK"),.wraddress_reg("INCLOCK"),.wrcontrol_reg("INCLOCK"),
                .rdaddress_reg("UNREGISTERED"),.rdcontrol_reg("UNREGISTERED"),.outdata_reg("UNREGISTERED"),
                .indata_aclr("OFF"),.wraddress_aclr("OFF"),.wrcontrol_aclr("OFF"),
                .rdaddress_aclr("OFF"),.rdcontrol_aclr("OFF"),.outdata_aclr("OFF"),.outdata_sclr("OFF"),
                .read_during_write_mode_mixed_ports("DONT_CARE")) ram_b (
                .inclock(i_clk),.inclocken(1'b1),.outclock(1'b0),.outclocken(1'b1),
                .aclr(1'b0),.sclr(1'b0),.wren(held_any_b),.rden(1'b1),.byteena(1'b1),
                .wraddressstall(1'b0),.rdaddressstall(1'b0),
                .wraddress(held_index_b),.data(held_data_b),.rdaddress(read_index[port]),.q(bank_b_q));
        altdpram #(.width(32),.widthad(6),.numwords(64),
                .intended_device_family("Cyclone V"),.ram_block_type("MLAB"),
                .indata_reg("INCLOCK"),.wraddress_reg("INCLOCK"),.wrcontrol_reg("INCLOCK"),
                .rdaddress_reg("UNREGISTERED"),.rdcontrol_reg("UNREGISTERED"),.outdata_reg("UNREGISTERED"),
                .indata_aclr("OFF"),.wraddress_aclr("OFF"),.wrcontrol_aclr("OFF"),
                .rdaddress_aclr("OFF"),.rdcontrol_aclr("OFF"),.outdata_aclr("OFF"),.outdata_sclr("OFF"),
                .read_during_write_mode_mixed_ports("DONT_CARE")) ram_c (
                .inclock(i_clk),.inclocken(1'b1),.outclock(1'b0),.outclocken(1'b1),
                .aclr(1'b0),.sclr(1'b0),.wren(held_any_c),.rden(1'b1),.byteena(1'b1),
                .wraddressstall(1'b0),.rdaddressstall(1'b0),
                .wraddress(held_index_c),.data(held_data_c),.rdaddress(read_index[port]),.q(bank_c_q));
        always_comb begin
                case(latest[read_index[port]])
                        0:bank_value[port]=bank_a_q;
                        1:bank_value[port]=bank_b_q;
                        default:bank_value[port]=bank_c_q;
                endcase
                if(!initialized[read_index[port]])bank_value[port]=0;
                read_value[port]=bank_value[port];
                for(int writer=0;writer<3;writer++)
                        if(committed_any[writer]&&committed_index[writer]==read_index[port])read_value[port]=committed_data[writer];
                if(held_any_a&&held_index_a==read_index[port])read_value[port]=held_data_a;
                if(held_any_b&&held_index_b==read_index[port])read_value[port]=held_data_b;
                if(held_any_c&&held_index_c==read_index[port])read_value[port]=held_data_c;
        end
end
// Architectural view used by the existing test-bench taps only.
assign {o_rd_data_e,o_rd_data_d,o_rd_data_c,o_rd_data_b,o_rd_data_a}=read_value;

end

endmodule

// ----------------------------------------------------------------------------
// EOF
// ----------------------------------------------------------------------------
