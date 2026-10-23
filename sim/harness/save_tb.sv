// SPDX-License-Identifier: GPL-2.0-or-later
// Bench top for sim/harness/save_main.cpp: the memory system (ngage_mem) with
// flash_save on its loader and save ports, wired as in NGage.sv (the memory
// system is held in reset while a mounted image loads). The C++ side plays
// the CPU's Wishbone master, the SDRAM chip, the DDRAM port and hps_io's SD
// slot for the save file.
module save_tb #(
	parameter int QUIET_CLKS = 80000,
	parameter int MAX_CLKS   = 300000
) (
	input  logic         clk,
	input  logic         por,          // power-on reset (flash_save)
	input  logic         reset,        // core reset
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

	input  logic         detach,
	input  logic         save_now,
	output logic         loading,
	output logic         saving_on,
	output logic         unsaved,
	output logic         active,
	output logic [1:0]   note,
	output logic         saved,

	// what the bench watches
	output logic         mark,
	output logic [13:0]  mark_blk,
	output logic         bk_taken,
	output logic [13:0]  bk_blk
);

	logic        ld_we, ld_busy, bk_req, bk_valid;
	logic [28:0] ld_addr;
	logic [63:0] ld_din, bk_data;
	logic [7:0]  ld_be;

	ngage_mem #(
		.FLASH_PROGRAM_CLKS(40), .FLASH_SECTOR_ERASE_CLKS(3000), .FLASH_ERASE_WINDOW_CLKS(200)
	) mem (
		.clk(clk),
		.reset(reset || loading || !sdram_ready),
		.sdram_init(sdram_init),
		.sdram_ready(sdram_ready),
		.flash_rst_n(1'b1),
		.wb_cyc(wb_cyc), .wb_stb(wb_stb), .wb_we(wb_we), .wb_adr(wb_adr), .wb_dat_i(wb_dat_i),
		.wb_sel(wb_sel), .wb_cti(wb_cti), .wb_bte(wb_bte), .wb_ack(wb_ack), .wb_err(wb_err), .wb_dat_o(wb_dat_o),
		.st_on(1'b0), .st_on_nxt(1'b0), .st_cyc(1'b0), .st_stb(1'b0), .st_we(1'b0), .st_adr(32'd0),
		.st_dat_i(32'd0), .st_sel(4'd0), .st_cti(3'd0), .st_bte(2'd0),
		.dma_cyc(1'b0), .dma_stb(1'b0), .dma_we(1'b0), .dma_adr(32'd0), .dma_dat_i(32'd0), .dma_sel(4'd0),
		.dma_ack(), .dma_err(), .dma_dat_o(),
		.p_sel(), .p_we(), .p_addr(), .p_wdata(), .p_be(), .p_rdata(32'd0), .p_wait(1'b0),
		.flash_busy(), .unmapped(),
		.ld_we(ld_we), .ld_addr(ld_addr), .ld_din(ld_din), .ld_be(ld_be), .ld_busy(ld_busy),
		.save_mark(mark), .save_mark_blk(mark_blk), .save_rd(bk_req), .save_blk(bk_blk),
		.save_taken(bk_taken), .save_valid(bk_valid), .save_data(bk_data),
		.ddram_busy(ddram_busy), .ddram_burstcnt(ddram_burstcnt), .ddram_addr(ddram_addr), .ddram_dout(ddram_dout),
		.ddram_dout_ready(ddram_dout_ready), .ddram_rd(ddram_rd), .ddram_din(ddram_din), .ddram_be(ddram_be),
		.ddram_we(ddram_we),
		.sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n),
		.sdram_we_n(sdram_we_n), .sdram_ba(sdram_ba), .sdram_a(sdram_a), .sdram_dqml(sdram_dqml),
		.sdram_dqmh(sdram_dqmh), .sdram_dq_o(sdram_dq_o), .sdram_dq_oe(sdram_dq_oe), .sdram_dq_i(sdram_dq_i)
	);

	flash_save #(.QUIET_CLKS(QUIET_CLKS), .MAX_CLKS(MAX_CLKS)) save (
		.clk(clk),
		.reset(por),
		.img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
		.sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
		.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr),
		.ld_we(ld_we), .ld_addr(ld_addr), .ld_din(ld_din), .ld_be(ld_be), .ld_busy(ld_busy),
		.mark(mark), .mark_blk(mark_blk), .bk_req(bk_req), .bk_blk(bk_blk), .bk_taken(bk_taken),
		.bk_valid(bk_valid), .bk_data(bk_data),
		.detach(detach), .save_now(save_now),
		.loading(loading), .saving_on(saving_on), .unsaved(unsaved), .present(), .active(active), .note(note), .saved(saved)
	);

endmodule
