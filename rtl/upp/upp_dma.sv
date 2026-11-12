// SPDX-License-Identifier: GPL-2.0-or-later
//
// UPP_WD2 DMA controller: channels 0-7 at 0x0C120300 + 0x40n, register for
// register as the reference model has them (model/hw/ngage_dma.c, from ekern's
// DMA layer, RH-29 v4.60 0x5031B2C0-0x5031B868; docs/UPP_WD2.md):
//
//   +0x04  storage; a write of 0 acknowledges the interrupt (0x5031B2E8)
//   +0x08  1 = start (memory to memory, 0x5031B43C), 2 = start paced by the
//          peripheral (0x5031B5D8), 0 = stop and acknowledge. Reads the value
//          written while the transfer runs and 0 once it is done (polled at
//          0x5031B2D4 after a stop). Other values are stored and do nothing.
//   +0x0C, +0x10  read 0 (read after a stop, 0x5031B2F4)
//   +0x14 / +0x20  source / destination address. 0x1xxxxxxx is the register
//          0x0Cxxxxxx (0x10121208 = LCD FIFO, 0x10120624 = MMC FIFO)
//   +0x18 / +0x24  source / destination mode: 0 fixed, otherwise incrementing
//          (2 for on-chip RAM, 4 for SDRAM, 0x5031B344)
//   +0x1C / +0x28  source / destination width: 0x20 and up 32 bits, 0x10 and
//          up 16, else 8
//   +0x2C  count - 1: halfwords for control 1, fixed-side
//          peripheral-width units for control 2 (0x5031B5CC)
//   other offsets: storage (the generic store in upp_periph).
// The count is converted to a byte budget independently of the source width.
// Reads and writes use their native widths, with only the remaining lanes
// enabled for either final partial unit. When done, the interrupt (source 6 + n,
// IrqDmaChannel0-7) is raised until +0x08 = 0 or +0x04 = 0; the kernel's ISR
// (0x50326B08) reads no status. [model guess] 0x0C120064/68 hold 4-bit
// request-line numbers per channel (MMC = 2, LCD = 7, 0x5031EDF8); the model
// ignores them, and so does this: a fixed-address side at the MMC or LCD FIFO
// waits for that FIFO (rx_ready / tx_ready) before each unit, so the transfer
// never holds the bus waiting for a peripheral. Anything else runs flat out.
//
// Where the model moves the data at once, this moves it over the bus master
// port (Wishbone B3 classic, one beat a cycle, through the arbiter in
// ngage_mem): ENGINES general transfers plus one word-only LCD reader run
// concurrently. Eligible aligned SDRAM -> fixed LCD FIFO descriptors use that
// reader and enqueue locally, preserving the LCD interface's ordered FIFO.
// Other descriptors retain generic width conversion. Further starts queue.
// A start while the channel runs restarts
// it; a stop ends it after the access in flight.
// Accesses are 32-bit (upp_periph drops others, as the model's region does).
module upp_dma #(
	parameter int ENGINES = 2
) (
	input  logic        clk,
	input  logic        reset,

	input  logic        acc,
	input  logic        wr,
	input  logic [11:0] off,          // byte offset in the 0x0C120000 page
	input  logic [31:0] wdata,
	output logic [31:0] rmask,
	output logic [31:0] rdata,

	output logic [7:0]  irq,

	input  logic        mmc_rx_ready,
	input  logic        mmc_tx_ready,
	input  logic        lcd_tx_ready,

	output wire         lcd_valid,
	output wire [31:0]  lcd_data,
	input  wire         lcd_ready,

	output logic        m_cyc,
	output logic        m_stb,
	output logic        m_we,
	output logic [31:0] m_adr,
	output logic [31:0] m_dat_o,
	output logic [3:0]  m_sel,
	input  logic        m_ack,
	input  logic        m_err,
	input  logic [31:0] m_dat_i
);

	// The last slot is a word-only LCD reader, not a general DMA worker.
	localparam TOTAL = ENGINES + 1;
	localparam LCD_SLOT = ENGINES;
	localparam int EW = (TOTAL > 1) ? $clog2(TOTAL) : 1;
	localparam logic [31:0] MMC_FIFO = 32'h0C12_0624;
	localparam logic [31:0] LCD_FIFO = 32'h0C12_1208;

	// ------------------------------------------------------------------
	// Channel registers
	// ------------------------------------------------------------------
	logic [7:0] req, go_clr, sinc, dinc, peripheral;
	logic [1:0] sw [0:7];
	logic [1:0] dw [0:7];

	wire [2:0]  ch   = 3'((off - 12'h300) >> 6);
	wire [5:0]  r    = off[5:0];

	function automatic logic [1:0] wlog(input logic [31:0] code);
		return (code >= 32'h20) ? 2'd2 : (code >= 32'h10) ? 2'd1 : 2'd0;
	endfunction

	function automatic logic [31:0] phys(input logic [31:0] a);
		return (a[31:28] == 4'h1) ? {4'h0, a[27:0]} + 32'h0C00_0000 : a;
	endfunction

	always_comb begin
		rmask = 32'd0;
		rdata = 32'd0;
		if (acc) begin
			case (r)
				6'h08: rmask = go_clr[ch] ? '1 : 32'd0;
				6'h0C, 6'h10: rmask = '1;
				default: ;
			endcase
		end
	end

	// src, dst, count by channel
	logic        pr_we;
	logic [4:0]  pr_waddr, pr_raddr;
	logic [31:0] pr_q;

	assign pr_we    = wr && (r == 6'h14 || r == 6'h20 || r == 6'h2C);
	assign pr_waddr = {ch, (r == 6'h14) ? 2'd0 : (r == 6'h20) ? 2'd1 : 2'd2};

	sdp_ram #(.AW(5), .DW(32)) params (
		.clk(clk),
		.we(pr_we),
		.waddr(pr_waddr),
		.wdata(wdata),
		.raddr(pr_raddr),
		.rdata(pr_q)
	);

	wire w_go   = wr && r == 6'h08;
	wire w_run  = w_go && (wdata == 32'd1 || wdata == 32'd2);
	wire w_stop = w_go && wdata == 32'd0;

	// ------------------------------------------------------------------
	// Engines
	// ------------------------------------------------------------------
	localparam logic [1:0] E_FREE = 2'd0, E_RUN = 2'd1, E_BUS = 2'd2;

	logic [1:0]  est    [0:TOTAL-1];
	logic [2:0]  ech    [0:TOTAL-1];
	logic [31:0] esrc   [0:TOTAL-1];
	logic [31:0] edst   [0:TOTAL-1];
	logic [34:0] eleft  [0:TOTAL-1];   // bytes still to read
	logic [63:0] ebuf   [0:TOTAL-1];   // bytes read and not yet written, first in 7:0
	logic [3:0]  efill  [0:TOTAL-1];
	logic        esinc  [0:TOTAL-1];
	logic        edinc  [0:TOTAL-1];
	logic [1:0]  esw    [0:TOTAL-1];
	logic [1:0]  edw    [0:TOTAL-1];
	logic        eabort [0:TOTAL-1];
	// the access an engine asks for
	logic        ewe    [0:TOTAL-1];
	logic [31:0] eadr   [0:TOTAL-1];
	logic [31:0] edat   [0:TOTAL-1];
	logic [3:0]  esel   [0:TOTAL-1];
	logic [2:0]  en     [0:TOTAL-1];   // bytes it moves

	// the master port
	logic          p_busy;
	logic [EW-1:0] p_e;
	logic [EW-1:0] rr;                   // round-robin start

	// the loader: picks a requested channel and a free engine, reads src/dst/count
	logic          ld_busy, ld_cancel;
	logic [1:0]    ld_step;
	logic [2:0]    ld_ch;
	logic [31:0]   ld_src, ld_dst;
	reg [2:0] req_rr;
	wire [34:0] lcd_bytes = ({3'd0, pr_q} + 35'd1) << 2;
	wire lcd_descriptor = peripheral[ld_ch] && sinc[ld_ch] &&
		!dinc[ld_ch] && sw[ld_ch] == 2 && dw[ld_ch] == 2 &&
		(ld_dst == LCD_FIFO || ld_dst == 32'h10121208) && ld_src[31:24] == 8'h0a &&
		ld_src[1:0] == 0 && ({11'd0, ld_src[23:0]} + lcd_bytes <= 35'h1000000);
	wire lcd_cancel = w_go && ch == ech[LCD_SLOT];
	assign lcd_valid = !reset && est[LCD_SLOT] == E_RUN &&
		efill[LCD_SLOT] != 0 && !eabort[LCD_SLOT] && !lcd_cancel;
	assign lcd_data = ebuf[LCD_SLOT][31:0];

	logic          free_any;
	logic [EW-1:0] free_e;
	always_comb begin
		free_any = 1'b0;
		free_e   = '0;
		for (int e = ENGINES - 1; e >= 0; e--) begin
			if (est[e] == E_FREE) begin
				free_any = 1'b1;
				free_e   = EW'(e);
			end
		end
	end

	reg [7:0] channel_active;
	always @* begin
		channel_active = 0;
		for (integer e = 0; e < TOTAL; e = e + 1)
			if (est[e] != E_FREE) channel_active[ech[e]] = 1;
	end
	logic       req_any;
	logic [2:0] req_ch;
	always_comb begin
		req_any = 1'b0;
		req_ch  = 3'd0;
		for (integer i = 7; i >= 0; i = i - 1) begin
			integer c;
			c = (int'(req_rr) + i) & 7;
			if (req[c] && !channel_active[c]) begin
				req_any = 1'b1;
				req_ch  = 3'(c);
			end
		end
	end

	assign pr_raddr = {ld_ch, ld_step};

	// the next engine asking for the port, from rr on
	logic          grant_any;
	logic [EW-1:0] grant_e;
	always_comb begin
		grant_any = 1'b0;
		grant_e   = '0;
		for (int i = TOTAL - 1; i >= 0; i--) begin
			int e;
			e = int'(rr) + i;
			if (e >= TOTAL) e = e - TOTAL;
			if (est[e] == E_BUS && (e != LCD_SLOT ||
                (!eabort[e] && !(w_go && ch == ech[e])))) begin
				grant_any = 1'b1;
				grant_e   = EW'(e);
			end
		end
	end

	assign m_stb = m_cyc;

	always_ff @(posedge clk) begin
		// ---- the engines ----
		for (int e = 0; e < TOTAL; e++) begin
			logic [2:0] swb, dwb, nr, nw;
			logic       paced;
			swb = 3'd1 << esw[e];
			dwb = 3'd1 << edw[e];
			nr  = (eleft[e] < 35'(swb)) ? 3'(eleft[e]) : swb;
			nw  = (efill[e] < 4'(dwb)) ? 3'(efill[e]) : dwb;

			// a stop or restart of its channel ends the transfer
			if (w_go && est[e] != E_FREE && ech[e] == ch) eabort[e] <= 1'b1;

			if (e == LCD_SLOT) begin
				if (est[e] == E_BUS && (eabort[e] || lcd_cancel) &&
					!(p_busy && p_e == LCD_SLOT)) est[e] <= E_FREE;
				// One held word; local enqueue is the destination completion.
				// A cancelled read drains on the existing master before reuse.
				if (est[e] == E_RUN) begin
					if (eabort[e] || lcd_cancel) begin
						est[e] <= E_FREE;
					end else if (efill[e] != 0) begin
						if (lcd_valid && lcd_ready) efill[e] <= 0;
					end else if (eleft[e] != 0) begin
						est[e] <= E_BUS;
					end else begin
						irq[ech[e]] <= 1;
						go_clr[ech[e]] <= 1;
						est[e] <= E_FREE;
					end
				end
			end else if (est[e] == E_RUN) begin
				if (eabort[e]) begin
					est[e] <= E_FREE;
				end else if (efill[e] >= 4'(dwb) || (eleft[e] == 35'd0 && efill[e] != 4'd0)) begin
					// a write of nw bytes
					paced = !edinc[e] && ((edst[e] == LCD_FIFO && !lcd_tx_ready) ||
					                      (edst[e] == MMC_FIFO && !mmc_tx_ready));
					if (!paced) begin
						ewe[e]  <= 1'b1;
						eadr[e] <= {edst[e][31:2], 2'b00};
						edat[e] <= 32'(ebuf[e]) << {edst[e][1:0], 3'b000};
						esel[e] <= 4'((5'b00001 << nw) - 5'd1) << edst[e][1:0];
						en[e]   <= nw;
						est[e]  <= E_BUS;
					end
				end else if (eleft[e] != 35'd0) begin
					// a read of nr bytes, including a possible partial source unit
					paced = !esinc[e] && esrc[e] == MMC_FIFO && !mmc_rx_ready;
					if (!paced) begin
						ewe[e]  <= 1'b0;
						eadr[e] <= {esrc[e][31:2], 2'b00};
						esel[e] <= 4'((5'b00001 << nr) - 5'd1) << esrc[e][1:0];
						en[e]   <= nr;
						est[e]  <= E_BUS;
					end
				end else begin
					// done (a register write below at the same edge wins)
					irq[ech[e]]    <= 1'b1;
					go_clr[ech[e]] <= 1'b1;
					est[e]         <= E_FREE;
				end
			end
		end

		// ---- the master port ----
		if (!p_busy) begin
			if (grant_any && !m_cyc) begin
				p_busy  <= 1'b1;
				p_e     <= grant_e;
				rr      <= (grant_e == EW'(TOTAL - 1)) ? '0 : grant_e + 1'd1;
				m_cyc   <= 1'b1;
				m_we    <= grant_e == LCD_SLOT ? 1'b0 : ewe[grant_e];
				m_adr   <= grant_e == LCD_SLOT ? esrc[LCD_SLOT] : eadr[grant_e];
				m_dat_o <= grant_e == LCD_SLOT ? 32'd0 : edat[grant_e];
				m_sel   <= grant_e == LCD_SLOT ? 4'hf : esel[grant_e];
			end
		end else if (m_ack || m_err) begin
			logic [31:0] rb;
			m_cyc    <= 1'b0;
			p_busy   <= 1'b0;
			est[p_e] <= E_RUN;
			if (p_e == LCD_SLOT) begin
				ebuf[p_e] <= {32'd0, m_err ? 32'd0 : m_dat_i};
				efill[p_e] <= 4;
				eleft[p_e] <= eleft[p_e] - 4;
				esrc[p_e] <= esrc[p_e] + 4;
			end else if (ewe[p_e]) begin
				ebuf[p_e]  <= ebuf[p_e] >> {en[p_e], 3'b000};
				efill[p_e] <= efill[p_e] - 4'(en[p_e]);
				if (edinc[p_e]) edst[p_e] <= edst[p_e] + 32'(en[p_e]);
			end else begin
				rb = m_err ? 32'd0 : m_dat_i >> {esrc[p_e][1:0], 3'b000};
				rb = rb & ((en[p_e] == 3'd4) ? 32'hFFFF_FFFF : (32'd1 << {en[p_e], 3'b000}) - 32'd1);
				ebuf[p_e]  <= ebuf[p_e] | ({32'd0, rb} << {efill[p_e], 3'b000});
				efill[p_e] <= efill[p_e] + 4'(en[p_e]);
				eleft[p_e] <= eleft[p_e] - 35'(en[p_e]);
				if (esinc[p_e]) esrc[p_e] <= esrc[p_e] + 32'(en[p_e]);
			end
		end

		// ---- the loader ----
		if (!ld_busy) begin
			if (req_any && !(w_go && ch == req_ch)) begin
				ld_busy     <= 1'b1;
				ld_cancel   <= 1'b0;
				ld_ch       <= req_ch;
				ld_step     <= 2'd0;
				req_rr <= req_ch + 1'b1;
				req[req_ch] <= 1'b0;
			end
		end else begin
			ld_step <= ld_step + 2'd1;
			case (ld_step)
				2'd1: ld_src <= pr_q;
				2'd2: ld_dst <= pr_q;
				2'd3: begin
					logic [1:0] count_shift;
					// M2M counts halfwords, even with 32-bit SDRAM accesses.
					// Paced TX counts destination units; RX counts source units.
					count_shift = peripheral[ld_ch] ?
					              (!dinc[ld_ch] ? dw[ld_ch] : sw[ld_ch]) : 2'd1;
					ld_busy <= 1'b0;
					if (!ld_cancel && !(w_go && ch == ld_ch)) begin
						if (lcd_descriptor && est[LCD_SLOT] == E_FREE) begin
							est[LCD_SLOT] <= E_RUN;
							ech[LCD_SLOT] <= ld_ch;
							esrc[LCD_SLOT] <= ld_src;
							eleft[LCD_SLOT] <= lcd_bytes;
							ebuf[LCD_SLOT] <= 0;
							efill[LCD_SLOT] <= 0;
							eabort[LCD_SLOT] <= 0;
						end else if ((lcd_descriptor || !free_any)) begin
							// Retry without blocking other channels behind a
							// full worker class. Register writes below win.
							req[ld_ch] <= 1;
						end else begin
						est[free_e]    <= E_RUN;
						ech[free_e]    <= ld_ch;
						esrc[free_e]   <= phys(ld_src);
						edst[free_e]   <= phys(ld_dst);
						eleft[free_e]  <= ({3'd0, pr_q} + 35'd1) << count_shift;
						ebuf[free_e]   <= 64'd0;
						efill[free_e]  <= 4'd0;
						esinc[free_e]  <= sinc[ld_ch];
						edinc[free_e]  <= dinc[ld_ch];
						esw[free_e]    <= sw[ld_ch];
						edw[free_e]    <= dw[ld_ch];
						eabort[free_e] <= 1'b0;
						end
					end
				end
				default: ;
			endcase
		end

		// ---- register writes ----
		if (wr) begin
			case (r)
				6'h04: if (wdata == 32'd0) irq[ch] <= 1'b0;
				6'h18: sinc[ch] <= wdata != 32'd0;
				6'h1C: sw[ch] <= wlog(wdata);
				6'h24: dinc[ch] <= wdata != 32'd0;
				6'h28: dw[ch] <= wlog(wdata);
				default: ;
			endcase
		end
		if (w_go) begin
			go_clr[ch] <= 1'b0;
			if (w_run) begin
				req[ch] <= 1'b1;
				peripheral[ch] <= wdata == 32'd2;
			end
			if (w_stop) begin
				req[ch] <= 1'b0;
				irq[ch] <= 1'b0;
			end
			if (ld_busy && ld_ch == ch) ld_cancel <= 1'b1;
		end

		if (reset) begin
			req    <= 8'd0;
			go_clr <= 8'd0;
			irq    <= 8'd0;
			sinc   <= 8'd0;
			dinc   <= 8'd0;
			peripheral <= 8'd0;
			for (int c = 0; c < 8; c++) begin
				sw[c] <= 2'd0;
				dw[c] <= 2'd0;
			end
			for (int e = 0; e < TOTAL; e++) est[e] <= E_FREE;
			req_rr <= 0;
			ld_busy <= 1'b0;
			p_busy  <= 1'b0;
			rr      <= '0;
			m_cyc   <= 1'b0;
		end
	end


endmodule
