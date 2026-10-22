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
// Merges two Wishbone busses onto a single bus. One side can from the
// instruction cache while the other from data cache. This module can
// be used to connect I and D caches to a common interface. Take note of
// special interface requirements based on ONLY_CORE parameter.
//

module zap_wb_merger #(

        //
        // If ONLY_CORE=0, use NXT ports from cache,
        // else use FF ports from CPU.
        //
        parameter logic ONLY_CORE = 1'd0
)
(

// Clock and reset
input logic             i_clk,
input logic             i_reset,

// Wishbone bus 1
input logic             i_c_wb_stb,
input logic             i_c_wb_cyc,
input logic             i_c_wb_wen,
input logic [3:0]       i_c_wb_sel,
input logic [31:0]      i_c_wb_dat,
input logic [31:0]      i_c_wb_adr,
input logic [2:0]       i_c_wb_cti,
output logic            o_c_wb_ack,
output logic            o_c_wb_err,

// Wishbone bus 2
input logic             i_d_wb_stb,
input logic             i_d_wb_cyc,
input logic             i_d_wb_wen,
input logic [3:0]       i_d_wb_sel,
input logic [31:0]      i_d_wb_dat,
input logic [31:0]      i_d_wb_adr,
input logic [2:0]       i_d_wb_cti,
output logic            o_d_wb_ack,
output logic            o_d_wb_err,

// Common bus
output logic            o_wb_cyc,
output logic            o_wb_stb,
output logic            o_wb_wen,
output logic [3:0]      o_wb_sel,
output logic [31:0]     o_wb_dat,
output logic [31:0]     o_wb_adr,
output logic [2:0]      o_wb_cti,
input logic             i_wb_ack,
input logic             i_wb_err

);

`include "zap_defines.svh"
`include "zap_localparams.svh"

////////////////////////////////////
// FSM
////////////////////////////////////

//
// Channel select state machine.
//
// This will select either instruction or
// data in a round robin fashion. It will
// not interrupt a burst.
//

// State variable.
enum logic {CODE = 1'd0, DATA = 1'd1, DEFAULT_XX = 'x} state_ff, state_nxt;

// Alias
logic switch;

assign switch = (i_wb_ack | i_wb_err) & (o_wb_cti == CTI_EOB);

always_comb
begin
        // There is no need to assign default values in this case.

        case(state_ff)

        CODE:
        begin
                // Switch over if EOB and data STB exists.
                if ( switch && i_d_wb_stb )
                begin
                        state_nxt = DATA;
                end
                // Switch over if code STB == 0 and data STB exists.
                else if ( !i_c_wb_stb && i_d_wb_stb )
                begin
                        state_nxt = DATA;
                end
                else
                begin
                        state_nxt = state_ff;
                end
        end

        DATA:
        begin
                // Switch over if EOB and code STB exists.
                if ( switch && i_c_wb_stb )
                begin
                        state_nxt = CODE;
                end
                // Switch over if data STB == 0 and code STB exists.
                else if ( i_c_wb_stb && !i_d_wb_stb )
                begin
                        state_nxt = CODE;
                end
                else
                begin
                        state_nxt = state_ff;
                end
        end

        default: // Propagate X.
        begin
                state_nxt = DEFAULT_XX;
        end

        endcase
end

// State Updation Logic
always_ff @ (posedge i_clk)
begin
        if ( i_reset )
        begin
                state_ff <= CODE;
        end
        else
        begin
                state_ff <= state_nxt;
        end
end

////////////////////////////////////
// ACK towards CPU
////////////////////////////////////

// Based on the current selection, redirect ACK to code or data.
assign o_c_wb_ack = (state_ff == CODE) & (i_wb_err | i_wb_ack);
assign o_d_wb_ack = (state_ff == DATA) & (i_wb_err | i_wb_ack);
assign o_c_wb_err = (state_ff == CODE) & i_wb_err;
assign o_d_wb_err = (state_ff == DATA) & i_wb_err;

/////////////////////////////////////
// WB output generation logic.
/////////////////////////////////////

if ( !ONLY_CORE )
begin: l_genblk1

        //
        // The NXT ports are registered here. ARM925T: both sides are
        // registered and the side is chosen after the registers by
        // state_ff, the registered state_nxt: the same values as
        // registering the side state_nxt chooses (upstream), with the
        // acknowledge-dependent select off the register inputs (timing).
        //
        logic        c_cyc, c_stb, c_wen, d_cyc, d_stb, d_wen;
        logic [3:0]  c_sel, d_sel;
        logic [31:0] c_dat, c_adr, d_dat, d_adr;
        logic [2:0]  c_cti, d_cti;

        always_ff @ (posedge i_clk)
        begin
                if ( i_reset )
                begin
                        {c_cyc, c_stb, c_wen} <= '0;
                        {d_cyc, d_stb, d_wen} <= '0;
                        c_sel <= '0; d_sel <= '0;
                        c_dat <= '0; d_dat <= '0;
                        c_adr <= '0; d_adr <= '0;
                        c_cti <= CTI_EOB; d_cti <= CTI_EOB;
                end
                else
                begin
                        c_cyc <= i_c_wb_cyc; c_stb <= i_c_wb_stb; c_wen <= i_c_wb_wen;
                        c_sel <= i_c_wb_sel; c_dat <= i_c_wb_dat; c_adr <= i_c_wb_adr; c_cti <= i_c_wb_cti;
                        d_cyc <= i_d_wb_cyc; d_stb <= i_d_wb_stb; d_wen <= i_d_wb_wen;
                        d_sel <= i_d_wb_sel; d_dat <= i_d_wb_dat; d_adr <= i_d_wb_adr; d_cti <= i_d_wb_cti;
                end
        end

        always_comb
        begin
                if ( state_ff == CODE )
                begin
                        o_wb_cyc = c_cyc; o_wb_stb = c_stb; o_wb_wen = c_wen; o_wb_sel = c_sel;
                        o_wb_dat = c_dat; o_wb_adr = c_adr; o_wb_cti = c_cti;
                end
                else
                begin
                        o_wb_cyc = d_cyc; o_wb_stb = d_stb; o_wb_wen = d_wen; o_wb_sel = d_sel;
                        o_wb_dat = d_dat; o_wb_adr = d_adr; o_wb_cti = d_cti;
                end
        end

end: l_genblk1
else
begin: l_genblk2

        //
        // Not required to flop these since the sources are flops themselves.
        // Just a 2:1 MUX on the path - very little delay - won't affect timing.
        // Here, we use all FF versions.
        //
        always_comb
        begin
                if ( state_ff == CODE )
                begin
                        o_wb_cyc = i_c_wb_cyc;
                        o_wb_stb = i_c_wb_stb;
                        o_wb_wen = i_c_wb_wen;
                        o_wb_sel = i_c_wb_sel;
                        o_wb_dat = i_c_wb_dat;
                        o_wb_adr = i_c_wb_adr;
                        o_wb_cti = i_c_wb_cti;
                end
                else
                begin
                        o_wb_cyc = i_d_wb_cyc;
                        o_wb_stb = i_d_wb_stb;
                        o_wb_wen = i_d_wb_wen;
                        o_wb_sel = i_d_wb_sel;
                        o_wb_dat = i_d_wb_dat;
                        o_wb_adr = i_d_wb_adr;
                        o_wb_cti = i_d_wb_cti;
                end
        end

end: l_genblk2

endmodule : zap_wb_merger

// ----------------------------------------------------------------------------
// END OF FILE
// ----------------------------------------------------------------------------
