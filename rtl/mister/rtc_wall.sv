// SPDX-License-Identifier: GPL-2.0-or-later
//
// The wall clock behind the UEMK RTC model (rtl/upp/upp_cbus.sv): set from
// MiSTer's RTC and counting in real time from there, with a calendar for the
// date. hps_io's RTC output has the MSM6242B layout: BCD seconds 7:0, minutes
// 15:8, hours 23:16, day 31:24, month 39:32, year 47:40 (2000-2099); bit 64
// toggles each time the HPS sends the time (after the data, at the end of
// the command), which it does when the core starts and then now and again,
// so the clock is set again each time. It is not reset with the core: only
// the power-up values (2000-01-01 00:00:00, valid low) start it.
//
// Outputs are binary: the time of day; the date as year << 16 | month << 8 |
// day, the layout of the HLE RTC date register (docs/UPP_WD2.md); days, the
// days since 2000-01-01 modulo 256, from which upp_cbus makes the UEMK day
// counter (it steps when the date does, also when the HPS moves the date);
// and valid, set once the HPS has sent a time, in the clock after it (when
// days follows the new date too).
module rtc_wall #(
	parameter int CLK_HZ = 104_000_000
) (
	input  logic        clk,

	input  logic [64:0] rtc,

	output logic        valid = 1'b0,
	output logic [5:0]  sec = 6'd0,
	output logic [5:0]  min = 6'd0,
	output logic [4:0]  hour = 5'd0,
	output logic [31:0] date = {16'd2000, 8'd1, 8'd1},
	output logic [7:0]  days = 8'd0
);

	localparam int PW = $clog2(CLK_HZ);

	logic [PW-1:0] pre = '0;
	logic          tog_q = 1'b0;
	logic          set_q = 1'b0;

	function automatic logic [6:0] bcd(input logic [7:0] b);
		return 7'(b[7:4]) * 7'd10 + 7'(b[3:0]);
	endfunction

	wire [15:0] year  = date[31:16];
	wire [7:0]  month = date[15:8];
	wire [7:0]  day   = date[7:0];
	wire [6:0]  y     = 7'(year - 16'd2000);
	wire        leap  = y[1:0] == 2'b00;        // 2000-2099

	logic [7:0] mdays;
	always_comb begin
		case (month)
			8'd2: mdays = leap ? 8'd29 : 8'd28;
			8'd4, 8'd6, 8'd9, 8'd11: mdays = 8'd30;
			default: mdays = 8'd31;
		endcase
	end

	// days before the month in a common year, modulo 256
	logic [7:0] mcum;
	always_comb begin
		case (month)
			8'd2:  mcum = 8'd31;
			8'd3:  mcum = 8'd59;
			8'd4:  mcum = 8'd90;
			8'd5:  mcum = 8'd120;
			8'd6:  mcum = 8'd151;
			8'd7:  mcum = 8'd181;
			8'd8:  mcum = 8'd212;
			8'd9:  mcum = 8'd243;
			8'd10: mcum = 8'(273);
			8'd11: mcum = 8'(304);
			8'd12: mcum = 8'(334);
			default: mcum = 8'd0;
		endcase
	end

	// days since 2000-01-01: 365 y + the leap years before y (2000 is one),
	// + the month's offset (+1 after February in a leap year) + day - 1
	wire [7:0] days_n = 8'(16'(y) * 16'd365) + 8'((y + 7'd3) >> 2) + mcum +
	                    {7'd0, leap && month > 8'd2} + day - 8'd1;

	always_ff @(posedge clk) begin
		tog_q <= rtc[64];
		set_q <= 1'b0;
		days  <= days_n;
		if (set_q) valid <= 1'b1;

		if (pre == PW'(CLK_HZ - 1)) begin
			pre <= '0;
			if (sec != 6'd59) begin
				sec <= sec + 6'd1;
			end else begin
				sec <= 6'd0;
				if (min != 6'd59) begin
					min <= min + 6'd1;
				end else begin
					min <= 6'd0;
					if (hour != 5'd23) begin
						hour <= hour + 5'd1;
					end else begin
						hour <= 5'd0;
						if (day < mdays) begin
							date[7:0] <= day + 8'd1;
						end else begin
							date[7:0] <= 8'd1;
							if (month < 8'd12) begin
								date[15:8] <= month + 8'd1;
							end else begin
								date[15:8]  <= 8'd1;
								date[31:16] <= year + 16'd1;
							end
						end
					end
				end
			end
		end else begin
			pre <= pre + 1'd1;
		end

		// a time from the HPS
		if (rtc[64] != tog_q) begin
			set_q <= 1'b1;
			pre   <= '0;
			sec   <= 6'(bcd(rtc[7:0]));
			min   <= 6'(bcd(rtc[15:8]));
			hour  <= 5'(bcd(rtc[23:16]));
			date  <= {16'd2000 + 16'(bcd(rtc[47:40])), 8'(bcd(rtc[39:32])), 8'(bcd(rtc[31:24]))};
		end
	end

endmodule
