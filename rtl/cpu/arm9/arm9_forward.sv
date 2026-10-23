// SPDX-License-Identifier: GPL-3.0-or-later
// Physical register tags. Slot zero is the youngest producer. A pending
// youngest write shadows every older value, even when it is not ready.
module arm9_forward #(
    parameter integer SOURCES = 4,
    parameter integer PRODUCERS = 3
) (
    input  logic [SOURCES-1:0][31:0] i_value,
    input  logic [SOURCES-1:0][5:0]  i_tag,
    input  logic [SOURCES-1:0]       i_used,
    input  logic [PRODUCERS-1:0][31:0] i_write_value,
    input  logic [PRODUCERS-1:0][5:0]  i_write_tag,
    input  logic [PRODUCERS-1:0]       i_write_valid,
    input  logic [PRODUCERS-1:0]       i_write_ready,
    output logic [SOURCES-1:0][31:0] o_value,
    output logic [SOURCES-1:0]       o_wait
);
    always_comb begin
        o_value = i_value;
        o_wait = {SOURCES{1'b0}};
        for (integer s = 0; s < SOURCES; s++) begin
            // Oldest first; each younger match overrides value AND readiness.
            for (integer p = PRODUCERS-1; p >= 0; p--) begin
                if (i_used[s] && i_write_valid[p] && i_tag[s] == i_write_tag[p]) begin
                    o_value[s] = i_write_value[p];
                    o_wait[s] = !i_write_ready[p];
                end
            end
        end
    end
endmodule
