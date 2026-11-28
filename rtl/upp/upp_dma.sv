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
//   +0x2C  count - 1, in source-width units (0x5031B5CC)
//   other offsets: storage (the generic store in upp_periph).
// A transfer reads count + 1 source units and writes the same bytes in
// destination-width units (a last partial unit as a narrower write), as the
// model does. When it is done the channel's interrupt (source 6 + n,
// IrqDmaChannel0-7) is raised until +0x08 = 0 or +0x04 = 0; the kernel's ISR
// (0x50326B08) reads no status. [model guess] 0x0C120064/68 hold 4-bit
// request-line numbers per channel (MMC = 2, LCD = 7, 0x5031EDF8); the model
// ignores them, and so does this: a fixed-address side at the MMC or LCD FIFO
// waits for that FIFO (rx_ready / tx_ready) before each unit, so the transfer
// never holds the bus waiting for a peripheral. Anything else runs flat out.
//
// Where the model moves the data at once, this moves it over the bus master
// port (Wishbone B3 classic, one beat a cycle, through the arbiter in
// ngage_mem): ENGINES general transfers take turns on the port with the
// dedicated NEM-4 LCD reader. Further starts wait for an engine.
// A start while the channel runs restarts
// it; a stop ends it after the access in flight.
// Accesses are 32-bit (upp_periph drops others, as the model's region does).
module upp_dma #(
	parameter int ENGINES = 3,
	parameter int LCD_DMA_WORDS = 4
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
	input  logic        nem4,
	output wire         lcd_valid,
	output wire [31:0]  lcd_data,
	input  logic        lcd_ready,
	input  logic        lcd_idle,

	output wire         m_cyc,
	output wire         m_stb,
	output wire         m_we,
	output wire [31:0]  m_adr,
	output wire [31:0]  m_dat_o,
	output wire [3:0]   m_sel,
	output wire         m_burst,
	input  logic        m_ack,
	input  logic        m_err,
	input  logic [31:0] m_dat_i
);

	localparam int EW = (ENGINES > 1) ? $clog2(ENGINES) : 1;
	localparam logic [31:0] MMC_FIFO = 32'h0C12_0624;
	localparam logic [31:0] LCD_FIFO = 32'h0C12_1208;

	// ------------------------------------------------------------------
	// Channel registers
	// ------------------------------------------------------------------
	logic [7:0] req, go_clr, sinc, dinc;
	logic [7:0] paced_start, lcd_destination, lcd_deferred;
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

	function automatic logic lcd_address(input logic [31:0] a);
		return a == LCD_FIFO || a == 32'h10121208;
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

	logic [1:0]  est    [0:ENGINES-1];
	logic [2:0]  ech    [0:ENGINES-1];
	logic [31:0] esrc   [0:ENGINES-1];
	logic [31:0] edst   [0:ENGINES-1];
	logic [32:0] eleft  [0:ENGINES-1];   // source units still to read
	logic [31:0] ebuf   [0:ENGINES-1];   // bytes read and not yet written, first in 7:0
	logic [2:0]  efill  [0:ENGINES-1];
	logic        esinc  [0:ENGINES-1];
	logic        edinc  [0:ENGINES-1];
	logic [1:0]  esw    [0:ENGINES-1];
	logic [1:0]  edw    [0:ENGINES-1];
	logic        eabort [0:ENGINES-1];
	// the access an engine asks for
	logic        ewe    [0:ENGINES-1];
	logic [31:0] eadr   [0:ENGINES-1];
	logic [31:0] edat   [0:ENGINES-1];
	logic [3:0]  esel   [0:ENGINES-1];
	logic [2:0]  en     [0:ENGINES-1];   // bytes it moves

	// the master port
	logic          p_busy;
	logic [EW-1:0] p_e;
	logic [EW-1:0] rr;                   // round-robin start
	logic          g_we;
	logic [31:0]   g_adr, g_dat;
	logic [3:0]    g_sel;

	// The loader reads src/dst/count before assigning either engine type.
	logic          ld_busy, ld_cancel;
	logic [1:0]    ld_step;
	logic [2:0]    ld_ch;
	logic [EW-1:0] ld_e;
	logic          ld_has_engine;
	logic [31:0]   ld_src, ld_dst;
	logic [2:0]    req_rr;

	wire fast_enabled = LCD_DMA_WORDS != 0 && nem4;
	wire lcd_busy, lcd_done, fetch_req, fetch_more;
	wire [31:0] fetch_addr;
	logic [2:0] lcd_ch;
	logic fetch_owned, last_lcd;

	wire lcd_descriptor = fast_enabled && paced_start[ld_ch] && sinc[ld_ch] &&
		!dinc[ld_ch] && sw[ld_ch] == 2 && dw[ld_ch] == 2 && lcd_address(ld_dst) &&
		ld_src[31:24] == 8'h0a && ld_src[1:0] == 0 && pr_q <= {10'd0, ~ld_src[23:2]};
	wire lcd_start = ld_busy && ld_step == 3 && !ld_cancel && !(w_go && ch == ld_ch) &&
		lcd_descriptor && !lcd_busy;
	wire lcd_stop = w_go && ch == lcd_ch;
	wire fetch_ack = fetch_owned && m_ack;
	wire fetch_err = fetch_owned && m_err;

	generate if (LCD_DMA_WORDS != 0) begin : native_lcd
		upp_lcd_dma #(.PACKET_WORDS(LCD_DMA_WORDS)) stream (
			.clk(clk), .reset(reset),
			.start(lcd_start), .source(ld_src[23:2]), .count_minus_one(pr_q[21:0]),
			.stop(lcd_stop), .busy(lcd_busy), .done(lcd_done),
			.read_req(fetch_req), .read_owned(fetch_owned), .read_addr(fetch_addr),
			.read_more(fetch_more), .read_ack(fetch_ack), .read_err(fetch_err), .read_data(m_dat_i),
			.pixel_valid(lcd_valid), .pixel_data(lcd_data), .pixel_ready(lcd_ready), .panel_idle(lcd_idle)
		);
	end else begin : classic_lcd
		assign lcd_busy   = 1'b0;
		assign lcd_done   = 1'b0;
		assign fetch_req  = 1'b0;
		assign fetch_more = 1'b0;
		assign fetch_addr = 32'd0;
		assign lcd_valid  = 1'b0;
		assign lcd_data   = 32'd0;
	end endgenerate

	logic          free_any;
	logic [EW-1:0] free_e;
	wire [EW-1:0]  generic_engine = ld_has_engine ? ld_e : free_e;
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

	logic       req_any;
	logic [2:0] req_ch;
	logic [7:0] channel_active;
	always_comb begin
		channel_active = 8'd0;
		for (int e = 0; e < ENGINES; e++)
			if (est[e] != E_FREE) channel_active[ech[e]] = 1'b1;
		if (lcd_busy) channel_active[lcd_ch] = 1'b1;

		req_any = 1'b0;
		req_ch  = 3'd0;
		for (int i = 7; i >= 0; i--) begin
			logic [2:0] c;
			c = (fast_enabled ? req_rr : 3'd0) + 3'(i);
			if (req[c] && (!fast_enabled || !channel_active[c]) &&
			    (free_any || (fast_enabled && !lcd_busy && paced_start[c] &&
			                  lcd_destination[c] && !lcd_deferred[c]))) begin
				req_any = 1'b1;
				req_ch  = c;
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
		for (int i = ENGINES - 1; i >= 0; i--) begin
			int e;
			e = int'(rr) + i;
			if (e >= ENGINES) e = e - ENGINES;
			if (est[e] == E_BUS) begin
				grant_any = 1'b1;
				grant_e   = EW'(e);
			end
		end
	end

	assign m_cyc   = fetch_owned || p_busy;
	assign m_stb   = m_cyc;
	assign m_we    = !fetch_owned && g_we;
	assign m_adr   = fetch_owned ? fetch_addr : g_adr;
	assign m_dat_o = g_dat;
	assign m_sel   = fetch_owned ? 4'hf : g_sel;
	assign m_burst = fetch_owned && fetch_more;

	always_ff @(posedge clk) begin
		// ---- the engines ----
		for (int e = 0; e < ENGINES; e++) begin
			logic [2:0] swb, dwb, nw;
			logic       paced;
			swb = 3'd1 << esw[e];
			dwb = 3'd1 << edw[e];
			nw  = (efill[e] < dwb) ? efill[e] : dwb;

			// a stop or restart of its channel ends the transfer
			if (w_go && est[e] != E_FREE && ech[e] == ch) eabort[e] <= 1'b1;

			if (est[e] == E_RUN) begin
				if (eabort[e]) begin
					est[e] <= E_FREE;
				end else if (efill[e] >= dwb || (eleft[e] == 33'd0 && efill[e] != 3'd0)) begin
					// a write of nw bytes
					paced = !edinc[e] && ((edst[e] == LCD_FIFO && !lcd_tx_ready) ||
					                      (edst[e] == MMC_FIFO && !mmc_tx_ready));
					if (!paced) begin
						ewe[e]  <= 1'b1;
						eadr[e] <= {edst[e][31:2], 2'b00};
						edat[e] <= ebuf[e] << {edst[e][1:0], 3'b000};
						esel[e] <= 4'((5'b00001 << nw) - 5'd1) << edst[e][1:0];
						en[e]   <= nw;
						est[e]  <= E_BUS;
					end
				end else if (eleft[e] != 33'd0) begin
					// a read of swb bytes
					paced = !esinc[e] && esrc[e] == MMC_FIFO && !mmc_rx_ready;
					if (!paced) begin
						ewe[e]  <= 1'b0;
						eadr[e] <= {esrc[e][31:2], 2'b00};
						esel[e] <= 4'((5'b00001 << swb) - 5'd1) << esrc[e][1:0];
						en[e]   <= swb;
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
		if (fetch_owned) begin
			if (fetch_err || (fetch_ack && !fetch_more)) fetch_owned <= 1'b0;
		end else if (!p_busy) begin
			if (fetch_req && (!grant_any || !last_lcd)) begin
				fetch_owned <= 1'b1;
				last_lcd    <= 1'b1;
			end else if (grant_any) begin
				p_busy  <= 1'b1;
				p_e     <= grant_e;
				rr      <= (grant_e == EW'(ENGINES - 1)) ? '0 : grant_e + 1'd1;
				last_lcd <= 1'b0;
				g_we    <= ewe[grant_e];
				g_adr   <= eadr[grant_e];
				g_dat   <= edat[grant_e];
				g_sel   <= esel[grant_e];
			end
		end else if (m_ack || m_err) begin
			logic [31:0] rb;
			p_busy   <= 1'b0;
			est[p_e] <= E_RUN;
			if (ewe[p_e]) begin
				ebuf[p_e]  <= ebuf[p_e] >> {en[p_e], 3'b000};
				efill[p_e] <= efill[p_e] - en[p_e];
				if (edinc[p_e]) edst[p_e] <= edst[p_e] + 32'(en[p_e]);
			end else begin
				rb = m_err ? 32'd0 : m_dat_i >> {esrc[p_e][1:0], 3'b000};
				rb = rb & ((en[p_e] == 3'd4) ? 32'hFFFF_FFFF : (32'd1 << {en[p_e], 3'b000}) - 32'd1);
				ebuf[p_e]  <= ebuf[p_e] | (rb << {efill[p_e], 3'b000});
				efill[p_e] <= efill[p_e] + en[p_e];
				eleft[p_e] <= eleft[p_e] - 33'd1;
				if (esinc[p_e]) esrc[p_e] <= esrc[p_e] + 32'(en[p_e]);
			end
		end

		// ---- the loader ----
		if (!ld_busy) begin
			if (req_any && !(w_go && ch == req_ch)) begin
				ld_busy     <= 1'b1;
				ld_cancel   <= 1'b0;
				ld_ch       <= req_ch;
				ld_e        <= free_e;
				ld_has_engine <= free_any;
				ld_step     <= 2'd0;
				req_rr      <= req_ch + 1'b1;
				req[req_ch] <= 1'b0;
			end
		end else begin
			ld_step <= ld_step + 2'd1;
			case (ld_step)
				2'd1: ld_src <= pr_q;
				2'd2: ld_dst <= pr_q;
				2'd3: begin
					ld_busy <= 1'b0;
					if (!ld_cancel && !(w_go && ch == ld_ch)) begin
						if (lcd_start) begin
							lcd_ch <= ld_ch;
						end else if (!lcd_descriptor && free_any) begin
							est[generic_engine]    <= E_RUN;
							ech[generic_engine]    <= ld_ch;
							esrc[generic_engine]   <= phys(ld_src);
							edst[generic_engine]   <= phys(ld_dst);
							eleft[generic_engine]  <= {1'b0, pr_q} + 33'd1;
							ebuf[generic_engine]   <= 32'd0;
							efill[generic_engine]  <= 3'd0;
							esinc[generic_engine]  <= sinc[ld_ch];
							edinc[generic_engine]  <= dinc[ld_ch];
							esw[generic_engine]    <= sw[ld_ch];
							edw[generic_engine]    <= dw[ld_ch];
							eabort[generic_engine] <= 1'b0;
						end else begin
							req[ld_ch] <= 1'b1;
							lcd_deferred[ld_ch] <= !lcd_descriptor;
						end
					end
				end
				default: ;
			endcase
		end

		if (lcd_done || (fetch_err && !lcd_stop)) begin
			go_clr[lcd_ch] <= 1'b1;
			if (lcd_done) irq[lcd_ch] <= 1'b1;
		end

		// ---- register writes ----
		if (wr) begin
			if (pr_we || (r >= 6'h18 && r <= 6'h28)) lcd_deferred[ch] <= 1'b0;
			case (r)
				6'h04: if (wdata == 32'd0) irq[ch] <= 1'b0;
				6'h20: lcd_destination[ch] <= lcd_address(wdata);
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
				paced_start[ch] <= wdata == 32'd2;
				lcd_deferred[ch] <= 1'b0;
			end
			if (w_stop) begin
				req[ch] <= 1'b0;
				irq[ch] <= 1'b0;
			end
			if (ld_busy && ld_ch == ch) ld_cancel <= 1'b1;
		end

		if (reset) begin
			req    <= 8'd0;
			paced_start <= 8'd0;
			lcd_destination <= 8'd0;
			lcd_deferred <= 8'd0;
			go_clr <= 8'd0;
			irq    <= 8'd0;
			sinc   <= 8'd0;
			dinc   <= 8'd0;
			for (int c = 0; c < 8; c++) begin
				sw[c] <= 2'd0;
				dw[c] <= 2'd0;
			end
			for (int e = 0; e < ENGINES; e++) est[e] <= E_FREE;
			ld_busy <= 1'b0;
			p_busy  <= 1'b0;
			fetch_owned <= 1'b0;
			last_lcd <= 1'b0;
			rr      <= '0;
			req_rr  <= '0;
		end
	end


endmodule
