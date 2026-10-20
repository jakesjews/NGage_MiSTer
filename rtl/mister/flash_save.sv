// SPDX-License-Identifier: GPL-2.0-or-later
//
// The CS1 flash image as a save file: an 8 MB image mounted on an hps_io
// block slot (WIDE = 1, 512-byte blocks) is copied into DDR3 at CS1's place
// (0x32000000, where ddram_flash serves the chip from), and every 512-byte
// block the firmware changes there (programs and erases of the C: drive, CS1
// 0x400000-0x7FFFFF) is written back to the file. So phone settings and game
// saves survive a power cycle.
//
//   * Mount (img_mounted with an 8 MB image): the dirty bitmap is cleared, the
//     image is read in 4 KB requests (sd_blk_cnt 7) into a buffer and copied
//     into DDR3 through ngage_mem's loader port; loading is high meanwhile
//     (hold the core in reset). Another size unmounts (note 2); a read-only
//     mount loads but never writes back (note 3).
//   * ddram_flash pulses mark for each CS1 word it writes; the block's bit in
//     a 16K-bit block RAM is set.
//   * Write-back starts QUIET_CLKS after the last change, MAX_CLKS after the
//     first unsaved one at the latest, or at once on save_now. It scans the
//     bitmap and for each dirty block reads it from DDR3 (ddram_flash's block
//     read: the bit is cleared in the clock the read is issued, so a write
//     after that marks it again and it goes out again) and sends it with
//     sd_wr. A pass that finds nothing, with no change during it, ends.
//   * The state survives a core reset (reset is the power-on reset); an ioctl
//     load of CS1 detaches the file (nothing more is written to it until the
//     next mount).
// CS0 is not saved: in the RH-29 v4.60 ROM only medint.pdd programs or erases
// flash, in its CS1 region, and the model's saved CS1 images differ from the
// firmware's only in 0x400000-0x7FFFFF.
module flash_save #(
	parameter logic [28:0] CS1_BASE   = 29'h0640_0000,     // 0x32000000 / 8
	parameter int          QUIET_CLKS = 104_000_000 / 10,  // 100 ms without a change
	parameter int          MAX_CLKS   = 2 * 104_000_000    // 2 s after the first change
) (
	input  logic        clk,
	input  logic        reset,

	// hps_io, this slot
	input  logic        img_mounted,
	input  logic        img_readonly,
	input  logic [63:0] img_size,
	output logic [31:0] sd_lba,
	output logic [5:0]  sd_blk_cnt,
	output logic        sd_rd = 1'b0,
	output logic        sd_wr = 1'b0,
	input  logic        sd_ack,
	input  logic [12:0] sd_buff_addr,
	input  logic [15:0] sd_buff_dout,
	output logic [15:0] sd_buff_din,
	input  logic        sd_buff_wr,

	// into DDR3: ngage_mem's loader port
	output logic        ld_we = 1'b0,
	output logic [28:0] ld_addr,
	output logic [63:0] ld_din,
	output logic [7:0]  ld_be,
	input  logic        ld_busy,

	// ngage_mem's save port (ddram_flash)
	input  logic        mark,
	input  logic [13:0] mark_blk,
	output logic        bk_req = 1'b0,
	output logic [13:0] bk_blk,
	input  logic        bk_taken,
	input  logic        bk_valid,
	input  logic [63:0] bk_data,

	input  logic        detach,
	input  logic        save_now,
	output logic        loading = 1'b0,
	output logic        saving_on,
	output logic        unsaved,
	output logic        active,
	output logic [1:0]  note = 2'd0,   // pulse: 1 mounted, 2 not 8 MB, 3 read-only
	output logic        saved = 1'b0   // pulse: a write-back asked for with save_now is done
);

	localparam int QW = $clog2(QUIET_CLKS + 1);
	localparam int MW = $clog2(MAX_CLKS + 1);

	localparam logic [3:0] S_INIT = 4'd0, S_OFF = 4'd1, S_SWEEP = 4'd2, S_LREQ = 4'd3,
	                       S_LXFER = 4'd4, S_LCOPY = 4'd5, S_IDLE = 4'd6, S_SCAN = 4'd7,
	                       S_CHECK = 4'd8, S_RD = 4'd9, S_RDATA = 4'd10, S_WREQ = 4'd11,
	                       S_WXFER = 4'd12;

	// power-up values as the reset's, so nothing moves before the first reset
	logic [3:0]  st = S_INIT;
	logic        ro = 1'b0, attached = 1'b0, pending = 1'b0, during = 1'b0, forced = 1'b0, force_q = 1'b0;
	logic [13:0] ptr;                  // bitmap sweep / scan position, load block
	logic [8:0]  beat;                 // copy beat in the 4 KB buffer
	logic [1:0]  cph;                  // copy phase
	logic [13:0] blk;                  // the block being written back
	logic [QW-1:0] quiet;
	logic [MW-1:0] age;

	// ------------------------------------------------------------------
	// The dirty bitmap: one bit a block. Writes: a mark (1), the clear in the
	// clock a block read is issued (0; never with a mark), the sweep (0).
	// ------------------------------------------------------------------
	logic        bm_we, bm_wd, bm_q;
	logic [13:0] bm_wa;

	always_comb begin
		bm_we = 1'b0;
		bm_wa = ptr;
		bm_wd = 1'b0;
		if (mark) begin
			bm_we = 1'b1;
			bm_wa = mark_blk;
			bm_wd = 1'b1;
		end else if (bk_taken) begin
			bm_we = 1'b1;
			bm_wa = blk;
		end else if (st == S_INIT || st == S_SWEEP) begin
			bm_we = 1'b1;
		end
	end

	sdp_ram #(.AW(14), .DW(1)) bitmap (
		.clk(clk), .we(bm_we), .waddr(bm_wa), .wdata(bm_wd), .raddr(ptr), .rdata(bm_q)
	);

	// ------------------------------------------------------------------
	// The buffer: 4 KB as 512 beats of four 16-bit lanes. Written by the
	// HPS (load) or by block reads; read for the DDR3 copy or by the HPS.
	// ------------------------------------------------------------------
	logic [3:0]  bf_we;
	logic [8:0]  bf_wa, bf_ra;
	logic [63:0] bf_wd, bf_q;
	logic [1:0]  lane_q;

	always_comb begin
		bf_we = 4'b0000;
		bf_wa = sd_buff_addr[10:2];
		bf_wd = {4{sd_buff_dout}};
		// (a request here is 4 KB at most: words past it are dropped)
		if (st == S_LXFER && sd_ack && sd_buff_wr && sd_buff_addr[12:11] == 2'b00) begin
			bf_we = 4'b0001 << sd_buff_addr[1:0];
		end else if (st == S_RDATA && bk_valid) begin
			bf_we = 4'b1111;
			bf_wa = beat;
			bf_wd = bk_data;
		end
		bf_ra = (st == S_LCOPY) ? beat : sd_buff_addr[10:2];
	end

	genvar l;
	generate
		for (l = 0; l < 4; l++) begin : g_lane
			sdp_ram #(.AW(9), .DW(16)) buffer (
				.clk(clk), .we(bf_we[l]), .waddr(bf_wa), .wdata(bf_wd[16 * l +: 16]),
				.raddr(bf_ra), .rdata(bf_q[16 * l +: 16])
			);
		end
	endgenerate

	always_ff @(posedge clk) lane_q <= sd_buff_addr[1:0];
	assign sd_buff_din = bf_q[16 * lane_q +: 16];

	// ------------------------------------------------------------------
	// Control
	// ------------------------------------------------------------------
	assign saving_on = attached && !ro && st != S_OFF && st != S_INIT && !loading;
	assign unsaved   = saving_on && pending;
	assign active    = st == S_LREQ || st == S_LXFER || st == S_LCOPY || st == S_RD ||
	                   st == S_RDATA || st == S_WREQ || st == S_WXFER;
	assign bk_blk    = blk;
	assign ld_be     = 8'hFF;
	assign ld_din    = bf_q;

	wire go = saving_on && pending && (force_q || quiet == QW'(QUIET_CLKS) || age == MW'(MAX_CLKS));

	always_ff @(posedge clk) begin
		note  <= 2'd0;
		saved <= 1'b0;
		if (save_now && !forced) force_q <= 1'b1;
		forced <= save_now;

		// changes
		if (mark) begin
			if (!pending) age <= '0;
			pending <= 1'b1;
			during  <= 1'b1;
			quiet   <= '0;
		end else begin
			if (quiet != QW'(QUIET_CLKS)) quiet <= quiet + 1'd1;
		end
		if (pending && age != MW'(MAX_CLKS)) age <= age + 1'd1;
		if (bk_taken) bk_req <= 1'b0;
		if (ld_we && !ld_busy) ld_we <= 1'b0;
		if (detach) attached <= 1'b0;

		case (st)
			S_INIT: begin
				ptr <= ptr + 14'd1;
				if (&ptr) st <= S_OFF;
			end

			S_SWEEP: begin
				ptr <= ptr + 14'd1;
				if (&ptr) begin
					ptr <= 14'd0;           // the first block of the load
					st  <= S_LREQ;
				end
			end

			// the image, 4 KB at a time
			S_LREQ: begin
				sd_rd      <= 1'b1;
				sd_lba     <= {18'd0, ptr};
				sd_blk_cnt <= 6'd7;
				if (sd_ack) begin
					sd_rd <= 1'b0;
					st    <= S_LXFER;
				end
			end
			S_LXFER: begin
				if (!sd_ack) begin
					beat <= 9'd0;
					cph  <= 2'd0;
					st   <= S_LCOPY;
				end
			end
			S_LCOPY: begin
				case (cph)
					2'd0: cph <= 2'd1;                    // the buffer reads the beat
					2'd1: begin
						ld_we   <= 1'b1;
						ld_addr <= CS1_BASE + 29'({ptr, 6'd0}) + 29'(beat);
						cph     <= 2'd2;
					end
					default: begin
						if (!ld_we || !ld_busy) begin
							cph  <= 2'd0;
							beat <= beat + 9'd1;
							if (&beat) begin
								ptr <= ptr + 14'd8;
								if (ptr == 14'h3FF8) begin
									loading <= 1'b0;
									pending <= 1'b0;
									st      <= S_IDLE;
								end else begin
									st <= S_LREQ;
								end
							end
						end
					end
				endcase
			end

			S_IDLE: begin
				if (go) begin
					ptr    <= 14'd0;
					during <= 1'b0;
					st     <= S_SCAN;
				end else if (force_q && saving_on && !pending) begin
					force_q <= 1'b0;
					saved   <= 1'b1;
				end
			end

			// the bitmap, a bit every two clocks
			S_SCAN: st <= S_CHECK;
			S_CHECK: begin
				if (bm_q) begin
					blk    <= ptr;
					bk_req <= 1'b1;
					st     <= S_RD;
				end else if (&ptr) begin
					if (during) begin
						ptr    <= 14'd0;
						during <= 1'b0;
						st     <= S_SCAN;
					end else begin
						pending <= 1'b0;
						if (force_q) saved <= 1'b1;
						force_q <= 1'b0;
						st      <= S_IDLE;
					end
				end else begin
					ptr <= ptr + 14'd1;
					st  <= S_SCAN;
				end
			end

			// one block: read from DDR3 (the bit clears as the read is issued),
			// then to the file
			S_RD: if (bk_taken) begin
				beat <= 9'd0;
				st   <= S_RDATA;
			end
			S_RDATA: if (bk_valid) begin
				beat <= beat + 9'd1;
				if (beat == 9'd63) st <= S_WREQ;
			end
			S_WREQ: begin
				sd_wr      <= 1'b1;
				sd_lba     <= {18'd0, blk};
				sd_blk_cnt <= 6'd0;
				if (sd_ack) begin
					sd_wr <= 1'b0;
					st    <= S_WXFER;
				end
			end
			S_WXFER: if (!sd_ack) begin
				if (&blk) begin
					ptr <= 14'h3FFF;        // the pass ends at the next check
					st  <= S_CHECK;
				end else begin
					ptr <= blk + 14'd1;
					st  <= S_SCAN;
				end
			end

			default: ;
		endcase

		// a mount: an 8 MB image is loaded, anything else unmounts
		if (img_mounted) begin
			sd_rd   <= 1'b0;
			sd_wr   <= 1'b0;
			bk_req  <= 1'b0;
			pending <= 1'b0;
			force_q <= 1'b0;
			if (img_size == 64'd8388608) begin
				ro       <= img_readonly;
				attached <= 1'b1;
				loading  <= 1'b1;
				ptr      <= 14'd0;
				note     <= img_readonly ? 2'd3 : 2'd1;
				st       <= S_SWEEP;
			end else begin
				attached <= 1'b0;
				loading  <= 1'b0;
				if (img_size != 64'd0) note <= 2'd2;
				st       <= S_OFF;
			end
		end

		if (reset) begin
			st       <= S_INIT;
			ptr      <= 14'd0;
			ro       <= 1'b0;
			attached <= 1'b0;
			pending  <= 1'b0;
			during   <= 1'b0;
			force_q  <= 1'b0;
			forced   <= 1'b0;
			loading  <= 1'b0;
			sd_rd    <= 1'b0;
			sd_wr    <= 1'b0;
			bk_req   <= 1'b0;
			ld_we    <= 1'b0;
			quiet    <= '0;
			age      <= '0;
			sd_lba   <= 32'd0;
			sd_blk_cnt <= 6'd0;
		end
	end

endmodule
