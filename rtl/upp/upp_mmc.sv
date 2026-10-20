// SPDX-License-Identifier: GPL-2.0-or-later
//
// UPP_WD2 MMC host (0x0C120600-0x0C12063F) in 1-bit mode on CLK, CMD and DAT0,
// with the register interface of the reference model (model/hw/ngage_mmc.c,
// from epbus.dll's WD2MMC layer, RH-29 v4.60; docs/UPP_WD2.md):
//
//   +0x04 control. Writing bit 0 = 1 starts a transfer; bits 5:2 = type:
//           0 command, no response          1 R1        2 R3 (CMD1)
//           3 R2 (CID, CSD)                 4 R1 + busy ([model guess] "R1b?")
//           8 command (CMD17/18) + read a block   9 read the next block (no command)
//          10 CMD12 after reading
//           5 command (CMD24/25) + write a block  6 write the next block (no command)
//           7 CMD12 after writing (R1 + busy)
//         bit 6 = no response CRC check (set with CMD1's R3). Bit 0 reads 0:
//         the transfer is taken at once (the driver polls it, 0x503F5490).
//         Other bits and writes without bit 0 (0x40 at power-up, 0 at
//         power-down) are storage only.
//   +0x08 data length of the following data phase (0: the block length the
//         card was given with CMD16, 512 after reset; at most 4096), storage
//   +0x0C, +0x10, +0x14  storage ([model guess] time-outs 0x1DC130 and clock
//         divider 0x280; nothing here uses them)
//   +0x18 status (read): bit 3 command busy, 2 data busy, 8 response word
//         available; command errors 6 response time-out, 1 response CRC; data
//         errors 0 data CRC, 5 busy time-out, 7 data time-out, 10 other (no
//         CRC status token after a written block). Cleared by every start.
//   +0x1C command index, +0x20 argument (write; storage)
//   +0x20 read: the next response word. R1/R3: one word, response bits 39:8;
//         R2: four words, bits 127:0 most significant first. Bit 8 clears
//         when the last word is read. 0 when there is none.
//   +0x24 data FIFO (8 bits per lane; the DMA target 0x10120624, 8-bit): a
//         read takes the next bytes of the block being read (0 past its end or
//         outside a read phase), a write gives the next bytes of the block
//         being written (dropped outside a write phase).
//   other offsets: storage (the generic store in upp_periph).
// Interrupt levels from the status, as in the model (bound by name in epbus
// 0x503F6180-0x503F62E8): MMCDataIdle 21 = !data busy, MMCDataRdy 22 = data
// busy, MMCCmdIdle 23 = !command busy, MMCCmdRdy 24 = response available.
//
// Where the model is instant this is real time. Command busy lasts until the
// response and NRC (8 clocks) after it, or the busy signal on DAT0 after it
// for types 4 and 7. A read block's data busy lasts until the block, CRC
// included, has arrived and every byte has been read from the FIFO (the model
// clears it with the last byte read); a written block's until the card's
// busy after its CRC status token ends (the model: the last byte written).
// The FIFO holds FIFO_DEPTH bytes; the clock stops while it is full during a
// read or empty during a write, and after a read block until type 9 asks for
// the next (CMD18 then waits on the card's side), so no data is ever lost.
// The DMA is paced by rx_ready / tx_ready (upp_dma).
//
// Bus: CLK = clk / DIV, low at rest; the host changes CMD/DAT0 as CLK falls
// and samples them as it rises (as rtl/board/mmc_card.sv expects). [assumed]
// DIV = 12 (8.67 MHz, the service manual's MMC clock); time-outs: 64 clocks
// to a response start bit (NCR max), 2^TIMEOUT_LOG2 clocks to a read block's
// start bit and for busy.
module upp_mmc #(
	parameter int DIV          = 12,
	parameter int RESP_WAIT    = 64,
	parameter int TIMEOUT_LOG2 = 21,
	parameter int FIFO_DEPTH   = 16
) (
	input  logic        clk,
	input  logic        reset,

	input  logic        acc,
	input  logic        we,
	input  logic        wr,
	input  logic        rd,
	input  logic [5:0]  off,
	input  logic [3:0]  be,
	input  logic [31:0] wdata,
	output logic [31:0] rmask,
	output logic [31:0] rdata,
	output logic        busy,

	output logic        rx_ready,       // a 1-byte FIFO read would not wait
	output logic        tx_ready,       // a 1-byte FIFO write would not wait
	output logic [3:0]  irq,            // {CmdRdy, CmdIdle, DataRdy, DataIdle}

	output logic        mmc_clk,
	output logic        cmd_o,
	output logic        cmd_oe,
	input  logic        cmd_i,
	output logic        dat_o,
	output logic        dat_oe,
	input  logic        dat_i
);

	localparam int PHW = $clog2(DIV);
	localparam int FAW = $clog2(FIFO_DEPTH);
	localparam int HALF = DIV / 2;

	// status bits
	localparam int B_DATA_CRC = 0, B_RESP_CRC = 1, B_DATA_BUSY = 2, B_CMD_BUSY = 3,
	               B_BUSY_TO = 5, B_RESP_TO = 6, B_DATA_TO = 7, B_RESP = 8, B_DATA_ERR = 10;

	// command engine
	localparam logic [2:0] C_IDLE = 3'd0, C_SEND = 3'd1, C_RWAIT = 3'd2, C_RECV = 3'd3,
	                       C_BUSY = 3'd4, C_TAIL = 3'd5;
	// data engine
	localparam logic [3:0] D_IDLE = 4'd0, D_RWAIT = 4'd1, D_RX = 4'd2, D_RDONE = 4'd3,
	                       D_TWAIT = 4'd4, D_TX = 4'd5, D_TSTAT = 4'd6, D_TBUSY = 4'd7,
	                       D_TAIL = 4'd8;

	// ------------------------------------------------------------------
	// CRCs (MMC: CRC7 x^7 + x^3 + 1, CRC16 x^16 + x^12 + x^5 + 1)
	// ------------------------------------------------------------------
	function automatic logic [6:0] crc7_bit(input logic [6:0] c, input logic b);
		logic fb;
		fb = c[6] ^ b;
		return {c[5:3], c[2] ^ fb, c[1:0], fb};
	endfunction
	function automatic logic [15:0] crc16_bit(input logic [15:0] c, input logic b);
		logic fb;
		fb = c[15] ^ b;
		return {c[14:12], c[11] ^ fb, c[10:5], c[4] ^ fb, c[3:0], fb};
	endfunction
	function automatic logic [6:0] crc7_40(input logic [39:0] v);
		logic [6:0] c;
		c = 7'd0;
		for (int i = 39; i >= 0; i--) c = crc7_bit(c, v[i]);
		return c;
	endfunction

	// ------------------------------------------------------------------
	// Registers
	// ------------------------------------------------------------------
	logic [10:0]  status;
	logic [5:0]   cmd_idx;
	logic [31:0]  arg;
	logic [12:0]  len_reg;            // +0x08, clamped to 4096
	logic [12:0]  blocklen;           // from CMD16
	logic [127:0] resp;
	logic [2:0]   resp_words, resp_pos;

	// the transfer
	logic [3:0]   ty;
	logic         nocrc;
	logic [12:0]  blen;               // bytes in the block of the data phase
	logic [12:0]  nfifo;              // bytes the bus has taken from / given to the FIFO
	logic [12:0]  nrx;                // bytes received from the card into the FIFO
	logic [12:0]  ntx;                // bytes taken from the FIFO for the card

	logic [2:0]   cstate;
	logic [3:0]   dstate;

	// ------------------------------------------------------------------
	// FIFO, FIFO_DEPTH bytes in registers
	// ------------------------------------------------------------------
	logic [7:0]     fmem [0:FIFO_DEPTH-1];
	logic [FAW-1:0] fwp, frp;
	logic [FAW:0]   fcnt;

	logic [2:0]   nbe;                // bytes the access moves
	always_comb begin
		nbe = 3'd0;
		for (int i = 0; i < 4; i++) nbe = nbe + {2'd0, be[i]};
	end

	wire        rx_phase  = dstate == D_RWAIT || dstate == D_RX || dstate == D_RDONE;
	wire        rx_coming = dstate == D_RWAIT || dstate == D_RX;
	wire        tx_phase  = dstate == D_TWAIT || dstate == D_TX;
	wire [12:0] rem       = blen - nfifo;
	// the bytes an access asks for, within the block
	wire [2:0]  need      = (13'(nbe) < rem) ? nbe : rem[2:0];
	wire [FAW:0] need_f   = (FAW + 1)'(need);
	wire [FAW:0] fdepth   = (FAW + 1)'(FIFO_DEPTH);

	wire fifo_rd = off == 6'h24 && !we;
	wire fifo_wr = off == 6'h24 && we;

	assign rx_ready = !(rx_coming && fcnt == '0);
	assign tx_ready = !(tx_phase && rem != 13'd0 && fcnt == fdepth);

	// a FIFO read takes the bytes it asks for that are there (busy waits
	// while more are coming), the rest of the lanes read 0
	wire [2:0] fifo_take = !rx_phase ? 3'd0 : (fcnt < need_f) ? fcnt[2:0] : need[2:0];
	logic [31:0] fifo_word;
	always_comb begin
		logic [2:0] k;
		fifo_word = 32'd0;
		k = 3'd0;
		for (int i = 0; i < 4; i++) begin
			if (be[i]) begin
				if (k < fifo_take) fifo_word[8 * i +: 8] = fmem[FAW'(frp + FAW'(k))];
				k = k + 3'd1;
			end
		end
	end

	always_comb begin
		rmask = 32'd0;
		rdata = 32'd0;
		busy  = 1'b0;
		if (acc) begin
			case (off)
				6'h04: begin rmask = 32'h0000_0001; rdata = 32'd0; end
				6'h18: begin rmask = '1; rdata = {21'd0, status}; end
				6'h20: if (!we) begin
					rmask = '1;
					rdata = (resp_pos < resp_words) ? resp[7'd96 - {resp_pos[1:0], 5'd0} +: 32] : 32'd0;
				end
				6'h24: begin
					if (!we) begin
						rmask = '1;
						rdata = fifo_word;
						busy  = rx_coming && fcnt < need_f;
					end else begin
						busy  = tx_phase && fdepth - fcnt < need_f;
					end
				end
				default: ;
			endcase
		end
	end

	// ------------------------------------------------------------------
	// The bus clock: periods of DIV clocks, run while an engine needs them
	// ------------------------------------------------------------------
	logic [PHW-1:0] ph;
	logic           run;               // this period is clocked
	wire            fall = run && ph == '0;
	wire            rise = run && ph == PHW'(HALF);
	logic           cmd_need, dat_need, dat_hold;

	assign mmc_clk = run && ph >= PHW'(HALF);

	// ------------------------------------------------------------------
	// The engines
	// ------------------------------------------------------------------
	logic [47:0]  csr;                 // command bits to send, next in 47
	logic [7:0]   ccnt;                // bits sent / received, clocks waited
	logic [126:0] rsr;                 // response bits received, last in 0
	logic [6:0]   rcrc;
	logic         resp_long;           // R2
	logic         resp_busy;           // types 4, 7
	logic         want_resp;
	logic         resp_ok;             // the response of this transfer has arrived
	logic [TIMEOUT_LOG2-1:0] cto;      // busy time-out after a response

	logic [TIMEOUT_LOG2-1:0] dto;      // data / busy time-out
	logic [15:0]  dcrc, dcrc_rx;
	logic [7:0]   dsr;                 // data byte being received or sent
	logic [3:0]   dbit;                // its bits so far (receive) / left (send)
	logic [4:0]   dcbit;               // CRC bits so far
	logic         dend;                // the end bit has been sent
	logic [2:0]   tok, tcnt;
	logic [3:0]   dtail;
	logic [1:0]   gap;

	wire [7:0] fifo_head = fmem[frp];

	// the start of a transfer at this edge
	wire       start = wr && off == 6'h04 && wdata[0];
	wire [3:0] sty   = wdata[5:2];
	wire       s_cmd = !(sty == 4'd6 || sty == 4'd9);
	wire [12:0] len_eff = (len_reg != 13'd0) ? len_reg : blocklen;

	always_comb begin
		cmd_need = cstate != C_IDLE;
		case (dstate)
			D_RWAIT, D_RX, D_TX, D_TSTAT, D_TBUSY, D_TAIL: dat_need = 1'b1;
			D_TWAIT: dat_need = fcnt != '0;
			default: dat_need = 1'b0;
		endcase
		// at a byte boundary, wait for FIFO room (receive) or a byte (send)
		dat_hold = (dstate == D_RX && dbit == 4'd0 && nrx < blen && fcnt == fdepth) ||
		           (dstate == D_TX && dbit == 4'd0 && ntx < blen && fcnt == '0);
	end

	always_ff @(posedge clk) begin
		logic       push1, pop1;
		logic [7:0] pbyte;
		logic [2:0] npush, npop, k;
		push1 = 1'b0;
		pop1  = 1'b0;
		pbyte = 8'd0;

		// ---- the clock ----
		if (run) ph <= (ph == PHW'(DIV - 1)) ? '0 : ph + 1'd1;
		if ((run && ph == PHW'(DIV - 1)) || !run) run <= (cmd_need || dat_need) && !dat_hold;

		// ---- register writes ----
		if (wr) begin
			case (off)
				6'h08: len_reg <= (wdata[31:12] != 20'd0) ? 13'd4096 : wdata[12:0];
				6'h1C: cmd_idx <= wdata[5:0];
				6'h20: arg <= wdata;
				default: ;
			endcase
		end
		if (rd && off == 6'h20 && resp_pos < resp_words) begin
			resp_pos <= resp_pos + 3'd1;
			if (resp_pos + 3'd1 >= resp_words) status[B_RESP] <= 1'b0;
		end

		// ---- command engine ----
		case (cstate)
			C_SEND: if (fall) begin
				if (ccnt == 8'd48) begin
					cmd_oe <= 1'b0;
					ccnt   <= 8'd0;
					cstate <= want_resp ? C_RWAIT : C_TAIL;
				end else begin
					cmd_oe <= 1'b1;
					cmd_o  <= csr[47];
					csr    <= {csr[46:0], 1'b1};
					ccnt   <= ccnt + 8'd1;
				end
			end
			C_RWAIT: if (rise) begin
				if (!cmd_i) begin
					rsr    <= 127'd0;
					ccnt   <= 8'd1;
					rcrc   <= crc7_bit(7'd0, 1'b0);
					cstate <= C_RECV;
				end else if (ccnt == 8'(RESP_WAIT)) begin
					status[B_RESP_TO]   <= 1'b1;
					status[B_DATA_BUSY] <= 1'b0;   // no data phase without a response
					ccnt   <= 8'd0;
					cstate <= C_TAIL;
				end else begin
					ccnt <= ccnt + 8'd1;
				end
			end
			C_RECV: if (rise) begin
				rsr  <= {rsr[125:0], cmd_i};
				ccnt <= ccnt + 8'd1;
				// CRC7: R1 over its first 40 bits, R2 over bits 127:8
				if (resp_long ? (ccnt >= 8'd8 && ccnt < 8'd128) : (ccnt < 8'd40))
					rcrc <= crc7_bit((resp_long && ccnt == 8'd8) ? 7'd0 : rcrc, cmd_i);
				if (ccnt == (resp_long ? 8'd135 : 8'd47)) begin
					logic [127:0] f;
					f = {rsr, cmd_i};
					resp       <= resp_long ? f[127:0] : {f[39:8], 96'd0};
					resp_words <= resp_long ? 3'd4 : 3'd1;
					resp_pos   <= 3'd0;
					status[B_RESP] <= 1'b1;
					if (!nocrc && ty != 4'd2 && f[7:1] != rcrc) status[B_RESP_CRC] <= 1'b1;
					resp_ok <= 1'b1;
					if (cmd_idx == 6'd16) blocklen <= (arg[31:12] != 20'd0) ? 13'd4096 : arg[12:0];
					ccnt   <= 8'd0;
					cto    <= '0;
					cstate <= resp_busy ? C_BUSY : C_TAIL;
				end
			end
			C_BUSY: if (rise) begin
				cto <= cto + 1'd1;
				if (dat_i || &cto) begin
					if (!dat_i) status[B_BUSY_TO] <= 1'b1;
					ccnt   <= 8'd0;
					cstate <= C_TAIL;
				end
			end
			C_TAIL: if (fall) begin
				if (ccnt == 8'd8) begin
					status[B_CMD_BUSY] <= 1'b0;
					cstate <= C_IDLE;
				end else begin
					ccnt <= ccnt + 8'd1;
				end
			end
			default: ;
		endcase

		// ---- data engine ----
		case (dstate)
			D_RWAIT: begin
				if (rise) begin
					dto <= dto + 1'd1;
					if (!dat_i) begin
						dbit   <= 4'd0;
						dcbit  <= 5'd0;
						dcrc   <= 16'd0;
						dstate <= D_RX;
					end else if (&dto) begin
						status[B_DATA_TO] <= 1'b1;
						dstate <= D_RDONE;
					end
				end
				// a command that went unanswered has no data phase
				if (status[B_RESP_TO]) dstate <= D_IDLE;
			end
			D_RX: if (rise) begin
				if (nrx < blen) begin
					dsr  <= {dsr[6:0], dat_i};
					dcrc <= crc16_bit(dcrc, dat_i);
					if (dbit == 4'd7) begin
						push1 = 1'b1;
						pbyte = {dsr[6:0], dat_i};
						nrx   <= nrx + 13'd1;
						dbit  <= 4'd0;
					end else begin
						dbit <= dbit + 4'd1;
					end
				end else if (dcbit < 5'd16) begin
					dcrc_rx <= {dcrc_rx[14:0], dat_i};
					dcbit   <= dcbit + 5'd1;
				end else begin
					// the end bit; the clock stops here until the next transfer
					if (dcrc_rx != dcrc || !dat_i) status[B_DATA_CRC] <= 1'b1;
					dstate <= D_RDONE;
				end
			end
			D_RDONE: begin
				// every byte received has been read
				if (fcnt == '0) begin
					status[B_DATA_BUSY] <= 1'b0;
					dstate <= D_IDLE;
				end
			end
			D_TWAIT: begin
				if (status[B_RESP_TO]) begin
					dstate <= D_IDLE;
				end else if (fall && resp_ok) begin
					if (gap != 2'd2) begin
						gap <= gap + 2'd1;
					end else if (fcnt != '0) begin
						// NWR >= 2 clocks after the response: the start bit
						dat_oe <= 1'b1;
						dat_o  <= 1'b0;
						dcrc   <= 16'd0;
						dbit   <= 4'd0;
						dcbit  <= 5'd0;
						dend   <= 1'b0;
						dstate <= D_TX;
					end
				end
			end
			D_TX: if (fall) begin
				if (dbit != 4'd0) begin
					dat_o <= dsr[7];
					dcrc  <= crc16_bit(dcrc, dsr[7]);
					dsr   <= {dsr[6:0], 1'b0};
					dbit  <= dbit - 4'd1;
				end else if (ntx < blen) begin
					// the next byte (dat_hold stops the clock while there is none)
					pop1  = 1'b1;
					dat_o <= fifo_head[7];
					dcrc  <= crc16_bit(dcrc, fifo_head[7]);
					dsr   <= {fifo_head[6:0], 1'b0};
					dbit  <= 4'd7;
					ntx   <= ntx + 13'd1;
				end else if (dcbit != 5'd16) begin
					dat_o <= dcrc[4'd15 - dcbit[3:0]];
					dcbit <= dcbit + 5'd1;
				end else if (!dend) begin
					dat_o <= 1'b1;             // the end bit
					dend  <= 1'b1;
				end else begin
					dat_oe <= 1'b0;
					tcnt   <= 3'd0;
					dto    <= '0;
					dstate <= D_TSTAT;
				end
			end
			D_TSTAT: if (rise) begin
				dto <= dto + 1'd1;
				if (tcnt == 3'd0) begin
					if (!dat_i) begin
						tcnt <= 3'd1;
					end else if (dto == TIMEOUT_LOG2'(16)) begin
						status[B_DATA_ERR] <= 1'b1;   // no CRC status token
						dto    <= '0;
						dstate <= D_TBUSY;
					end
				end else if (tcnt != 3'd4) begin
					tok  <= {tok[1:0], dat_i};
					tcnt <= tcnt + 3'd1;
				end else begin
					// the token's end bit; the card is busy while DAT0 is low
					if (tok != 3'b010) status[B_DATA_CRC] <= 1'b1;
					dto    <= '0;
					dstate <= D_TBUSY;
				end
			end
			D_TBUSY: if (rise) begin
				dto <= dto + 1'd1;
				if (dat_i || &dto) begin
					if (!dat_i) status[B_BUSY_TO] <= 1'b1;
					dtail  <= 4'd0;
					dstate <= D_TAIL;
				end
			end
			D_TAIL: if (fall) begin
				if (dtail == 4'd8) begin
					status[B_DATA_BUSY] <= 1'b0;
					dstate <= D_IDLE;
				end else begin
					dtail <= dtail + 4'd1;
				end
			end
			default: ;
		endcase

		// ---- the FIFO ----
		npush = 3'd0;
		npop  = 3'd0;
		if (rd && fifo_rd && rx_phase) begin
			npop  = fifo_take;
			nfifo <= nfifo + 13'(fifo_take);
		end
		if (wr && fifo_wr && tx_phase) begin
			k = 3'd0;
			for (int i = 0; i < 4; i++) begin
				if (be[i] && 13'(k) < rem) begin
					fmem[FAW'(fwp + FAW'(k))] <= wdata[8 * i +: 8];
					k = k + 3'd1;
				end
			end
			npush = k;
			nfifo <= nfifo + 13'(k);
		end
		if (push1) begin
			fmem[fwp] <= pbyte;
			npush = 3'd1;
		end
		if (pop1) npop = 3'd1;
		fwp  <= fwp + FAW'(npush);
		frp  <= frp + FAW'(npop);
		fcnt <= fcnt + (FAW + 1)'(npush) - (FAW + 1)'(npop);

		// ---- a new transfer ----
		if (start) begin
			ty         <= sty;
			nocrc      <= wdata[6];
			status     <= 11'd0;
			resp_words <= 3'd0;
			resp_pos   <= 3'd0;
			resp_ok    <= sty == 4'd6;
			cmd_oe     <= 1'b0;
			dat_oe     <= 1'b0;
			fwp        <= '0;
			frp        <= '0;
			fcnt       <= '0;
			nfifo      <= 13'd0;
			nrx        <= 13'd0;
			ntx        <= 13'd0;
			gap        <= 2'd0;
			dto        <= '0;
			blen       <= (len_eff > 13'd4096) ? 13'd4096 : len_eff;
			resp_long  <= sty == 4'd3;
			resp_busy  <= sty == 4'd4 || sty == 4'd7;
			want_resp  <= sty != 4'd0;
			if (s_cmd) begin
				status[B_CMD_BUSY] <= 1'b1;
				csr    <= {1'b0, 1'b1, cmd_idx, arg, crc7_40({1'b0, 1'b1, cmd_idx, arg}), 1'b1};
				ccnt   <= 8'd0;
				cstate <= C_SEND;
			end else begin
				cstate <= C_IDLE;
			end
			case (sty)
				4'd8, 4'd9: begin status[B_DATA_BUSY] <= 1'b1; dstate <= D_RWAIT; end
				4'd5, 4'd6: begin status[B_DATA_BUSY] <= 1'b1; dstate <= D_TWAIT; end
				default: dstate <= D_IDLE;
			endcase
		end

		if (reset) begin
			run        <= 1'b0;
			ph         <= '0;
			cstate     <= C_IDLE;
			dstate     <= D_IDLE;
			status     <= 11'd0;
			resp_words <= 3'd0;
			resp_pos   <= 3'd0;
			cmd_oe     <= 1'b0;
			cmd_o      <= 1'b1;
			dat_oe     <= 1'b0;
			dat_o      <= 1'b1;
			fwp        <= '0;
			frp        <= '0;
			fcnt       <= '0;
			nfifo      <= 13'd0;
			nrx        <= 13'd0;
			ntx        <= 13'd0;
			blen       <= 13'd0;
			len_reg    <= 13'd0;
			blocklen   <= 13'd512;
			cmd_idx    <= 6'd0;
			arg        <= 32'd0;
		end
	end

	assign irq = {status[B_RESP], !status[B_CMD_BUSY], status[B_DATA_BUSY], !status[B_DATA_BUSY]};

	logic unused;
	assign unused = ^{ty[3], ty[1:0]};

endmodule
