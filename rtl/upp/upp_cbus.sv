// SPDX-License-Identifier: GPL-2.0-or-later
//
// UPP_WD2 CBUS master (0x0C150420-0x0C150427) with register models of the
// devices behind it, as the reference model has them (model/hw/ngage_cbus.c,
// model/cbus-regs.txt; bootstrap 0x35AC-0x3678, cbus.dll 0x5037CF4C read /
// 0x5037D28C write, RH-29 v4.60; docs/UPP_WD2.md). 16-bit registers:
//
//   +0x420  transfer length: bits 4:0 = data bits - 1 (the rest stored)
//   +0x422  control: bits 4:0 register, 7:5 device, bit 8 = read (writing it
//           starts the read); bits 9:0 stored. Read: bit 10 = done.
//   +0x424  data bits 31:16
//   +0x426  data bits 15:0; writing it starts a write of the register control
//           names, with the length's bits
// A 32-bit write is the low half, then the high half.
//
// The devices are not on a serial bus here: a transfer is a lookup in a
// register file of 8 devices x 32 registers, two clocks long (the model's is
// instant; done reads 0 for those clocks, and the data registers wait).
// Values (model/cbus-regs.txt):
//   UEMK (device 1): 0x15 interrupt status reads 0x0008 (bootstrap 0x2EE8 goes
//     on only with bit 3 or 4 set; [model guess] bit 3 = power-key power-on);
//     0x1F power-on status reads 0 except bit 1 = the power key held (ekeyb
//     0x5041CCBC reads it as the power key; the bootstrap at 0x3090 takes the
//     normal power-on path with it set, start-up reason 0). As in the model the
//     key counts as held for POWER_ON_HOLD_CLKS after reset (3 s, a user
//     switching the phone on; the model holds it 3 guest seconds because the
//     bootstrap reads it only after its flash digest check) and while
//     power_key is high. [deviation] It also stays held until the first read
//     of 0x1F, so that the bootstrap sees it however long the digest check
//     takes on this CPU; in the model that read comes after 1-2 s.
//     A/D converter: a write of 0x19 with bit 11 set converts channel bits
//     15:12 into 0x1A (10 bits): channel 6, the battery-size indicator, reads
//     485 ([model guess], inside cbus.dll's 380-590 "normal battery" range,
//     0x5037E240); other channels read 0.
//     Real-time clock (rtc.dll; the model's rtc_read): 0x11, 0x12 and 0x13
//     read the seconds, minutes and hours of the wall clock (rtl/mister/
//     rtc_wall.sv, MiSTer's RTC, counting in real time), 0x01 the day
//     counter, 8 bits, which steps when the wall clock's date does. A write
//     of 0x01 sets the counter. 0x04 (calibration; rtc.dll takes 0 for a
//     clock that lost power) is 0x00C0 after reset, as cbus-regs.txt.
//     At reset, and when the wall clock gets its first time from the HPS,
//     the counter is 0 and the HLE RTC date register (0x0C1F0100, an
//     emulator invention that upp_periph reads from rtc_base) takes the
//     wall clock's date: so date + counter days + time of day is the time.
//     Before the HPS has sent a time, the date register reads 0 (unknown)
//     and the clock runs from 00:00:00.
//   Device 4 (probably ZOCUS; cbus.dll's self-test 0x5037E008 needs register 0
//     to read 0x04xx): register 0 reads 0x0400.
//   Device 5 is the Bluetooth module (rtl/board/bt_module.sv, outside this
//     block as it is outside the chip): a read takes bt_rdata in the clock of
//     bt_rd, a write gives bt_wdata in the clock of bt_wr, with the register
//     in bt_reg. The write reaches the module a clock after it starts, from
//     registers (the value comes late in the clock and the module decodes a
//     command from it); done reads 0 for that clock. While the module makes
//     its next word (bt_busy) a read waits, done reading 0. A write started
//     while a read of the module is still on its way is not passed on (the
//     driver starts nothing before done).
//   Everything else: storage, 0 after reset.
// "ro" registers keep the written value but read their fixed one, as the
// model's ro lines. Reads and writes are masked to the transfer length.
module upp_cbus #(
	parameter int POWER_ON_HOLD_CLKS = 312_000_000
) (
	input  logic        clk,
	input  logic        reset,

	input  logic        acc,
	input  logic        we,
	input  logic        wr,
	input  logic        off_hi,       // the word at 0x0C150424 (0: 0x0C150420)
	input  logic [3:0]  be,
	input  logic [31:0] wdata,
	output logic [31:0] rmask,
	output logic [31:0] rdata,
	output logic        busy,

	input  logic        power_key,

	// the Bluetooth module, CBUS device 5
	output logic        bt_rd,
	output logic        bt_wr,
	output logic [4:0]  bt_reg,
	output logic [15:0] bt_wdata,
	input  logic [15:0] bt_rdata,
	input  logic        bt_busy,

	// the wall clock (rtc_wall)
	input  logic        rtc_valid,
	input  logic [5:0]  rtc_sec,
	input  logic [5:0]  rtc_min,
	input  logic [4:0]  rtc_hour,
	input  logic [7:0]  rtc_days,
	input  logic [31:0] rtc_date,
	output logic [31:0] rtc_base       // the HLE RTC date register
);

	// ---- the device model (model/cbus-regs.txt) ----
	function automatic logic is_ro(input logic [2:0] d, input logic [4:0] r);
		return (d == 3'd1 && r == 5'h15) || (d == 3'd1 && r == 5'h1F) || (d == 3'd4 && r == 5'h00);
	endfunction
	function automatic logic [31:0] ro_val(input logic [2:0] d, input logic [4:0] r);
		if (d == 3'd1 && r == 5'h15) return 32'h0008;
		if (d == 3'd4 && r == 5'h00) return 32'h0400;
		return 32'h0000;                  // UEMK 0x1F: bit 1 is the power key
	endfunction
	function automatic logic [9:0] adc_val(input logic [3:0] ch);
		return (ch == 4'd6) ? 10'd485 : 10'd0;
	endfunction
	// initial values of registers that are not ro: UEMK 0x04 = 0x00C0
	function automatic logic [31:0] init_val(input logic [7:0] i);
		return (i == {3'd1, 5'h04}) ? 32'h0000_00C0 : 32'd0;
	endfunction

	localparam int HW = $clog2(POWER_ON_HOLD_CLKS + 1);

	logic [15:0] len, data_hi, data_lo;
	logic [9:0]  ctrl;
	logic [9:0]  adc;                   // UEMK 0x1A
	logic        rd_pend, rd_q;
	logic [2:0]  rd_dev;
	logic [4:0]  rd_reg;
	logic [5:0]  rd_bits;
	logic [8:0]  clr;                   // the reset fill of the register file
	logic [HW-1:0] hold;
	logic          read_1f;            // UEMK 0x1F has been read since reset
	logic [7:0]    day_off;            // day counter = day_off + rtc_days
	logic          rtc_vq;

	wire  clearing = !clr[8];
	wire  power    = power_key || hold != '0 || !read_1f;

	// the register file
	logic        rf_we;
	logic [7:0]  rf_waddr;
	logic [31:0] rf_wdata, rf_q;

	sdp_ram #(.AW(8), .DW(32)) rf (
		.clk(clk),
		.we(rf_we),
		.waddr(rf_waddr),
		.wdata(rf_wdata),
		.raddr({rd_dev, rd_reg}),
		.rdata(rf_q)
	);

	function automatic logic [31:0] bmask(input logic [5:0] bits);
		return (bits >= 6'd32) ? 32'hFFFF_FFFF : (32'd1 << bits) - 32'd1;
	endfunction

	// the halves this access writes, and the values they leave
	wire        w_lo = wr && be[1:0] != 2'b00;
	wire        w_hi = wr && be[3:2] != 2'b00;
	wire [4:0]  len_n  = (w_lo && !off_hi) ? wdata[4:0] : len[4:0];
	wire [15:0] dhi_n  = (w_lo && off_hi) ? wdata[15:0] : data_hi;
	wire        start_rd = w_hi && !off_hi && wdata[24];
	wire        start_wr = w_hi && off_hi;
	wire [2:0]  w_dev  = ctrl[7:5];
	wire [4:0]  w_reg  = ctrl[4:0];
	wire [5:0]  w_bits = {1'b0, len[4:0]} + 6'd1;
	wire [31:0] w_val  = ({16'd0, wdata[31:16]} | ((w_bits > 6'd16) ? {dhi_n, 16'd0} : 32'd0)) & bmask(w_bits);

	// the Bluetooth module: a write goes out a clock later; a read in its
	// second clock waits while the module is busy or takes a write
	logic        bt_wr_q;
	logic [4:0]  bt_wreg_q;
	logic [15:0] bt_wdata_q;
	wire rd_bt   = rd_q && rd_dev == 3'd5;
	wire rd_hold = rd_bt && (bt_busy || bt_wr_q);
	assign bt_rd    = rd_bt && !rd_hold;
	assign bt_wr    = bt_wr_q;
	assign bt_reg   = bt_wr_q ? bt_wreg_q : rd_reg;
	assign bt_wdata = bt_wdata_q;

	wire xfer_busy = rd_pend || rd_q || clearing || bt_wr_q;

	always_comb begin
		rmask = 32'd0;
		rdata = 32'd0;
		busy  = 1'b0;
		if (acc) begin
			rmask = '1;
			if (!off_hi) begin
				rdata = {5'd0, !xfer_busy, ctrl[9:0], len};
			end else begin
				rdata = {data_lo, data_hi};
				busy  = !we && xfer_busy;
			end
		end
	end

	always_ff @(posedge clk) begin
		rf_we    <= 1'b0;
		rd_q     <= rd_pend || rd_hold;
		rd_pend  <= 1'b0;
		bt_wr_q    <= start_wr && w_dev == 3'd5 && !rd_bt;
		bt_wreg_q  <= w_reg;
		bt_wdata_q <= w_val[15:0];
		if (hold != '0) hold <= hold - 1'd1;

		if (w_lo) begin
			if (!off_hi) len <= wdata[15:0];
			else                data_hi <= wdata[15:0];
		end
		if (w_hi) begin
			if (!off_hi) ctrl <= wdata[25:16];
			else                data_lo <= wdata[31:16];
		end

		if (start_rd) begin
			rd_pend <= 1'b1;
			rd_dev  <= wdata[23:21];
			rd_reg  <= wdata[20:16];
			rd_bits <= {1'b0, len_n} + 6'd1;
		end
		if (rd_q && !rd_hold) begin
			logic [31:0] v;
			v = is_ro(rd_dev, rd_reg) ? ro_val(rd_dev, rd_reg) :
			    (rd_dev == 3'd1 && rd_reg == 5'h1A) ? {22'd0, adc} :
			    (rd_dev == 3'd5) ? {16'd0, bt_rdata} : rf_q;
			if (rd_dev == 3'd1) begin
				case (rd_reg)
					5'h11: v = {26'd0, rtc_sec};
					5'h12: v = {26'd0, rtc_min};
					5'h13: v = {27'd0, rtc_hour};
					5'h01: v = {24'd0, day_off + rtc_days};
					default: ;
				endcase
			end
			if (rd_dev == 3'd1 && rd_reg == 5'h1F) begin
				v[1] = power;
				read_1f <= 1'b1;
			end
			v = v & bmask(rd_bits);
			data_lo <= v[15:0];
			data_hi <= v[31:16];
		end
		if (start_wr) begin
			rf_we    <= 1'b1;
			rf_waddr <= {w_dev, w_reg};
			rf_wdata <= w_val;
			if (w_dev == 3'd1 && w_reg == 5'h1A) adc <= w_val[9:0];
			if (w_dev == 3'd1 && w_reg == 5'h19 && w_val[11]) adc <= adc_val(w_val[15:12]);
			if (w_dev == 3'd1 && w_reg == 5'h01) day_off <= w_val[7:0] - rtc_days;
		end

		// the wall clock's first time from the HPS: the counter starts again
		rtc_vq <= rtc_valid;
		if (rtc_valid && !rtc_vq) begin
			day_off  <= 8'd0 - rtc_days;
			rtc_base <= rtc_date;
		end

		if (clearing) begin
			rf_we    <= 1'b1;
			rf_waddr <= clr[7:0];
			rf_wdata <= init_val(clr[7:0]);
			clr      <= clr + 9'd1;
		end

		if (reset) begin
			len     <= 16'd0;
			ctrl    <= 10'd0;
			data_hi <= 16'd0;
			data_lo <= 16'd0;
			adc     <= 10'd0;
			rd_pend <= 1'b0;
			rd_q    <= 1'b0;
			bt_wr_q <= 1'b0;
			rd_dev  <= 3'd0;
			rd_reg  <= 5'd0;
			clr     <= 9'd0;
			hold    <= HW'(POWER_ON_HOLD_CLKS);
			read_1f <= 1'b0;
			day_off <= 8'd0 - rtc_days;
			rtc_vq  <= rtc_valid;
			rtc_base <= rtc_valid ? rtc_date : 32'd0;
		end
	end


endmodule
