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
// The MiSTer shell around the N-Gage's parts: the CPU (rtl/cpu, a TI ARM925T
// made from ZAP: docs/CPU.md), the UPP_WD2 ASIC's memory system and
// peripherals (rtl/upp, docs/UPP_WD2.md), the board devices (rtl/board) and
// the MiSTer-side blocks (rtl/mister: the flash images in DDR3, the C: save
// file, the wall clock, the test picture, the debug rings). The reasons for
// the choices below are in docs/PROGRESS-LOG.md.
// clk_sys is 104 MHz, 4 x 26 MHz, the phone's reference: the MCU, flash,
// timer and MMC clocks divide from it exactly.

module emu #(
	// the CPU's I-cache: 32 KB, twice the phone's, as built and as every
	// bench runs it (16384 gives the phone's size)
	parameter int ICACHE_SIZE                = 32768,
	parameter int DCACHE_WAYS                = 2
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

assign AUDIO_S = 1;                     // AUDIO_L/R: the HLE audio device
assign AUDIO_MIX = 0;

assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

// the OSD's video options, applied by video_freak at the end of the video
// section; crop_ok (status_menumask bit 0) offers the crop where it applies
wire        rotated;
wire  [1:0] ar       = status[122:121];
wire        vcrop_en = status[9];
wire  [3:0] vcopt    = status[13:10];
wire  [1:0] vscale   = status[15:14];
reg         crop_ok;

`include "build_id.v"
localparam CONF_STR = {
	"NGage;;",
	"-;",
	"F1,0C1ROM,Load firmware (RH2941.0C1);",
	"F2,021ROM,Load language pack (RH2941.021);",
	"F3,BIN,Load flash CS0 image;",
	"F4,BIN,Load flash CS1 image;",
	"S0,BINVHD,Mount C: save;",
	"S1,MMCIMGBINVHD,Mount MMC card;",
	"-;",
	"O[2:1],Rotate,Off,Clockwise,Anticlockwise;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[5:3],Scandoubler Fx,None,CRT 25%,CRT 50%,CRT 75%;",
	"d0O[9],Vertical Crop,Disabled,180p(6x);",
	"d0O[13:10],Crop Offset,0,2,4,6,8,10,-12,-10,-8,-6,-4,-2;",
	"O[15:14],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
`ifdef NGAGE_DEBUG
	"-;",
	"O[8],Debug overlay,Off,On;",
`endif
	"-;",
	"T[7],Save C: now;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"J,5,7,OK,Left soft,Right soft,Menu,Call,End,*,#,Clear,Edit,Power,0,1,2,3,4,6,8,9;",
	"jn,A,B,X,L,R,Start,Select,,,,,,,Y;",
	"I,C: save mounted,C: save file must be 4 or 8 MB,C: read-only: no saves,C: saved,Booting the phone - about a minute...,Phone kernel is up,Firmware file damaged,Firmware 4.10 loaded,Firmware not recognised: needs RH-29 4.10,Firmware reloaded: load both files;",
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
// MiSTer sends the game folder's boot0.rom and boot1.rom when the core starts,
// in that order, with no menu index and the file's number in bits 7:6 (0x00,
// 0x40): they are the firmware and its language pack, as F1 and F2 are. A
// file picked in the OSD or named by a launcher keeps its menu index in bits
// 5:0 (bits 7:6 are then its extension). boot2.rom and boot3.rom (0x80, 0xC0)
// are not used. boot.rom also arrives as index 0, after boot1.rom: it is the
// firmware under the other name, and the loader takes the two in either
// order (rtl/mister/phoenix_load.sv). With both boot0.rom and boot.rom in
// the folder the second starts a new pair that no language pack completes.
wire  [15:0] ioctl_index_hps;
wire  [15:0] ioctl_index = ioctl_index_hps[5:0] != 6'd0 ? ioctl_index_hps :
                           ioctl_index_hps[7:6] == 2'd0 ? 16'd1 :
                           ioctl_index_hps[7:6] == 2'd1 ? 16'd2 : ioctl_index_hps;
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

// SD slot 0: the C: save file (boot0.vhd in the game folder); slot 1: the MMC card
hps_io #(.CONF_STR(CONF_STR), .WIDE(1), .VDNUM(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask({15'd0, crop_ok}),
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
	.ioctl_index(ioctl_index_hps),
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
	.sd_buff_wr(sd_buff_wr),

	.RTC(rtc_hps)
);

///////////////////////   CLOCK   ////////////////////////////////

// the wall clock for the UEMK RTC model, from MiSTer's RTC
wire [64:0] rtc_hps;
wire        rtc_valid;
wire  [5:0] rtc_sec, rtc_min;
wire  [4:0] rtc_hour;
wire  [7:0] rtc_days;
wire [31:0] rtc_date;
wire        c_blank /* verilator public_flat_rd */;         // from ddram_flash: CS1's C: area is erased

rtc_wall rtc_wall
(
	.clk(clk_sys),
	.rtc(rtc_hps),
	.valid(rtc_valid),
	.sec(rtc_sec),
	.min(rtc_min),
	.hour(rtc_hour),
	.date(rtc_date),
	.days(rtc_days)
);

///////////////////////   RESET   ////////////////////////////////

// power-on reset of the whole core
reg [1:0] por = 2'b11;
always @(posedge clk_sys) por <= {por[0], RESET | ~pll_locked};
wire sys_reset = por[1];
// the board: also held while a flash image loads or a CS1 save image is
// copied in
// (public: the top bench reads it, and Verilator 5.054 otherwise folds it
// into the save module's output)
wire fs_loading /* verilator public_flat_rd */;
wire ph_busy /* verilator public_flat_rd */;
// The slow sources (the framework's reset, the OSD's reset bit and button,
// a download, the two loaders) are registered once; their OR fans out to
// the whole memory side from hps_io in one clock.
reg  reset_slow = 1'b1;
always @(posedge clk_sys) reset_slow <= sys_reset | status[0] | buttons[1] | ioctl_download | fs_loading | ph_busy;
wire reset = reset_slow;

///////////////////////   MEMORY   ///////////////////////////////

// DDR3 loader clients retain ownership until their command is accepted.
// Phoenix also reads the version signature; it is the only loader reader.
wire        ld_busy, ld_we, ld_rd, ld_valid, dl_we, fs_we, tr_we, kt_we, ph_we, ph_rd;
wire  [1:0] dl_loaded;                 // development flat CS0 / CS1 images
wire  [7:0] ld_be, dl_be, fs_be, tr_be, kt_be, ph_be;
wire [28:0] ld_addr, dl_addr, fs_addr, tr_addr, kt_addr, ph_addr;
wire [63:0] ld_din, dl_din, fs_din, tr_din, kt_din, ph_din, ld_data;
wire        dl_wait, ph_wait;
wire        ph_ready /* verilator public_flat_rd */;
wire  [2:0] ph_note;
wire  [1:0] ph_have;
wire  [4:0] ph_state;
wire [15:0] ph_errors;
reg   [2:0] ld_own = 3'd0;             // flat, save, trace, kernel text, Phoenix
localparam DBG_TRACE = 0;              // debug rings off for a release build

wire ld_own_cmd = ld_we || ld_rd;
always @(posedge clk_sys) begin
	if (!ld_own_cmd) begin
		if (ph_we || ph_rd) ld_own <= 3'd4;
		else if (dl_we)     ld_own <= 3'd0;
		else if (fs_we)     ld_own <= 3'd1;
		else if (tr_we)     ld_own <= 3'd2;
		else if (kt_we)     ld_own <= 3'd3;
	end
end
assign ld_we   = (ld_own == 3'd4) ? ph_we   : (ld_own == 3'd1) ? fs_we   : (ld_own == 3'd2) ? tr_we   : (ld_own == 3'd3) ? kt_we   : dl_we;
assign ld_rd   = ld_own == 3'd4 && ph_rd;
assign ld_addr = (ld_own == 3'd4) ? ph_addr : (ld_own == 3'd1) ? fs_addr : (ld_own == 3'd2) ? tr_addr : (ld_own == 3'd3) ? kt_addr : dl_addr;
assign ld_din  = (ld_own == 3'd4) ? ph_din  : (ld_own == 3'd1) ? fs_din  : (ld_own == 3'd2) ? tr_din  : (ld_own == 3'd3) ? kt_din  : dl_din;
assign ld_be   = (ld_own == 3'd4) ? ph_be   : (ld_own == 3'd1) ? fs_be   : (ld_own == 3'd2) ? tr_be   : (ld_own == 3'd3) ? kt_be   : dl_be;
assign ioctl_wait = dl_wait || ph_wait;

phoenix_load phoenix_load (
	.clk(clk_sys), .reset(sys_reset),
	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index[5:0]),
	.ioctl_wr(ioctl_wr), .ioctl_dout(ioctl_dout), .ioctl_wait(ph_wait),
	.ld_we(ph_we), .ld_rd(ph_rd), .ld_addr(ph_addr), .ld_din(ph_din), .ld_be(ph_be),
	.ld_busy(ld_busy || ld_own != 3'd4), .ld_valid(ld_valid), .ld_data(ld_data),
	.ready(ph_ready), .busy(ph_busy), .note(ph_note), .errors(ph_errors), .debug_have(ph_have), .debug_state(ph_state)
);

// A flat CS1 download can supply C: without a save mount. Flat CS0 selects
// the development route, which requires both flat chips (S1 loads only C:).
reg use_phoenix = 1'b1;
always @(posedge clk_sys) begin
	if (ioctl_download && (ioctl_index[5:0] == 6'd1 || ioctl_index[5:0] == 6'd2)) use_phoenix <= 1'b1;
	if (ioctl_download && ioctl_index[5:0] == 6'd3) use_phoenix <= 1'b0;
	if (sys_reset) use_phoenix <= 1'b1;
end

ddram_loader ddram_loader
(
	.clk(clk_sys),
	.reset(sys_reset),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(dl_wait),
	.ddram_busy(ld_busy || ld_own != 3'd0),
	.ddram_burstcnt(),           // single writes
	.ddram_addr(dl_addr),
	.ddram_din(dl_din),
	.ddram_be(dl_be),
	.ddram_we(dl_we),
	.ddram_rd(),
	.loaded(dl_loaded)           // for the CPU: which images are in
);

assign DDRAM_CLK = clk_sys;

// the memory system's Wishbone port: the CPU's (docs/CPU.md, "In the core")
// (the benches watch it, sim/harness)
wire        wb_cyc /* verilator public_flat_rd */, wb_stb /* verilator public_flat_rd */, wb_we /* verilator public_flat_rd */;
wire        wb_ack /* verilator public_flat_rd */, wb_err /* verilator public_flat_rd */;
wire [31:0] wb_adr /* verilator public_flat_rd */, wb_dat_w /* verilator public_flat_rd */;
wire [31:0] wb_dat_r /* verilator public_flat_rd */;
wire  [3:0] wb_sel /* verilator public_flat_rd */;
wire  [2:0] wb_cti;
wire  [1:0] wb_bte;
wire        wb_no_late_error;

// the peripheral register bus
wire        p_sel, p_we, p_wait;
wire [27:0] p_addr;
wire [31:0] p_wdata, p_rdata;
wire  [3:0] p_be;

// the DMA controller's bus master
wire        dma_cyc, dma_stb, dma_we, dma_ack, dma_err;
wire [31:0] dma_adr, dma_dat_w, dma_dat_r;
wire  [3:0] dma_sel;

wire        dbg_dma_owner;
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
	.wb_no_late_error(wb_no_late_error),
	.wb_dat_o(wb_dat_r),
	.dbg_dma_owner(dbg_dma_owner),

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

	.ld_rd(ld_rd), .ld_valid(ld_valid), .ld_data(ld_data),
	.ld_we(ld_we),
	.ld_addr(ld_addr),
	.ld_din(ld_din),
	.ld_be(ld_be),
	.ld_busy(ld_busy),

	.save_mark(save_mark),
	.save_mark_blk(save_mark_blk),
	.c_blank(c_blank),
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

// SD slot 0 loads only C: at CS1 + 4 MB; changed C: blocks go back to
// the file. Legacy 8 MB saves use only their upper half.
wire        save_mark, save_rd, save_taken, save_valid;
wire [13:0] save_mark_blk, save_blk;
wire [63:0] save_data;
wire        fs_active, fs_saved;
wire        fs_present;                // the save file is mounted and in DDR3
wire  [1:0] fs_note;
reg   [1:0] dl_cs1 = 2'b00;            // an ioctl load of CS1 starts: the file is detached

always @(posedge clk_sys) dl_cs1 <= {dl_cs1[0], ioctl_download && ioctl_index[5:0] == 6'd4};

flash_save flash_save
(
	.clk(clk_sys),
	.reset(sys_reset),
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
	.sd_buff_wr(sd_buff_wr),
	.ld_we(fs_we),
	.ld_addr(fs_addr),
	.ld_din(fs_din),
	.ld_be(fs_be),
	.ld_busy(ld_busy || ld_own != 3'd1),
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
	.present(fs_present),
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

wire        upp_lcd_csx, upp_lcd_dcx, upp_lcd_wrx, upp_lcd_rdx, upp_lcd_resx, upp_lcd_d_oe;
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

wire [31:0] dbg_src0, dbg_en0_irq, dbg_en0_fiq;

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
	.dbg_src0(dbg_src0),
	.dbg_en0_irq(dbg_en0_irq),
	.dbg_en0_fiq(dbg_en0_fiq),
	.fiq(cpu_fiq),
	.lcd_csx(upp_lcd_csx),
	.lcd_dcx(upp_lcd_dcx),
	.lcd_wrx(upp_lcd_wrx),
	.lcd_rdx(upp_lcd_rdx),
	.lcd_resx(upp_lcd_resx),
	.lcd_d_o(upp_lcd_d),
	.lcd_d_oe(upp_lcd_d_oe),
	.lcd_d_i(panel_d),
	.lcd_active(),
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
	.rtc_valid(rtc_valid),
	.rtc_sec(rtc_sec),
	.rtc_min(rtc_min),
	.rtc_hour(rtc_hour),
	.rtc_days(rtc_days),
	.rtc_date(rtc_date),
	.c_blank(c_blank),
	.audio_l(AUDIO_L),
	.audio_r(AUDIO_R),
	.sti_we(sti_we),
	.sti_addr(),
	.sti_be(sti_be),
	.sti_data(sti_data)
);

// the firmware's debug text (STI) to a ring in DDR3 (rtl/mister/dbg_sti.sv),
// read by tools/mister_trace.py fetch-sti
wire        sti_we;
wire  [3:0] sti_be;
wire [31:0] sti_data;
wire [15:0] kt_count;
wire  [7:0] kt_dropped;

generate if (DBG_TRACE) begin : g_sti
dbg_sti dbg_sti
(
	.clk(clk_sys),
	.reset(sys_reset),
	.sti_we(sti_we),
	.sti_be(sti_be),
	.sti_data(sti_data),
	.ld_we(kt_we),
	.ld_addr(kt_addr),
	.ld_din(kt_din),
	.ld_be(kt_be),
	.ld_busy(ld_busy || ld_own != 3'd3),
	.count(kt_count),
	.dropped(kt_dropped)
);
end else begin : g_nosti
assign kt_we = 1'b0;
assign kt_addr = 29'd0;
assign kt_din = 64'd0;
assign kt_be = 8'd0;
assign kt_count = 16'd0;
assign kt_dropped = 8'd0;
wire unused_sti = &{1'b0, sti_we, sti_be, sti_data};
end endgenerate

///////////////////////   CPU   ////////////////////////////////

// Out of reset once the board is, the memory test is off and both flash
// images are in (verified/patched Phoenix pair and C:, or both flat chips).
// The start also
// waits for MiSTer's clock, up to RTC_WAIT_CLKS: Main sends it once, after
// the launcher's files, and the stand-in reads the HLE date once at its entry
// (docs/PROGRESS-LOG.md, 2026-10-21 evening).
localparam int RTC_WAIT_CLKS = 312_000_000;
wire        images_in = use_phoenix ? (ph_ready && (fs_present || dl_loaded[1])) : (&dl_loaded);
reg  [28:0] rtc_timer = 0;
reg         rtc_wait = 1'b1;
always @(posedge clk_sys) begin
	if (!images_in || mem_reset) rtc_timer <= 0;
	else if (rtc_timer != 29'(RTC_WAIT_CLKS)) rtc_timer <= rtc_timer + 1'd1;
	rtc_wait <= !rtc_valid && rtc_timer != 29'(RTC_WAIT_CLKS);
end

// maxfan: Quartus copies this register near its loads (its one copy
// crossed the device to the whole CPU, 3.2 ns of routing at 104 MHz).
(* maxfan = 32 *) reg cpu_reset /* verilator public_flat_rd */ = 1'b1;
always @(posedge clk_sys) cpu_reset <= mem_reset | ~images_in | rtc_wait;

wire        cpu_req, cpu_we, cpu_burst;
wire  [1:0] cpu_bte;
wire [31:0] cpu_addr, cpu_wdata;
wire  [3:0] cpu_be;

wire [31:0] cpu_dbg_pc;

// debug trace taps (dbg_trace below)
wire        tr_wb_valid, tr_wb_dvalid, tr_wb_uop_last, tr_wb_pabt, tr_wb_und, tr_wb_swi, tr_wb_irq, tr_wb_fiq;
wire  [1:0] tr_wb_dabt;
wire [31:0] tr_wb_pc, tr_wb_cpsr, tr_wb_cpsr_nxt;
wire        tr_d_done, tr_d_we;
wire        cpu_dbg_wfi;
wire  [7:0] cpu_dbg_stall;
wire  [7:0] cpu_dbg_icache;
wire  [3:0] cpu_dbg_dcache;   // load fills, store fills, write-backs, uncached completions
wire [31:0] tr_d_va, tr_d_wdata, tr_d_rdata;
wire  [3:0] tr_d_sel;

arm925t #(
	.ICACHE_SIZE(ICACHE_SIZE),
	.DCACHE_WAYS(DCACHE_WAYS)
) arm925t
(
	.clk(clk_sys),
	.reset(cpu_reset),
	.irq(cpu_irq),
	.fiq(cpu_fiq),
	.bus_req(cpu_req),
	.bus_we(cpu_we),
	.bus_addr(cpu_addr),
	.bus_be(cpu_be),
	.bus_wdata(cpu_wdata),
	.bus_burst(cpu_burst),
	.bus_bte(cpu_bte),
	.bus_rdata(wb_dat_r),
	.bus_ack(wb_ack),
	.bus_err(wb_err),
	.bus_no_late_error(wb_no_late_error), // consumed only with CPU ACK
	.dbg_pc(cpu_dbg_pc),
	.dbg_wb_valid(tr_wb_valid),
	.dbg_wfi(cpu_dbg_wfi),
	.dbg_stall(cpu_dbg_stall),
	.dbg_dcache(cpu_dbg_dcache),
	.dbg_icache(cpu_dbg_icache),
	.dbg_wb_dvalid(tr_wb_dvalid),
	.dbg_wb_uop_last(tr_wb_uop_last),
	.dbg_wb_dabt(tr_wb_dabt),
	.dbg_wb_pabt(tr_wb_pabt),
	.dbg_wb_und(tr_wb_und),
	.dbg_wb_swi(tr_wb_swi),
	.dbg_wb_irq(tr_wb_irq),
	.dbg_wb_fiq(tr_wb_fiq),
	.dbg_wb_pc(tr_wb_pc),
	.dbg_wb_cpsr(tr_wb_cpsr),
	.dbg_wb_cpsr_nxt(tr_wb_cpsr_nxt),
	.dbg_d_done(tr_d_done),
	.dbg_d_we(tr_d_we),
	.dbg_d_va(tr_d_va),
	.dbg_d_sel(tr_d_sel),
	.dbg_d_wdata(tr_d_wdata),
	.dbg_d_rdata(tr_d_rdata)
);

// the hardware trace (rtl/mister/dbg_trace.sv, DBG_TRACE): rings dumped to
// DDR3 on an abort, an undefined instruction or a trigger (dbg_trig below);
// tools/mister_trace.py reads them
wire        dbg_trig;
wire  [7:0] tr_dumps, tr_triggers;
wire        tr_dumping;
wire [31:0] tr_trig_pc;

generate if (DBG_TRACE) begin : g_trace
dbg_trace dbg_trace
(
	.clk(clk_sys),
	.reset(sys_reset),
	.cpu_reset(cpu_reset),
	.wb_valid(tr_wb_valid),
	.wb_dvalid(tr_wb_dvalid),
	.wb_uop_last(tr_wb_uop_last),
	.wb_dabt(tr_wb_dabt),
	.wb_pabt(tr_wb_pabt),
	.wb_und(tr_wb_und),
	.wb_swi(tr_wb_swi),
	.wb_irq(tr_wb_irq),
	.wb_fiq(tr_wb_fiq),
	.wb_pc(tr_wb_pc),
	.wb_cpsr(tr_wb_cpsr),
	.wb_cpsr_nxt(tr_wb_cpsr_nxt),
	.d_done(tr_d_done),
	.d_we(tr_d_we),
	.d_va(tr_d_va),
	.d_sel(tr_d_sel),
	.d_wdata(tr_d_wdata),
	.d_rdata(tr_d_rdata),
	.b_ack(cpu_req & wb_ack),
	.b_err(wb_err),
	.b_we(wb_we),
	.b_adr(wb_adr),
	.b_sel(wb_sel),
	.b_cti(wb_cti),
	.b_wdata(wb_dat_w),
	.b_rdata(wb_dat_r),
	.trig_in(dbg_trig),
	.ld_we(tr_we),
	.ld_addr(tr_addr),
	.ld_din(tr_din),
	.ld_be(tr_be),
	.ld_busy(ld_busy || ld_own != 3'd2),
	.dumps(tr_dumps),
	.triggers(tr_triggers),
	.dumping(tr_dumping),
	.trig_pc(tr_trig_pc)
);
end else begin : g_notrace
assign tr_we = 1'b0;
assign tr_addr = 29'd0;
assign tr_din = 64'd0;
assign tr_be = 8'd0;
assign tr_dumps = 8'd0;
assign tr_triggers = 8'd0;
assign tr_dumping = 1'b0;
assign tr_trig_pc = 32'd0;
wire unused_trace = &{1'b0, tr_wb_valid, tr_wb_dvalid, tr_wb_uop_last, tr_wb_dabt, tr_wb_pabt, tr_wb_und,
                      tr_wb_swi, tr_wb_irq, tr_wb_fiq, tr_wb_pc, tr_wb_cpsr, tr_wb_cpsr_nxt, tr_d_done, tr_d_we,
                      tr_d_va, tr_d_sel, tr_d_wdata, tr_d_rdata, dbg_trig};
end endgenerate

// the Wishbone port is the CPU's
assign wb_cyc   = cpu_req;
assign wb_stb   = cpu_req;
assign wb_we    = cpu_we;
assign wb_adr   = cpu_addr;
assign wb_dat_w = cpu_wdata;
assign wb_sel   = cpu_be;
assign wb_cti   = cpu_burst ? 3'b010 : 3'b111;
assign wb_bte   = cpu_bte;

// The firmware's first LCD frame is a cheap boot milestone.
reg         cpu_reset_q = 1'b1;
reg         boot_done /* verilator public_flat_rd */ = 1'b0;
wire        boot_start = cpu_reset_q && !cpu_reset;
wire        boot_up = !cpu_reset && !boot_done && lcd_frame_ev;
always @(posedge clk_sys) begin
	cpu_reset_q <= cpu_reset;
	if (cpu_reset) boot_done <= 1'b0;
	else if (boot_up) boot_done <= 1'b1;
end

// Queue info events, with a low cycle between pulses: a mounted or save
// event must not swallow a boot message (or vice versa) on the same clock.
wire  [9:0] info_events = {ph_note == 3'd4, ph_note == 3'd2, ph_note == 3'd3, ph_note == 3'd1, boot_up, boot_start, fs_saved,
                          fs_note == 2'd3, fs_note == 2'd2, fs_note == 2'd1};
reg   [9:0] info_pending = 0;
reg   [7:0] info_q = 0;
reg         info_req_q = 0;
reg   [7:0] info_next;
reg   [9:0] info_mask;
always @* begin
	info_next = 0;
	info_mask = 0;
	for (int i = 9; i >= 0; i--) begin
		if (info_pending[i]) begin
			info_next = 8'(i + 1);
			info_mask = 10'(1 << i);
		end
	end
end
always @(posedge clk_sys) begin
	info_req_q <= 1'b0;
	info_pending <= info_pending | info_events;
	if (!info_req_q && info_next != 0) begin
		info_q <= info_next;
		info_req_q <= 1'b1;
		info_pending <= (info_pending & ~info_mask) | info_events;
	end
	if (cpu_reset) info_pending[5:4] <= 2'b00;
	if (sys_reset) begin
		info_pending <= 0;
		info_req_q <= 1'b0;
	end
end

assign info_req = info_req_q;
assign info     = info_q;

assign LED_POWER = 2'b00;

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
	.stop_queued(!dbg_src0[23]),
	.present(),
	.write_protected(),
	.active(mmc_active),
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
	.sd_buff_wr(sd_buff_wr & sd_ack[1])      // the buffer is shared by both slots
);

assign LED_DISK = {1'b0, mmc_active | fs_active};

///////////////////////   KEYS   /////////////////////////////////

wire [ngage_keys::NKEYS-1:0] keys /* verilator public_flat_rd */;
wire       power_key /* verilator public_flat_rd */;
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
	.col_oe(upp_col_oe),
	.col_out(upp_col_out),
	.row_oe(upp_row_oe),
	.row_out(upp_row_out),
	.col_in(kp_col_in),
	.row_in(kp_row_in),
	.pwronx(pwronx)
);

///////////////////////   DISPLAY   //////////////////////////////

// the panel's bus is the UPP's LCD interface's
wire       panel_d_oe;
wire [7:0] lcd_d = upp_lcd_d_oe ? upp_lcd_d : panel_d_oe ? panel_d : 8'hFF;

wire        scan_en;
wire  [7:0] scan_x, scan_y;
wire [15:0] scan_rgb;
wire [15:0] panel_rgb;
wire        lcd_on;

wire       lcd_frame_ev, lcd_pix_ev;
wire [7:0] lcd_pix_y;

lcd_panel lcd_panel
(
	.clk(clk_sys),
	.reset(sys_reset),
	.csx(upp_lcd_csx),
	.dcx(upp_lcd_dcx),
	.wrx(upp_lcd_wrx),
	.rdx(upp_lcd_rdx),
	.resx(upp_lcd_resx),
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
	.display_on(lcd_on),
	.frame_ev(lcd_frame_ev),
	.pix_ev(lcd_pix_ev),
	.pix_y(lcd_pix_y)
);

// The debug overlay (OSD "Debug overlay"): the CPU's PC, status bits and
// 32-bit words as white pixels; tools/mister_dbg.py has the row layout and
// decodes a screenshot. The overlay, its per-second counters and the trace
// triggers are built only with NGAGE_DEBUG (NGage.qsf): the measurement
// core; every other build is the stripped core, about 1,700 ALMs smaller.
`ifdef NGAGE_DEBUG
// a completed CPU bus beat, for the counters
wire        dbg_bus_beat  = wb_cyc && wb_stb && (wb_ack || wb_err);
// Appended words 37/38 (rows 156-158 and 160-162): loader state and history.
// Count actual ioctl_download rising edges, including raw F3/F4. These survive
// CPU/OSD resets; sys_reset (RESET input/PLL unlock) clears the history.
reg         dbg_download_q = 0;
reg   [5:0] dbg_download_index = 0;
reg  [15:0] dbg_download_counts = 0; // F1/F2/F3/F4, four saturating nibbles
reg   [2:0] dbg_ph_note = 0;
reg  [31:0] dbg_loader_q = 0, dbg_load_counts_q = 0;
always @(posedge clk_sys) begin
	dbg_download_q <= ioctl_download;
	if (ioctl_download && !dbg_download_q) begin
		dbg_download_index <= ioctl_index[5:0];
		case (ioctl_index[5:0])
			6'd1: if (dbg_download_counts[15:12] != 4'hF) dbg_download_counts[15:12] <= dbg_download_counts[15:12] + 4'd1;
			6'd2: if (dbg_download_counts[11:8] != 4'hF) dbg_download_counts[11:8] <= dbg_download_counts[11:8] + 4'd1;
			6'd3: if (dbg_download_counts[7:4] != 4'hF) dbg_download_counts[7:4] <= dbg_download_counts[7:4] + 4'd1;
			6'd4: if (dbg_download_counts[3:0] != 4'hF) dbg_download_counts[3:0] <= dbg_download_counts[3:0] + 4'd1;
			default: ;
		endcase
	end
	if (ph_note != 0) dbg_ph_note <= ph_note;
	// Snapshot both words on the same frame boundary, even while CPU reset.
	if (scan_en && scan_x == 8'd0 && scan_y == 8'd0) begin
		dbg_loader_q <= {ph_ready, ph_busy, ph_have, dbg_download_index, dbg_ph_note, ph_state, 14'd0};
		dbg_load_counts_q <= {dbg_download_counts, ph_errors};
	end
	if (sys_reset) begin
		dbg_download_q <= 0; dbg_download_index <= 0; dbg_download_counts <= 0;
		dbg_ph_note <= 0; dbg_loader_q <= 0; dbg_load_counts_q <= 0;
	end
end
reg  [31:0] dbg_pc_q = 0;
reg         dbg_bus_q = 0;
reg   [7:0] dbg_bits_q = 0;
// audio: the largest sample magnitude of each channel over the last frame
wire [15:0] aud_abs_l = AUDIO_L[15] ? -AUDIO_L : AUDIO_L;
wire [15:0] aud_abs_r = AUDIO_R[15] ? -AUDIO_R : AUDIO_R;
reg  [15:0] aud_peak_l = 0, aud_peak_r = 0, dbg_aud_l = 0, dbg_aud_r = 0;
always @(posedge clk_sys) begin
	if (cpu_req & wb_ack) dbg_bus_q <= 1'b1;
	if (aud_abs_l > aud_peak_l) aud_peak_l <= aud_abs_l;
	if (aud_abs_r > aud_peak_r) aud_peak_r <= aud_abs_r;
	if (scan_en && scan_x == 8'd0 && scan_y == 8'd0) begin
		dbg_pc_q   <= cpu_dbg_pc;
		dbg_bits_q <= {cpu_reset, cpu_irq, cpu_fiq, dbg_bus_q, dl_loaded[0], dl_loaded[1], fs_present, 1'b0};
		dbg_bus_q  <= 1'b0;
		dbg_aud_l  <= aud_peak_l;
		dbg_aud_r  <= aud_peak_r;
		aud_peak_l <= 16'd0;
		aud_peak_r <= 16'd0;
	end
end
// Kern::Fault's record, snooped from the kernel's writes to on-chip RAM
// 0x0C0047F0/F4/F8 (tools/mister_dbg.py, docs/PROGRESS-LOG.md 2026-10-21)
reg [31:0] dbg_f0 = 0, dbg_f4 = 0, dbg_f8 = 0;
// trace triggers besides the faults (0 = off): 16 clocks after a read of the
// physical word address DBG_TRIG_RD (the HLE RTC date register), on a write
// to flash CS1 from DBG_TRIG_WR_AFTER_S seconds after the CPU start, and at
// DBG_TRIG_AT1_S / DBG_TRIG_AT2_S seconds, a sample of a slow boot phase
// (docs/PROGRESS-LOG.md, 2026-10-21 and 2026-10-22)
localparam [31:0] DBG_TRIG_RD = 32'h0C1F0100;
localparam [7:0] DBG_TRIG_WR_AFTER_S = 8'd0;
localparam [7:0] DBG_TRIG_AT1_S = 8'd55;
localparam [7:0] DBG_TRIG_AT2_S = 8'd130;
reg  [26:0] dbg_sec_pre = 0;
reg   [7:0] dbg_sec = 0;
always @(posedge clk_sys) begin
	if (cpu_reset) begin
		dbg_sec_pre <= 0;
		dbg_sec     <= 0;
	end else if (dbg_sec_pre == 27'd103_999_999) begin
		dbg_sec_pre <= 0;
		if (dbg_sec != 8'hFF) dbg_sec <= dbg_sec + 1'd1;
	end else begin
		dbg_sec_pre <= dbg_sec_pre + 1'd1;
	end
end
wire        dbg_tick = dbg_sec_pre == 27'd103_999_999;   // the second's last clock

// per-second counters for the overlay (rtl/mister/dbg_counters.sv)
wire        dbg_bus_pend  = wb_cyc && wb_stb && !wb_ack && !wb_err;
wire        dbg_bus_sdram = wb_adr[27:25] == 3'b101;      // 0x0A000000 window
wire        dbg_bus_flash = wb_adr[27:26] == 2'b00;       // CS0-CS3
// the events, one 32-bit count each: LCD frames and pixels, instructions
// retired, clocks in wait-for-interrupt, bus wait clocks by target, bus
// beats, the CPU's stall and flush taps (zap_core o_dbg_stall), uops
// retired, replays, and the MMC card path (512-byte blocks completed,
// clocks in a data phase, clocks the wire waits for Linux). A replay
// (dbg_wb_dabt[1]: the writeback sends the
// instruction round again because the data cache was busy with a fill) has
// no architectural effect and is not a retired instruction or uop, as the
// CPU bench counts them (sim/cpu/tb/main.cpp).
// Counter indices 0..24 retain their original meanings. Appended:
// 25 FIFO full, 26 fetch request without ACK, 27 demand I-fill completions,
// 28 fetch wait with FIFO not full, 29 I-fill waits behind the DATA owner,
// 30 I-fill waits for the external DMA/self-test grant, 31/32 I/D TLB beats.
// Overlay word index = counter index + 12 (37..44 for the additions).
// Loader status/history follow at words 45/46 (rows 188/192).
localparam DBG_CNT = 33;
reg         dbg_mmc_busy_q = 0;
always @(posedge clk_sys) dbg_mmc_busy_q <= dbg_src0[22];
wire        tr_wb_retire = (tr_wb_valid || tr_wb_dvalid) && !tr_wb_dabt[1];
wire [DBG_CNT-1:0] dbg_ev = {
	cpu_dbg_icache[7:6],                                  // 32..31 D/I TLB walk beats
	cpu_dbg_icache[5] && dbg_dma_owner,                   // 30 I-fill external grant wait
	cpu_dbg_icache[4:0],                                  // 29..25 merger wait, true wait, fills, fetch wait, FIFO full
	cpu_dbg_dcache,                                       // 24..21 D-cache: uncached completions, line write-backs, store-miss fills, load-miss fills
	dbg_src0[22] && dbg_src0[23] && !card_dat_oe,         // 20 mmc wire waits for Linux
	dbg_src0[22],                                         // 19 mmc clocks in data phase
	dbg_mmc_busy_q && !dbg_src0[22],                      // 18 mmc 512-byte blocks completed
	tr_wb_valid && tr_wb_dabt[1],                         // 17 replays
	tr_wb_retire,                                         // 16 uops retired
	cpu_dbg_stall,                                        // 15..8 clear_wb, clear_alu, decode, shifter, issue, fifo empty, code, data
	dbg_bus_beat,                                         // 7
	dbg_bus_pend && !dbg_bus_sdram && !dbg_bus_flash,     // 6
	dbg_bus_pend && dbg_bus_flash,                        // 5
	dbg_bus_pend && dbg_bus_sdram,                        // 4
	cpu_dbg_wfi,                                          // 3
	tr_wb_retire && tr_wb_uop_last,                       // 2 instructions retired
	lcd_pix_ev,                                           // 1
	lcd_frame_ev};                                        // 0
wire [DBG_CNT-1:0][31:0] dbg_cnt;

dbg_counters #(.N(DBG_CNT)) dbg_counters
(
	.clk(clk_sys),
	.reset(sys_reset),
	.tick(dbg_tick),
	.ev(dbg_ev),
	.cnt(dbg_cnt)
);

// Exceptions, and whose clocks the privileged ones are: the overlay's second
// column (x 56..87, the rows from y = 8; tools/mister_dbg.py). The writeback
// stage's exception outputs pulse in the clock an exception is taken, and
// the CPU is in User mode while the CPSR's mode field says so. Privileged
// clocks are charged to the exception that last took the CPU out of User
// mode, until the CPSR is back there: an interrupt inside a kernel call is
// the call's time, and so is a thread the kernel switches to inside it.
// Word 0 is a marker (the decoder's test for this column). Counters, per
// second: 0..5 SWI, IRQ, FIQ, data-abort, prefetch-abort and undefined
// exceptions taken; 6 clocks in User mode; 7..12 privileged clocks after a
// SWI, IRQ, FIQ, data abort, prefetch abort, undefined instruction; 13
// instructions retired in User mode; 14 aborts and undefined instructions
// taken in a privileged mode, 15 SWIs, 16 interrupts; 17/18 kernel calls
// (SWI to User mode again) of 4,096 clocks or more, of 65,536 or more;
// 19..21 clocks in Supervisor, Undefined and IRQ mode (this kernel
// reschedules and switches processes in Undefined mode, and the system
// idles in it); 22..26 the RH-29 v4.60 kernel's process switch, counted where its
// instructions retire: the switch itself (the DACR write at 0x50324110),
// its whole I-cache, I-TLB and D-TLB invalidations (0x50324134, 0x5032413C,
// 0x50324144; each conditional) and its clean-and-invalidate loop over the
// D-cache (entered at 0x503224BC). Another firmware has other addresses.
// Then five words sampled at the frame start: the PC of one SWI in 64
// (picked by an LFSR), of the last data abort, prefetch abort and undefined
// instruction (the stage's PC: the address + 8, + 4 in Thumb), and the low
// CPSR byte before each: {undefined, prefetch abort, data abort, SWI}.
// Counters 27 to 38 are the display's (the unrotated picture): an upload is
// a RAMWR from the top line until its 36,608th pixel (given up after 2.5 ms
// without one); a video frame is torn when a pixel is written on the line
// the scan-out is drawing, and fresh when an upload ended since the frame
// before. The last six sort the fresh frames by the video frames since the
// fresh one before: 1, 2, 3, 4, 5 or 6, 7 and more.
localparam DBG_CNT2 = 39;
localparam [31:0] DBG_COL2_MARK = 32'h4E47_4534;        // "NGE4"
wire        dbg_user  = tr_wb_cpsr[4:0] == 5'b10000;
wire  [5:0] dbg_exc   = {tr_wb_und, tr_wb_pabt, tr_wb_dabt[0], tr_wb_fiq, tr_wb_irq, tr_wb_swi};
reg   [5:0] dbg_cause = 0;
reg         dbg_user_q = 0;
reg  [16:0] dbg_away  = 0;                               // clocks since User mode, saturating
reg  [15:0] dbg_lfsr  = 16'hACE1;
reg  [31:0] dbg_swi_pc = 0, dbg_dabt_pc = 0, dbg_pabt_pc = 0, dbg_und_pc = 0, dbg_exc_cpsr = 0;
reg  [31:0] dbg_swi_pc_q = 0, dbg_dabt_pc_q = 0, dbg_pabt_pc_q = 0, dbg_und_pc_q = 0, dbg_exc_cpsr_q = 0;
always @(posedge clk_sys) begin
	dbg_user_q <= dbg_user;
	dbg_lfsr   <= {dbg_lfsr[14:0], dbg_lfsr[15] ^ dbg_lfsr[13] ^ dbg_lfsr[12] ^ dbg_lfsr[10]};
	if (dbg_user && dbg_exc != 6'd0) dbg_cause <= dbg_exc;
	if (dbg_user) dbg_away <= 17'd0;
	else if (!dbg_away[16]) dbg_away <= dbg_away + 17'd1;
	if (tr_wb_swi && dbg_lfsr[5:0] == 6'd0) begin
		dbg_swi_pc        <= tr_wb_pc;
		dbg_exc_cpsr[7:0] <= tr_wb_cpsr[7:0];
	end
	if (tr_wb_dabt[0]) begin
		dbg_dabt_pc        <= tr_wb_pc;
		dbg_exc_cpsr[15:8] <= tr_wb_cpsr[7:0];
	end
	if (tr_wb_pabt) begin
		dbg_pabt_pc         <= tr_wb_pc;
		dbg_exc_cpsr[23:16] <= tr_wb_cpsr[7:0];
	end
	if (tr_wb_und) begin
		dbg_und_pc          <= tr_wb_pc;
		dbg_exc_cpsr[31:24] <= tr_wb_cpsr[7:0];
	end
	if (cpu_reset) begin
		dbg_cause    <= 6'd0;
		dbg_swi_pc   <= 32'd0;
		dbg_dabt_pc  <= 32'd0;
		dbg_pabt_pc  <= 32'd0;
		dbg_und_pc   <= 32'd0;
		dbg_exc_cpsr <= 32'd0;
	end
	if (scan_en && scan_x == 8'd0 && scan_y == 8'd0) begin
		dbg_swi_pc_q   <= dbg_swi_pc;
		dbg_dabt_pc_q  <= dbg_dabt_pc;
		dbg_pabt_pc_q  <= dbg_pabt_pc;
		dbg_und_pc_q   <= dbg_und_pc;
		dbg_exc_cpsr_q <= dbg_exc_cpsr;
	end
end
reg         dbg_up = 0;                                  // an upload is in progress
reg  [15:0] dbg_up_pix = 0;
reg  [17:0] dbg_up_gap = 0;
reg         dbg_vact = 0;                                // the scan-out is inside the picture
reg         dbg_torn = 0, dbg_fresh = 0;
reg   [2:0] dbg_vf_gap = 0;                              // video frames since the last fresh one, up to 7
wire        dbg_vf      = scan_en && scan_x == 8'd0 && scan_y == 8'd0;   // a video frame's first pixel
wire        dbg_up_done = dbg_up && lcd_pix_ev && dbg_up_pix == 16'd36607;
always @(posedge clk_sys) begin
	if (lcd_frame_ev) begin
		dbg_up     <= 1'b1;
		dbg_up_pix <= 16'd0;
		dbg_up_gap <= 18'd0;
	end else if (dbg_up && lcd_pix_ev) begin
		dbg_up_pix <= dbg_up_pix + 16'd1;
		dbg_up_gap <= 18'd0;
		if (dbg_up_pix == 16'd36607) dbg_up <= 1'b0;
	end else if (dbg_up) begin
		dbg_up_gap <= dbg_up_gap + 18'd1;
		if (&dbg_up_gap) dbg_up <= 1'b0;
	end
	if (dbg_vf) begin
		dbg_vact  <= 1'b1;
		dbg_torn  <= 1'b0;
		dbg_fresh <= 1'b0;
		if (dbg_fresh) dbg_vf_gap <= 3'd1;
		else if (dbg_vf_gap != 3'd7) dbg_vf_gap <= dbg_vf_gap + 3'd1;
	end else if (scan_en && scan_x == 8'd175 && scan_y == 8'd207) begin
		dbg_vact  <= 1'b0;
	end
	if (lcd_pix_ev && dbg_vact && lcd_pix_y == scan_y) dbg_torn <= 1'b1;
	if (dbg_up_done) dbg_fresh <= 1'b1;
	if (sys_reset) begin
		dbg_up     <= 1'b0;
		dbg_vact   <= 1'b0;
		dbg_torn   <= 1'b0;
		dbg_fresh  <= 1'b0;
		dbg_vf_gap <= 3'd0;
	end
end
wire        dbg_back = dbg_user && !dbg_user_q;          // the first User clock again
wire        dbg_ret   = tr_wb_valid && tr_wb_pc[31:16] == 16'h5032;   // an instruction of that kernel page retires
wire [DBG_CNT2-1:0] dbg_ev2 = {
	dbg_vf && dbg_fresh && dbg_vf_gap == 3'd7,                // 38 fresh frames 7 or more video frames after the last
	dbg_vf && dbg_fresh && (dbg_vf_gap == 3'd5 || dbg_vf_gap == 3'd6), // 37 5 or 6
	dbg_vf && dbg_fresh && dbg_vf_gap == 3'd4,                // 36 4
	dbg_vf && dbg_fresh && dbg_vf_gap == 3'd3,                // 35 3
	dbg_vf && dbg_fresh && dbg_vf_gap == 3'd2,                // 34 2
	dbg_vf && dbg_fresh && dbg_vf_gap == 3'd1,                // 33 the very next video frame
	dbg_up_done,                                              // 32 uploads ended
	dbg_vf && dbg_fresh,                                      // 31 fresh video frames
	dbg_vf && dbg_torn,                                       // 30 torn video frames
	dbg_up && dbg_user,                                       // 29 clocks of an upload in User mode
	dbg_up && tr_wb_cpsr[4:0] == 5'b11011,                    // 28 clocks of an upload in Undefined mode
	dbg_up,                                                   // 27 clocks of an upload
	dbg_ret && tr_wb_pc[15:0] == 16'h24C4,                    // 26 D-cache clean-and-invalidate loops
	dbg_ret && tr_wb_pc[15:0] == 16'h414C,                    // 25 D-TLB invalidations
	dbg_ret && tr_wb_pc[15:0] == 16'h4144,                    // 24 I-TLB invalidations
	dbg_ret && tr_wb_pc[15:0] == 16'h413C,                    // 23 I-cache invalidations
	dbg_ret && tr_wb_pc[15:0] == 16'h4118,                    // 22 process switches (the DACR write)
	tr_wb_cpsr[4:0] == 5'b10010,                              // 21 clocks in IRQ mode
	tr_wb_cpsr[4:0] == 5'b11011,                              // 20 clocks in Undefined mode
	tr_wb_cpsr[4:0] == 5'b10011,                              // 19 clocks in Supervisor mode
	dbg_back && dbg_cause[0] && dbg_away[16],                 // 18 kernel calls of 65,536 clocks or more
	dbg_back && dbg_cause[0] && dbg_away[16:12] != 5'd0,      // 17 of 4,096 or more
	!dbg_user && (tr_wb_irq || tr_wb_fiq),                    // 16 interrupts taken in a privileged mode
	!dbg_user && tr_wb_swi,                                   // 15 SWIs taken in a privileged mode
	!dbg_user && (tr_wb_dabt[0] || tr_wb_pabt || tr_wb_und),  // 14 aborts and undefined taken in a privileged mode
	dbg_user && tr_wb_retire && tr_wb_uop_last,               // 13 instructions retired in User mode
	{6{!dbg_user}} & dbg_cause,                               // 12..7 privileged clocks after und, pabt, dabt, fiq, irq, swi
	dbg_user,                                                 // 6 clocks in User mode
	dbg_exc};                                                 // 5..0 und, pabt, dabt, fiq, irq, swi taken
wire [DBG_CNT2-1:0][31:0] dbg_cnt2;

dbg_counters #(.N(DBG_CNT2)) dbg_counters2
(
	.clk(clk_sys),
	.reset(sys_reset),
	.tick(dbg_tick),
	.ev(dbg_ev2),
	.cnt(dbg_cnt2)
);

wire dbg_trig_wr = DBG_TRIG_WR_AFTER_S != 8'd0 && dbg_sec >= DBG_TRIG_WR_AFTER_S &&
                   cpu_req && wb_ack && wb_we && wb_adr[31:24] == 8'h02;
wire dbg_trig_at = dbg_sec_pre == 27'd0 &&
                   ((DBG_TRIG_AT1_S != 8'd0 && dbg_sec == DBG_TRIG_AT1_S) ||
                    (DBG_TRIG_AT2_S != 8'd0 && dbg_sec == DBG_TRIG_AT2_S));
reg  [15:0] dbg_trd_q = 0;
always @(posedge clk_sys) dbg_trd_q <= {dbg_trd_q[14:0],
	(DBG_TRIG_RD != 32'd0 && cpu_req && wb_ack && !wb_we && wb_adr[31:2] == DBG_TRIG_RD[31:2]) || dbg_trig_wr || dbg_trig_at};
assign dbg_trig = (wb_cyc && wb_stb && wb_we && wb_ack && wb_adr[31:20] == 12'h0C0 &&
                   wb_adr[15:2] == 14'(32'h47F0 >> 2)) || dbg_trd_q[15];
always @(posedge clk_sys) begin
	if (wb_cyc && wb_stb && wb_we && wb_ack && wb_adr[31:20] == 12'h0C0) begin
		if (wb_adr[15:2] == 14'(32'h47F0 >> 2)) dbg_f0 <= wb_dat_w;
		if (wb_adr[15:2] == 14'(32'h47F4 >> 2)) dbg_f4 <= wb_dat_w;
		if (wb_adr[15:2] == 14'(32'h47F8 >> 2)) dbg_f8 <= wb_dat_w;
	end
end
wire        dbg_on    = status[8];
wire        dbg_pcrow = scan_y < 8'd3 && scan_x >= 8'd16 && scan_x < 8'd48;
wire        dbg_strow = scan_y >= 8'd4 && scan_y < 8'd7 && scan_x >= 8'd16 && scan_x < 8'd24;
// the 32-bit rows at y = 8, 12, ... (3 lines each; 12 words, then the
// counters): tools/mister_dbg.py
localparam [7:0] DBG_WEND = 8'd8 + 8'd4 * 8'(12 + DBG_CNT + 2) - 8'd1;
wire        dbg_wrow  = scan_y >= 8'd8 && scan_y < DBG_WEND && scan_y[1:0] != 2'd3 && scan_x >= 8'd16 && scan_x < 8'd48;
wire [31:0] dbg_word  = (scan_y[7:2] == 6'd2) ? dbg_src0 :
                        (scan_y[7:2] == 6'd3) ? dbg_en0_irq :
                        (scan_y[7:2] == 6'd4) ? dbg_en0_fiq :
                        (scan_y[7:2] == 6'd5) ? dbg_f0 :
                        (scan_y[7:2] == 6'd6) ? dbg_f4 :
                        (scan_y[7:2] == 6'd7) ? dbg_f8 :
                        (scan_y[7:2] == 6'd8) ? tr_trig_pc :
                        (scan_y[7:2] == 6'd9) ? {tr_dumps, tr_triggers, kt_count} :
                        (scan_y[7:2] == 6'd10) ? {rtc_valid, 7'd0, 3'd0, rtc_hour, 2'd0, rtc_min, 2'd0, rtc_sec} :
                        (scan_y[7:2] == 6'd11) ? rtc_date :
                        (scan_y[7:2] == 6'd12) ? {dbg_aud_l, dbg_aud_r} :
                        (scan_y[7:2] == 6'd13) ? {kt_dropped, 7'd0, tr_dumping, 16'd0} :
                        (scan_y[7:2] == 6'd14 + 6'(DBG_CNT)) ? dbg_loader_q :
                        (scan_y[7:2] == 6'd15 + 6'(DBG_CNT)) ? dbg_load_counts_q :
                        (scan_y[7:2] >= 6'd14 && scan_y[7:2] < 6'd14 + 6'(DBG_CNT)) ? dbg_cnt[$clog2(DBG_CNT)'(scan_y[7:2] - 6'd14)] :
                                                 32'd0;
// the second column (x 56..87): the marker, the exception counters, the
// five sampled words
localparam [7:0] DBG_W2END = 8'd8 + 8'd4 * 8'(1 + DBG_CNT2 + 5) - 8'd1;
wire        dbg_col2  = scan_x >= 8'd56;
wire        dbg_wrow2 = scan_y >= 8'd8 && scan_y < DBG_W2END && scan_y[1:0] != 2'd3 && scan_x >= 8'd56 && scan_x < 8'd88;
wire  [5:0] dbg_row2  = scan_y[7:2] - 6'd3;              // the counter's index; the marker is the row before
wire [31:0] dbg_word2 = (scan_y[7:2] == 6'd2)           ? DBG_COL2_MARK :
                        (dbg_row2 == 6'(DBG_CNT2))      ? dbg_swi_pc_q :
                        (dbg_row2 == 6'(DBG_CNT2 + 1))  ? dbg_dabt_pc_q :
                        (dbg_row2 == 6'(DBG_CNT2 + 2))  ? dbg_pabt_pc_q :
                        (dbg_row2 == 6'(DBG_CNT2 + 3))  ? dbg_und_pc_q :
                        (dbg_row2 == 6'(DBG_CNT2 + 4))  ? dbg_exc_cpsr_q :
                        (dbg_row2 < 6'(DBG_CNT2))       ? dbg_cnt2[$clog2(DBG_CNT2)'(dbg_row2)] :
                                                          32'd0;
// the row select and the word are registered once (scan_x/y hold for the 16
// clocks of a pixel); the row mux into the bit select was the worst setup path
logic        dbg_pcrow_q, dbg_strow_q, dbg_wrow_q;
logic [31:0] dbg_word_q;
logic [4:0]  dbg_col_q;
always_ff @(posedge clk_sys) begin
	dbg_pcrow_q <= dbg_pcrow;
	dbg_strow_q <= dbg_strow;
	dbg_wrow_q  <= dbg_wrow || dbg_wrow2;
	dbg_word_q  <= dbg_col2 ? dbg_word2 : dbg_word;
	dbg_col_q   <= dbg_col2 ? 5'(scan_x - 8'd56) : 5'(scan_x - 8'd16);
end
wire        dbg_bit   = dbg_pcrow_q ? dbg_pc_q[5'd31 - dbg_col_q] :
                        dbg_strow_q ? dbg_bits_q[3'd7 - 3'(dbg_col_q)] :
                                      dbg_word_q[5'd31 - dbg_col_q];
wire [15:0] dbg_rgb   = dbg_bit ? 16'hFFFF : 16'h0000;
`else
wire        dbg_on = 1'b0, dbg_pcrow_q = 1'b0, dbg_strow_q = 1'b0, dbg_wrow_q = 1'b0;
wire [15:0] dbg_rgb = 16'h0000;
assign dbg_trig = 1'b0;
wire unused_dbg = &{1'b0, cpu_dbg_pc, cpu_dbg_stall, cpu_dbg_dcache, cpu_dbg_icache, dbg_dma_owner, cpu_dbg_wfi, dbg_src0, dbg_en0_irq,
                    dbg_en0_fiq, tr_trig_pc, tr_dumps, tr_triggers, tr_dumping, kt_count, kt_dropped,
                    lcd_pix_ev, lcd_pix_y, status[8], ph_have, ph_state, ph_errors};
`endif
assign scan_rgb = (dbg_on && (dbg_pcrow_q || dbg_strow_q || dbg_wrow_q)) ? dbg_rgb : panel_rgb;

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
wire [1:0] sl = scale[1:0];
wire       scandoubler = (scale != 3'd0) || forced_scandoubler;

assign CLK_VIDEO = clk_sys;
assign VGA_SL = sl;

wire       vga_de;

video_mixer #(.LINE_LENGTH(256), .GAMMA(1)) video_mixer
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.ce_pix(ce_pix),
	.scandoubler(scandoubler),
	.hq2x(1'b0),           // HQ2x left out: its blend logic is unused and synthesis drops it
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
	.VGA_DE(vga_de)
);

// the framework's aspect ratio, vertical crop and integer scaling
// (sys/video_freak, wired as the NES and SNES cores do). Original is the
// panel's own ratio, 176:208 upright; the crop takes the upright 208 lines
// to 180, the 6x fit of 1080p, and is offered whenever it applies to the
// frame: not gated on HDMI_HEIGHT, which is the height Main lets the scaler
// fill, not the display's (docs/PROGRESS-LOG.md, 2026-10-22). The offset
// moves the 180-line window by that many lines from the centre.
always @(posedge CLK_VIDEO) begin
	crop_ok <= !scandoubler && !rotated;
end

wire [4:0] voff = (vcopt < 4'd6) ? {vcopt, 1'b0} : ({vcopt, 1'b0} - 5'd24);

video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(vga_de),
	.ARX((ar == 2'd0) ? (rotated ? 12'd208 : 12'd176) : {10'd0, ar - 2'd1}),
	.ARY((ar == 2'd0) ? (rotated ? 12'd176 : 12'd208) : 12'd0),
	.CROP_SIZE((crop_ok && vcrop_en) ? 12'd180 : 12'd0),
	.CROP_OFF(voff),
	.SCALE({1'b0, vscale})
);

// on while a flash image loads, and while the panel is lit
assign LED_USER = ioctl_download | lcd_on;

endmodule
