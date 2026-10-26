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
// be used to connect I and D caches to a common interface (the caches' NXT
// ports; ZAP's cacheless form was removed on 2026-10-25).
//

module zap_wb_merger
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
input logic [1:0]       i_c_wb_bte, // ARM925T: I-cache critical-word-first
output logic            o_c_wb_ack,
output logic            o_c_wb_err,
output logic            o_c_wb_no_late_error,
output logic            o_dbg_data_owner, // registered grant, observation only

// Wishbone bus 2
input logic             i_d_wb_stb,
input logic             i_d_wb_cyc,
input logic             i_d_wb_wen,
input logic [3:0]       i_d_wb_sel,
input logic [31:0]      i_d_wb_dat,
input logic [31:0]      i_d_wb_adr,
input logic [2:0]       i_d_wb_cti,
input logic [1:0]       i_d_wb_bte, // ARM925T: critical-word-first fill
output logic            o_d_wb_ack,
output logic            o_d_wb_err,

// Common bus
output logic            o_wb_cyc,
output logic            o_wb_stb,
output logic            o_wb_wen,
output logic [3:0]      o_wb_sel,
output logic [31:0]     o_wb_dat,
(* dont_retime *) output logic [31:0] o_wb_adr,
output logic [2:0]      o_wb_cti,
output logic [1:0]      o_wb_bte,
input logic             i_wb_ack,
input logic             i_wb_err,
input logic             i_wb_no_late_error

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
typedef enum logic {CODE = 1'd0, DATA = 1'd1, DEFAULT_XX = 'x} owner_t;
(* preserve, dont_retime *) owner_t state_ff;
owner_t state_nxt;

// Alias
logic switch;

assign o_dbg_data_owner = state_ff == DATA;

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
// Response sideband: same grant as ACK, no additional state or ACK path.
assign o_c_wb_no_late_error = (state_ff == CODE) & i_wb_no_late_error;
assign o_d_wb_err = (state_ff == DATA) & i_wb_err;

/////////////////////////////////////
// WB output generation logic.
/////////////////////////////////////

if (1)
begin: l_genblk1
        // ARM925T: only write data uses speculative banks. Keep the bus
        // address registered after arbitration: a post-register address
        // mux lengthens the whole-core bus decode and SDRAM address paths.
        (* dont_retime *) logic [31:0] code_data_ff, data_data_ff;
        (* preserve, dont_retime *) owner_t data_owner_ff;
        always_ff @(posedge i_clk) begin
                if (i_reset) begin
                        code_data_ff <= 32'b0;
                        data_data_ff <= 32'b0;
                        data_owner_ff <= CODE;
                end else begin
                        code_data_ff <= i_c_wb_dat;
                        data_data_ff <= i_d_wb_dat;
                        data_owner_ff <= state_nxt;
                end
        end
        assign o_wb_dat = data_owner_ff == CODE ? code_data_ff : data_data_ff;

        //
        // We can flop these, because we're using NXT ports.
        // Use state_nxt since we are using wishbone NXT ports.
        //
        always_ff @ (posedge i_clk)
        begin
                if ( i_reset )
                begin
                        o_wb_cyc <= 0;
                        o_wb_stb <= 0;
                        o_wb_wen <= 0;
                        o_wb_sel <= 0;
                        o_wb_adr <= 0;
                        o_wb_cti <= CTI_EOB;
                        o_wb_bte <= 2'b00;
                end
                else if ( state_nxt == CODE )
                begin
                        o_wb_cyc <= i_c_wb_cyc;
                        o_wb_stb <= i_c_wb_stb;
                        o_wb_wen <= i_c_wb_wen;
                        o_wb_sel <= i_c_wb_sel;
                        o_wb_adr <= i_c_wb_adr;
                        o_wb_cti <= i_c_wb_cti;
                        o_wb_bte <= i_c_wb_bte;
                end
                else
                begin
                        o_wb_cyc <= i_d_wb_cyc;
                        o_wb_stb <= i_d_wb_stb;
                        o_wb_wen <= i_d_wb_wen;
                        o_wb_sel <= i_d_wb_sel;
                        o_wb_adr <= i_d_wb_adr;
                        o_wb_cti <= i_d_wb_cti;
                        o_wb_bte <= i_d_wb_bte;
                end
        end

end: l_genblk1

endmodule : zap_wb_merger

// ----------------------------------------------------------------------------
// END OF FILE
// ----------------------------------------------------------------------------
