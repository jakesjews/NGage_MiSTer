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
// There is no CPU yet (the UPP_WD2 ASIC is still being reverse engineered).
// What is here:
//  * the OSD: the two NOR flash images are loaded into DDR3 (CS0 at
//    0x31000000, CS1 at 0x32000000); an MMC image is mounted on hps_io's
//    SD slot 0; controls, rotation, aspect ratio, scandoubler, reset;
//  * the display module (lcd_panel) and its scan-out (video_out), with
//    lcd_testgen standing in for the CPU: it draws a test picture through
//    the panel's 8080 bus and shows the keypad state as the matrix reports
//    it;
//  * the keypad matrix, fed from the joystick and keyboard;
//  * the MMC card on the SD slot (it loads the CID/CSD sidecar when an image
//    is mounted; its bus is idle until the ASIC's MMC host exists);
//  * the two NOR flash chips, idle until there is a CPU, with their memory
//    ports unconnected until there is a DDR3/SDRAM controller for them.
// clk_sys is 104 MHz: 4 x 26 MHz, the phone's reference, so the MCU clock
// (104 MHz), the flash and timer clock (104/3) and the MMC clock (26/3)
// divide from it exactly.

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;

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

assign LED_POWER = 0;
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
	"S0,IMGBIN,Mount MMC card;",
	"-;",
	"O[2:1],Rotate,Off,Clockwise,Anticlockwise;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"J,5,7,OK,Left soft,Right soft,Menu,Call,End,*,#,Clear,Edit,Power;",
	"jn,A,B,X,L,R,Start,Select;",
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

wire         ioctl_download;
wire  [15:0] ioctl_index;
wire         ioctl_wr;
wire  [26:0] ioctl_addr;
wire  [15:0] ioctl_dout;
wire         ioctl_wait;

wire   [0:0] img_mounted;
wire         img_readonly;
wire  [63:0] img_size;
wire  [31:0] sd_lba[1];
wire   [5:0] sd_blk_cnt[1];
wire   [0:0] sd_rd, sd_wr, sd_ack;
wire  [12:0] sd_buff_addr;
wire  [15:0] sd_buff_dout;
wire  [15:0] sd_buff_din[1];
wire         sd_buff_wr;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1), .VDNUM(1)) hps_io
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
	.info_req(1'b0),
	.info(8'd0),
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
wire reset = sys_reset | status[0] | buttons[1] | ioctl_download;

///////////////////////   FLASH IMAGES   /////////////////////////

assign DDRAM_CLK = clk_sys;

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
	.ddram_busy(DDRAM_BUSY),
	.ddram_burstcnt(DDRAM_BURSTCNT),
	.ddram_addr(DDRAM_ADDR),
	.ddram_din(DDRAM_DIN),
	.ddram_be(DDRAM_BE),
	.ddram_we(DDRAM_WE),
	.ddram_rd(DDRAM_RD),
	.loaded()                    // for the CPU: both images are in
);

// The flash chips, on CS0 and CS1. Their bus side waits for the CPU and their
// memory side for the controller that will serve it from the images above.
wire [15:0] cs0_mem_rdata = 16'hFFFF, cs1_mem_rdata = 16'hFFFF;
wire        cs0_mem_ack = 1'b0, cs1_mem_ack = 1'b0;

nor_flash #(.AW(23), .DEVICE_ID(16'h22F8)) flash_cs0
(
	.clk(clk_sys),
	.reset(reset),
	.rst_n(1'b1),
	.bus_req(1'b0),
	.bus_we(1'b0),
	.bus_addr(23'd0),
	.bus_wdata(16'd0),
	.bus_rdata(),
	.bus_ack(),
	.mem_req(),
	.mem_we(),
	.mem_addr(),
	.mem_wdata(),
	.mem_rdata(cs0_mem_rdata),
	.mem_ack(cs0_mem_ack),
	.busy()
);

nor_flash #(.AW(22), .DEVICE_ID(16'h22FA)) flash_cs1
(
	.clk(clk_sys),
	.reset(reset),
	.rst_n(1'b1),
	.bus_req(1'b0),
	.bus_we(1'b0),
	.bus_addr(22'd0),
	.bus_wdata(16'd0),
	.bus_rdata(),
	.bus_ack(),
	.mem_req(),
	.mem_we(),
	.mem_addr(),
	.mem_wdata(),
	.mem_rdata(cs1_mem_rdata),
	.mem_ack(cs1_mem_ack),
	.busy()
);

///////////////////////   MMC CARD   /////////////////////////////

wire mmc_active;

// The card's bus: CLK low and CMD/DAT0 pulled up until the ASIC's MMC host
// drives them.
mmc_card mmc_card
(
	.clk(clk_sys),
	.reset(sys_reset),
	.mmc_clk(1'b0),
	.cmd_i(1'b1),
	.cmd_o(),
	.cmd_oe(),
	.dat_i(1'b1),
	.dat_o(),
	.dat_oe(),
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
	.sd_buff_wr(sd_buff_wr)
);

assign LED_DISK = {1'b0, mmc_active};

///////////////////////   KEYS   /////////////////////////////////

wire [ngage_keys::NKEYS-1:0] keys;
wire       power_key;
wire [4:0] kp_col_oe, kp_col_out;
wire [5:0] kp_row_in;
wire       pwronx;

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
	.row_oe(6'd0),
	.row_out(6'd0),
	.col_in(),
	.row_in(kp_row_in),
	.pwronx(pwronx)
);

///////////////////////   DISPLAY   //////////////////////////////

wire       lcd_csx, lcd_dcx, lcd_wrx, lcd_rdx, lcd_resx;
wire [7:0] lcd_d;

lcd_testgen lcd_testgen
(
	.clk(clk_sys),
	.reset(reset),
	.csx(lcd_csx),
	.dcx(lcd_dcx),
	.wrx(lcd_wrx),
	.rdx(lcd_rdx),
	.resx(lcd_resx),
	.d(lcd_d),
	.col_oe(kp_col_oe),
	.col_out(kp_col_out),
	.row_in(kp_row_in),
	.pwronx(pwronx)
);

wire        scan_en;
wire  [7:0] scan_x, scan_y;
wire [15:0] scan_rgb;
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
	.d_o(),
	.d_oe(),
	.te(),
	.te_ext_sel(1'b0),
	.te_ext(1'b0),
	.scan_en(scan_en),
	.scan_x(scan_x),
	.scan_y(scan_y),
	.scan_rgb(scan_rgb),
	.display_on(lcd_on)
);

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
