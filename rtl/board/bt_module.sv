// SPDX-License-Identifier: GPL-2.0-or-later
//
// The N-Gage QD's Bluetooth module as its driver sees it: CBUS device 5, a
// Bluetooth 1.1 controller with nobody in range. The reference is
// model/hw/ngage_bt_chip.h, which keeps the same state register for
// register (sim/harness/bt_main.cpp compares the two access by access);
// docs/BLUETOOTH.md has the evidence, read out of btldd.ldd and hci.dll.
//
// Registers (16 bits; the number is the CBUS register):
//   0x00  data: read, the next two bytes of the packet held for the phone,
//         first byte in bits 15:8; write, the next two of the phone's packet
//   0x01  length in bytes of the packet held
//   0x06  read: status, bit 2 awake (always), bit 4 a packet is held, bit 6
//         register 0x08 has an answer, bit 7 the module has reset; bits 4-8
//         clear when read. Write: bit 0 resets the module
//   0x08  write 0x8000 | n: room for a packet of n bytes? 0xC000 | n: its n
//         bytes are written. Read: the answer, n with bits 15:14 = 00 / 01
//   0x09  reset reason, 0x0008 after a reset the phone asked for
//   0x0A  write 0x8000: answer through 0x08 with the buffer size, 520
// The interrupt line pulses for a clock when a status bit is set.
//
// Nothing is buffered. Of the phone's packet the module keeps what a
// command is decoded from (its type byte, opcode, parameter length and the
// first four parameter bytes) and, for Change_Local_Name, the words as
// they come, in a small RAM. Its own packet is made a word at a time from
// what the last command left: `rdata` for the data register is ready when
// `busy` is low, four clocks after the read before it or a write (which
// may change what the word is made from).
//
// The bus side (upp_cbus) gives `rd` only in a clock in which `busy` is
// low; `wr` at any time.
module bt_module #(
	parameter int CLK_HZ        = 104_000_000,
	parameter int RESET_CLKS    = CLK_HZ / 100,          // reset request to "reset": 10 ms, a guess
	parameter int INQ_UNIT_CLKS = (CLK_HZ / 100) * 128   // an inquiry's length unit, 1.28 s
) (
	input  logic        clk,
	input  logic        reset,        // the phone's power-on reset

	input  logic        rd,
	input  logic        wr,
	input  logic [4:0]  rn,           // the register
	input  logic [15:0] wdata,
	output logic [15:0] rdata,
	output logic        busy,
	output logic        irq
);

	localparam logic [4:0] R_DATA = 5'h00, R_RXLEN = 5'h01, R_STATUS = 5'h06,
	                       R_REG0 = 5'h08, R_REASON = 5'h09, R_START = 5'h0A;
	localparam logic [1:0] RX_NONE = 2'd0, RX_REPLY = 2'd1, RX_INQ = 2'd2;
	localparam logic [1:0] SRC_NONE = 2'd0, SRC_FIX = 2'd1, SRC_PAR = 2'd2, SRC_NAME = 2'd3;
	localparam logic [7:0] ST_OK = 8'h00, ST_UNKNOWN = 8'h01, ST_DISALLOWED = 8'h0C, ST_BAD = 8'h12;
	localparam logic [9:0] BUF_SIZE = 10'd520;
	localparam int RW = $clog2(RESET_CLKS + 1);
	localparam int UW = $clog2(INQ_UNIT_CLKS + 1);

	// ------------------------------------------------------------------
	// The values a command reads back before the phone has written them
	// (bt_par in the reference): entry, bytes, default, for the OGF 3 read
	// command at this OCF; the write command is the next OCF.
	// ------------------------------------------------------------------
	function automatic logic [4:0] par_entry(input logic [9:0] ocf);  // {hit, entry}
		case (ocf)
			10'h009: return {1'b1, 4'd0};
			10'h015: return {1'b1, 4'd1};
			10'h017: return {1'b1, 4'd2};
			10'h019: return {1'b1, 4'd3};
			10'h01B: return {1'b1, 4'd4};
			10'h01D: return {1'b1, 4'd5};
			10'h01F: return {1'b1, 4'd6};
			10'h021: return {1'b1, 4'd7};
			10'h023: return {1'b1, 4'd8};
			10'h025: return {1'b1, 4'd9};
			10'h029: return {1'b1, 4'd10};
			10'h02B: return {1'b1, 4'd11};
			10'h02E: return {1'b1, 4'd12};
			10'h039: return {1'b1, 4'd13};
			10'h03B: return {1'b1, 4'd14};
			10'h03D: return {1'b1, 4'd15};
			default: return 5'd0;
		endcase
	endfunction
	function automatic logic [2:0] par_size(input logic [3:0] e);
		case (e)
			4'd1, 4'd2, 4'd9: return 3'd2;
			4'd8:             return 3'd3;
			4'd4, 4'd5, 4'd13: return 3'd4;
			default:          return 3'd1;
		endcase
	endfunction
	function automatic logic [31:0] par_def(input logic [3:0] e);   // first byte lowest
		case (e)
			4'd1:  return 32'h0000_1FA0;      // connection accept timeout
			4'd2:  return 32'h0000_2000;      // page timeout
			4'd4:  return 32'h0012_0800;      // page scan activity
			4'd5:  return 32'h0012_0800;      // inquiry scan activity
			4'd9:  return 32'h0000_0060;      // voice setting
			4'd10: return 32'h0000_0001;      // broadcast retransmissions
			4'd13: return 32'h9E8B_3301;      // one inquiry access code, the general one
			default: return 32'd0;
		endcase
	endfunction

	// Commands that complete at once with fixed values (bt_fix): {hit, index, bytes}
	function automatic logic [8:0] fix_entry(input logic [15:0] op);
		case (op)
			16'h0C0D: return {1'b1, 4'd0, 4'd4};
			16'h0C11: return {1'b1, 4'd1, 4'd1};
			16'h0C12: return {1'b1, 4'd2, 4'd2};
			16'h0C38: return {1'b1, 4'd3, 4'd1};
			16'h1001: return {1'b1, 4'd4, 4'd8};
			16'h1003: return {1'b1, 4'd5, 4'd8};
			16'h1005: return {1'b1, 4'd6, 4'd7};
			16'h1007: return {1'b1, 4'd7, 4'd1};
			16'h1009: return {1'b1, 4'd8, 4'd6};
			16'h0C01, 16'h0C05, 16'h0C0B, 16'h0C31, 16'h0C33: return {1'b1, 4'd0, 4'd0};
			default:  return 9'd0;
		endcase
	endfunction
	function automatic logic [7:0] fix_byte(input logic [3:0] idx, input logic [2:0] k);
		logic [63:0] v;                   // first byte lowest
		case (idx)
			4'd3:    v = 64'h0000_0000_0000_0001;      // one inquiry access code
			4'd4:    v = 64'h0000_0001_0100_0001;      // HCI 1.1, LMP 1.1, manufacturer 1
			4'd5:    v = 64'h0000_0000_000F_FFFF;      // the features of 1.1
			4'd6:    v = 64'h0000_0800_0840_0153;      // ACL 339 x 8, SCO 64 x 8
			4'd8:    v = 64'h0000_0060_5700_0000;      // 00:60:57:00:00:00
			default: v = 64'd0;
		endcase
		return v[8 * k +: 8];
	endfunction

	// ------------------------------------------------------------------
	// State
	// ------------------------------------------------------------------
	logic          in_reset;
	logic [RW-1:0] rst_cnt;
	logic          ev_rx, ev_ack, ev_reset, reason_host;
	logic [15:0]   reg0;

	// the phone's packet
	logic [9:0]  tx_cnt;                // bytes written since room was asked for
	logic        is_cmd;                // its byte 0 was 0x01
	logic [15:0] op;                    // bytes 2, 3
	logic [7:0]  plen;                  // byte 4
	logic [31:0] hold;                  // bytes 5-8, first lowest

	// the controller
	logic [15:0] par_set;
	logic [7:0]  name_len;
	logic        inq_run, inq_done;
	logic [5:0]  inq_left;
	logic [UW-1:0] inq_cnt;

	// the answer to the last command
	logic        rep_pend, rep_cs;
	logic [7:0]  rep_status;
	logic [15:0] rep_op;
	logic [1:0]  rep_src;
	logic [3:0]  rep_idx;
	logic [7:0]  rep_n;

	// the packet held for the phone
	logic [1:0]  rx_kind;
	logic [8:0]  rx_len, rx_idx;
	logic [15:0] rx_word;
	logic [2:0]  fst;                   // 0 idle, 1-4 making rx_word
	logic [7:0]  b0;

	// ------------------------------------------------------------------
	// A command, decoded when the phone says its packet is written
	// ------------------------------------------------------------------
	wire [8:0]  tx_w   = tx_cnt[9:1];
	wire        w_data = wr && !in_reset && rn == R_DATA && tx_cnt < BUF_SIZE;
	logic [6:0]  name_ra;
	logic [15:0] name_q;
	logic        par_we;
	logic [31:0] par_q;

	wire        w_reg0   = wr && !in_reset && rn == R_REG0;
	wire        w_room   = w_reg0 && wdata[15:14] == 2'b10;
	wire        w_done   = w_reg0 && wdata[15:14] == 2'b11;
	wire [9:0]  c_len    = (wdata[13:0] > {4'd0, BUF_SIZE}) ? BUF_SIZE : wdata[9:0];
	wire        c_valid  = w_done && tx_cnt >= c_len && c_len >= 10'd5 && is_cmd;
	wire [9:0]  c_room   = c_len - 10'd5;
	wire [7:0]  c_plen   = ({2'd0, plen} > c_room) ? c_room[7:0] : plen;
	wire [5:0]  c_ogf    = op[15:10];
	wire [8:0]  c_fix    = fix_entry(op);
	wire [4:0]  c_rd     = par_entry(op[9:0]);
	wire [4:0]  c_wr     = par_entry(op[9:0] - 10'd1);
	wire        c_parhit = c_ogf == 6'd3 && !c_fix[8] && (c_rd[4] || c_wr[4]);
	wire        c_wr_bad = {5'd0, par_size(c_wr[3:0])} > c_plen || (c_wr[3:0] == 4'd13 && hold[7:0] != 8'd1);
	wire        c_inq_bad = c_plen < 8'd5 || hold[31:24] < 8'd1 || hold[31:24] > 8'h30;

	logic        d_rep, d_cs;
	logic [7:0]  d_status;
	logic [1:0]  d_src;
	logic [3:0]  d_idx;
	logic [7:0]  d_n;
	logic        d_inq_start, d_inq_stop, d_hreset, d_name;

	always_comb begin
		d_rep       = 1'b1;
		d_cs        = 1'b0;
		d_status    = ST_OK;
		d_src       = SRC_NONE;
		d_idx       = 4'd0;
		d_n         = 8'd0;
		d_inq_start = 1'b0;
		d_inq_stop  = 1'b0;
		d_hreset    = 1'b0;
		d_name      = 1'b0;
		par_we      = 1'b0;
		if (c_fix[8]) begin
			d_n   = {4'd0, c_fix[3:0]};
			d_src = (c_fix[3:0] != 4'd0) ? SRC_FIX : SRC_NONE;
			d_idx = c_fix[7:4];
		end else if (c_parhit && c_rd[4]) begin        // Read_...
			d_src = SRC_PAR;
			d_idx = c_rd[3:0];
			d_n   = {5'd0, par_size(c_rd[3:0])};
		end else if (c_parhit) begin                   // Write_...
			if (c_wr_bad) d_status = ST_BAD;
			else          par_we   = c_valid;
		end else begin
			case (op)
				16'h0401: begin                        // Inquiry
					d_cs = 1'b1;
					if (c_inq_bad)    d_status = ST_BAD;
					else if (inq_run) d_status = ST_DISALLOWED;
					else              d_inq_start = 1'b1;
				end
				16'h0402: begin                        // Inquiry_Cancel
					if (inq_run) d_inq_stop = 1'b1;
					else         d_status   = ST_DISALLOWED;
				end
				16'h0C03: d_hreset = 1'b1;             // Reset
				16'h0C13: d_name   = 1'b1;             // Change_Local_Name
				16'h0C14: begin                        // Read_Local_Name
					d_src = SRC_NAME;
					d_n   = 8'd248;
				end
				16'h0C35: d_rep = 1'b0;                // Host_Number_Of_Completed_Packets
				default: begin
					d_cs     = 1'b1;
					d_status = (c_ogf == 6'd1 || c_ogf == 6'd2) ? ST_DISALLOWED : ST_UNKNOWN;
				end
			endcase
		end
	end

	// ------------------------------------------------------------------
	// The RAMs: a new name's words as written (word w of the packet, 2-126),
	// and the written parameter values
	// ------------------------------------------------------------------
	sdp_ram #(.AW(7), .DW(16)) name_ram (
		.clk(clk),
		.we(w_data && op == 16'h0C13 && tx_w >= 9'd2 && tx_w <= 9'd126),
		.waddr(tx_w[6:0]),
		.wdata(wdata),
		.raddr(name_ra),
		.rdata(name_q)
	);

	sdp_ram #(.AW(4), .DW(32)) par_ram (
		.clk(clk),
		.we(par_we),
		.waddr(c_wr[3:0]),
		.wdata(hold),
		.raddr(rep_idx),
		.rdata(par_q)
	);

	// ------------------------------------------------------------------
	// The packet for the phone, a byte at a time
	// ------------------------------------------------------------------
	function automatic logic [7:0] rx_byte(
		input logic [8:0]  i,
		input logic [1:0]  kind,
		input logic        cs,
		input logic [7:0]  status,
		input logic [15:0] ropc,
		input logic [1:0]  src,
		input logic [3:0]  idx,
		input logic [7:0]  n,
		input logic        pset,
		input logic [31:0] pq,
		input logic [7:0]  nlen,
		input logic [7:0]  nm
	);
		logic [8:0]  k;
		logic [31:0] pv;
		k  = i - 9'd8;
		pv = pset ? pq : par_def(idx);
		if (kind == RX_INQ) begin
			// Inquiry Complete: status 0, no responses
			case (i)
				9'd0: return 8'h04;
				9'd2: return 8'h01;
				9'd3: return 8'h02;
				default: return 8'h00;
			endcase
		end
		if (i < 9'd8) begin
			case (i[2:0])
				3'd0: return 8'h04;
				3'd1: return 8'h00;
				3'd2: return cs ? 8'h0F : 8'h0E;       // Command Status / Complete
				3'd3: return cs ? 8'h04 : 8'd4 + n;
				3'd4: return cs ? status : 8'h01;
				3'd5: return cs ? 8'h01 : ropc[7:0];
				3'd6: return cs ? ropc[7:0] : ropc[15:8];
				default: return cs ? ropc[15:8] : status;
			endcase
		end
		if (cs) return 8'h00;
		case (src)
			SRC_FIX:  return fix_byte(idx, k[2:0]);
			SRC_PAR:  return pv[8 * k[1:0] +: 8];
			SRC_NAME: return (k < {1'b0, nlen}) ? nm : 8'h00;
			default:  return 8'h00;
		endcase
	endfunction

	// name byte k was byte k + 5 of the packet that set it; reply byte i is
	// name byte i - 8, so packet byte i - 3: for the even i of a word's first
	// byte the low half of word (i - 4) / 2, for the second the high half of
	// the next word
	wire [6:0] na = rx_idx[7:1] - 7'd2;
	wire [7:0] gen0 = rx_byte(rx_idx, rx_kind, rep_cs, rep_status, rep_op, rep_src, rep_idx, rep_n,
	                          par_set[rep_idx], par_q, name_len, name_q[7:0]);
	wire [7:0] gen1 = rx_byte(rx_idx + 9'd1, rx_kind, rep_cs, rep_status, rep_op, rep_src, rep_idx, rep_n,
	                          par_set[rep_idx], par_q, name_len, name_q[15:8]);

	// ------------------------------------------------------------------
	// Reads
	// ------------------------------------------------------------------
	always_comb begin
		rdata = 16'd0;
		if (!in_reset) begin
			case (rn)
				R_DATA:   rdata = (rx_kind != RX_NONE) ? rx_word : 16'd0;
				R_RXLEN:  rdata = (rx_kind != RX_NONE) ? {7'd0, rx_len} : 16'd0;
				R_STATUS: rdata = {8'd0, ev_reset, ev_ack, 1'b0, ev_rx, 1'b0, 1'b1, 2'b00};
				R_REG0:   rdata = reg0;
				R_REASON: rdata = {12'd0, reason_host, 3'd0};
				default:  rdata = 16'd0;
			endcase
		end
	end

	assign busy = fst != 3'd0;

	wire r_data  = rd && !in_reset && rn == R_DATA && rx_kind != RX_NONE;
	wire r_last  = r_data && rx_idx + 9'd2 >= rx_len;
	wire w_reset = wr && rn == R_STATUS && wdata[0];
	wire inq_end = inq_left == 6'd1 && inq_cnt == UW'(INQ_UNIT_CLKS - 1);

	always_ff @(posedge clk) begin
		// A clock does what the reference does in one call, in its order:
		// the access, then the timers, then the next packet for the phone.
		// These follow the state through the clock.
		logic [1:0] v_kind;
		logic       v_rep, v_cs, v_inqd, v_run, v_up, v_ev;
		logic [7:0] v_n;
		v_kind = rx_kind;
		v_rep  = rep_pend;
		v_cs   = rep_cs;
		v_n    = rep_n;
		v_inqd = inq_done;
		v_run  = inq_run;
		v_up   = 1'b0;                  // a packet goes up
		v_ev   = 1'b0;                  // a status bit is set

		// ---- making rx_word ----
		// (the RAMs give a word the clock after its address; the parameter
		// RAM's address is rep_idx all along)
		case (fst)
			3'd1: begin name_ra <= na;        fst <= 3'd2; end
			3'd2: begin name_ra <= na + 7'd1; fst <= 3'd3; end
			3'd3: begin b0 <= gen0;           fst <= 3'd4; end
			3'd4: begin
				rx_word <= {b0, (rx_idx + 9'd1 < rx_len) ? gen1 : 8'h00};
				fst     <= 3'd0;
			end
			default: ;
		endcase

		// ---- reads ----
		if (rd && !in_reset) begin
			if (rn == R_STATUS) begin
				ev_rx    <= 1'b0;
				ev_ack   <= 1'b0;
				ev_reset <= 1'b0;
			end
			if (r_last) begin
				v_kind = RX_NONE;           // the phone has all of it
			end else if (r_data) begin
				rx_idx <= rx_idx + 9'd2;
				fst    <= 3'd1;
			end
		end

		// ---- writes ----
		if (wr && !in_reset) begin
			// what a held packet is made from may change: make its word again
			if (rx_kind != RX_NONE) fst <= 3'd1;

			if (w_data) begin
				tx_cnt <= tx_cnt + 10'd2;
				case (tx_w)
					9'd0: is_cmd <= wdata[15:8] == 8'h01;
					9'd1: op     <= {wdata[7:0], wdata[15:8]};
					9'd2: begin plen <= wdata[15:8]; hold[7:0] <= wdata[7:0]; end
					9'd3: hold[23:8]  <= {wdata[7:0], wdata[15:8]};
					9'd4: hold[31:24] <= wdata[15:8];
					default: ;
				endcase
			end
			if (rn == R_START && wdata[15]) begin
				reg0   <= {6'd0, BUF_SIZE};
				ev_ack <= 1'b1;
				v_ev   = 1'b1;
			end
			if (w_room) begin
				tx_cnt <= 10'd0;
				reg0   <= {2'b00, wdata[13:0]};
				ev_ack <= 1'b1;
				v_ev   = 1'b1;
			end
			if (w_done) begin
				tx_cnt <= 10'd0;
				reg0   <= {2'b01, wdata[13:0]};
				ev_ack <= 1'b1;
				v_ev   = 1'b1;
			end
			if (c_valid) begin
				if (par_we) par_set[c_wr[3:0]] <= 1'b1;
				if (d_name) name_len <= (c_plen > 8'd248) ? 8'd248 : c_plen;
				if (d_inq_start) begin
					v_run    = 1'b1;
					inq_left <= hold[29:24];
					inq_cnt  <= '0;
				end
				if (d_inq_stop) v_run = 1'b0;
				if (d_hreset) begin
					v_run    = 1'b0;
					v_inqd   = 1'b0;
					par_set  <= 16'd0;
					name_len <= 8'd0;
				end
				if (d_rep) begin
					v_rep      = 1'b1;
					v_cs       = d_cs;
					v_n        = d_n;
					rep_cs     <= d_cs;
					rep_status <= d_status;
					rep_op     <= op;
					rep_src    <= d_src;
					rep_idx    <= d_idx;
					rep_n      <= d_n;
					if (v_kind == RX_REPLY) v_kind = RX_NONE;   // the answer nobody read
				end
			end
		end

		// ---- the inquiry's time ----
		if (inq_run) begin
			if (inq_cnt == UW'(INQ_UNIT_CLKS - 1)) begin
				inq_cnt  <= '0;
				inq_left <= inq_left - 6'd1;
			end else begin
				inq_cnt <= inq_cnt + 1'd1;
			end
			if (inq_end && v_run) begin     // not if this clock's command stopped it
				v_run  = 1'b0;
				v_inqd = 1'b1;
			end
		end

		// ---- the reset the phone asked for ----
		if (in_reset) begin
			rst_cnt <= rst_cnt - 1'd1;
			if (rst_cnt == RW'(1)) begin
				in_reset    <= 1'b0;
				reason_host <= 1'b1;
				ev_reset    <= 1'b1;
				v_ev        = 1'b1;
			end
		end

		// ---- the next packet for the phone: a command's answer first,
		// then the end of an inquiry ----
		if (!in_reset && v_kind == RX_NONE) begin
			if (v_rep) begin
				v_rep  = 1'b0;
				v_kind = RX_REPLY;
				v_up   = 1'b1;
				rx_len <= v_cs ? 9'd8 : 9'd8 + {1'b0, v_n};
			end else if (v_inqd) begin
				v_inqd = 1'b0;
				v_kind = RX_INQ;
				v_up   = 1'b1;
				rx_len <= 9'd6;
			end
		end
		if (v_up) begin
			rx_idx <= 9'd0;
			fst    <= 3'd1;
			ev_rx  <= 1'b1;
			v_ev   = 1'b1;
		end else if (v_kind == RX_NONE) begin
			fst <= 3'd0;
		end

		rx_kind  <= v_kind;
		rep_pend <= v_rep;
		inq_done <= v_inqd;
		inq_run  <= v_run;
		irq      <= v_ev;

		// ---- power-on, and the reset the phone asks for ----
		if (reset || w_reset) begin
			in_reset    <= w_reset && !reset;
			rst_cnt     <= RW'(RESET_CLKS);
			ev_rx       <= 1'b0;
			ev_ack      <= 1'b0;
			ev_reset    <= 1'b0;
			reason_host <= 1'b0;
			reg0        <= 16'd0;
			tx_cnt      <= 10'd0;
			is_cmd      <= 1'b0;
			op          <= 16'd0;
			plen        <= 8'd0;
			hold        <= 32'd0;
			par_set     <= 16'd0;
			name_len    <= 8'd0;
			inq_run     <= 1'b0;
			inq_done    <= 1'b0;
			inq_left    <= 6'd0;
			inq_cnt     <= '0;
			rep_pend    <= 1'b0;
			rep_cs      <= 1'b0;
			rep_status  <= 8'd0;
			rep_op      <= 16'd0;
			rep_src     <= SRC_NONE;
			rep_idx     <= 4'd0;
			rep_n       <= 8'd0;
			rx_kind     <= RX_NONE;
			rx_len      <= 9'd0;
			rx_idx      <= 9'd0;
			rx_word     <= 16'd0;
			fst         <= 3'd0;
			b0          <= 8'd0;
			name_ra     <= 7'd0;
			irq         <= 1'b0;
		end
	end

endmodule
