// Simulation stand-in for sys/hps_io.sv with the ports NGage.sv uses. The C++
// bench sets the sim_* registers and reads the core's requests directly.
module hps_io #(
	parameter CONF_STR      = "",
	parameter CONF_STR_BRAM = 0,
	parameter PS2DIV        = 0,
	parameter WIDE          = 0,
	parameter VDNUM         = 1,
	parameter BLKSZ         = 2,
	parameter PS2WE         = 0,
	parameter F12KEYMOD     = 0
) (
	input  wire         clk_sys,
	inout  wire  [45:0] HPS_BUS,
	inout  wire  [35:0] EXT_BUS,
	inout  wire  [21:0] gamma_bus,

	output wire         forced_scandoubler,
	output wire   [1:0] buttons,
	output wire [127:0] status,
	input  wire  [15:0] status_menumask,
	input  wire [127:0] status_in,
	input  wire         status_set,
	input  wire         info_req,
	input  wire   [7:0] info,
	input  wire         new_vmode,
	input  wire         video_rotated,

	input  wire         ps2_kbd_clk_in,
	input  wire         ps2_kbd_data_in,
	input  wire         ps2_mouse_clk_in,
	input  wire         ps2_mouse_data_in,
	input  wire   [2:0] ps2_kbd_led_status,
	input  wire   [2:0] ps2_kbd_led_use,
	input  wire  [15:0] joystick_0_rumble,
	input  wire  [15:0] joystick_1_rumble,
	input  wire  [15:0] joystick_2_rumble,
	input  wire  [15:0] joystick_3_rumble,
	input  wire  [15:0] joystick_4_rumble,
	input  wire  [15:0] joystick_5_rumble,

	output wire  [10:0] ps2_key,
	output wire  [31:0] joystick_0,
	output wire  [31:0] joystick_1,

	output wire         ioctl_download,
	output wire  [15:0] ioctl_index,
	output wire         ioctl_wr,
	output wire  [26:0] ioctl_addr,
	output wire  [15:0] ioctl_dout,
	input  wire         ioctl_wait,
	input  wire         ioctl_upload_req,
	input  wire   [7:0] ioctl_upload_index,
	input  wire  [15:0] ioctl_din,

	output wire [VDNUM-1:0] img_mounted,
	output wire             img_readonly,
	output wire      [63:0] img_size,
	input  wire      [31:0] sd_lba[VDNUM],
	input  wire       [5:0] sd_blk_cnt[VDNUM],
	input  wire [VDNUM-1:0] sd_rd,
	input  wire [VDNUM-1:0] sd_wr,
	output wire [VDNUM-1:0] sd_ack,
	output wire      [12:0] sd_buff_addr,
	output wire      [15:0] sd_buff_dout,
	input  wire      [15:0] sd_buff_din[VDNUM],
	output wire             sd_buff_wr,

	// RTC, MSM6242B layout (BCD); bit 64 toggles with each time sent
	output wire      [64:0] RTC
);
	reg [127:0] sim_status /* verilator public_flat_rw */ = 0;
	reg   [1:0] sim_buttons /* verilator public_flat_rw */ = 0;
	reg  [10:0] sim_ps2_key /* verilator public_flat_rw */ = 0;
	reg  [31:0] sim_joy0 /* verilator public_flat_rw */ = 0;
	reg  [31:0] sim_joy1 /* verilator public_flat_rw */ = 0;
	reg         sim_scandoubler /* verilator public_flat_rw */ = 0;

	reg         sim_download /* verilator public_flat_rw */ = 0;
	reg  [15:0] sim_index /* verilator public_flat_rw */ = 0;
	reg         sim_wr /* verilator public_flat_rw */ = 0;
	reg  [26:0] sim_addr /* verilator public_flat_rw */ = 0;
	reg  [15:0] sim_dout /* verilator public_flat_rw */ = 0;
	wire        sim_wait /* verilator public_flat_rd */ = ioctl_wait;

	// The benches number the slots by device: slot 0 is the MMC card and slot 1
	// the C: save file. On the MiSTer the save is image 0 (boot.vhd) and the
	// card image 1, so the two are crossed here (CARD and SAVE, the port index).
	localparam int CARD = VDNUM > 1 ? 1 : 0;
	localparam int SAVE = 0;
	// sim_mounted and sim_sd_ack: a bit a slot (slot 0, the MMC card, is bit 0)
	reg [VDNUM-1:0] sim_mounted /* verilator public_flat_rw */ = 0;
	reg         sim_readonly /* verilator public_flat_rw */ = 0;
	reg  [63:0] sim_size /* verilator public_flat_rw */ = 0;
	wire [31:0] sim_sd_lba /* verilator public_flat_rd */ = sd_lba[CARD];
	wire  [5:0] sim_sd_blk_cnt /* verilator public_flat_rd */ = sd_blk_cnt[CARD];
	wire        sim_sd_rd /* verilator public_flat_rd */ = sd_rd[CARD];
	wire        sim_sd_wr /* verilator public_flat_rd */ = sd_wr[CARD];
	wire [15:0] sim_sd_din /* verilator public_flat_rd */ = sd_buff_din[CARD];
	// slot 1 (the C: save file), when there is one
	wire [31:0] sim_sd_lba1 /* verilator public_flat_rd */ = sd_lba[SAVE];
	wire  [5:0] sim_sd_blk_cnt1 /* verilator public_flat_rd */ = sd_blk_cnt[SAVE];
	wire        sim_sd_rd1 /* verilator public_flat_rd */ = VDNUM > 1 && sd_rd[SAVE];
	wire        sim_sd_wr1 /* verilator public_flat_rd */ = VDNUM > 1 && sd_wr[SAVE];
	reg [VDNUM-1:0] sim_sd_ack /* verilator public_flat_rw */ = 0;
	reg  [12:0] sim_sd_addr /* verilator public_flat_rw */ = 0;
	reg  [15:0] sim_sd_dout /* verilator public_flat_rw */ = 0;
	reg         sim_sd_wr_buf /* verilator public_flat_rw */ = 0;
	wire        sim_info_req /* verilator public_flat_rd */ = info_req;
	wire  [7:0] sim_info /* verilator public_flat_rd */ = info;
	reg  [64:0] sim_rtc /* verilator public_flat_rw */ = 0;

	assign forced_scandoubler = sim_scandoubler;
	assign buttons      = sim_buttons;
	assign status       = sim_status;
	assign ps2_key      = sim_ps2_key;
	assign joystick_0   = sim_joy0;
	assign joystick_1   = sim_joy1;
	assign ioctl_download = sim_download;
	assign ioctl_index  = sim_index;
	assign ioctl_wr     = sim_wr;
	assign ioctl_addr   = sim_addr;
	assign ioctl_dout   = sim_dout;
	assign img_mounted  = VDNUM > 1 ? VDNUM'({sim_mounted[0], sim_mounted[VDNUM > 1 ? 1 : 0]}) : sim_mounted;
	assign img_readonly = sim_readonly;
	assign img_size     = sim_size;
	assign sd_ack       = VDNUM > 1 ? VDNUM'({sim_sd_ack[0], sim_sd_ack[VDNUM > 1 ? 1 : 0]}) : sim_sd_ack;
	assign sd_buff_addr = sim_sd_addr;
	assign sd_buff_dout = sim_sd_dout;
	assign sd_buff_wr   = sim_sd_wr_buf;
	assign RTC          = sim_rtc;

	// gamma table off, as hps_io leaves it until the menu loads one
	assign gamma_bus[20:0] = {clk_sys, 20'd0};
endmodule
