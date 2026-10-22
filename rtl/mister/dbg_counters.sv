// SPDX-License-Identifier: GPL-2.0-or-later
//
// Per-second counters for the debug overlay: how fast the core actually
// runs the firmware and the games. Every input event is counted for one
// second (tick marks the second's last clock) and the count is latched
// into the output word for the overlay rows; the next second starts over.
//
//   frames_s      LCD frames: a RAMWR that starts at page 0 (games that
//                 draw in strips start each frame at the top)
//   pix_s         LCD pixels written
//   retired_s     instructions retired by the CPU
//   wfi_s         clocks the CPU spent waiting for an interrupt (idle)
//   wait_*_s      clocks a CPU bus beat was pending on the SDRAM, the
//                 flash, or anything else (on-chip RAM, peripherals)
//   beats_s       CPU bus beats answered
//
// tools/mister_dbg.py prints them from a capture. The counts are the
// core's own rate; what the phone did is a separate question.
module dbg_counters (
	input  logic        clk,
	input  logic        reset,
	input  logic        tick,

	input  logic        frame,
	input  logic        pix,
	input  logic        retired,
	input  logic        wfi,
	input  logic        wait_sdram,
	input  logic        wait_flash,
	input  logic        wait_other,
	input  logic        beat,

	output logic [31:0] frames_s,
	output logic [31:0] pix_s,
	output logic [31:0] retired_s,
	output logic [31:0] wfi_s,
	output logic [31:0] wait_sdram_s,
	output logic [31:0] wait_flash_s,
	output logic [31:0] wait_other_s,
	output logic [31:0] beats_s
);

	logic [31:0] c_frames = '0, c_pix = '0, c_retired = '0, c_wfi = '0;
	logic [31:0] c_wsdram = '0, c_wflash = '0, c_wother = '0, c_beats = '0;

	// a counter's value including this clock's event
	wire [31:0] n_frames  = c_frames  + 32'(frame);
	wire [31:0] n_pix     = c_pix     + 32'(pix);
	wire [31:0] n_retired = c_retired + 32'(retired);
	wire [31:0] n_wfi     = c_wfi     + 32'(wfi);
	wire [31:0] n_wsdram  = c_wsdram  + 32'(wait_sdram);
	wire [31:0] n_wflash  = c_wflash  + 32'(wait_flash);
	wire [31:0] n_wother  = c_wother  + 32'(wait_other);
	wire [31:0] n_beats   = c_beats   + 32'(beat);

	always_ff @(posedge clk) begin
		if (reset) begin
			{c_frames, c_pix, c_retired, c_wfi} <= '0;
			{c_wsdram, c_wflash, c_wother, c_beats} <= '0;
			{frames_s, pix_s, retired_s, wfi_s} <= '0;
			{wait_sdram_s, wait_flash_s, wait_other_s, beats_s} <= '0;
		end else if (tick) begin
			frames_s     <= n_frames;   c_frames  <= '0;
			pix_s        <= n_pix;      c_pix     <= '0;
			retired_s    <= n_retired;  c_retired <= '0;
			wfi_s        <= n_wfi;      c_wfi     <= '0;
			wait_sdram_s <= n_wsdram;   c_wsdram  <= '0;
			wait_flash_s <= n_wflash;   c_wflash  <= '0;
			wait_other_s <= n_wother;   c_wother  <= '0;
			beats_s      <= n_beats;    c_beats   <= '0;
		end else begin
			c_frames  <= n_frames;
			c_pix     <= n_pix;
			c_retired <= n_retired;
			c_wfi     <= n_wfi;
			c_wsdram  <= n_wsdram;
			c_wflash  <= n_wflash;
			c_wother  <= n_wother;
			c_beats   <= n_beats;
		end
	end

endmodule
