// SPDX-License-Identifier: GPL-2.0-or-later
//
// The N-Gage QD's memory system behind the CPU's Wishbone master and the DMA
// controller's (rtl/upp/upp_dma.sv), which wb_arb2 takes in turns:
//   upp_bus      the UPP_WD2 map (flash, EMIF registers, SDRAM, on-chip RAM,
//                the peripheral register bus)
//   nor_flash    CS0 (16 MB, K8S2815ETA) and CS1 (8 MB, K8S6415ETA)
//   ddram_flash  their arrays in DDR3 (the images the OSD loads), shared
//                with the image loader
//   sdram        the 16 MB SDRAM on the MiSTer SDRAM module
// The peripheral register bus leaves this module for the UPP peripheral
// models (rtl/upp/upp_periph.sv); the DMA master port comes back from them.
//
// Clocks and resets: one clock (clk_sys). sdram_init restarts the SDRAM's
// power-up (tie it to the power-on reset only: the guest's RAM survives a
// core reset). reset holds the bus, the flash chips and the DDR3 path; hold
// it while sdram_ready is low and while an image loads. flash_rst_n is the
// chips' RP# pin.
module ngage_mem #(
	parameter int ONCHIP_BYTES            = 64 << 10,
	parameter int CLK_HZ                  = 104_000_000,
	// the flash chips' busy times (nor_flash's defaults)
	parameter int FLASH_PROGRAM_CLKS      = CLK_HZ / 100_000,      // 10 us
	parameter int FLASH_SECTOR_ERASE_CLKS = CLK_HZ / 10 * 7,       // 0.7 s
	parameter int FLASH_ERASE_WINDOW_CLKS = CLK_HZ / 20_000        // 50 us
) (
	input  logic         clk,
	input  logic         reset,
	input  logic         sdram_init,
	output logic         sdram_ready,
	input  logic         flash_rst_n,

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

	// the DMA controller: Wishbone B3 classic single beats
	input  logic         dma_cyc,
	input  logic         dma_stb,
	input  logic         dma_we,
	input  logic [31:0]  dma_adr,
	input  logic [31:0]  dma_dat_i,
	input  logic [3:0]   dma_sel,
	output logic         dma_ack,
	output logic         dma_err,
	output logic [31:0]  dma_dat_o,

	output logic         p_sel,
	output logic         p_we,
	output logic [27:0]  p_addr,
	output logic [31:0]  p_wdata,
	output logic [3:0]   p_be,
	input  logic [31:0]  p_rdata,
	input  logic         p_wait,

	output logic [1:0]   flash_busy,   // RY/BY# of CS0, CS1 (inverted)
	output logic         unmapped,

	// the image loader's DDRAM side
	input  logic         ld_we,
	input  logic         ld_rd,
	input  logic [28:0]  ld_addr,
	input  logic [63:0]  ld_din,
	input  logic [7:0]   ld_be,
	output logic         ld_busy,
	output logic         ld_valid,
	output logic [63:0]  ld_data,

	// saving CS1 (rtl/mister/flash_save.sv): the 512-byte blocks CS1 writes
	// change, and block reads of CS1 (ddram_flash)
	output logic         save_mark,
	output logic [13:0]  save_mark_blk,
	output logic         c_blank,       // CS1's C: area starts erased (HLE 0x0C1F0104)
	input  logic         save_rd,
	input  logic [13:0]  save_blk,
	output logic         save_taken,
	output logic         save_valid,
	output logic [63:0]  save_data,

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
	input  logic [15:0]  sdram_dq_i
);

	// flash chips: bus side from upp_bus, array side to DDR3
	logic        fl0_req, fl0_we, fl0_ack, fl1_req, fl1_we, fl1_ack;
	logic [22:0] fl0_addr;
	logic [21:0] fl1_addr;
	logic [15:0] fl0_wdata, fl0_rdata, fl1_wdata, fl1_rdata;
	logic        fl0_array, fl0_lreq, fl0_ltaken, fl0_lrvalid, fl0_lrbeat;
	logic [22:2] fl0_laddr;
	logic [63:0] fl0_lrdata;
	logic        fl1_array, fl1_lreq, fl1_ltaken, fl1_lrvalid, fl1_lrbeat;
	logic [21:2] fl1_laddr;
	logic [63:0] fl1_lrdata;
	logic        m0_req, m0_we, m0_ack, m1_req, m1_we, m1_ack;
	logic [22:0] m0_addr;
	logic [21:0] m1_addr;
	logic [15:0] m0_wdata, m0_rdata, m1_wdata, m1_rdata;
	logic        m0_lreq, m0_ltaken, m0_lrvalid, m0_lrbeat;
	logic [22:2] m0_laddr;
	logic [63:0] m0_lrdata;
	logic        m1_lreq, m1_ltaken, m1_lrvalid, m1_lrbeat;
	logic [21:2] m1_laddr;
	logic [63:0] m1_lrdata;

	// SDRAM controller port
	logic         sdr_req, sdr_we, sdr_line, sdr_busy, sdr_rvalid;
	logic [24:2]  sdr_addr;
	logic [127:0] sdr_wdata;
	logic [15:0]  sdr_wbe;
	logic [1:0]   sdr_rword;
	logic [31:0]  sdr_rdata;

	// the masters onto the bus
	logic        b_cyc, b_stb, b_we, b_ack, b_err, b_idle;
	logic [31:0] b_adr, b_dat_w, b_dat_r;
	logic [3:0]  b_sel;
	logic [2:0]  b_cti;
	logic [1:0]  b_bte;

	wb_arb2 arb (
		.clk(clk),
		.reset(reset),
		.m0_cyc(wb_cyc), .m0_stb(wb_stb), .m0_we(wb_we), .m0_adr(wb_adr), .m0_dat(wb_dat_i),
		.m0_sel(wb_sel), .m0_cti(wb_cti), .m0_bte(wb_bte), .m0_ack(wb_ack), .m0_err(wb_err),
		.m1_cyc(dma_cyc), .m1_stb(dma_stb), .m1_we(dma_we), .m1_adr(dma_adr), .m1_dat(dma_dat_i),
		.m1_sel(dma_sel), .m1_ack(dma_ack), .m1_err(dma_err),
		.s_cyc(b_cyc), .s_stb(b_stb), .s_we(b_we), .s_adr(b_adr), .s_dat(b_dat_w), .s_sel(b_sel),
		.s_cti(b_cti), .s_bte(b_bte), .s_ack(b_ack), .s_err(b_err), .s_idle(b_idle)
	);

	assign wb_dat_o  = b_dat_r;
	assign dma_dat_o = b_dat_r;

	upp_bus #(.ONCHIP_BYTES(ONCHIP_BYTES)) bus (
		.clk(clk),
		.reset(reset),
		.wb_cyc(b_cyc), .wb_stb(b_stb), .wb_we(b_we), .wb_adr(b_adr), .wb_dat_i(b_dat_w),
		.wb_sel(b_sel), .wb_cti(b_cti), .wb_bte(b_bte), .wb_ack(b_ack), .wb_err(b_err), .wb_dat_o(b_dat_r),
		.fl0_req(fl0_req), .fl0_we(fl0_we), .fl0_addr(fl0_addr), .fl0_wdata(fl0_wdata), .fl0_rdata(fl0_rdata), .fl0_ack(fl0_ack),
		.fl0_array(fl0_array), .fl0_lreq(fl0_lreq), .fl0_laddr(fl0_laddr), .fl0_ltaken(fl0_ltaken),
		.fl0_lrvalid(fl0_lrvalid), .fl0_lrbeat(fl0_lrbeat), .fl0_lrdata(fl0_lrdata),
		.fl1_req(fl1_req), .fl1_we(fl1_we), .fl1_addr(fl1_addr), .fl1_wdata(fl1_wdata), .fl1_rdata(fl1_rdata), .fl1_ack(fl1_ack),
		.fl1_array(fl1_array), .fl1_lreq(fl1_lreq), .fl1_laddr(fl1_laddr), .fl1_ltaken(fl1_ltaken),
		.fl1_lrvalid(fl1_lrvalid), .fl1_lrbeat(fl1_lrbeat), .fl1_lrdata(fl1_lrdata),
		.sdr_req(sdr_req), .sdr_we(sdr_we), .sdr_line(sdr_line), .sdr_addr(sdr_addr), .sdr_wdata(sdr_wdata),
		.sdr_wbe(sdr_wbe), .sdr_busy(sdr_busy), .sdr_rvalid(sdr_rvalid), .sdr_rword(sdr_rword), .sdr_rdata(sdr_rdata),
		.p_sel(p_sel), .p_we(p_we), .p_addr(p_addr), .p_wdata(p_wdata), .p_be(p_be), .p_rdata(p_rdata), .p_wait(p_wait),
		.unmapped(unmapped),
		.idle(b_idle)
	);

	nor_flash #(.AW(23), .DEVICE_ID(16'h22F8), .CLK_HZ(CLK_HZ),
		.PROGRAM_CLKS(FLASH_PROGRAM_CLKS), .SECTOR_ERASE_CLKS(FLASH_SECTOR_ERASE_CLKS),
		.ERASE_WINDOW_CLKS(FLASH_ERASE_WINDOW_CLKS)) flash_cs0 (
		.c_blank(1'b0),
		.clk(clk),
		.reset(reset),
		.rst_n(flash_rst_n),
		.bus_req(fl0_req),
		.bus_we(fl0_we),
		.bus_addr(fl0_addr),
		.bus_wdata(fl0_wdata),
		.bus_rdata(fl0_rdata),
		.bus_ack(fl0_ack),
		.bus_array(fl0_array),
		.bus_lreq(fl0_lreq),
		.bus_laddr(fl0_laddr),
		.bus_ltaken(fl0_ltaken),
		.bus_lrvalid(fl0_lrvalid),
		.bus_lrbeat(fl0_lrbeat),
		.bus_lrdata(fl0_lrdata),
		.mem_req(m0_req),
		.mem_we(m0_we),
		.mem_addr(m0_addr),
		.mem_wdata(m0_wdata),
		.mem_rdata(m0_rdata),
		.mem_ack(m0_ack),
		.mem_lreq(m0_lreq),
		.mem_laddr(m0_laddr),
		.mem_ltaken(m0_ltaken),
		.mem_lrvalid(m0_lrvalid),
		.mem_lrbeat(m0_lrbeat),
		.mem_lrdata(m0_lrdata),
		.busy(flash_busy[0])
	);

	nor_flash #(.AW(22), .DEVICE_ID(16'h22FA), .CLK_HZ(CLK_HZ),
		.PROGRAM_CLKS(FLASH_PROGRAM_CLKS), .SECTOR_ERASE_CLKS(FLASH_SECTOR_ERASE_CLKS),
		.ERASE_WINDOW_CLKS(FLASH_ERASE_WINDOW_CLKS)) flash_cs1 (
		.c_blank(c_blank),
		.clk(clk),
		.reset(reset),
		.rst_n(flash_rst_n),
		.bus_req(fl1_req),
		.bus_we(fl1_we),
		.bus_addr(fl1_addr),
		.bus_wdata(fl1_wdata),
		.bus_rdata(fl1_rdata),
		.bus_ack(fl1_ack),
		.bus_array(fl1_array),
		.bus_lreq(fl1_lreq),
		.bus_laddr(fl1_laddr),
		.bus_ltaken(fl1_ltaken),
		.bus_lrvalid(fl1_lrvalid),
		.bus_lrbeat(fl1_lrbeat),
		.bus_lrdata(fl1_lrdata),
		.mem_req(m1_req),
		.mem_we(m1_we),
		.mem_addr(m1_addr),
		.mem_wdata(m1_wdata),
		.mem_rdata(m1_rdata),
		.mem_ack(m1_ack),
		.mem_lreq(m1_lreq),
		.mem_laddr(m1_laddr),
		.mem_ltaken(m1_ltaken),
		.mem_lrvalid(m1_lrvalid),
		.mem_lrbeat(m1_lrbeat),
		.mem_lrdata(m1_lrdata),
		.busy(flash_busy[1])
	);

	ddram_flash ddram_flash (
		.clk(clk),
		.reset(reset),
		.cs0_req(m0_req), .cs0_we(m0_we), .cs0_addr(m0_addr), .cs0_wdata(m0_wdata), .cs0_rdata(m0_rdata), .cs0_ack(m0_ack),
		.cs0_lreq(m0_lreq), .cs0_laddr(m0_laddr), .cs0_ltaken(m0_ltaken),
		.cs0_lrvalid(m0_lrvalid), .cs0_lrbeat(m0_lrbeat), .cs0_lrdata(m0_lrdata),
		.cs1_req(m1_req), .cs1_we(m1_we), .cs1_addr(m1_addr), .cs1_wdata(m1_wdata), .cs1_rdata(m1_rdata), .cs1_ack(m1_ack),
		.cs1_lreq(m1_lreq), .cs1_laddr(m1_laddr), .cs1_ltaken(m1_ltaken),
		.cs1_lrvalid(m1_lrvalid), .cs1_lrbeat(m1_lrbeat), .cs1_lrdata(m1_lrdata),
		.ld_we(ld_we), .ld_rd(ld_rd), .ld_valid(ld_valid), .ld_data(ld_data), .ld_addr(ld_addr), .ld_din(ld_din), .ld_be(ld_be), .ld_busy(ld_busy),
		.mark(save_mark), .mark_blk(save_mark_blk), .c_blank(c_blank), .bk_req(save_rd), .bk_blk(save_blk),
		.bk_taken(save_taken), .bk_valid(save_valid), .bk_data(save_data),
		.ddram_busy(ddram_busy), .ddram_burstcnt(ddram_burstcnt), .ddram_addr(ddram_addr), .ddram_dout(ddram_dout),
		.ddram_dout_ready(ddram_dout_ready), .ddram_rd(ddram_rd), .ddram_din(ddram_din), .ddram_be(ddram_be),
		.ddram_we(ddram_we)
	);

	sdram #(.CLK_HZ(CLK_HZ)) sdram (
		.clk(clk),
		.init(sdram_init),
		.ready(sdram_ready),
		.req(sdr_req),
		.busy(sdr_busy),
		.we(sdr_we),
		.line(sdr_line),
		.addr(sdr_addr),
		.wdata(sdr_wdata),
		.wbe(sdr_wbe),
		.rvalid(sdr_rvalid),
		.rword(sdr_rword),
		.rdata(sdr_rdata),
		.sdram_cke(sdram_cke),
		.sdram_cs_n(sdram_cs_n),
		.sdram_ras_n(sdram_ras_n),
		.sdram_cas_n(sdram_cas_n),
		.sdram_we_n(sdram_we_n),
		.sdram_ba(sdram_ba),
		.sdram_a(sdram_a),
		.sdram_dqml(sdram_dqml),
		.sdram_dqmh(sdram_dqmh),
		.sdram_dq_o(sdram_dq_o),
		.sdram_dq_oe(sdram_dq_oe),
		.sdram_dq_i(sdram_dq_i)
	);

endmodule
