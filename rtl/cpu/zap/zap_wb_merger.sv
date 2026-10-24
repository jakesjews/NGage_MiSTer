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
        parameter logic ONLY_CORE = 1'd0,
        parameter logic [31:0] CACHE_LINE = 32'd8
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
input logic [1:0]       i_c_wb_bte, // ARM925T: I-cache critical-word-first
output logic            o_c_wb_ack,
output logic            o_c_wb_err,
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

// One immutable dirty victim, independent of DATA ownership. The producer
// reserves an empty buffer before accepting a dirty miss. Invalidation is
// deliberately absent from this interface: accepted bytes must reach memory.
input logic             i_victim_valid,
input logic [CACHE_LINE*8-1:0] i_victim_line,
input logic [31:0]      i_victim_addr,
input logic             i_victim_drain,
output logic            o_victim_busy,
output logic            o_victim_done,

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
typedef enum logic [1:0] {CODE = 2'd0, DATA = 2'd1, VICTIM = 2'd2, DEFAULT_XX = 'x} owner_t;
(* preserve, dont_retime *) owner_t state_ff;
owner_t state_nxt;

// Alias
logic switch;

localparam integer LINE_W = $clog2(CACHE_LINE);
localparam integer BEAT_W = $clog2(CACHE_LINE/4);
logic [CACHE_LINE*8-1:0] victim_line_ff;
logic [31:LINE_W] victim_pa_ff;
logic victim_valid_ff;
logic [BEAT_W-1:0] victim_beat_ff, victim_beat_next;
logic victim_take, victim_last, victim_available;
logic c_checked_ff, d_checked_ff, c_conflict_ff, d_conflict_ff;
logic c_ready, d_ready;

assign o_dbg_data_owner = state_ff == DATA || state_ff == VICTIM;
assign o_victim_busy = victim_valid_ff;
assign victim_take = state_ff == VICTIM && o_wb_stb && (i_wb_ack || i_wb_err);
assign victim_last = victim_take && o_wb_cti == CTI_EOB;
assign victim_available = victim_valid_ff && !victim_last;
assign victim_beat_next = victim_beat_ff + {{(BEAT_W-1){1'b0}}, victim_take};
// Only buffer-overlap requests pay this admission edge. Compare physical
// addresses into flags before arbitration; no address comparator is added
// to the normal bus-address/ACK cone. An admitted burst keeps its grant.
assign c_ready = !victim_valid_ff ||
    ((state_ff == CODE && o_wb_stb && !switch) ||
     (c_checked_ff && !c_conflict_ff && !(state_ff == CODE && switch)));
assign d_ready = !victim_valid_ff ||
    ((state_ff == DATA && o_wb_stb && !switch) ||
     (d_checked_ff && !d_conflict_ff && !(state_ff == DATA && switch)));

always_ff @(posedge i_clk) begin
        if (i_reset) begin
                victim_valid_ff <= 1'b0;
                victim_beat_ff <= '0;
                o_victim_done <= 1'b0;
                c_checked_ff <= 1'b0;
                d_checked_ff <= 1'b0;
                c_conflict_ff <= 1'b0;
                d_conflict_ff <= 1'b0;
        end else begin
                o_victim_done <= victim_last;
                if (i_victim_valid && !ONLY_CORE) begin
                        victim_valid_ff <= 1'b1;
                        victim_line_ff <= i_victim_line;
                        victim_pa_ff <= i_victim_addr[31:LINE_W];
                        victim_beat_ff <= '0;
                end else if (victim_last) begin
                        victim_valid_ff <= 1'b0;
                        victim_beat_ff <= '0;
                end else if (victim_take)
                        victim_beat_ff <= victim_beat_next;

                c_checked_ff <= victim_valid_ff && i_c_wb_stb &&
                                !(state_ff == CODE && switch);
                d_checked_ff <= victim_valid_ff && i_d_wb_stb &&
                                !(state_ff == DATA && switch);
                c_conflict_ff <= i_c_wb_adr[31:LINE_W] == victim_pa_ff;
                d_conflict_ff <= i_d_wb_adr[31:LINE_W] == victim_pa_ff;
        end
end

`ifndef SYNTHESIS
always_ff @(posedge i_clk)
        if (!i_reset && i_victim_valid)
                assert (!victim_valid_ff && !ONLY_CORE)
                    else $fatal(1, "Victim buffer overflow or ONLY_CORE handoff");
`endif

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

        VICTIM:
                state_nxt = i_c_wb_stb ? CODE : i_d_wb_stb ? DATA : CODE;

        default: // Propagate X.
        begin
                state_nxt = DEFAULT_XX;
        end

        endcase

        if (!ONLY_CORE && (victim_valid_ff || state_ff == VICTIM)) begin
                // Never interrupt a transaction, including a beat awaiting
                // its first ACK. A required fence/conflict wins at EOB.
                if (o_wb_stb && !switch)
                        state_nxt = state_ff;
                else if (victim_available && (i_victim_drain ||
                         (i_c_wb_stb && c_checked_ff && c_conflict_ff) ||
                         (i_d_wb_stb && d_checked_ff && d_conflict_ff)))
                        state_nxt = VICTIM;
                else if (i_c_wb_stb && (!i_d_wb_stb || i_d_wb_wen || state_ff != CODE))
                        state_nxt = CODE;
                else if (i_d_wb_stb && !i_d_wb_wen)
                        state_nxt = DATA;
                else if (victim_available)
                        state_nxt = VICTIM;
                else if (i_d_wb_stb)
                        state_nxt = DATA;
                else
                        state_nxt = CODE;
        end
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
        // ARM925T: only write data uses speculative banks. Keep the bus
        // address registered after arbitration: a post-register address
        // mux lengthens the whole-core bus decode and SDRAM address paths.
        (* dont_retime *) logic [31:0] code_data_ff, data_data_ff, victim_data_ff;
        (* preserve, dont_retime *) owner_t data_owner_ff;
        always_ff @(posedge i_clk) begin
                if (i_reset) begin
                        code_data_ff <= 32'b0;
                        data_data_ff <= 32'b0;
                        victim_data_ff <= 32'b0;
                        data_owner_ff <= CODE;
                end else begin
                        code_data_ff <= i_c_wb_dat;
                        data_data_ff <= i_d_wb_dat;
                        victim_data_ff <= victim_line_ff[victim_beat_next*32 +: 32];
                        data_owner_ff <= state_nxt;
                end
        end
        assign o_wb_dat = data_owner_ff == CODE ? code_data_ff :
                          data_owner_ff == DATA ? data_data_ff : victim_data_ff;

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
                        o_wb_cyc <= i_c_wb_cyc && c_ready;
                        o_wb_stb <= i_c_wb_stb && c_ready;
                        o_wb_wen <= i_c_wb_wen;
                        o_wb_sel <= i_c_wb_sel;
                        o_wb_adr <= i_c_wb_adr;
                        o_wb_cti <= i_c_wb_cti;
                        o_wb_bte <= i_c_wb_bte;
                end
                else if (state_nxt == DATA)
                begin
                        o_wb_cyc <= i_d_wb_cyc && d_ready;
                        o_wb_stb <= i_d_wb_stb && d_ready;
                        o_wb_wen <= i_d_wb_wen;
                        o_wb_sel <= i_d_wb_sel;
                        o_wb_adr <= i_d_wb_adr;
                        o_wb_cti <= i_d_wb_cti;
                        o_wb_bte <= i_d_wb_bte;
                end
                else begin
                        o_wb_cyc <= victim_available;
                        o_wb_stb <= victim_available;
                        o_wb_wen <= 1'b1;
                        o_wb_sel <= 4'hf;
                        o_wb_adr <= {victim_pa_ff, victim_beat_next, 2'b00};
                        o_wb_cti <= &victim_beat_next ? CTI_EOB : CTI_BURST;
                        o_wb_bte <= CACHE_LINE == 16 ? 2'b01 : 2'b00;
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
                        o_wb_bte = i_c_wb_bte;
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
                        o_wb_bte = i_d_wb_bte;
                end
        end

end: l_genblk2

endmodule : zap_wb_merger

// ----------------------------------------------------------------------------
// END OF FILE
// ----------------------------------------------------------------------------
