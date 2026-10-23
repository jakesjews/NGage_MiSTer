// SPDX-License-Identifier: GPL-2.0-or-later
//
// Per-second counters for the debug overlay: how fast the core actually
// runs the firmware and the games, and where the CPU's clocks go. Every
// event ev[i] is counted for one second (tick marks the second's last
// clock) and the count is latched into cnt[i] for the overlay rows; the
// next second starts over. NGage.sv names the events; tools/mister_dbg.py
// prints them from a capture. The counts are the core's own rate; what
// the phone did is a separate question.
module dbg_counters #(
	parameter N = 8
) (
	input  logic              clk,
	input  logic              reset,
	input  logic              tick,
	input  logic [N-1:0]      ev,
	output logic [N-1:0][31:0] cnt
);

	logic [N-1:0][31:0] c = '0;

	always_ff @(posedge clk) begin
		for (int i = 0; i < N; i++) begin
			if (reset) begin
				c[i]   <= '0;
				cnt[i] <= '0;
			end else if (tick) begin
				cnt[i] <= c[i] + 32'(ev[i]);
				c[i]   <= '0;
			end else begin
				c[i]   <= c[i] + 32'(ev[i]);
			end
		end
	end

endmodule
