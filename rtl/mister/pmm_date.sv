// SPDX-License-Identifier: GPL-2.0-or-later
//
// The phone's date at power-on, from MiSTer's clock.
//
// The UEMK's clock has the time of day and an 8-bit day counter, no date.
// The date is kept in PMM, group 212: records 0 and 1 hold one 64-bit time
// each (microseconds in EUser's calendar). NOS hands both to Symbian's
// rtc.dll when the phone starts, and rtc.dll takes the clock as set only
// when they are equal and not zero: the time is then the date of the first
// with the UEMK's time of day, plus the UEMK's day counter (rtc.dll
// 0x50349088, 0x5034A678 in RH-29 4.10). rtc.dll writes the pair equal as
// the last step of setting the clock and unequal, a minute apart, as the
// first; the steps between wait for UEMK interrupts this core does not make
// (rtl/upp/upp_cbus.sv), so PMM is left with the unequal pair, the clock
// counts as not set at every start and Startup.app asks for the time and
// date each time. And a phone that was off for a week would be a week
// behind in any case: its day counter starts at 0 here.
//
// So this block, on start, puts today's date (at 00:00:00) into both records
// of the PMM copy in DDR3, as the stand-in for NOS once handed rtc.dll the
// date of MiSTer's clock (docs/NOS_STANDIN.md, "Clock"). The time of day is
// the UEMK's, which is MiSTer's (rtl/mister/rtc_wall.sv). It is an emulator's
// convenience and changes data the firmware wrote, nothing the firmware
// runs. A PMM without the records (a phone before its first start) is left
// alone: NOS writes them, unequal, and the next start finds them.
//
// PMM here is the QD's: 64 KiB in eight 8 KiB sectors. A sector in use has
// "PMMCAT" at offset 6 and records from 0x20: F4 (A4 once replaced), group,
// record (16 bits), four bytes, length (16 bits), the offset of the next
// record in the sector (16 bits), data; little-endian (tools/mkpmm.py).
// Every sector's chain is walked, and each record 0 or 1 of group 212 that
// is in use and 8 bytes long gets the time. A chain ends at an FF where a
// record would start, at an offset that does not go forward, or at the
// sector's end.
//
// The loader port (rtl/mem/ddram_flash.sv): a command is held until ld_busy
// is low in a clock; a read's beat comes with ld_valid. A write into the PMM
// window empties that module's cache, so the CPU reads what was written.
module pmm_date #(
	parameter logic [28:0] PMM_BASE = 29'h0664_0000,   // 0x33200000 / 8
	// EUser's day number of 2000-01-01: the proleptic Gregorian count from
	// 0000-01-01 plus the 12 days of its Julian leap years up to 1600
	parameter logic [19:0] DAY_2000 = 20'd730497
) (
	input  logic        clk,
	input  logic        reset,
	input  logic        start,          // one clock: walk PMM and write the date
	input  logic [31:0] date,           // year << 16 | month << 8 | day, 2000-2099 (rtc_wall)
	output logic        busy,
	output logic [3:0]  patched,        // records written in the last walk

	output logic        ld_rd = 1'b0,
	output logic        ld_we = 1'b0,
	output logic [28:0] ld_addr,
	output logic [63:0] ld_din,
	output logic  [7:0] ld_be,
	input  logic        ld_busy,
	input  logic        ld_valid,
	input  logic [63:0] ld_data
);

	localparam logic [24:0] DAY_US_4K = 25'd21_093_750;   // microseconds a day / 4096
	localparam logic [12:0] FIRST_RECORD = 13'h0020;
	localparam logic [12:0] LAST_HEADER = 13'h2000 - 13'd12;
	localparam logic [12:0] LAST_TIME = 13'h2000 - 13'd20;

	typedef enum logic [2:0] {S_IDLE, S_MUL, S_FETCH, S_READ, S_EVAL, S_WRITE, S_WAIT} st_t;
	st_t st = S_IDLE;

	// ------------------------------------------------------------------
	// The date as EUser's time
	// ------------------------------------------------------------------
	function automatic logic [8:0] before_month(input logic [3:0] m);
		case (m)
			4'd1: return 9'd0;     4'd2: return 9'd31;    4'd3: return 9'd59;    4'd4: return 9'd90;
			4'd5: return 9'd120;   4'd6: return 9'd151;   4'd7: return 9'd181;   4'd8: return 9'd212;
			4'd9: return 9'd243;   4'd10: return 9'd273;  4'd11: return 9'd304;  default: return 9'd334;
		endcase
	endfunction

	// 2000-2099: every fourth year is a leap year
	wire [6:0]  year = 7'(date[31:16] - 16'd2000);
	wire [6:0]  leap_days = (year + 7'd3) >> 2;        // the leap days of the years before
	wire [19:0] day_no = DAY_2000 + 20'(year) * 20'd365 + 20'(leap_days) + 20'(before_month(date[11:8])) +
	                     20'(year[1:0] == 2'd0 && date[15:8] > 8'd2) + 20'(date[7:0]) - 20'd1;

	logic [44:0] mul_a;
	logic [24:0] mul_b;
	logic [44:0] mul_p;
	wire  [63:0] ttime = {7'd0, mul_p, 12'd0};

	// ------------------------------------------------------------------
	// The walk
	// ------------------------------------------------------------------
	logic [2:0]  sect;
	logic [12:0] p;                     // the record, as an offset in its sector
	logic        head;                  // the twelve bytes are a sector's start, not a record's
	logic [3:0]  idx;                   // the byte being fetched, then written
	logic [95:0] hdr;
	logic        have = 1'b0;           // beat_q holds beat have_beat
	logic [12:0] have_beat;
	logic [63:0] beat_q;

	wire [12:0] at = head ? 13'd0 : p;
	wire [15:0] fetch_pos = {sect, at} + 16'(idx);
	wire [15:0] write_pos = {sect, p} + 16'd12 + 16'(idx);

	wire [7:0]  r_tag = hdr[7:0];
	wire [7:0]  r_group = hdr[15:8];
	wire [15:0] r_record = hdr[31:16];
	wire [15:0] r_len = hdr[79:64];
	wire [15:0] r_next = hdr[95:80];
	wire        is_cat = hdr[95:48] == {"T", "A", "C", "M", "M", "P"};
	wire        is_date = r_tag == 8'hF4 && r_group == 8'd212 && r_record <= 16'd1 && r_len == 16'd8 && p <= LAST_TIME;
	wire        goes_on = r_next[15:13] == 3'd0 && r_next[12:0] > p && r_next[12:0] <= LAST_HEADER;

	assign busy = st != S_IDLE;
	wire unused = &{1'b0, hdr[47:32]};

	always_ff @(posedge clk) begin
		if (ld_rd && !ld_busy) ld_rd <= 1'b0;

		case (st)
			S_IDLE: if (start) begin
				mul_a   <= 45'(day_no);
				mul_b   <= DAY_US_4K;
				mul_p   <= '0;
				patched <= '0;
				st      <= S_MUL;
			end

			// the day number times a day's microseconds, a bit a clock
			S_MUL: begin
				if (mul_b[0]) mul_p <= mul_p + mul_a;
				mul_a <= {mul_a[43:0], 1'b0};
				mul_b <= {1'b0, mul_b[24:1]};
				if (mul_b[24:1] == '0) begin
					sect <= '0;
					head <= 1'b1;
					idx  <= '0;
					have <= 1'b0;
					st   <= S_FETCH;
				end
			end

			// twelve bytes at fetch_pos, a beat at a time
			S_FETCH: begin
				if (have && have_beat == fetch_pos[15:3]) begin
					hdr[8 * idx +: 8] <= beat_q[8 * fetch_pos[2:0] +: 8];
					if (idx == 4'd11) st <= S_EVAL;
					else idx <= idx + 4'd1;
				end else begin
					ld_rd   <= 1'b1;
					ld_addr <= PMM_BASE + 29'(fetch_pos[15:3]);
					st      <= S_READ;
				end
			end
			S_READ: if (ld_valid) begin
				beat_q       <= ld_data;
				have      <= 1'b1;
				have_beat <= fetch_pos[15:3];
				st        <= S_FETCH;
			end

			S_EVAL: begin
				idx <= '0;
				st  <= S_FETCH;
				if (head) begin
					if (is_cat) begin
						head <= 1'b0;
						p    <= FIRST_RECORD;
					end else if (sect == 3'd7) st <= S_IDLE;
					else sect <= sect + 3'd1;
				end else if (is_date) begin
					st <= S_WRITE;
				end else if (r_tag != 8'hFF && goes_on) begin
					p <= r_next[12:0];
				end else begin
					head <= 1'b1;
					if (sect == 3'd7) st <= S_IDLE;
					else sect <= sect + 3'd1;
				end
			end

			// the eight bytes of the time, one a write
			S_WRITE: begin
				ld_we   <= 1'b1;
				ld_addr <= PMM_BASE + 29'(write_pos[15:3]);
				ld_din  <= {8{ttime[8 * idx[2:0] +: 8]}};
				ld_be   <= 8'd1 << write_pos[2:0];
				st      <= S_WAIT;
			end
			S_WAIT: if (!ld_busy) begin
				ld_we <= 1'b0;
				have  <= 1'b0;
				if (idx == 4'd7) begin
					patched <= patched + 4'd1;
					idx     <= '0;
					st      <= S_FETCH;
					if (goes_on) p <= r_next[12:0];
					else begin
						head <= 1'b1;
						if (sect == 3'd7) st <= S_IDLE;
						else sect <= sect + 3'd1;
					end
				end else begin
					idx <= idx + 4'd1;
					st  <= S_WRITE;
				end
			end

			default: st <= S_IDLE;
		endcase

		if (reset) begin
			st    <= S_IDLE;
			ld_rd <= 1'b0;
			ld_we <= 1'b0;
			have  <= 1'b0;
		end
	end

endmodule
