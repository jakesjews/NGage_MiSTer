// SPDX-License-Identifier: GPL-2.0-or-later
//
// The UPP_WD2's on-chip peripherals on upp_bus's peripheral register bus
// (0x0C100000-0x0DFFFFFF), as the reference model maps them (model/hw/ngage.c
// and the files below; docs/UPP_WD2.md):
//
//   0x0C120000-0x0C12003F  clock and system page: storage; 0x0C120020 bits
//                          26-28 read 1, the DPLLs locked (bootstrap polls bit
//                          26 at 0x3770, bit 27 at 0x382C). Bit 25 is ready
//                          while clock control holds 0x20 or 0x40 (native NOS).
//   0x0C120040-0x0C12007F  OS-timer interrupt unit          upp_intc
//   0x0C120100-0x0C12027F  interrupt controller             upp_intc
//   0x0C120300-0x0C1204FF  DMA controller, 8 channels       upp_dma
//   0x0C120600-0x0C12063F  MMC host                         upp_mmc
//   0x0C120A00-0x0C120ABF  timers 0-5                       upp_timers
//   0x0C121200-0x0C12120F  LCD bus interface                upp_lcdif
//   0x0C148000             NOS clock unit: storage, bit 0 reads 1 (locked)
//   0x0C149000             MCU DPLL: storage, bit 0 reads 1 (locked; bootstrap
//                          0x37FC, model/upp-quirks.txt)
//   0x0C150002             GSM system-type strap in bit 6
//   0x0C150014, 0x0C150016 CTSI interrupt enables (the Bluetooth module's
//                          line)                             upp_uif
//   0x0C150100, 0x0C150102 CTSI interrupt status            upp_uif
//   0x0C150112, 0x0C150114 CTSI delay calibration           upp_uif
//   0x0C150116, 0x0C150118 CTSI NOS counter and compare     upp_uif
//   0x0C15021C             MBUS command strobes complete immediately
//   0x0C150400-0x0C15041F  UIF ports D/E (keypad)           upp_uif
//   0x0C150420-0x0C150427  CBUS master, UEMK and the rest   upp_cbus
//   0x0C150504             idle FBUS transmitter status
//   0x0C150510–0x0C150563  NEM-4 EUART1 control and data     upp_euart
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
	parameter int MMC_DIV            = 4,              // 104 / 4 = 26 MHz (12 is the phone's own rate, the service manual's 8.66 MHz, for an accuracy build)
	parameter int MMC_TIMEOUT_LOG2   = 23,             // 2^23 / 26 MHz = 322.6 ms (21 at MMC_DIV = 12)
	parameter int LCD_WR_LOW         = 2,
	parameter int LCD_WR_HIGH        = 2,
	parameter int LCD_RD_LOW         = 4,
	parameter int LCD_RD_HIGH        = 6,
	parameter int DMA_ENGINES        = 3,
	parameter int POWER_ON_HOLD_CLKS = 312_000_000,    // 3 s, as the model
	parameter int ALARM_CLKS         = 7_995_392,
	parameter int CLK_HZ             = 104_000_000     // for the audio device and CTSI
) (
	input  logic        clk,
	input  logic        reset,
	input  logic        nem4,

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

	// The MDI peer's payload access to the shared SDRAM rings.
	output logic        mdi_req,
	output logic        mdi_we,
	output logic [7:0]  mdi_word,
	output logic [31:0] mdi_wdata,
	output logic [3:0]  mdi_be,
	input  logic        mdi_ack,
	input  logic        mdi_err,
	input  logic [31:0] mdi_rdata,

	// to the CPU, active high (the ARM925T's nIRQ / nFIQ inverted)
	output logic        irq,
	output logic        fiq,
	output logic [31:0] dbg_src0,        // debug overlay: interrupt sources, bank 0
	output logic [31:0] dbg_en0_irq,
	output logic [31:0] dbg_en0_fiq,

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
	output logic        nem4_lcd_valid,
	output logic        nem4_lcd_header,
	output logic [31:0] nem4_lcd_data,
	input  logic        nem4_lcd_ready,

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

	// the Bluetooth module on CBUS (bt_module) and its interrupt line
	output logic        bt_rd,
	output logic        bt_wr,
	output logic [4:0]  bt_reg,
	output logic [15:0] bt_wdata,
	input  logic [15:0] bt_rdata,
	input  logic        bt_busy,
	input  logic        bt_irq,

	// Transaction-level byte link to the external NEM-4 D550.
	output wire         adsp_clock_ready,
	output wire         adsp_receive_enabled,
	output wire         adsp_tx_valid,
	input  logic        adsp_tx_ready,
	output wire [7:0]   adsp_tx_data,
	input  logic        adsp_rx_valid,
	output wire         adsp_rx_ready,
	input  logic [7:0]  adsp_rx_data,

	// the wall clock (rtc_wall) for the UEMK RTC and the date register
	input  logic        rtc_valid,
	input  logic [5:0]  rtc_sec,
	input  logic [5:0]  rtc_min,
	input  logic [4:0]  rtc_hour,
	input  logic [7:0]  rtc_days,
	input  logic [31:0] rtc_date,
	input  logic        c_blank,       // HLE 0x0C1F0104 bit 0: CS1's C: area is erased

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
	wire pg48 = in_c1 && page == 8'h48;
	wire pg49 = in_c1 && page == 8'h49;
	wire pg50 = in_c1 && page == 8'h50;
	wire pgF0 = in_c1 && page == 8'hF0;

	wire s_intc = pg20 && ((off >= 12'h040 && off < 12'h080) || (off >= 12'h100 && off < 12'h280));
	wire s_dma  = pg20 && off >= 12'h300 && off < 12'h500;
	wire s_mmc  = pg20 && off >= 12'h600 && off < 12'h640;
	wire s_tmr  = pg20 && off >= 12'hA00 && off < 12'hAC0;
	wire s_lcd  = pg21 && off >= 12'h200 && off < 12'h210;
	wire s_ctsi = pg50 && (off == 12'h100 || off == 12'h014);
	wire s_cal_counter = pg50 && off == 12'h110;
	wire s_cal_window  = pg50 && off == 12'h114;
	wire s_nos_timer   = pg50 && (off == 12'h010 || off == 12'h118);
	wire s_genio = pg50 && off[11:4] == 8'h20;
	wire s_kp   = pg50 && off >= 12'h400 && off < 12'h420;
	wire s_cbus = pg50 && off >= 12'h420 && off < 12'h428;
	wire s_date = pgF0 && off >= 12'h100 && off < 12'h110;
	wire s_sti  = p_addr[27:21] == 7'b1101_111;
	wire s_mdi_control = in_c1 && page == 8'h4B && off == 12'h004;
	wire s_mdi = s_mdi_control || (in_c1 && page == 8'h00 &&
	                            (off == 12'h3E8 || off == 12'h3EC));

	wire be32 = p_be == 4'b1111;
	wire be16 = p_be == 4'b0011 || p_be == 4'b1100;
	wire size_ok = (s_intc || s_dma || s_tmr || s_lcd || s_date) ? be32 :
	               (s_ctsi || s_kp) ? be16 :
	               s_cbus ? (be16 || be32) : 1'b1;

	// ------------------------------------------------------------------
	// The access
	// ------------------------------------------------------------------
	logic [1:0]  cnt;                   // clocks of the access so far
	logic        rdy_q;
	logic        dma_hit_q;             // the DMA select and the offset, registered in the
	logic [11:0] off_q;                 // access's first clock (an access completes a clock
	                                    // later at the earliest), so the page and range
	                                    // decode is not in the same clock as the DMA's
	                                    // register writes (timing)
	logic [31:0] rd_q;
	logic        init_busy;
	logic        blk_busy;
	wire simif_claim, simif_bad, simif_busy, simif_irq;
	wire euart_claim, euart_bad, euart_ready, euart_fiq;

	wire done = p_sel && rdy_q && (p_we ? cnt != 2'd0 : cnt[1]) &&
	            !(simif_claim && simif_busy) && euart_ready;
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
	wire  [3:0]  st_be = p_be & {{2{!s_cal_counter}}, {2{!s_cal_window}}};

	bram32 #(.AW(13)) storage (
		.clk(clk),
		.we(init_busy || (wr && in_c1 && !s_mdi && !s_genio && !simif_claim && !euart_claim)),
		.be(init_busy ? 4'b1111 : st_be),
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
	             m_uif, d_uif, m_cbus, d_cbus, rtc_base;
	logic        b_mmc, b_lcd, b_cbus;
	logic [5:0]  tmr_irq;
	logic [7:0]  dma_irq;
	logic [3:0]  mmc_irq;
	logic        ctsi_irq;
	logic        pcm_link_up, pcm_write, alarm_irq;
	logic [7:0]  pcm_offset;
	logic [31:0] pcm_data;
	logic [19:0] pcm_status;
	logic        mmc_rx_ready, mmc_tx_ready, lcd_tx_ready;

	// the two masters behind the DMA port
	logic        d_cyc, d_stb, d_we, a_cyc, a_stb, a_we;
	logic [31:0] d_adr, d_dat, a_adr, a_dat;
	logic [3:0]  d_sel, a_sel;
	logic        own_au;               // 1: the audio device has the port

	// interrupt sources, bit 32k + b = bank k bit b (docs/UPP_WD2.md)
	wire [95:0] src = {69'd0,
		simif_irq | euart_fiq,         // 26 CTSI_FIQ
		ctsi_irq,                      // 25 CTSI_IRQ
		mmc_irq,                       // 24 MMCCmdRdy, 23 MMCCmdIdle, 22 MMCDataRdy, 21 MMCDataIdle
		5'd0,                          // 16-20 Ir4M
		2'd0,                          // 14 FlashCopyRdy, 15 LCDBuffer
		dma_irq,                       // 6-13 DmaChannel0-7
		tmr_irq[5:2],                  // 2-5 Timer2-5
		tmr_irq[1] | alarm_irq,        // 1 Timer1 / UEM alarm
		tmr_irq[0]};                 // 0 Timer0

	upp_intc #(.FIQ_ONLY(96'd1 << 26)) intc (
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
		.fiq(fiq),
		.dbg_en0_irq(dbg_en0_irq),
		.dbg_en0_fiq(dbg_en0_fiq)
	);
	assign dbg_src0 = src[31:0];

	upp_timers #(.TIMER_DIV(TIMER_DIV), .NEM4_TIMER_DIV(CLK_HZ / 26_000_000)) timers (
		.clk(clk),
		.reset(reset),
		.nem4(nem4),
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
		.wr(done && p_we && dma_hit_q),
		.off(off_q),
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

	upp_pcm #(.CLK_HZ(CLK_HZ)) pcm (
		.clk(clk),
		.reset(reset),
		.enabled(pcm_link_up),
		.wr(pcm_write),
		.off(pcm_offset),
		.wdata(pcm_data),
		.stream_status(pcm_status),
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
		.out_valid(),
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
		.nem4(nem4),
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
		.nem4_word_valid(nem4_lcd_valid),
		.nem4_word_header(nem4_lcd_header),
		.nem4_word_data(nem4_lcd_data),
		.nem4_word_ready(nem4_lcd_ready),
		.csx(lcd_csx),
		.dcx(lcd_dcx),
		.wrx(lcd_wrx),
		.rdx(lcd_rdx),
		.resx(lcd_resx),
		.d_o(lcd_d_o),
		.d_oe(lcd_d_oe),
		.d_i(lcd_d_i)
	);

	logic       nos_tick;
	logic [1:0] mdi_events;
	logic [31:0] d_mdi;
	wire [31:0] m_mdi = (acc && s_mdi) ? 32'hFFFF_FFFF : 32'd0;
	wire [1:0] mdi_reg = s_mdi_control ? 2'd0 : {p_addr[2], !p_addr[2]};

	upp_mdi mdi (
		.clk(clk),
		.reset(reset),
		.tick(nos_tick),
		.wr(wr && s_mdi),
		.reg_sel(mdi_reg),
		.din(p_wdata),
		.sel(p_be),
		.dout(d_mdi),
		.irq_events(mdi_events),
		.pcm_status(pcm_status),
		.pcm_link_up(pcm_link_up),
		.pcm_write(pcm_write),
		.pcm_offset(pcm_offset),
		.pcm_data(pcm_data),
		.mem_req(mdi_req),
		.mem_we(mdi_we),
		.mem_word(mdi_word),
		.mem_wdata(mdi_wdata),
		.mem_be(mdi_be),
		.mem_rdata(mdi_rdata),
		.mem_ack(mdi_ack),
		.mem_err(mdi_err)
	);

	upp_uif #(.CLK_HZ(CLK_HZ)) uif (
		.clk(clk),
		.reset(reset),
		.acc(acc && (s_ctsi || s_kp || s_cal_counter || s_cal_window || s_nos_timer)),
		.wr(wr && (s_ctsi || s_kp || s_cal_window || s_nos_timer)),
		.off(off),
		.hi(p_be[2]),
		.wdata(p_wdata),
		.be(p_be),
		.rmask(m_uif),
		.rdata(d_uif),
		.bt_irq(bt_irq && !nem4),
		.mdi_events(mdi_events),
		.nos_tick(nos_tick),
		.ctsi_irq(ctsi_irq),
		.col_oe(kp_col_oe),
		.col_out(kp_col_out),
		.row_oe(kp_row_oe),
		.row_out(kp_row_out),
		.col_in(kp_col_in),
		.row_in(kp_row_in)
	);

	wire ear_route, sim_route, tx_route;
	wire [31:0] d_genio;
	wire [31:0] m_genio = {32{acc && s_genio}};
	upp_gpio genio (
		.clk(clk),
		.reset(reset),
		.wr(wr && s_genio),
		.word_addr(p_addr[3:2]),
		.din(p_wdata),
		.sel(p_be),
		.ear_route(ear_route),
		.sim_route(sim_route),
		.tx_route(tx_route),
		.dout(d_genio)
	);

	// Keep the native SIM controller and the synthetic card on a byte interface.
	wire sim_tx_valid, sim_rx_valid, sim_rx_pop, sim_tx_will_emit;
	wire [7:0] sim_tx_data, sim_rx_data;
	wire [6:0] sim_rx_available;
	wire [31:0] d_simif;
	wire [31:0] m_simif = {32{simif_claim}};
	upp_simif simif (
		.clk(clk),
		.reset(reset),
		.present(1'b1),
		.req(acc),
		.commit(done),
		.we(p_we),
		.addr(p_addr[27:2]),
		.din(p_wdata),
		.sel(p_be),
		.claim(simif_claim),
		.bad(simif_bad),
		.dout(d_simif),
		.fiq_pending(simif_irq),
		.card_tx_valid(sim_tx_valid),
		.card_tx_data(sim_tx_data),
		.card_rx_valid(sim_rx_valid),
		.card_rx_data(sim_rx_data),
		.card_available(sim_rx_available),
		.card_tx_will_emit(sim_tx_will_emit),
		.card_rx_pop(sim_rx_pop)
	);
	upp_test_sim #(.CLOCK_DIV(CLK_HZ / 3_250_000)) test_sim (
		.clk(clk),
		.reset(reset),
		.tx_valid(sim_tx_valid),
		.tx_data(sim_tx_data),
		.rx_pop(sim_rx_pop),
		.rx_valid(sim_rx_valid),
		.rx_data(sim_rx_data),
		.overflow(),
		.available(sim_rx_available),
		.tx_will_emit(sim_tx_will_emit),
		.busy(simif_busy)
	);

	// EUART1 status shares the upper halfword at 0x0C1500B8 with the SIMIF.
	wire [31:0] d_euart;
	wire [31:0] m_euart = !euart_claim ? 32'd0 :
	                       off == 12'h0B8 ? 32'hFFFF_0000 : 32'hFFFF_FFFF;
	upp_euart euart1 (
		.clk(clk),
		.reset(reset || !nem4),
		.enabled(nem4),
		.req(acc),
		.commit(done),
		.we(p_we),
		.addr(p_addr[27:2]),
		.din(p_wdata),
		.sel(p_be),
		.claim(euart_claim),
		.bad(euart_bad),
		.ready(euart_ready),
		.dout(d_euart),
		.irq_pending(euart_fiq),
		.tx_valid(adsp_tx_valid),
		.tx_ready(adsp_tx_ready),
		.tx_data(adsp_tx_data),
		.rx_valid(adsp_rx_valid),
		.rx_ready(adsp_rx_ready),
		.rx_data(adsp_rx_data),
		.receive_enabled(adsp_receive_enabled)
	);

	upp_cbus #(.POWER_ON_HOLD_CLKS(POWER_ON_HOLD_CLKS), .ALARM_CLKS(ALARM_CLKS)) cbus (
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
		.alarm_irq_clear(wr && s_intc && off == 12'h10C && p_wdata[1]),
		.alarm_irq(alarm_irq),
		.ear_route(ear_route),
		.sim_route(sim_route),
		.tx_route(tx_route),
		.adsp_clock_ready(adsp_clock_ready),
		.bt_present(!nem4),
		.bt_rd(bt_rd),
		.bt_wr(bt_wr),
		.bt_reg(bt_reg),
		.bt_wdata(bt_wdata),
		.bt_rdata(bt_rdata),
		.bt_busy(bt_busy),
		.rtc_valid(rtc_valid),
		.rtc_sec(rtc_sec),
		.rtc_min(rtc_min),
		.rtc_hour(rtc_hour),
		.rtc_days(rtc_days),
		.rtc_date(rtc_date),
		.rtc_base(rtc_base)
	);

	// Mirror the control word so its state is available during a status read.
	// This is the immediate ready response used by the NEM-4 clock model.
	logic [31:0] clock_control;
	always_ff @(posedge clk) begin
		if (reset) clock_control <= 32'd0;
		else if (wr && pg20 && off[11:2] == 10'h001) begin
			for (int lane = 0; lane < 4; lane++) begin
				if (p_be[lane]) clock_control[8*lane +: 8] <= p_wdata[8*lane +: 8];
			end
		end
	end

	wire nos_clock_ready = clock_control == 32'h20 || clock_control == 32'h40;
	wire clock_status = acc && pg20 && off == 12'h020;
	// Both clock units report immediate lock in the peripheral model.
	wire dpll_status = acc && (pg48 || pg49) && off == 12'h000;
	// The modeled FBUS transmitter has no traffic in flight.
	wire fbus_status = acc && pg50 && off == 12'h504;
	wire gsm_strap = acc && pg50 && off == 12'h000;
	wire mbus_strobe = acc && pg50 && off == 12'h21C;
	// The QD NOS checks the UPP_WD2 revision nibble in its native self-test.
	wire upp_revision = acc && in_c1 && page == 8'h4B && off == 12'h000;
	wire [31:0] m_q = clock_status ? 32'h1E00_0000 :
	                  dpll_status ? 32'h0000_0001 :
	                  fbus_status ? 32'h0000_01D0 :
	                  gsm_strap ? 32'h0040_0000 :
	                  mbus_strobe ? 32'h0040_9818 :
	                  upp_revision ? 32'h0000_00F0 : 32'd0;
	wire [31:0] d_q = clock_status ? (32'h1C00_0000 | {6'd0, nos_clock_ready, 25'd0}) :
	                  mbus_strobe ? {9'd0, st_q[23], 22'd0} :
	                  upp_revision ? 32'h0000_0080 : m_q;
	// the HLE RTC date register
	wire [31:0] m_date = (acc && s_date) ? 32'hFFFF_FFFF : 32'd0;
	wire [31:0] d_date = (off[3:0] == 4'h0) ? rtc_base :
	                     (off[3:0] == 4'h4) ? {31'd0, c_blank} : 32'd0;

	wire [31:0] rmask = m_intc | m_tmr | m_dma | m_mmc | m_lcd | m_uif | m_cbus | m_date | m_mdi |
	                    m_genio | m_simif | m_euart | m_q;
	wire [31:0] rbits = (d_intc & m_intc) | (d_tmr & m_tmr) | (d_dma & m_dma) | (d_mmc & m_mmc) |
	                    (d_lcd & m_lcd) | (d_uif & m_uif) | (d_cbus & m_cbus) |
	                    (d_date & m_date) | (d_mdi & m_mdi) | (d_genio & m_genio) |
	                    (simif_bad ? 32'd0 : (d_simif & m_simif)) |
	                    (euart_bad ? 32'd0 : (d_euart & m_euart)) | d_q;
	assign blk_busy = (s_mmc && b_mmc) || (s_lcd && b_lcd) || (s_cbus && b_cbus) ||
	                  (simif_claim && simif_busy) || !euart_ready;

	always_ff @(posedge clk) begin
		cnt   <= p_sel ? (cnt == 2'd3 ? 2'd3 : cnt + 2'd1) : 2'd0;
		rdy_q <= !init_busy && !(size_ok && blk_busy);
		dma_hit_q <= s_dma && size_ok;
		off_q     <= off;
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
