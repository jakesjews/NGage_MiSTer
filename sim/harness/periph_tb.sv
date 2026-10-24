// SPDX-License-Identifier: GPL-2.0-or-later
// Bench top for sim/harness/periph_main.cpp: the memory system (ngage_mem:
// upp_bus behind the CPU / DMA arbiter, SDRAM, the flash chips and their DDR3
// path) with the UPP peripherals (upp_periph) on its register bus and their
// DMA master on its second port, and the board devices they drive: the
// display module (lcd_panel), the MMC card (mmc_card) and the key matrix
// (keypad_matrix), and the wall clock (rtc_wall, its second RTC_CLK_HZ
// clocks long here), wired as in NGage.sv. The C++ side plays the CPU's
// Wishbone master, the SDRAM chip, the DDRAM port and hps_io's SD interface,
// and watches the register bus.
module periph_tb #(
	parameter int MMC_DIV            = 4,
	parameter int MMC_TIMEOUT_LOG2   = 16,
	parameter int POWER_ON_HOLD_CLKS = 20000,
	parameter int RTC_CLK_HZ         = 20000
) (
	input  logic         clk,
	input  logic         reset,
	input  logic         sdram_init,
	output logic         sdram_ready,

	input  logic         wb_cyc,
	input  logic         wb_stb,
	input  logic         wb_we,
	input  logic [31:0]  wb_adr,
	input  logic [31:0]  wb_dat_i,
	input  logic [3:0]   wb_sel,
	input  logic [2:0]   wb_cti,
	input  logic [1:0]   wb_bte,
	output logic         wb_ack,
	output logic         wb_err,
	output logic [31:0]  wb_dat_o,

	input  logic         ddram_busy,
	output logic [7:0]   ddram_burstcnt,
	output logic [28:0]  ddram_addr,
	input  logic [63:0]  ddram_dout,
	input  logic         ddram_dout_ready,
	output logic         ddram_rd,
	output logic [63:0]  ddram_din,
	output logic [7:0]   ddram_be,
	output logic         ddram_we,

	output logic         sdram_cke,
	output logic         sdram_cs_n,
	output logic         sdram_ras_n,
	output logic         sdram_cas_n,
	output logic         sdram_we_n,
	output logic [1:0]   sdram_ba,
	output logic [12:0]  sdram_a,
	output logic         sdram_dqml,
	output logic         sdram_dqmh,
	output logic [15:0]  sdram_dq_o,
	output logic [15:0]  sdram_dq_oe,
	input  logic [15:0]  sdram_dq_i,

	input  logic         img_mounted,
	input  logic         img_readonly,
	input  logic [63:0]  img_size,
	output logic [31:0]  sd_lba,
	output logic [5:0]   sd_blk_cnt,
	output logic         sd_rd,
	output logic         sd_wr,
	input  logic         sd_ack,
	input  logic [12:0]  sd_buff_addr,
	input  logic [15:0]  sd_buff_dout,
	output logic [15:0]  sd_buff_din,
	input  logic         sd_buff_wr,
	output logic         card_present,

	input  logic [29:0]  keys,
	input  logic         power,
	input  logic [64:0]  rtc,            // hps_io's RTC output

	input  logic         scan_en,
	input  logic [7:0]   scan_x,
	input  logic [7:0]   scan_y,
	output logic [15:0]  scan_rgb,

	// what the bench watches
	output logic         irq,
	output logic         fiq,
	output logic         p_sel,
	output logic         p_we,
	output logic         p_wait,
	output logic [27:0]  p_addr,
	output logic [3:0]   p_be,
	output logic [31:0]  p_wdata,
	output logic         dma_cyc,
	output logic         sti_we,
	output logic [3:0]   sti_be,
	output logic [31:0]  sti_data,
	output logic         lcd_wrx,
	output logic         mmc_clk,
	output logic         mmc_cmd,
	output logic         mmc_dat,
	output logic [15:0]  audio_l,
	output logic [15:0]  audio_r
);

	logic [31:0] p_rdata;
	logic        dma_stb, dma_we, dma_ack, dma_err;
	logic [31:0] dma_adr, dma_dat_w, dma_dat_r;
	logic [3:0]  dma_sel;

	ngage_mem #(
		.FLASH_PROGRAM_CLKS(40), .FLASH_SECTOR_ERASE_CLKS(3000), .FLASH_ERASE_WINDOW_CLKS(200)
	) mem (
		.clk(clk),
		.reset(reset || !sdram_ready),
		.sdram_init(sdram_init),
		.sdram_ready(sdram_ready),
		.flash_rst_n(1'b1),
		.wb_cyc(wb_cyc), .wb_stb(wb_stb), .wb_we(wb_we), .wb_adr(wb_adr), .wb_dat_i(wb_dat_i),
		.wb_sel(wb_sel), .wb_cti(wb_cti), .wb_bte(wb_bte), .wb_ack(wb_ack), .wb_err(wb_err), .wb_dat_o(wb_dat_o),
		.wb_no_late_error(),
		.dma_cyc(dma_cyc), .dma_stb(dma_stb), .dma_we(dma_we), .dma_adr(dma_adr), .dma_dat_i(dma_dat_w),
		.dma_sel(dma_sel), .dma_ack(dma_ack), .dma_err(dma_err), .dma_dat_o(dma_dat_r),
		.p_sel(p_sel), .p_we(p_we), .p_addr(p_addr), .p_wdata(p_wdata), .p_be(p_be), .p_rdata(p_rdata), .p_wait(p_wait),
		.flash_busy(), .unmapped(),
		.ld_rd(1'b0), .ld_valid(), .ld_data(), .ld_we(1'b0), .ld_addr(29'd0), .ld_din(64'd0), .ld_be(8'd0), .ld_busy(),
		.save_mark(), .save_mark_blk(), .save_rd(1'b0), .save_blk(14'd0), .save_taken(), .save_valid(), .save_data(),
		.ddram_busy(ddram_busy), .ddram_burstcnt(ddram_burstcnt), .ddram_addr(ddram_addr), .ddram_dout(ddram_dout),
		.ddram_dout_ready(ddram_dout_ready), .ddram_rd(ddram_rd), .ddram_din(ddram_din), .ddram_be(ddram_be),
		.ddram_we(ddram_we),
		.sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n),
		.sdram_we_n(sdram_we_n), .sdram_ba(sdram_ba), .sdram_a(sdram_a), .sdram_dqml(sdram_dqml),
		.sdram_dqmh(sdram_dqmh), .sdram_dq_o(sdram_dq_o), .sdram_dq_oe(sdram_dq_oe), .sdram_dq_i(sdram_dq_i)
	);

	logic       lcd_csx, lcd_dcx, lcd_rdx, lcd_resx, lcd_d_oe, panel_d_oe;
	logic [7:0] lcd_d_o, panel_d;
	logic       mmc_cmd_o, mmc_cmd_oe, mmc_dat_o, mmc_dat_oe;
	logic       card_cmd_o, card_cmd_oe, card_dat_o, card_dat_oe;
	logic [31:0] dbg_src0;
	logic [4:0] col_oe, col_out, col_in;
	logic [5:0] row_oe, row_out, row_in;
	logic       pwronx;
	logic        rtc_valid;
	logic [5:0]  rtc_sec, rtc_min;
	logic [4:0]  rtc_hour;
	logic [7:0]  rtc_days;
	logic [31:0] rtc_date;

	rtc_wall #(.CLK_HZ(RTC_CLK_HZ)) wall (
		.clk(clk), .rtc(rtc), .valid(rtc_valid), .sec(rtc_sec), .min(rtc_min), .hour(rtc_hour),
		.date(rtc_date), .days(rtc_days)
	);

	assign mmc_cmd = (mmc_cmd_oe ? mmc_cmd_o : 1'b1) & (card_cmd_oe ? card_cmd_o : 1'b1);
	assign mmc_dat = (mmc_dat_oe ? mmc_dat_o : 1'b1) & (card_dat_oe ? card_dat_o : 1'b1);

	upp_periph #(
		.MMC_DIV(MMC_DIV), .MMC_TIMEOUT_LOG2(MMC_TIMEOUT_LOG2), .POWER_ON_HOLD_CLKS(POWER_ON_HOLD_CLKS)
	) periph (
		.clk(clk),
		.reset(reset || !sdram_ready),
		.p_sel(p_sel), .p_we(p_we), .p_addr(p_addr), .p_wdata(p_wdata), .p_be(p_be), .p_rdata(p_rdata), .p_wait(p_wait),
		.dma_cyc(dma_cyc), .dma_stb(dma_stb), .dma_we(dma_we), .dma_adr(dma_adr), .dma_dat_o(dma_dat_w),
		.dma_sel(dma_sel), .dma_ack(dma_ack), .dma_err(dma_err), .dma_dat_i(dma_dat_r),
		.irq(irq), .fiq(fiq), .dbg_src0(dbg_src0),
		.lcd_csx(lcd_csx), .lcd_dcx(lcd_dcx), .lcd_wrx(lcd_wrx), .lcd_rdx(lcd_rdx), .lcd_resx(lcd_resx),
		.lcd_d_o(lcd_d_o), .lcd_d_oe(lcd_d_oe), .lcd_d_i(panel_d), .lcd_active(),
		.mmc_clk(mmc_clk), .mmc_cmd_o(mmc_cmd_o), .mmc_cmd_oe(mmc_cmd_oe), .mmc_cmd_i(mmc_cmd),
		.mmc_dat_o(mmc_dat_o), .mmc_dat_oe(mmc_dat_oe), .mmc_dat_i(mmc_dat),
		.kp_col_oe(col_oe), .kp_col_out(col_out), .kp_row_oe(row_oe), .kp_row_out(row_out),
		.kp_col_in(col_in), .kp_row_in(row_in), .power_key(!pwronx),
		.rtc_valid(rtc_valid), .rtc_sec(rtc_sec), .rtc_min(rtc_min), .rtc_hour(rtc_hour), .rtc_days(rtc_days),
		.rtc_date(rtc_date), .c_blank(1'b0), .audio_l(audio_l), .audio_r(audio_r),
		.sti_we(sti_we), .sti_addr(), .sti_be(sti_be), .sti_data(sti_data)
	);

	lcd_panel #(.CLK_HZ(104_000_000)) panel (
		.clk(clk),
		.reset(reset),
		.csx(lcd_csx), .dcx(lcd_dcx), .wrx(lcd_wrx), .rdx(lcd_rdx), .resx(lcd_resx),
		.d_i(lcd_d_oe ? lcd_d_o : panel_d_oe ? panel_d : 8'hFF),
		.d_o(panel_d), .d_oe(panel_d_oe), .te(),
		.te_ext_sel(1'b0), .te_ext(1'b0),
		.scan_en(scan_en), .scan_x(scan_x), .scan_y(scan_y), .scan_rgb(scan_rgb),
		.display_on()
	);

	mmc_card card (
		.clk(clk),
		.reset(reset),
		.mmc_clk(mmc_clk),
		.cmd_i(mmc_cmd), .cmd_o(card_cmd_o), .cmd_oe(card_cmd_oe),
		.dat_i(mmc_dat), .dat_o(card_dat_o), .dat_oe(card_dat_oe),
		.stop_queued(!dbg_src0[23]),
		.present(card_present), .write_protected(), .active(),
		.img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
		.sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
		.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr)
	);

	keypad_matrix kp (
		.clk(clk),
		.keys(keys),
		.power(power),
		.col_oe(col_oe), .col_out(col_out), .row_oe(row_oe), .row_out(row_out),
		.col_in(col_in), .row_in(row_in),
		.pwronx(pwronx)
	);

endmodule
