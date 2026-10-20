//============================================================================
//
//  Nokia N-Gage QD (RH-29) core for MiSTer: the shell and the board.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================
//
// There is no CPU yet; wb_selftest stands in for it on the memory system's
// Wishbone port (a memory test, run from the OSD), and cpu_irq / cpu_fiq wait
// for it. What is here:
//  * the OSD: the two NOR flash images are loaded into DDR3 (CS0 at
//    0x31000000, CS1 at 0x32000000); an MMC image is mounted on hps_io's
//    SD slot 0; controls, rotation, aspect ratio, scandoubler, reset;
//  * the display module (lcd_panel) and its scan-out (video_out). Its 8080
//    bus and the key matrix lines belong to lcd_testgen until the UPP's LCD
//    interface first drives the bus (so with no CPU the test picture shows,
//    drawn by lcd_testgen with the keypad state as the matrix reports it),
//    and to the UPP from then on;
//  * the keypad matrix, fed from the joystick and keyboard; its power key
//    goes to the UEMK model (UEMK register 0x1F bit 1);
//  * the MMC card on the SD slot, on the UPP's MMC host (CLK/CMD/DAT0 with
//    pull-ups); it loads the CID/CSD sidecar when an image is mounted;
//  * the memory system (rtl/upp/ngage_mem.sv): the UPP_WD2 bus map, the two
//    NOR flash chips with their arrays in DDR3 (the loaded images), the
//    16 MB SDRAM on the MiSTer SDRAM module, the on-chip RAM and the EMIF
//    registers; the DMA controller is its second bus master;
//  * the UPP_WD2 peripherals (rtl/upp/upp_periph.sv) on the peripheral
//    register bus: interrupt controller, timers, DMA, MMC host, LCD
//    interface, keypad ports, CBUS with the UEMK model, storage for the rest;
//  * wb_selftest on the Wishbone port: with "Memory test" on, it tests the
//    SDRAM, the on-chip RAM, the EMIF block and the flash path in passes,
//    shows the result on the OSD after the first pass and after a failure,
//    and blinks the power LED (slow: passing, fast: failed).
// clk_sys is 104 MHz: 4 x 26 MHz, the phone's reference, so the MCU clock
// (104 MHz), the flash and timer clock (104/3) and the MMC clock (26/3)
// divide from it exactly.

module emu #(
	// the self-test's coverage (the simulation tests a part)
	parameter int SELFTEST_SDRAM_WORDS_LOG2  = 22,
	parameter int SELFTEST_ONCHIP_WORDS_LOG2 = 14,
	parameter int SELFTEST_FLASH_WORDS_LOG2  = 12
) (
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 0;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
assign AUDIO_MIX = 0;

assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire        rotated;
wire  [1:0] ar = status[122:121];

// the picture is 176x208 (11:13), or 208x176 turned
assign VIDEO_ARX = (ar == 2'd0) ? (rotated ? 13'd13 : 13'd11) : {11'd0, ar - 2'd1};
assign VIDEO_ARY = (ar == 2'd0) ? (rotated ? 13'd11 : 13'd13) : 13'd0;

`include "build_id.v"
localparam CONF_STR = {
	"NGage;;",
	"-;",
	"F1,BIN,Load flash CS0 (16 MB);",
	"F2,BIN,Load flash CS1 (8 MB);",
	"S1,BIN,Mount flash CS1 (save);",
	"S0,IMGBIN,Mount MMC card;",
	"-;",
	"O[2:1],Rotate,Off,Clockwise,Anticlockwise;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	"O[6],Memory test,Off,On;",
	"-;",
	"T[7],Save C: now;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"J,5,7,OK,Left soft,Right soft,Menu,Call,End,*,#,Clear,Edit,Power;",
	"jn,A,B,X,L,R,Start,Select;",
	"I,Memory test passed,Memory test FAILED,CS1 mounted: C: saves to it,CS1 save file must be 8 MB,CS1 read-only: no C: saves,C: saved;",
	"V,v",`BUILD_DATE
};

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
wire pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.locked(pll_locked)
);

///////////////////////   HPS   //////////////////////////////////

wire         forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire  [31:0] joystick_0, joystick_1;
wire  [21:0] gamma_bus;

wire         info_req;
wire   [7:0] info;

wire         ioctl_download;
wire  [15:0] ioctl_index;
wire         ioctl_wr;
wire  [26:0] ioctl_addr;
wire  [15:0] ioctl_dout;
wire         ioctl_wait;

wire   [1:0] img_mounted;
wire         img_readonly;
wire  [63:0] img_size;
wire  [31:0] sd_lba[2];
wire   [5:0] sd_blk_cnt[2];
wire   [1:0] sd_rd, sd_wr, sd_ack;
wire  [12:0] sd_buff_addr;
wire  [15:0] sd_buff_dout;
wire  [15:0] sd_buff_din[2];
wire         sd_buff_wr;

// SD slot 0: the MMC card; slot 1: the CS1 flash image as a save file
hps_io #(.CONF_STR(CONF_STR), .WIDE(1), .VDNUM(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),
	.status_in(128'd0),
	.status_set(1'b0),
	.info_req(info_req),
	.info(info),
	.new_vmode(1'b0),
	.video_rotated(1'b0),

	.ps2_kbd_clk_in(1'b1),
	.ps2_kbd_data_in(1'b1),
	.ps2_mouse_clk_in(1'b1),
	.ps2_mouse_data_in(1'b1),
	.ps2_kbd_led_status(3'd0),
	.ps2_kbd_led_use(3'd0),
	.joystick_0_rumble(16'd0),
	.joystick_1_rumble(16'd0),
	.joystick_2_rumble(16'd0),
	.joystick_3_rumble(16'd0),
	.joystick_4_rumble(16'd0),
	.joystick_5_rumble(16'd0),
	.ioctl_upload_req(1'b0),
	.ioctl_upload_index(8'd0),
	.ioctl_din(16'd0),

	.ps2_key(ps2_key),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr)
);

///////////////////////   RESET   ////////////////////////////////

// power-on reset of the whole core; the board is also held while a flash
// image loads
reg [1:0] por = 2'b11;
always @(posedge clk_sys) por <= {por[0], RESET | ~pll_locked};
wire sys_reset = por[1];
// (and while a mounted CS1 save image is copied in)
wire fs_loading;
wire reset = sys_reset | status[0] | buttons[1] | ioctl_download | fs_loading;

///////////////////////   MEMORY   ///////////////////////////////

// The flash images go to DDR3 through the loader port, which shares the
// DDRAM port with the flash chips' arrays (ddram_flash in ngage_mem): the
// ioctl loader's (F1/F2), or flash_save's while it copies a mounted CS1 save
// image in (S1). The port changes hands only between commands.
wire        ld_busy, ld_we, dl_we, fs_we;
wire  [7:0] ld_be, dl_be, fs_be;
wire [28:0] ld_addr, dl_addr, fs_addr;
wire [63:0] ld_din, dl_din, fs_din;
reg         ld_own = 1'b0;             // 1: flash_save

always @(posedge clk_sys) begin
	if (!ld_own && !dl_we && fs_we) ld_own <= 1'b1;
	else if (ld_own && !fs_we && dl_we) ld_own <= 1'b0;
end
assign ld_we   = ld_own ? fs_we   : dl_we;
assign ld_addr = ld_own ? fs_addr : dl_addr;
assign ld_din  = ld_own ? fs_din  : dl_din;
assign ld_be   = ld_own ? fs_be   : dl_be;

ddram_loader ddram_loader
(
	.clk(clk_sys),
	.reset(sys_reset),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.ddram_busy(ld_busy || ld_own),
	.ddram_burstcnt(),           // single writes
	.ddram_addr(dl_addr),
	.ddram_din(dl_din),
	.ddram_be(dl_be),
	.ddram_we(dl_we),
	.ddram_rd(),
	.loaded()                    // for the CPU: both images are in
);

assign DDRAM_CLK = clk_sys;

// The CPU's Wishbone port: the self-test until the CPU exists. The CPU
// (rtl/cpu/arm925t.sv, req/ack with a burst flag) connects as
//   wb_cyc = wb_stb = bus_req, wb_we = bus_we, wb_adr = bus_addr,
//   wb_sel = bus_be, wb_dat_w = bus_wdata, wb_cti = bus_burst ? 3'b010 : 3'b111,
//   wb_bte = 2'b00; bus_rdata = wb_dat_r, bus_ack = wb_ack, bus_err = wb_err.
// Flash reads return only the halfwords bus_be asks for (the others read 0):
// reading the other half would be a second status read, which toggles DQ6.
wire        wb_cyc, wb_stb, wb_we, wb_ack, wb_err;
wire [31:0] wb_adr, wb_dat_w, wb_dat_r;
wire  [3:0] wb_sel;
wire  [2:0] wb_cti;
wire  [1:0] wb_bte;

// the peripheral register bus
wire        p_sel, p_we, p_wait;
wire [27:0] p_addr;
wire [31:0] p_wdata, p_rdata;
wire  [3:0] p_be;

// the DMA controller's bus master
wire        dma_cyc, dma_stb, dma_we, dma_ack, dma_err;
wire [31:0] dma_adr, dma_dat_w, dma_dat_r;
wire  [3:0] dma_sel;

wire        sdram_ready;
wire [15:0] sdram_dq_o, sdram_dq_oe;
wire        mem_reset = reset | ~sdram_ready;

ngage_mem ngage_mem
(
	.clk(clk_sys),
	.reset(mem_reset),
	.sdram_init(sys_reset),
	.sdram_ready(sdram_ready),
	.flash_rst_n(1'b1),

	.wb_cyc(wb_cyc),
	.wb_stb(wb_stb),
	.wb_we(wb_we),
	.wb_adr(wb_adr),
	.wb_dat_i(wb_dat_w),
	.wb_sel(wb_sel),
	.wb_cti(wb_cti),
	.wb_bte(wb_bte),
	.wb_ack(wb_ack),
	.wb_err(wb_err),
	.wb_dat_o(wb_dat_r),

	.dma_cyc(dma_cyc),
	.dma_stb(dma_stb),
	.dma_we(dma_we),
	.dma_adr(dma_adr),
	.dma_dat_i(dma_dat_w),
	.dma_sel(dma_sel),
	.dma_ack(dma_ack),
	.dma_err(dma_err),
	.dma_dat_o(dma_dat_r),

	.p_sel(p_sel),
	.p_we(p_we),
	.p_addr(p_addr),
	.p_wdata(p_wdata),
	.p_be(p_be),
	.p_rdata(p_rdata),
	.p_wait(p_wait),

	.flash_busy(),
	.unmapped(),

	.ld_we(ld_we),
	.ld_addr(ld_addr),
	.ld_din(ld_din),
	.ld_be(ld_be),
	.ld_busy(ld_busy),

	.save_mark(save_mark),
	.save_mark_blk(save_mark_blk),
	.save_rd(save_rd),
	.save_blk(save_blk),
	.save_taken(save_taken),
	.save_valid(save_valid),
	.save_data(save_data),

	.ddram_busy(DDRAM_BUSY),
	.ddram_burstcnt(DDRAM_BURSTCNT),
	.ddram_addr(DDRAM_ADDR),
	.ddram_dout(DDRAM_DOUT),
	.ddram_dout_ready(DDRAM_DOUT_READY),
	.ddram_rd(DDRAM_RD),
	.ddram_din(DDRAM_DIN),
	.ddram_be(DDRAM_BE),
	.ddram_we(DDRAM_WE),

	.sdram_cke(SDRAM_CKE),
	.sdram_cs_n(SDRAM_nCS),
	.sdram_ras_n(SDRAM_nRAS),
	.sdram_cas_n(SDRAM_nCAS),
	.sdram_we_n(SDRAM_nWE),
	.sdram_ba(SDRAM_BA),
	.sdram_a(SDRAM_A),
	.sdram_dqml(SDRAM_DQML),
	.sdram_dqmh(SDRAM_DQMH),
	.sdram_dq_o(sdram_dq_o),
	.sdram_dq_oe(sdram_dq_oe),
	.sdram_dq_i(SDRAM_DQ)
);

genvar dq_i;
generate
	for (dq_i = 0; dq_i < 16; dq_i++) begin : g_sdram_dq
		assign SDRAM_DQ[dq_i] = sdram_dq_oe[dq_i] ? sdram_dq_o[dq_i] : 1'bZ;
	end
endgenerate

///////////////////////   CS1 SAVE   ///////////////////////////

// The CS1 image mounted on SD slot 1 ("Mount flash CS1 (save)") is copied
// into DDR3, and the 512-byte blocks the firmware changes in it (the C:
// drive) are written back to the file: rtl/mister/flash_save.sv. "Save C:
// now" writes back at once; otherwise 100 ms after the last change.
wire        save_mark, save_rd, save_taken, save_valid;
wire [13:0] save_mark_blk, save_blk;
wire [63:0] save_data;
wire        fs_active, fs_saved;
wire  [1:0] fs_note;
reg   [1:0] dl_cs1 = 2'b00;            // an ioctl load of CS1 starts: the file is detached

always @(posedge clk_sys) dl_cs1 <= {dl_cs1[0], ioctl_download && ioctl_index[5:0] == 6'd2};

flash_save flash_save
(
	.clk(clk_sys),
	.reset(sys_reset),
	.img_mounted(img_mounted[1]),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba[1]),
	.sd_blk_cnt(sd_blk_cnt[1]),
	.sd_rd(sd_rd[1]),
	.sd_wr(sd_wr[1]),
	.sd_ack(sd_ack[1]),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din[1]),
	.sd_buff_wr(sd_buff_wr),
	.ld_we(fs_we),
	.ld_addr(fs_addr),
	.ld_din(fs_din),
	.ld_be(fs_be),
	.ld_busy(ld_busy || !ld_own),
	.mark(save_mark),
	.mark_blk(save_mark_blk),
	.bk_req(save_rd),
	.bk_blk(save_blk),
	.bk_taken(save_taken),
	.bk_valid(save_valid),
	.bk_data(save_data),
	.detach(dl_cs1 == 2'b01),
	.save_now(status[7]),
	.loading(fs_loading),
	.saving_on(),
	.unsaved(),
	.active(fs_active),
	.note(fs_note),
	.saved(fs_saved)
);

sdram_clkout sdram_clkout
(
	.clk(clk_sys),
	.sdram_clk(SDRAM_CLK)
);

///////////////////////   UPP PERIPHERALS   ////////////////////

// interrupts for the CPU (arm925t's irq / fiq, active high)
wire        cpu_irq, cpu_fiq;

wire        upp_lcd_csx, upp_lcd_dcx, upp_lcd_wrx, upp_lcd_rdx, upp_lcd_resx, upp_lcd_d_oe, upp_lcd_on;
wire  [7:0] upp_lcd_d;
wire  [7:0] panel_d;
wire        mmc_clk, mmc_cmd_o, mmc_cmd_oe, mmc_dat_o, mmc_dat_oe;
wire        card_cmd_o, card_cmd_oe, card_dat_o, card_dat_oe;
wire  [4:0] upp_col_oe, upp_col_out, kp_col_in;
wire  [5:0] upp_row_oe, upp_row_out, kp_row_in;
wire        pwronx;                  // the power key, low while held (keypad_matrix)

// the MMC lines, pulled up, driven by the host and the card
wire mmc_cmd = (mmc_cmd_oe ? mmc_cmd_o : 1'b1) & (card_cmd_oe ? card_cmd_o : 1'b1);
wire mmc_dat = (mmc_dat_oe ? mmc_dat_o : 1'b1) & (card_dat_oe ? card_dat_o : 1'b1);

upp_periph upp_periph
(
	.clk(clk_sys),
	.reset(mem_reset),
	.p_sel(p_sel),
	.p_we(p_we),
	.p_addr(p_addr),
	.p_wdata(p_wdata),
	.p_be(p_be),
	.p_rdata(p_rdata),
	.p_wait(p_wait),
	.dma_cyc(dma_cyc),
	.dma_stb(dma_stb),
	.dma_we(dma_we),
	.dma_adr(dma_adr),
	.dma_dat_o(dma_dat_w),
	.dma_sel(dma_sel),
	.dma_ack(dma_ack),
	.dma_err(dma_err),
	.dma_dat_i(dma_dat_r),
	.irq(cpu_irq),
	.fiq(cpu_fiq),
	.lcd_csx(upp_lcd_csx),
	.lcd_dcx(upp_lcd_dcx),
	.lcd_wrx(upp_lcd_wrx),
	.lcd_rdx(upp_lcd_rdx),
	.lcd_resx(upp_lcd_resx),
	.lcd_d_o(upp_lcd_d),
	.lcd_d_oe(upp_lcd_d_oe),
	.lcd_d_i(panel_d),
	.lcd_active(upp_lcd_on),
	.mmc_clk(mmc_clk),
	.mmc_cmd_o(mmc_cmd_o),
	.mmc_cmd_oe(mmc_cmd_oe),
	.mmc_cmd_i(mmc_cmd),
	.mmc_dat_o(mmc_dat_o),
	.mmc_dat_oe(mmc_dat_oe),
	.mmc_dat_i(mmc_dat),
	.kp_col_oe(upp_col_oe),
	.kp_col_out(upp_col_out),
	.kp_row_oe(upp_row_oe),
	.kp_row_out(upp_row_out),
	.kp_col_in(kp_col_in),
	.kp_row_in(kp_row_in),
	.power_key(~pwronx),
	.sti_we(),
	.sti_addr(),
	.sti_be(),
	.sti_data()
);

wire [15:0] test_errors;
wire        test_pass_done;
wire        test_on = status[6];

wb_selftest #(
	.SDRAM_WORDS_LOG2(SELFTEST_SDRAM_WORDS_LOG2),
	.ONCHIP_WORDS_LOG2(SELFTEST_ONCHIP_WORDS_LOG2),
	.FLASH_WORDS_LOG2(SELFTEST_FLASH_WORDS_LOG2)
) wb_selftest (
	.clk(clk_sys),
	.reset(mem_reset),
	.enable(test_on),
	.wb_cyc(wb_cyc),
	.wb_stb(wb_stb),
	.wb_we(wb_we),
	.wb_adr(wb_adr),
	.wb_dat(wb_dat_w),
	.wb_sel(wb_sel),
	.wb_cti(wb_cti),
	.wb_bte(wb_bte),
	.wb_ack(wb_ack),
	.wb_err(wb_err),
	.wb_dat_i(wb_dat_r),
	.passes(),
	.errors(test_errors),
	.err_adr(),
	.err_got(),
	.err_want(),
	.pass_done(test_pass_done)
);

// OSD message after the first pass, and after a pass that found new errors
reg  [15:0] test_reported = 0;
reg         test_first = 1;
reg   [7:0] info_q = 0;
reg         info_req_q = 0;
always @(posedge clk_sys) begin
	info_req_q <= 1'b0;
	// the CS1 save's messages: 3 mounted, 4 not 8 MB, 5 read-only, 6 saved
	if (fs_note != 2'd0 || fs_saved) begin
		info_q     <= fs_saved ? 8'd6 : 8'd2 + {6'd0, fs_note};
		info_req_q <= 1'b1;
	end else if (test_pass_done && (test_first || test_errors != test_reported)) begin
		info_q        <= (test_errors == 16'd0) ? 8'd1 : 8'd2;
		info_req_q    <= 1'b1;
		test_first    <= 1'b0;
		test_reported <= test_errors;
	end
	if (!test_on) begin
		test_first    <= 1'b1;
		test_reported <= 16'd0;
	end
end
assign info_req = info_req_q;
assign info     = info_q;

// power LED while the test runs: slow blink passing, fast blink failed
reg [24:0] blink = 0;
always @(posedge clk_sys) blink <= blink + 1'd1;
assign LED_POWER = {test_on, test_on & ((test_errors != 16'd0) ? blink[21] : blink[24])};

///////////////////////   MMC CARD   /////////////////////////////

wire mmc_active;

// on the UPP's MMC host
mmc_card mmc_card
(
	.clk(clk_sys),
	.reset(sys_reset),
	.mmc_clk(mmc_clk),
	.cmd_i(mmc_cmd),
	.cmd_o(card_cmd_o),
	.cmd_oe(card_cmd_oe),
	.dat_i(mmc_dat),
	.dat_o(card_dat_o),
	.dat_oe(card_dat_oe),
	.present(),
	.write_protected(),
	.active(mmc_active),
	.img_mounted(img_mounted[0]),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba[0]),
	.sd_blk_cnt(sd_blk_cnt[0]),
	.sd_rd(sd_rd[0]),
	.sd_wr(sd_wr[0]),
	.sd_ack(sd_ack[0]),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din[0]),
	.sd_buff_wr(sd_buff_wr & sd_ack[0])      // the buffer is shared by both slots
);

assign LED_DISK = {1'b0, mmc_active | fs_active};

///////////////////////   KEYS   /////////////////////////////////

wire [ngage_keys::NKEYS-1:0] keys;
wire       power_key;
wire [4:0] kp_col_oe, kp_col_out, tg_col_oe, tg_col_out;
wire [5:0] kp_row_oe, kp_row_out;

// the matrix lines: lcd_testgen's until the UPP drives the display
assign kp_col_oe  = upp_lcd_on ? upp_col_oe  : tg_col_oe;
assign kp_col_out = upp_lcd_on ? upp_col_out : tg_col_out;
assign kp_row_oe  = upp_lcd_on ? upp_row_oe  : 6'd0;
assign kp_row_out = upp_lcd_on ? upp_row_out : 6'd0;

ngage_input ngage_input
(
	.clk(clk_sys),
	.reset(sys_reset),
	.joy0(joystick_0),
	.joy1(joystick_1),
	.ps2_key(ps2_key),
	.keys(keys),
	.power(power_key)
);

keypad_matrix keypad_matrix
(
	.clk(clk_sys),
	.keys(keys),
	.power(power_key),
	.col_oe(kp_col_oe),
	.col_out(kp_col_out),
	.row_oe(kp_row_oe),
	.row_out(kp_row_out),
	.col_in(kp_col_in),
	.row_in(kp_row_in),
	.pwronx(pwronx)
);

///////////////////////   DISPLAY   //////////////////////////////

wire       tg_csx, tg_dcx, tg_wrx, tg_rdx, tg_resx;
wire [7:0] tg_d;

lcd_testgen lcd_testgen
(
	.clk(clk_sys),
	.reset(reset),
	.csx(tg_csx),
	.dcx(tg_dcx),
	.wrx(tg_wrx),
	.rdx(tg_rdx),
	.resx(tg_resx),
	.d(tg_d),
	.col_oe(tg_col_oe),
	.col_out(tg_col_out),
	.row_in(kp_row_in),
	.pwronx(pwronx)
);

// the panel's bus: lcd_testgen's until the UPP's LCD interface first drives it
wire       lcd_csx  = upp_lcd_on ? upp_lcd_csx  : tg_csx;
wire       lcd_dcx  = upp_lcd_on ? upp_lcd_dcx  : tg_dcx;
wire       lcd_wrx  = upp_lcd_on ? upp_lcd_wrx  : tg_wrx;
wire       lcd_rdx  = upp_lcd_on ? upp_lcd_rdx  : tg_rdx;
wire       lcd_resx = upp_lcd_on ? upp_lcd_resx : tg_resx;
wire       panel_d_oe;
wire [7:0] lcd_d    = !upp_lcd_on ? tg_d : upp_lcd_d_oe ? upp_lcd_d : panel_d_oe ? panel_d : 8'hFF;

wire        scan_en;
wire  [7:0] scan_x, scan_y;
wire [15:0] scan_rgb;
wire [15:0] panel_rgb;
wire        lcd_on;

lcd_panel lcd_panel
(
	.clk(clk_sys),
	.reset(sys_reset),
	.csx(lcd_csx),
	.dcx(lcd_dcx),
	.wrx(lcd_wrx),
	.rdx(lcd_rdx),
	.resx(lcd_resx),
	.d_i(lcd_d),
	.d_o(panel_d),
	.d_oe(panel_d_oe),
	.te(),
	.te_ext_sel(1'b0),
	.te_ext(1'b0),
	.scan_en(scan_en),
	.scan_x(scan_x),
	.scan_y(scan_y),
	.scan_rgb(panel_rgb),
	.display_on(lcd_on)
);

// Memory-test status square in the top-left 12x12 panel pixels, so the
// result can be read from a screenshot (MiSTer screenshots leave out the
// OSD): blue = test off, yellow = running before the first pass ends,
// green = passes without errors, magenta = errors seen. scan_x/scan_y hold
// for a whole pixel, so the substitution lines up exactly.
reg test_any_pass = 0;
always @(posedge clk_sys) begin
	if (!test_on) test_any_pass <= 1'b0;
	else if (test_pass_done) test_any_pass <= 1'b1;
end
wire [15:0] test_rgb = !test_on                ? 16'h001F :
                       (test_errors != 16'd0)  ? 16'hF81F :
                       test_any_pass           ? 16'h07E0 : 16'hFFE0;
assign scan_rgb = (scan_x < 8'd12 && scan_y < 8'd12) ? test_rgb : panel_rgb;

wire       ce_pix;
wire       hs, vs, hblank, vblank;
wire [7:0] r, g, b;

video_out video_out
(
	.clk(clk_sys),
	.reset(sys_reset),
	.rotate(status[2:1]),
	.scan_en(scan_en),
	.scan_x(scan_x),
	.scan_y(scan_y),
	.scan_rgb(scan_rgb),
	.ce_pix(ce_pix),
	.hsync(hs),
	.vsync(vs),
	.hblank(hblank),
	.vblank(vblank),
	.de(),
	.red(r),
	.green(g),
	.blue(b),
	.rotated(rotated)
);

wire [2:0] scale = status[5:3];
wire [1:0] sl = (scale != 3'd0) ? 2'(scale - 3'd1) : 2'd0;

assign CLK_VIDEO = clk_sys;
assign VGA_SL = sl;

video_mixer #(.LINE_LENGTH(256), .GAMMA(1)) video_mixer
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.ce_pix(ce_pix),
	.scandoubler((scale != 3'd0) || forced_scandoubler),
	.hq2x(scale == 3'd1),
	.gamma_bus(gamma_bus),
	.R(r),
	.G(g),
	.B(b),
	.HSync(hs),
	.VSync(vs),
	.HBlank(hblank),
	.VBlank(vblank),
	.HDMI_FREEZE(HDMI_FREEZE),
	.freeze_sync(),
	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_VS(VGA_VS),
	.VGA_HS(VGA_HS),
	.VGA_DE(VGA_DE)
);

// on while a flash image loads, and while the panel is lit
assign LED_USER = ioctl_download | lcd_on;

endmodule
