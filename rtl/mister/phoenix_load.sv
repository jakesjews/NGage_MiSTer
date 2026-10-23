// SPDX-License-Identifier: GPL-2.0-or-later
// Phoenix DCT4 stream -> flash arrays, followed by the RH-29 4.60 patch ROM.
// F1 MCU / F2 language, hps_io WIDE=1. The first file of a pair fills CS0
// and ONLY the firmware half of CS1 with FF. Either file may arrive first;
// repeating a completed file starts a new pair. C: is never touched.
//
// Checksums: complemented byte sum, with the +1 data-checksum convention
// used by the supplied C1/S5 also accepted (fls2bin's d_fix == 1). For 21,
// the checksummed header tail is bytes 7..14, identical to 14's bytes 1..8;
// its six extra bytes are opaque. 20/25/26 have no checksums in fls2bin.
// 2E mass-memory records are checked but never mapped into NOR.
//
// One byte is kept as lookahead: WIDE pads an odd-length file with an
// unspecified high byte. At EOF that byte is discarded ONLY at a record
// boundary; a partial header/data/token section fails. ioctl_wait provides
// backpressure during fills, DDR writes, verification and patching.
module phoenix_load #(
	parameter logic [28:0] CS0_BASE = 29'h0620_0000,
	parameter logic [28:0] CS1_BASE = 29'h0640_0000,
	parameter PATCH_FILE = "rtl/mister/phoenix_patch.hex"
) (
	input logic clk, reset,
	input logic ioctl_download,
	input logic [5:0] ioctl_index,
	input logic ioctl_wr,
	input logic [15:0] ioctl_dout,
	output logic ioctl_wait,
	output logic ld_we = 0, ld_rd = 0,
	output logic [28:0] ld_addr,
	output logic [63:0] ld_din,
	output logic [7:0] ld_be,
	input logic ld_busy, ld_valid,
	input logic [63:0] ld_data,
	output logic ready = 0,
	output logic busy,
	output logic [2:0] note = 0, // 1 damaged, 2 unknown version, 3 loaded, 4 reload both
	output logic [15:0] errors = 0,
	output wire [1:0] debug_have,
	output wire [4:0] debug_state
);
	`include "rtl/mister/phoenix_patch.vh"
	localparam int PW = $clog2(PATCH_BYTES);
	logic [7:0] patch_rom [0:PATCH_BYTES-1];
	initial $readmemh(PATCH_FILE, patch_rom);
	logic [PW-1:0] rom_ptr;
	logic [7:0] rom_q;
	always_ff @(posedge clk) rom_q <= patch_rom[rom_ptr];

	typedef enum logic [4:0] {IDLE, FILL, MAGIC, TLEN, TCOUNT, TID, TLEN1,
		TLEN2, TESC, TDATA, TPAD, RECORD, HEADER, DATA, BAD,
		VERIFY, VWAIT, PFETCH, PBYTE} state_t;
	state_t st = IDLE;
	wire active = ioctl_download && (ioctl_index[5:0] == 1 || ioctl_index[5:0] == 2);
	logic active_q = 0, start_pending = 0, next_lang = 0, lang = 0;
	logic eof = 0, session_live = 0, seen_record = 0;
	logic reload_notice = 0;
	logic [1:0] have = 0;
	assign debug_have = have;
	assign debug_state = 5'(st);
	logic [31:0] fifo;
	logic [2:0] count = 0;
	wire [7:0] byte_in = fifo[7:0];
	wire parsing = st >= MAGIC && st <= BAD;
	assign busy = st != IDLE || start_pending || active;
	assign ioctl_wait = start_pending || (active && !active_q) || count >= 2 ||
	                    ld_we || ld_rd || (st != IDLE && !parsing);
	wire consume = parsing && count != 0 && (count > 1 || eof) && !ld_we && !ioctl_wr;

	logic fill_chip;
	logic [20:0] fill_beat;
	logic [1:0] idx;
	logic [31:0] token_left, token_count;
	logic [15:0] token_data;
	logic nested;
	logic [7:0] rtype, hsum, dsum, dcheck;
	logic [4:0] hi, hlen;
	logic [31:0] addr;
	logic [23:0] length, left;
	wire mapped = rtype == 8'h14 || rtype == 8'h21;
	wire checked_data = mapped || rtype == 8'h2E;
	wire [7:0] sum_next = dsum + byte_in;
	wire data_ok = dcheck == ~sum_next || (mapped && dcheck == (8'd0 - sum_next));
	wire [32:0] block_end = {1'b0, addr} + {9'd0, length};
	wire in_range = (addr < 32'h0100_0000 && block_end <= 33'h00100_0000) ||
	                (addr >= 32'h0200_0000 && block_end <= 33'h00240_0000);

	function automatic logic [28:0] image_beat(input logic chip, input logic [20:0] beat);
		return (chip ? CS1_BASE : CS0_BASE) + {8'd0, beat};
	endfunction
	function automatic logic [63:0] signature(input logic [1:0] n);
		case (n)
			0: return 64'h14c206de0813e5a4; // unpatched entry 8F00 digest
			1: return 64'h9960dc01f8c92a5c;
			2: return 64'hf0038f1bffb1002f; // unpatched entry 8F18 digest
			3: return 64'h517617f355432c59;
		endcase
	endfunction
	logic version_bad;
	logic patch_chip, patch_data;
	logic [2:0] patch_hi;
	logic [23:0] patch_off;
	logic [31:0] patch_left;

	task automatic damage();
		if (!(&errors)) errors <= errors + 16'd1;
	endtask
	// token_left includes the length byte being consumed now.
	task automatic token_begin(input logic [15:0] n);
		if ({16'd0, n} > token_left - 32'd1) begin
			damage(); st <= BAD;
		end else if (n == 0) begin
			token_count <= token_count - 32'd1;
			st <= token_count == 1 ? (token_left == 1 ? RECORD : TPAD) : TID;
		end else begin
			token_data <= n;
			st <= TDATA;
		end
	endtask

	always @(posedge clk) begin
		active_q <= active;
		note <= 0;
		if (ld_we && !ld_busy) ld_we <= 0;
		if (ld_rd && !ld_busy) ld_rd <= 0;
		if (active && !active_q) begin
			start_pending <= 1;
			next_lang <= ioctl_index[5:0] == 2;
			ready <= 0;
		end
		if (!active && active_q) eof <= 1;
		if (active && ioctl_wr) begin
			fifo <= fifo | ({16'd0, ioctl_dout} << (8 * count));
			count <= count + 3'd2;
		end else if (consume) begin
			fifo <= fifo >> 8;
			count <= count - 3'd1;
		end

		if (st == IDLE && start_pending && !ld_we && !ld_rd) begin
			start_pending <= 0;
			lang <= next_lang;
			eof <= !active;
			fifo <= 0; count <= 0; errors <= 0; seen_record <= 0;
			// A repeated completed file invalidates the previous pair. Report at
			// EOF, after Main has finished its synchronous file transfer. Comparing
			// the incoming original to DDR is not sufficient: DDR is now patched.
			reload_notice <= session_live && have[next_lang];
			if (!session_live || have[next_lang]) begin
				have <= 0;
				session_live <= 1;
				fill_chip <= 0; fill_beat <= 0;
				st <= FILL;
			end else st <= MAGIC;
		end

		if (st == FILL && (!ld_we || !ld_busy)) begin
			ld_we <= 1; ld_din <= '1; ld_be <= '1;
			ld_addr <= (fill_chip ? CS1_BASE : CS0_BASE) + {8'd0, fill_beat};
			fill_beat <= fill_beat + 21'd1;
			if (!fill_chip && &fill_beat) begin
				fill_chip <= 1; fill_beat <= 0;
			end else if (fill_chip && fill_beat == 21'h07FFFF) st <= MAGIC;
		end

		if (consume) begin
			// Last high byte of an odd file: arbitrary transport padding.
			if (eof && count == 1 && st == RECORD) begin end
			else if (st >= TCOUNT && st <= TPAD && token_left == 0) begin
				damage(); st <= BAD;
			end else begin
				if (st >= TCOUNT && st <= TPAD) token_left <= token_left - 32'd1;
				case (st)
					MAGIC: begin
						if (byte_in != 8'hA2) begin damage(); st <= BAD; end
						else begin st <= TLEN; idx <= 0; token_left <= 0; end
					end
					TLEN: begin
						token_left <= {token_left[23:0], byte_in}; idx <= idx + 2'd1;
						if (idx == 3) begin
							if ({token_left[23:0], byte_in} < 4) begin damage(); st <= BAD; end
							else begin st <= TCOUNT; token_count <= 0; end
						end
					end
					TCOUNT: begin
						token_count <= {token_count[23:0], byte_in}; idx <= idx + 2'd1;
						if (idx == 3) st <= {token_count[23:0], byte_in} == 0 ?
						                                  (token_left == 1 ? RECORD : TPAD) : TID;
					end
					TID: begin nested <= byte_in == 8'hF3; st <= TLEN1; end
					TLEN1: begin
						if (nested) begin token_data <= {byte_in, 8'd0}; st <= TLEN2; end
						else if (byte_in == 0) st <= TESC;
						else token_begin({8'd0, byte_in});
					end
					TLEN2: token_begin({token_data[15:8], byte_in});
					TESC: token_begin({8'd0, byte_in});
					TDATA: begin
						token_data <= token_data - 16'd1;
						if (token_data == 1) begin
							token_count <= token_count - 32'd1;
							st <= token_count == 1 ? (token_left == 1 ? RECORD : TPAD) : TID;
						end
					end
					TPAD: if (token_left == 1) st <= RECORD;
					RECORD: begin
						rtype <= byte_in; hi <= 1; hsum <= 0; dsum <= 0;
						addr <= 0; length <= 0; seen_record <= 1; st <= HEADER;
						case (byte_in)
							8'h14, 8'h2E, 8'h26: hlen <= 10;
							8'h21: hlen <= 16;
							8'h20: hlen <= 6;
							8'h25: hlen <= 2;
							default: begin damage(); st <= BAD; end
						endcase
					end
					HEADER: begin
						hi <= hi + 5'd1;
						if (hi < hlen - 1 && (rtype != 8'h21 || hi >= 7)) hsum <= hsum + byte_in;
						if ((rtype == 8'h14 && hi >= 1 && hi <= 4) || (rtype == 8'h21 && hi >= 7 && hi <= 10))
							addr <= {addr[23:0], byte_in};
						if ((rtype != 8'h21 && hi == 5) || (rtype == 8'h21 && hi == 11)) dcheck <= byte_in;
						if (((rtype == 8'h14 || rtype == 8'h2E) && hi >= 6 && hi <= 8) ||
						    (rtype == 8'h21 && hi >= 12 && hi <= 14) || (rtype == 8'h20 && (hi == 3 || hi == 4)))
							length <= {length[15:0], byte_in};
						if (hi == hlen - 1) begin
							left <= length; st <= length == 0 ? RECORD : DATA;
							if (rtype == 8'h25) begin left <= {16'd0, byte_in}; st <= byte_in == 0 ? RECORD : DATA; end
							if (rtype == 8'h26) st <= RECORD;
							if (checked_data && byte_in != ~hsum) damage();
							if (mapped && !in_range) begin damage(); st <= BAD; end
							if (checked_data && length == 0 && dcheck != 8'hFF && !(mapped && dcheck == 0)) damage();
						end
					end
					DATA: begin
						left <= left - 24'd1; dsum <= sum_next;
						if (mapped) begin
							ld_we <= 1; ld_addr <= image_beat(addr[25], addr[23:3]);
							ld_din <= {8{byte_in}}; ld_be <= 8'b1 << addr[2:0];
							addr <= addr + 32'd1;
						end
						if (left == 1) begin
							st <= RECORD;
							if (checked_data && !data_ok) damage();
						end
					end
					default: ; // BAD drains the file
				endcase
			end
		end

		if (eof && count == 0 && !ld_we && parsing) begin
			eof <= 0;
			if (st != RECORD || !seen_record || errors != 0) begin
				if (errors == 0) damage();
				note <= 1; session_live <= 0; have <= 0; st <= IDLE;
			end else begin
				have[lang] <= 1;
				if (have[!lang]) begin idx <= 0; version_bad <= 0; st <= VERIFY; end
				else begin
					st <= IDLE;
					if (reload_notice) note <= 4;
				end
			end
		end
		if (st == VERIFY && !ld_rd) begin
			ld_rd <= 1;
			ld_addr <= CS0_BASE + 29'h11E1 + 29'(idx) + 29'(idx[1]);
			st <= VWAIT;
		end
		if (st == VWAIT && ld_valid) begin
			version_bad <= version_bad || ld_data != signature(idx);
			idx <= idx + 2'd1;
			if (idx != 3) st <= VERIFY;
			else if (version_bad || ld_data != signature(idx)) begin note <= 2; st <= IDLE; end
			else begin
				rom_ptr <= 0; patch_hi <= 0; patch_data <= 0; st <= PFETCH;
			end
		end
		if (st == PFETCH && !ld_we) st <= PBYTE;
		if (st == PBYTE) begin
			rom_ptr <= rom_ptr + 1'b1; st <= PFETCH;
			if (patch_data) begin
				ld_we <= 1; ld_addr <= image_beat(patch_chip, patch_off[23:3]);
				ld_din <= {8{rom_q}}; ld_be <= 8'b1 << patch_off[2:0];
				patch_off <= patch_off + 24'd1; patch_left <= patch_left - 32'd1;
				if (patch_left == 1) begin patch_data <= 0; patch_hi <= 0; end
			end else begin
				patch_hi <= patch_hi + 3'd1;
				if (patch_hi == 0) begin
					patch_chip <= rom_q[0];
					if (rom_q == 8'hFF) begin ready <= 1; note <= 3; st <= IDLE; end
				end else if (patch_hi <= 3) patch_off <= {patch_off[15:0], rom_q};
				else patch_left <= {patch_left[23:0], rom_q};
				if (patch_hi == 7) patch_data <= 1;
			end
		end
		if (reset) begin
			st <= IDLE; active_q <= 0; start_pending <= 0; eof <= 0;
			count <= 0; fifo <= 0; have <= 0; session_live <= 0; reload_notice <= 0;
			ready <= 0; errors <= 0; ld_we <= 0; ld_rd <= 0; note <= 0; rom_ptr <= 0;
		end
	end
endmodule
