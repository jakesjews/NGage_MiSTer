// SPDX-License-Identifier: GPL-2.0-or-later
//
// The UPP_WD2's on-chip peripherals on upp_bus's peripheral register bus
// (0x0C100000-0x0DFFFFFF), as the reference model maps them (model/hw/ngage.c
// and the files below; docs/UPP_WD2.md):
//
//   0x0C120000-0x0C12003F  clock and system page: storage; 0x0C120020 bits
//                          26-28 read 1, the DPLLs locked (bootstrap polls bit
//                          26 at 0x3770, bit 27 at 0x382C; model/upp-quirks.txt)
//   0x0C120040-0x0C12007F  OS-timer interrupt unit          upp_intc
//   0x0C120100-0x0C12027F  interrupt controller             upp_intc
//   0x0C120300-0x0C1204FF  DMA controller, 8 channels       upp_dma
//   0x0C120600-0x0C12063F  MMC host                         upp_mmc
//   0x0C120A00-0x0C120ABF  timers 0-5                       upp_timers
//   0x0C121200-0x0C12120F  LCD bus interface                upp_lcdif
//   0x0C149000             MCU DPLL: storage, bit 0 reads 1 (locked; bootstrap
//                          0x37FC, model/upp-quirks.txt)
//   0x0C150100             CTSI interrupt status            upp_uif
//   0x0C150400-0x0C15041F  UIF ports D/E (keypad)           upp_uif
//   0x0C150420-0x0C150427  CBUS master, UEMK and the rest   upp_cbus
//   0x0C1F0000-0x0C1F00FF  HLE audio device (emulator)      upp_haudio
//   0x0C1F0100-0x0C1F010F  HLE RTC date register (emulator): +0 the date,
//                          the rest 0, writes dropped        upp_cbus
//   0x0DE00000-0x0DFFFFFF  STI trace window: writes go to sti_* (the kernel's
//                          debug text, ngage_sti.c), reads 0
//   the rest of 0x0C1xxxxx registers with no known behaviour: storage, as the
//                          model's storage block (ngage_upp.c): reads return
//                          what was written, byte for byte, 0 after reset
//   everything else        reads 0, writes are dropped (the model's probe)
// Inside a block's window the registers the block does not answer are storage
// too, as in the model (each block's header says which those are), and a
// block can answer some bits of a register and leave the rest to storage
// (rmask). Accesses of a size a block's model region does not take (32-bit
// only for the intc, timers, DMA and LCD; 16-bit for the keypad and CTSI;
// 16/32-bit for CBUS) are dropped and read 0, as QEMU does with them.
//
// The two emulator devices are inventions of this project for what NOS and
// the DSP did on the phone (docs/UPP_WD2.md, "Emulator devices"); only the
// NOS stand-in uses them. Their windows take 32-bit accesses only and hide
// the storage behind them, as the model's regions do over its storage block.
// The audio device reads its samples through the DMA controller's bus master
// port: the two take it in turns, a cycle each (the DMA controller's is one
// beat, the audio device's the one or two of a frame). Its interrupt is
// source 5 (IrqTimer5) ORed with timer 5's (in the model whichever changed
// last sets the line; nothing runs timer 5).
//
// Storage is a block RAM of 8 slots of 4 KB, one per page the firmware is
// known to use (0x0C120, 0x0C121, 0x0C149, 0x0C14D, 0x0C14F, 0x0C150) and two
// shared by the other pages of 0x0C1xxxxx [assumed: those alias each other;
// the model has the whole 1 MB]. It is cleared after reset (8192 clocks, while
// accesses wait), so a core reset is a power-on for the registers.
//
// Timing on the register bus: a write completes in its second clock, a read
// in its third (the storage and block read data are registered), later while
// a block is busy (a full FIFO, a bus read from the panel, MMC data still on
// its way, a CBUS transfer).
module upp_periph #(
	parameter int TIMER_DIV          = 3,              // 104 / 3 = 34.67 MHz
	parameter int MMC_DIV            = 12,             // 104 / 12 = 8.67 MHz
	parameter int MMC_TIMEOUT_LOG2   = 21,
	parameter int LCD_WR_LOW         = 2,
	parameter int LCD_WR_HIGH        = 2,
	parameter int LCD_RD_LOW         = 4,
	parameter int LCD_RD_HIGH        = 6,
	parameter int DMA_ENGINES        = 3,
	parameter int POWER_ON_HOLD_CLKS = 312_000_000,    // 3 s, as the model
	parameter int CLK_HZ             = 104_000_000     // for the audio device
) (
	input  logic        clk,
	input  logic        reset,

	// the peripheral register bus (upp_bus)
	input  logic        p_sel,
	input  logic        p_we,
	input  logic [27:0] p_addr,
	input  logic [31:0] p_wdata,
	input  logic [3:0]  p_be,
	output logic [31:0] p_rdata,
	output logic        p_wait,

	// the bus master of the DMA controller and the audio device (Wishbone B3
	// classic, single beats)
	output logic        dma_cyc,
	output logic        dma_stb,
	output logic        dma_we,
	output logic [31:0] dma_adr,
	output logic [31:0] dma_dat_o,
	output logic [3:0]  dma_sel,
	input  logic        dma_ack,
	input  logic        dma_err,
	input  logic [31:0] dma_dat_i,

	// to the CPU, active high (the ARM925T's nIRQ / nFIQ inverted)
	output logic        irq,
	output logic        fiq,

	// the display module's 8080 bus
	output logic        lcd_csx,
	output logic        lcd_dcx,
	output logic        lcd_wrx,
	output logic        lcd_rdx,
	output logic        lcd_resx,
	output logic [7:0]  lcd_d_o,
	output logic        lcd_d_oe,
	input  logic [7:0]  lcd_d_i,
	output logic        lcd_active,      // the interface has driven the bus since reset

	// the MMC slot
	output logic        mmc_clk,
	output logic        mmc_cmd_o,
	output logic        mmc_cmd_oe,
	input  logic        mmc_cmd_i,
	output logic        mmc_dat_o,
	output logic        mmc_dat_oe,
	input  logic        mmc_dat_i,

	// the key matrix lines (keypad_matrix) and the power key (to the UEMK)
	output logic [4:0]  kp_col_oe,
	output logic [4:0]  kp_col_out,
	output logic [5:0]  kp_row_oe,
	output logic [5:0]  kp_row_out,
	input  logic [4:0]  kp_col_in,
	input  logic [5:0]  kp_row_in,
	input  logic        power_key,

	// the wall clock (rtc_wall) for the UEMK RTC and the date register
	input  logic        rtc_valid,
	input  logic [5:0]  rtc_sec,
	input  logic [5:0]  rtc_min,
	input  logic [4:0]  rtc_hour,
	input  logic [7:0]  rtc_days,
	input  logic [31:0] rtc_date,

	// the audio device's output, signed, at 48 kHz
	output logic [15:0] audio_l,
	output logic [15:0] audio_r,

	// writes to the STI trace window (debug)
	output logic        sti_we,
	output logic [20:0] sti_addr,
	output logic [3:0]  sti_be,
	output logic [31:0] sti_data
);

	// ------------------------------------------------------------------
	// Decoding
	// ------------------------------------------------------------------
	wire        in_c1 = p_addr[27:20] == 8'hC1;
	wire [7:0]  page  = p_addr[19:12];
	wire [11:0] off   = {p_addr[11:2], 2'b00};

	wire pg20 = in_c1 && page == 8'h20;
	wire pg21 = in_c1 && page == 8'h21;
	wire pg49 = in_c1 && page == 8'h49;
	wire pg50 = in_c1 && page == 8'h50;
	wire pgF0 = in_c1 && page == 8'hF0;

	wire s_intc = pg20 && ((off >= 12'h040 && off < 12'h080) || (off >= 12'h100 && off < 12'h280));
	wire s_dma  = pg20 && off >= 12'h300 && off < 12'h500;
	wire s_mmc  = pg20 && off >= 12'h600 && off < 12'h640;
	wire s_tmr  = pg20 && off >= 12'hA00 && off < 12'hAC0;
	wire s_lcd  = pg21 && off >= 12'h200 && off < 12'h210;
	wire s_ctsi = pg50 && off == 12'h100;
	wire s_kp   = pg50 && off >= 12'h400 && off < 12'h420;
	wire s_cbus = pg50 && off >= 12'h420 && off < 12'h428;
	wire s_aud  = pgF0 && off < 12'h100;
	wire s_date = pgF0 && off >= 12'h100 && off < 12'h110;
	wire s_sti  = p_addr[27:21] == 7'b1101_111;

	wire be32 = p_be == 4'b1111;
	wire be16 = p_be == 4'b0011 || p_be == 4'b1100;
	wire size_ok = (s_intc || s_dma || s_tmr || s_lcd || s_aud || s_date) ? be32 :
	               s_ctsi ? p_be == 4'b0011 :
	               s_kp ? be16 :
	               s_cbus ? (be16 || be32) : 1'b1;

	// ------------------------------------------------------------------
	// The access
	// ------------------------------------------------------------------
	logic [1:0]  cnt;                   // clocks of the access so far
	logic        rdy_q;
	logic [31:0] rd_q;
	logic        init_busy;
	logic        blk_busy;

	wire done = p_sel && rdy_q && (p_we ? cnt != 2'd0 : cnt[1]);
	assign p_wait  = p_sel && !done;
	assign p_rdata = rd_q;

	wire acc = p_sel && size_ok && !init_busy;
	wire wr  = done && p_we && size_ok;
	wire rd  = done && !p_we && size_ok;

	// ------------------------------------------------------------------
	// Storage
	// ------------------------------------------------------------------
	logic [2:0]  slot;
	always_comb begin
		case (page)
			8'h20: slot = 3'd0;
			8'h21: slot = 3'd1;
			8'h49: slot = 3'd2;
			8'h4D: slot = 3'd3;
			8'h4F: slot = 3'd4;
			8'h50: slot = 3'd5;
			default: slot = {2'b11, page[0]};
		endcase
	end

	logic [12:0] clr;
	logic [31:0] st_q;
	wire  [12:0] st_idx = {slot, p_addr[11:2]};

	bram32 #(.AW(13)) storage (
		.clk(clk),
		.we(init_busy || (wr && in_c1)),
		.be(init_busy ? 4'b1111 : p_be),
		.waddr(init_busy ? clr : st_idx),
		.wdata(init_busy ? 32'd0 : p_wdata),
		.raddr(st_idx),
		.rdata(st_q)
	);

	always_ff @(posedge clk) begin
		if (init_busy) begin
			clr <= clr + 13'd1;
			if (clr == 13'h1FFF) init_busy <= 1'b0;
		end
		if (reset) begin
			clr       <= 13'd0;
			init_busy <= 1'b1;
		end
	end

	// ------------------------------------------------------------------
	// The blocks
	// ------------------------------------------------------------------
	logic [31:0] m_intc, d_intc, m_tmr, d_tmr, m_dma, d_dma, m_mmc, d_mmc, m_lcd, d_lcd,
	             m_uif, d_uif, m_cbus, d_cbus, m_aud, d_aud, rtc_base;
	logic        b_mmc, b_lcd, b_cbus;
	logic [5:0]  tmr_irq;
	logic [7:0]  dma_irq;
	logic [3:0]  mmc_irq;
	logic        ctsi_irq;
	logic        aud_irq;
	logic        mmc_rx_ready, mmc_tx_ready, lcd_tx_ready;

	// the two masters behind the DMA port
	logic        d_cyc, d_stb, d_we, a_cyc, a_stb, a_we;
	logic [31:0] d_adr, d_dat, a_adr, a_dat;
	logic [3:0]  d_sel, a_sel;
	logic        own_au;               // 1: the audio device has the port

	// interrupt sources, bit 32k + b = bank k bit b (docs/UPP_WD2.md)
	wire [95:0] src = {70'd0,
		ctsi_irq,                      // 25 CTSI_IRQ
		mmc_irq,                       // 24 MMCCmdRdy, 23 MMCCmdIdle, 22 MMCDataRdy, 21 MMCDataIdle
		5'd0,                          // 16-20 Ir4M
		2'd0,                          // 14 FlashCopyRdy, 15 LCDBuffer
		dma_irq,                       // 6-13 DmaChannel0-7
		tmr_irq[5] | aud_irq,          // 5 Timer5, the HLE audio device
		tmr_irq[4:0]};                 // 0-4 Timer0-4

	upp_intc intc (
		.clk(clk),
		.reset(reset),
		.src(src),
		.ost_set(3'd0),                // nothing known sets the OS-timer status
		.acc(acc && s_intc),
		.wr(wr && s_intc),
		.off(off),
		.wdata(p_wdata),
		.rmask(m_intc),
		.rdata(d_intc),
		.irq(irq),
		.fiq(fiq)
	);

	upp_timers #(.TIMER_DIV(TIMER_DIV)) timers (
		.clk(clk),
		.reset(reset),
		.acc(acc && s_tmr),
		.wr(wr && s_tmr),
		.off(off),
		.wdata(p_wdata),
		.rmask(m_tmr),
		.rdata(d_tmr),
		.irq(tmr_irq)
	);

	upp_dma #(.ENGINES(DMA_ENGINES)) dma (
		.clk(clk),
		.reset(reset),
		.acc(acc && s_dma),
		.wr(wr && s_dma),
		.off(off),
		.wdata(p_wdata),
		.rmask(m_dma),
		.rdata(d_dma),
		.irq(dma_irq),
		.mmc_rx_ready(mmc_rx_ready),
		.mmc_tx_ready(mmc_tx_ready),
		.lcd_tx_ready(lcd_tx_ready),
		.m_cyc(d_cyc),
		.m_stb(d_stb),
		.m_we(d_we),
		.m_adr(d_adr),
		.m_dat_o(d_dat),
		.m_sel(d_sel),
		.m_ack(dma_ack && !own_au),
		.m_err(dma_err && !own_au),
		.m_dat_i(dma_dat_i)
	);

	upp_haudio #(.CLK_HZ(CLK_HZ)) haudio (
		.clk(clk),
		.reset(reset),
		.acc(acc && s_aud),
		.wr(wr && s_aud),
		.off(off[7:0]),
		.wdata(p_wdata),
		.rmask(m_aud),
		.rdata(d_aud),
		.irq(aud_irq),
		.m_cyc(a_cyc),
		.m_stb(a_stb),
		.m_we(a_we),
		.m_adr(a_adr),
		.m_dat_o(a_dat),
		.m_sel(a_sel),
		.m_ack(dma_ack && own_au),
		.m_err(dma_err && own_au),
		.m_dat_i(dma_dat_i),
		.out_l(audio_l),
		.out_r(audio_r),
		.frame_we(),
		.frame_l(),
		.frame_r()
	);

	// the shared master port: the owner keeps it while it has CYC up
	always_ff @(posedge clk) begin
		if (own_au ? (!a_cyc && d_cyc) : (!d_cyc && a_cyc)) own_au <= !own_au;
		if (reset) own_au <= 1'b0;
	end
	assign dma_cyc   = own_au ? a_cyc : d_cyc;
	assign dma_stb   = own_au ? a_stb : d_stb;
	assign dma_we    = own_au ? a_we  : d_we;
	assign dma_adr   = own_au ? a_adr : d_adr;
	assign dma_dat_o = own_au ? a_dat : d_dat;
	assign dma_sel   = own_au ? a_sel : d_sel;

	upp_mmc #(.DIV(MMC_DIV), .TIMEOUT_LOG2(MMC_TIMEOUT_LOG2)) mmc (
		.clk(clk),
		.reset(reset),
		.acc(acc && s_mmc),
		.we(p_we),
		.wr(wr && s_mmc),
		.rd(rd && s_mmc),
		.off(off[5:0]),
		.be(p_be),
		.wdata(p_wdata),
		.rmask(m_mmc),
		.rdata(d_mmc),
		.busy(b_mmc),
		.rx_ready(mmc_rx_ready),
		.tx_ready(mmc_tx_ready),
		.irq(mmc_irq),
		.mmc_clk(mmc_clk),
		.cmd_o(mmc_cmd_o),
		.cmd_oe(mmc_cmd_oe),
		.cmd_i(mmc_cmd_i),
		.dat_o(mmc_dat_o),
		.dat_oe(mmc_dat_oe),
		.dat_i(mmc_dat_i)
	);

	upp_lcdif #(.WR_LOW(LCD_WR_LOW), .WR_HIGH(LCD_WR_HIGH), .RD_LOW(LCD_RD_LOW),
		.RD_HIGH(LCD_RD_HIGH)) lcdif (
		.clk(clk),
		.reset(reset),
		.acc(acc && s_lcd),
		.we(p_we),
		.wr(wr && s_lcd),
		.rd(rd && s_lcd),
		.off(off[3:0]),
		.wdata(p_wdata),
		.rmask(m_lcd),
		.rdata(d_lcd),
		.busy(b_lcd),
		.tx_ready(lcd_tx_ready),
		.active(lcd_active),
		.csx(lcd_csx),
		.dcx(lcd_dcx),
		.wrx(lcd_wrx),
		.rdx(lcd_rdx),
		.resx(lcd_resx),
		.d_o(lcd_d_o),
		.d_oe(lcd_d_oe),
		.d_i(lcd_d_i)
	);

	upp_uif uif (
		.clk(clk),
		.reset(reset),
		.acc(acc && (s_ctsi || s_kp)),
		.wr(wr && (s_ctsi || s_kp)),
		.off(off),
		.hi(p_be[2]),
		.wdata(p_wdata),
		.rmask(m_uif),
		.rdata(d_uif),
		.ctsi_irq(ctsi_irq),
		.col_oe(kp_col_oe),
		.col_out(kp_col_out),
		.row_oe(kp_row_oe),
		.row_out(kp_row_out),
		.col_in(kp_col_in),
		.row_in(kp_row_in)
	);

	upp_cbus #(.POWER_ON_HOLD_CLKS(POWER_ON_HOLD_CLKS)) cbus (
		.clk(clk),
		.reset(reset),
		.acc(acc && s_cbus),
		.we(p_we),
		.wr(wr && s_cbus),
		.off_hi(p_addr[2]),
		.be(p_be),
		.wdata(p_wdata),
		.rmask(m_cbus),
		.rdata(d_cbus),
		.busy(b_cbus),
		.power_key(power_key),
		.rtc_valid(rtc_valid),
		.rtc_sec(rtc_sec),
		.rtc_min(rtc_min),
		.rtc_hour(rtc_hour),
		.rtc_days(rtc_days),
		.rtc_date(rtc_date),
		.rtc_base(rtc_base)
	);

	// the read quirks of the clock page and the DPLL (model/upp-quirks.txt)
	wire [31:0] m_q = (acc && pg20 && off == 12'h020) ? 32'h1C00_0000 :
	                  (acc && pg49 && off == 12'h000) ? 32'h0000_0001 : 32'd0;
	// the HLE RTC date register
	wire [31:0] m_date = (acc && s_date) ? 32'hFFFF_FFFF : 32'd0;
	wire [31:0] d_date = (off[3:0] == 4'h0) ? rtc_base : 32'd0;

	wire [31:0] rmask = m_intc | m_tmr | m_dma | m_mmc | m_lcd | m_uif | m_cbus | m_aud | m_date | m_q;
	wire [31:0] rbits = (d_intc & m_intc) | (d_tmr & m_tmr) | (d_dma & m_dma) | (d_mmc & m_mmc) |
	                    (d_lcd & m_lcd) | (d_uif & m_uif) | (d_cbus & m_cbus) | (d_aud & m_aud) |
	                    (d_date & m_date) | m_q;
	assign blk_busy = (s_mmc && b_mmc) || (s_lcd && b_lcd) || (s_cbus && b_cbus);

	always_ff @(posedge clk) begin
		cnt   <= p_sel ? (cnt == 2'd3 ? 2'd3 : cnt + 2'd1) : 2'd0;
		rdy_q <= !init_busy && !(size_ok && blk_busy);
		rd_q  <= (in_c1 && size_ok) ? ((st_q & ~rmask) | rbits) : 32'd0;
		if (reset) begin
			cnt   <= 2'd0;
			rdy_q <= 1'b0;
		end
	end

	// ------------------------------------------------------------------
	// STI trace window
	// ------------------------------------------------------------------
	always_ff @(posedge clk) begin
		sti_we   <= wr && s_sti;
		sti_addr <= p_addr[20:0];
		sti_be   <= p_be;
		sti_data <= p_wdata;
	end

endmodule
