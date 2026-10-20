// SPDX-License-Identifier: GPL-2.0-or-later
//
// A Wishbone B3 master standing in for the CPU until it exists: a memory
// test of the memory system through upp_bus, the way ZAP will use it
// (4-beat incrementing bursts for line fills and write-backs, classic cycles
// with SEL for the rest). While enable is high it runs passes of:
//   1. the boot code's EMIF set-up written and read back;
//   2. the CS2 ID probe: must read 0 (no flash);
//   3. on-chip RAM and SDRAM: filled with write-back bursts, checked with
//      line fills, then every 16th word rewritten a byte or a halfword at a
//      time (the other lanes carry inverted data, which must not land) and
//      checked with classic reads;
//   4. CS0 flash: each line read with a classic read of its first word and a
//      line fill, which must agree;
//   5. a peripheral register written and read back.
// The pattern depends on the address and the pass, so stale data fails.
// errors counts the failed reads (the first is kept in err_*); pass_done
// pulses at the end of each pass. The region sizes are parameters so that a
// simulation can test a small part.
module wb_selftest #(
	parameter int SDRAM_WORDS_LOG2  = 22,    // 16 MB
	parameter int ONCHIP_WORDS_LOG2 = 14,    // 64 KB
	parameter int FLASH_WORDS_LOG2  = 12     // the first 16 KB of CS0
) (
	input  logic        clk,
	input  logic        reset,
	input  logic        enable,

	output logic        wb_cyc,
	output logic        wb_stb,
	output logic        wb_we,
	output logic [31:0] wb_adr,
	output logic [31:0] wb_dat,
	output logic [3:0]  wb_sel,
	output logic [2:0]  wb_cti,
	output logic [1:0]  wb_bte,
	input  logic        wb_ack,
	input  logic        wb_err,
	input  logic [31:0] wb_dat_i,

	output logic [15:0] passes,
	output logic [15:0] errors,
	output logic [31:0] err_adr,
	output logic [31:0] err_got,
	output logic [31:0] err_want,
	output logic        pass_done
);

	typedef enum logic [3:0] {
		P_EMIF_W, P_EMIF_R, P_CS2,
		P_OC_FILL, P_OC_CHECK, P_OC_BYTES, P_OC_BCHECK,
		P_SD_FILL, P_SD_CHECK, P_SD_BYTES, P_SD_BCHECK,
		P_FLASH, P_PER_W, P_PER_R, P_END
	} phase_t;

	localparam logic [31:0] OC_BASE = 32'h0C00_0000;
	localparam logic [31:0] SD_BASE = 32'h0A00_0000;
	localparam logic [31:0] PER_REG = 32'h0C1E_0010;

	// the boot code's EMIF writes
	function automatic logic [31:0] emif_val(input logic [2:0] i);
		case (i)
			3'd0: return 32'h7037_F800;
			3'd1: return 32'hB295_0489;
			3'd2: return 32'h0000_0037;
			3'd3: return 32'h2020_2112;
			3'd4: return 32'h2020_2112;
			default: return 32'h0110_0000;
		endcase
	endfunction
	function automatic logic [7:0] emif_off(input logic [2:0] i);
		case (i)
			3'd0: return 8'h00;
			3'd1: return 8'h04;
			3'd2: return 8'h08;
			3'd3: return 8'h10;
			3'd4: return 8'h14;
			default: return 8'h18;
		endcase
	endfunction

	logic [15:0] pass_n = '0;
	logic [15:0] errors_q = '0;

	// (functions take everything as arguments: Quartus 17 does not see a
	// module variable read inside a function as a use)
	function automatic logic [31:0] pat(input logic [31:0] a, input logic [15:0] p);
		logic [31:0] x;
		x = a ^ {p, p};
		return x ^ {x[7:0], x[31:8]} ^ {x[18:0], x[31:19]} ^ 32'h5A3C_96E1;
	endfunction

	phase_t      phase = P_EMIF_W;
	logic [23:0] idx;             // word (or line) within the phase
	logic [1:0]  beat;
	logic        active = 1'b0;   // a transaction is on the bus
	logic        was_burst;
	logic [31:0] flash_first;
	logic        check;           // the read is checked against want

	assign wb_bte    = 2'b00;
	assign passes    = pass_n;
	assign errors    = errors_q;

	// the transaction for the current phase and index
	logic        t_we, t_burst, t_chk;
	logic [31:0] t_adr, t_dat;
	logic [3:0]  t_sel;
	logic [23:0] t_last;          // last index of the phase

	always_comb begin
		t_we = 1'b0; t_burst = 1'b0; t_chk = 1'b1;
		t_adr = 32'd0; t_dat = 32'd0; t_sel = 4'hF; t_last = '0;
		case (phase)
			P_EMIF_W: begin t_we = 1'b1; t_adr = {24'h080000, emif_off(idx[2:0])}; t_dat = emif_val(idx[2:0]); t_last = 24'd5; end
			P_EMIF_R: begin t_adr = {24'h080000, emif_off(idx[2:0])}; t_last = 24'd5; end
			P_CS2: begin t_adr = {30'h0100_0000, idx[0], 1'b0}; t_sel = idx[0] ? 4'hC : 4'h3; t_last = 24'd1; end
			P_OC_FILL, P_OC_CHECK: begin
				t_we = phase == P_OC_FILL; t_burst = 1'b1;
				t_adr = OC_BASE | 32'({idx, 4'h0}); t_last = 24'((1 << (ONCHIP_WORDS_LOG2 - 2)) - 1);
			end
			P_SD_FILL, P_SD_CHECK: begin
				t_we = phase == P_SD_FILL; t_burst = 1'b1;
				t_adr = SD_BASE | 32'({idx, 4'h0}); t_last = 24'((1 << (SDRAM_WORDS_LOG2 - 2)) - 1);
			end
			P_OC_BYTES, P_OC_BCHECK, P_SD_BYTES, P_SD_BCHECK: begin
				// every 16th word: four byte writes or two halfword writes
				t_we   = phase == P_OC_BYTES || phase == P_SD_BYTES;
				t_adr  = ((phase == P_OC_BYTES || phase == P_OC_BCHECK) ? OC_BASE : SD_BASE) | 32'({idx[23:3], 6'h00});
				t_sel  = t_we ? (idx[2] ? (4'h3 << {idx[0], 1'b0}) : (4'h1 << idx[1:0])) : 4'hF;
				t_last = 24'(((1 << ((phase == P_OC_BYTES || phase == P_OC_BCHECK) ? ONCHIP_WORDS_LOG2 : SDRAM_WORDS_LOG2)) / 16) * 8 - 1);
			end
			P_FLASH: begin
				// even index: a classic read of a line's first word; odd: the line
				t_burst = idx[0];
				t_adr   = 32'({idx[23:1], 4'h0});
				t_chk   = idx[0];
				t_last  = 24'((1 << (FLASH_WORDS_LOG2 - 1)) - 1);
			end
			P_PER_W: begin t_we = 1'b1; t_adr = PER_REG; end
			P_PER_R: begin t_adr = PER_REG; end
			default: ;
		endcase
		if (t_we && phase != P_EMIF_W) t_dat = pat(t_adr, pass_n);
	end

	// the expected data of a read beat
	function automatic logic [31:0] expect_of(input phase_t ph, input logic [31:0] a, input logic [2:0] i,
			input logic [31:0] ff, input logic [15:0] p);
		case (ph)
			P_EMIF_R: return emif_val(i);
			P_CS2:    return 32'd0;
			P_FLASH:  return ff;
			default:  return pat(a, p);
		endcase
	endfunction

	always_ff @(posedge clk) begin
		pass_done <= 1'b0;

		if (!active) begin
			if (enable && !reset) begin
				wb_cyc <= 1'b1;
				wb_stb <= 1'b1;
				wb_we  <= t_we;
				wb_adr <= t_adr;
				wb_dat <= t_we && (phase == P_OC_BYTES || phase == P_SD_BYTES)
				          ? (pat(t_adr, pass_n) & {{8{t_sel[3]}}, {8{t_sel[2]}}, {8{t_sel[1]}}, {8{t_sel[0]}}}) |
				            (~pat(t_adr, pass_n) & ~{{8{t_sel[3]}}, {8{t_sel[2]}}, {8{t_sel[1]}}, {8{t_sel[0]}}})
				          : t_dat;
				wb_sel <= t_sel;
				wb_cti <= t_burst ? 3'b010 : 3'b111;
				was_burst <= t_burst;
				check  <= t_chk;
				beat   <= 2'd0;
				active <= 1'b1;
			end
		end else if (wb_ack || wb_err) begin
			// the beat on the bus is done
			if (!wb_we && check) begin
				if (wb_err || (wb_dat_i & {{8{wb_sel[3]}}, {8{wb_sel[2]}}, {8{wb_sel[1]}}, {8{wb_sel[0]}}}) !=
				              (expect_of(phase, wb_adr, idx[2:0], flash_first, pass_n) & {{8{wb_sel[3]}}, {8{wb_sel[2]}}, {8{wb_sel[1]}}, {8{wb_sel[0]}}})) begin
					if (errors_q == 16'd0) begin
						err_adr  <= wb_adr;
						err_got  <= wb_dat_i;
						err_want <= expect_of(phase, wb_adr, idx[2:0], flash_first, pass_n);
					end
					if (errors_q != 16'hFFFF) errors_q <= errors_q + 16'd1;
				end
			end
			if (phase == P_FLASH && !was_burst) flash_first <= wb_dat_i;
			if (was_burst && beat != 2'd3) begin
				beat   <= beat + 2'd1;
				wb_adr <= wb_adr + 32'd4;
				wb_dat <= pat(wb_adr + 32'd4, pass_n);
				wb_cti <= (beat == 2'd2) ? 3'b111 : 3'b010;
				if (phase == P_FLASH) check <= 1'b0;   // only the first beat is compared
			end else begin
				wb_cyc <= 1'b0;
				wb_stb <= 1'b0;
				active <= 1'b0;
				if (idx == t_last) begin
					idx <= '0;
					if (phase == P_PER_R) begin
						phase     <= P_EMIF_W;
						pass_n    <= pass_n + 16'd1;
						pass_done <= 1'b1;
					end else begin
						phase <= phase_t'(phase + 4'd1);
					end
				end else begin
					idx <= idx + 24'd1;
				end
			end
		end

		if (reset || !enable) begin
			if (!active || reset) begin
				wb_cyc <= 1'b0;
				wb_stb <= 1'b0;
				active <= 1'b0;
				phase  <= P_EMIF_W;
				idx    <= '0;
			end
		end
		if (reset) begin
			errors_q <= '0;
		end
	end

endmodule
