// Bench for the whole core (module emu of NGage.sv): the shell with the board
// devices, stand-ins for hps_io and video_mixer (sim/stubs), and a model of
// the DDRAM port.
//
//   Vemu [--out DIR]
//
//  * the test picture lcd_testgen draws through the panel's bus comes out of
//    the MiSTer video outputs, upright, 176x208, against the picture built
//    here from the same pattern;
//  * held joystick buttons and keyboard keys reach the matrix, the scan finds
//    them, and their boxes change colour (and back when released);
//  * rotation turns the frame and the aspect ratio with it;
//  * flash images loaded through ioctl land in DDR3 at 0x31000000 (CS0) and
//    0x32000000 (CS1), byte for byte, with the port busy at random;
//  * the CPU stays in reset until both images are in, then runs the small
//    program at the start of the CS0 image (a store to SDRAM, a load back, a
//    second store), and is held again while the memory test runs;
//  * mounting an MMC image makes the card read its last block (the sidecar);
//  * the memory system: the SDRAM chip model on the SDRAM pins and the DDRAM
//    port model behind DDR3; with "Memory test" on, wb_selftest passes over
//    SDRAM, on-chip RAM, the EMIF block, CS2 and the flash path (built with
//    small regions) and reports it on the OSD; with SDRAM bits flipped under
//    it, it reports a failure; the SDRAM and DDRAM models see no timing or
//    protocol error.
// Frames go to DIR as PPM.
#include "Vemu.h"
#include "Vemu___024root.h"
#include "verilated.h"
#include "common.h"
#include "ddram_model.h"
#include "sdram_model.h"
#include "phoenix_stream.h"
#include <fstream>

#include <cstring>
#include <utility>
#include <vector>
#include <string>

namespace {

constexpr int W = 176, H = 208;

// the same picture as lcd_testgen.sv's pattern(), 12 bpp
uint16_t pattern(int x, int y, uint32_t st) {
	int x3 = 3 * x;
	if (x < 8 && y < 8) return 0xF00;
	if (x == 0 || y == 0 || x == 175 || y == 207) return 0xFFF;
	if (y < 64) {
		static const uint16_t bars[8] = {0xFFF, 0xFF0, 0x0FF, 0x0F0, 0xF0F, 0xF00, 0x00F, 0x000};
		int b = x3 >> 6;
		return bars[b > 7 ? 7 : b];
	}
	if (y < 128) {
		int r = x3 >> 5;
		if (r > 15) r = 15;
		return (uint16_t)(r << 8 | ((y - 64) >> 2) << 4 | 8);
	}
	int c = -1, r = -1;
	for (int i = 0; i < 5; i++) if (x >= 8 + 34 * i && x < 36 + 34 * i) c = i;
	for (int i = 0; i < 6; i++) if (y >= 132 + 12 * i && y < 142 + 12 * i) r = i;
	if (c >= 0 && r >= 0) {
		int k = r * 5 + c;
		static const uint32_t fitted = 0x39CEF7FFu;  // 30'b11100_11100_11101_11101_11111_11111
		if (k == 20) return st >> k & 1 ? 0xF00 : 0x400;
		if (fitted >> k & 1) return st >> k & 1 ? 0xFF0 : 0x226;
	}
	return 0x222;
}
// 12 bpp through the panel's reset RGBSET table, as lcd_testgen loads it
uint16_t to565(uint16_t p) {
	auto l5 = [](int v) { return v == 15 ? 31 : v * 2; };
	auto l6 = [](int v) { return v == 15 ? 63 : v * 4; };
	return (uint16_t)(l5(p >> 8) << 11 | l6((p >> 4) & 15) << 5 | l5(p & 15));
}

struct Bench {
	Vemu *t = new Vemu;
	Vemu___024root *r;
	sim::Rng rng{11};
	uint64_t clocks = 0;
	// DDR3, 0x31000000 to 0x327FFFFF
	static constexpr uint32_t DDR_BASE = 0x31000000u, DDR_SIZE = 0x01800000u;
	DdramModel dm{40u << 20, 5};
	uint8_t *ddr;                    // the flash windows in dm
	uint64_t ddr_writes = 0;
	bool ddr_stray = false;
	SdramChip chip{9};
	// OSD info messages
	std::vector<int> infos;
	bool info_prev = false;
	// MMC image served on SD slot 0
	std::vector<uint8_t> img;
	int sd_state = 0, sd_delay = 0, sd_word = 0, sd_words = 0;
	std::vector<uint32_t> sd_lbas;
	// slot 1: the CS1 save file
	std::vector<uint8_t> img1;
	int s1_state = 0, s1_delay = 0, s1_word = 0, s1_words = 0;
	uint32_t s1_lba = 0;
	uint64_t s1_reads = 0, s1_writes = 0;
	bool disk_led = false;
	// writes the CPU makes on the Wishbone port (address, data)
	std::vector<std::pair<uint32_t, uint32_t>> cpu_writes;

	Bench() : r(t->rootp) {
		ddr = &dm.mem[DDR_BASE - DdramModel::BASE];
		memset(ddr, 0x5A, DDR_SIZE);
		dm.prof.busy_pct = 25;
		t->CLK_50M = 0; t->RESET = 1; t->DDRAM_BUSY = 0; t->DDRAM_DOUT = 0; t->DDRAM_DOUT_READY = 0;
		t->HDMI_WIDTH = 0; t->HDMI_HEIGHT = 0; t->OSD_STATUS = 0; t->SD_MISO = 1; t->SD_CD = 1;
		t->UART_CTS = 0; t->UART_RXD = 1; t->UART_DSR = 0; t->USER_IN = 0x7F; t->CLK_AUDIO = 0;
		t->eval();
		for (int i = 0; i < 8; i++) tick();
		t->RESET = 0;
	}
	~Bench() { t->final(); delete t; }

	// slot 1, served when slot 0 is quiet: reads of blk_cnt + 1 blocks; a
	// write request is only counted (nothing should ask for one here)
	void download(int index, const std::vector<uint8_t> &data, bool settle = true) {
		auto &h = *r;
		h.emu__DOT__hps_io__DOT__sim_index = index;
		h.emu__DOT__hps_io__DOT__sim_download = 1;
		ticks(5);
		auto wait = [&]() {
			uint64_t end = clocks + 10000000;
			while (h.emu__DOT__hps_io__DOT__sim_wait && clocks < end) tick();
			CHECK(clocks < end, "download backpressure timeout");
		};
		for (size_t a = 0; a < data.size(); a += 2) {
			wait();
			h.emu__DOT__hps_io__DOT__sim_addr = (uint32_t)a;
			h.emu__DOT__hps_io__DOT__sim_dout = data[a] | ((a + 1 < data.size() ? data[a + 1] : 0x7A) << 8);
			h.emu__DOT__hps_io__DOT__sim_wr = 1;
			tick(); h.emu__DOT__hps_io__DOT__sim_wr = 0;
			ticks(rng.range(1, 6));
		}
		wait(); ticks(5);
		h.emu__DOT__hps_io__DOT__sim_download = 0;
		ticks(5);
		if (!settle) return;             // as Main: on to the next file at once
		uint64_t end = clocks + 1000000;
		while (h.emu__DOT__ph_busy && clocks < end) tick();
		CHECK(clocks < end, "Phoenix patch/verify timeout");
		ticks(20);
	}

	void s1_step() {
		auto &h = *r;
		if (h.emu__DOT__hps_io__DOT__sim_sd_wr1) s1_writes++;
		switch (s1_state) {
		case 0:
			if (h.emu__DOT__hps_io__DOT__sim_sd_rd1 && sd_state == 0) {
				s1_lba = h.emu__DOT__hps_io__DOT__sim_sd_lba1;
				s1_words = 256 * (h.emu__DOT__hps_io__DOT__sim_sd_blk_cnt1 + 1);
				s1_delay = 40;
				s1_state = 1;
			}
			break;
		case 1:
			if (--s1_delay == 0) { h.emu__DOT__hps_io__DOT__sim_sd_ack = 2; s1_word = 0; s1_delay = 3; s1_state = 2; }
			break;
		case 2:
			if (--s1_delay > 0) break;
			s1_delay = 3;
			if (s1_word < s1_words) {
				size_t off = (size_t)s1_lba * 512 + s1_word * 2;
				h.emu__DOT__hps_io__DOT__sim_sd_addr = s1_word;
				h.emu__DOT__hps_io__DOT__sim_sd_dout = (uint16_t)(img1[off] | img1[off + 1] << 8);
				h.emu__DOT__hps_io__DOT__sim_sd_wr_buf = 1;
				s1_word++;
			} else {
				h.emu__DOT__hps_io__DOT__sim_sd_ack = 0;
				s1_reads++;
				s1_state = 0;
			}
			break;
		}
	}

	void sd_step() {
		r->emu__DOT__hps_io__DOT__sim_sd_wr_buf = 0;
		r->emu__DOT__hps_io__DOT__sim_mounted = 0;
		if (s1_state) { s1_step(); return; }
		s1_step();
		switch (sd_state) {
		case 0:
			if (r->emu__DOT__hps_io__DOT__sim_sd_rd) {
				sd_lbas.push_back(r->emu__DOT__hps_io__DOT__sim_sd_lba);
				sd_words = 256 * (r->emu__DOT__hps_io__DOT__sim_sd_blk_cnt + 1);
				sd_delay = 100;
				sd_state = 1;
			}
			break;
		case 1:
			if (--sd_delay == 0) { r->emu__DOT__hps_io__DOT__sim_sd_ack = 1; sd_word = 0; sd_delay = 4; sd_state = 2; }
			break;
		case 2:
			if (--sd_delay > 0) break;
			sd_delay = 4;
			if (sd_word < sd_words) {
				size_t off = (size_t)sd_lbas.back() * 512 + sd_word * 2;
				r->emu__DOT__hps_io__DOT__sim_sd_addr = sd_word;
				r->emu__DOT__hps_io__DOT__sim_sd_dout = off + 1 < img.size() ? (uint16_t)(img[off] | img[off + 1] << 8) : 0;
				r->emu__DOT__hps_io__DOT__sim_sd_wr_buf = 1;
				sd_word++;
			} else {
				r->emu__DOT__hps_io__DOT__sim_sd_ack = 0;
				sd_state = 0;
			}
			break;
		}
	}

	void tick() {
		t->DDRAM_BUSY = dm.busy;
		t->DDRAM_DOUT = dm.dout;
		t->DDRAM_DOUT_READY = dm.dout_ready;
		t->SDRAM_DQ = chip.sample(clocks + 1);
		t->eval();
		// the DDRAM port takes a write at an edge where WE is high and BUSY low
		// (registers start at 0 on the FPGA, at random here: skip the reset)
		if (clocks > 16) {
			if (t->DDRAM_WE && !t->DDRAM_BUSY) {
				uint64_t byte = (uint64_t)t->DDRAM_ADDR << 3;
				for (int i = 0; i < 8; i++) {
					if (!(t->DDRAM_BE >> i & 1)) continue;
					uint64_t a = byte + i;
					if (a < DDR_BASE || a >= (uint64_t)DDR_BASE + DDR_SIZE) ddr_stray = true;
				}
				ddr_writes++;
			}
			dm.step(t->DDRAM_RD, t->DDRAM_WE, t->DDRAM_ADDR, t->DDRAM_BURSTCNT, t->DDRAM_DIN, t->DDRAM_BE);
		}
		t->CLK_50M = 1; t->eval();
		clocks++;
		SdramPins p;
		p.cs_n = t->SDRAM_nCS; p.ras_n = t->SDRAM_nRAS; p.cas_n = t->SDRAM_nCAS; p.we_n = t->SDRAM_nWE;
		p.ba = t->SDRAM_BA; p.a = t->SDRAM_A; p.dqm = t->SDRAM_DQML | t->SDRAM_DQMH << 1;
		p.dq_oe = t->SDRAM_DQ__en != 0; p.dq_o = t->SDRAM_DQ__out;
		if (!t->SDRAM_CKE) sim::fail("SDRAM CKE low");
		if (clocks > 2) chip.edge(clocks, p);
		bool ir = r->emu__DOT__hps_io__DOT__sim_info_req;
		if (ir && !info_prev) infos.push_back(r->emu__DOT__hps_io__DOT__sim_info);
		info_prev = ir;
		if (t->LED_DISK & 1) disk_led = true;
		if (!r->emu__DOT__test_on && r->emu__DOT__wb_cyc && r->emu__DOT__wb_we && r->emu__DOT__wb_ack)
			cpu_writes.emplace_back(r->emu__DOT__wb_adr, r->emu__DOT__wb_dat_w);
		sd_step();
		t->CLK_50M = 0; t->eval();
	}
	void ticks(uint64_t n) { while (n--) tick(); }

	// the next whole frame as the outputs show it: the pixels under DE
	sim::Image frame() {
		bool vs_prev = t->VGA_VS;
		// to the start of a frame
		for (;;) { tick(); if (t->VGA_VS && !vs_prev) break; vs_prev = t->VGA_VS; }
		std::vector<std::vector<uint32_t>> rows;
		std::vector<uint32_t> row;
		bool de_prev = false;
		vs_prev = true;
		for (;;) {
			tick();
			if (t->VGA_VS && !vs_prev) break;
			vs_prev = t->VGA_VS;
			if (!t->CE_PIXEL) continue;
			if (t->VGA_DE) row.push_back((uint32_t)t->VGA_R << 16 | (uint32_t)t->VGA_G << 8 | t->VGA_B);
			else if (de_prev) { rows.push_back(row); row.clear(); }
			de_prev = t->VGA_DE;
		}
		int h = (int)rows.size(), w = h ? (int)rows[0].size() : 0;
		sim::Image im(w, h);
		for (int y = 0; y < h; y++) {
			if ((int)rows[y].size() != w) sim::fail("frame line %d has %zu pixels, line 0 %d", y, rows[y].size(), w);
			for (int x = 0; x < w && x < (int)rows[y].size(); x++)
				im.set(x, y, (uint8_t)(rows[y][x] >> 16), (uint8_t)(rows[y][x] >> 8), (uint8_t)rows[y][x]);
		}
		return im;
	}
};

// colour of the memory-test status square (panel pixels x, y < 12) in the
// frames compared, RGB565, or -1: there is none while the test is off
// (yellow = running, green = passed, magenta = errors)
int square565 = -1;

// compare a captured frame with the pattern for key state st, turned by rot
int compare(const sim::Image &got, uint32_t st, int rot, const char *what, bool activity = false) {
	bool turned = rot == 1 || rot == 2;
	int w = turned ? H : W, h = turned ? W : H;
	if (got.w != w || got.h != h) { sim::fail("%s: frame is %dx%d, want %dx%d", what, got.w, got.h, w, h); return -1; }
	int bad = 0;
	for (int y = 0; y < h; y++)
		for (int x = 0; x < w; x++) {
			int sx = x, sy = y;
			if (rot == 1) { sx = y; sy = H - 1 - x; }
			if (rot == 2) { sx = W - 1 - y; sy = x; }
			bool dot = activity && sx >= 164 && sx < 170 && sy >= 4 && sy < 10;
			uint32_t want = sim::rgb565_to_888(dot ? 0x07E0 :
				(square565 >= 0 && sx < 12 && sy < 12) ? (uint16_t)square565 : to565(pattern(sx, sy, st)));
			if (got.get(x, y) != want && bad++ < 4)
				sim::fail("%s: pixel (%d,%d) = %06x, want %06x", what, x, y, got.get(x, y), want);
		}
	if (bad > 4) sim::fail("%s: %d pixels differ", what, bad);
	return bad;
}

}  // namespace

// Exercise the actual ioctl -> shared DDR port -> version read -> patch path.
// Separate shell instance leaves the existing video/CPU regression independent.
static void test_phoenix(const std::string &out) {
	Bench b;
	auto &r = *b.r;
	b.ticks(30000);
	r.emu__DOT__hps_io__DOT__sim_rtc[0] = 0x01120000;
	r.emu__DOT__hps_io__DOT__sim_rtc[1] = 0x00000406;
	r.emu__DOT__hps_io__DOT__sim_rtc[2] = 1;
	b.ticks(20);
	static const uint32_t prog[] = {0xE3A0040A,0xE59F1010,0xE5801000,0xE5902000,
	                                0xE2822001,0xE5802004,0xEAFFFFFE,0x12345678};
	phoenix::Bytes code(sizeof prog); memcpy(code.data(), prog, sizeof prog);
	auto mcu = phoenix::mcu(); phoenix::record(mcu, 0x14, 0, code);
	// Framework order with no launcher: Main sends boot0.rom, the MCU file
	// (index 0), and then boot1.rom, the language pack (file number 1 in index
	// bits 7:6, no menu index: 0x40).
	b.download(0, mcu);
	CHECK(r.emu__DOT__cpu_reset && !r.emu__DOT__ph_ready, "MCU alone cannot boot");
	CHECK_EQ(b.ddr[0x85], 255, "Phoenix FF gap");
	CHECK_EQ(b.ddr[0xFFFFFF], 255, "CS0 fill reaches last byte");
	CHECK_EQ(b.ddr[0x13FFFFF], 255, "CS1 firmware fill reaches last byte");
	CHECK_EQ(b.ddr[0x1400000], 0x5A, "Phoenix fill stops before C:");
	CHECK_EQ(b.ddr[0x80], 1, "21 record data");
	CHECK_EQ(b.ddr[0x1000003], 0x11, "14 CS1 record data");
	b.download(0x40, phoenix::language());
	CHECK(r.emu__DOT__ph_ready && r.emu__DOT__cpu_reset, "both files still need C:");
	CHECK_EQ(b.ddr[0xF00001], 6, "language mapped");
	CHECK_EQ(std::count(b.infos.begin(), b.infos.end(), 10), 1, "4.60 OSD message");
	CHECK_EQ(std::count(b.infos.begin(), b.infos.end(), 9), 0, "valid checksums");
	std::ifstream hex("rtl/mister/phoenix_patch.hex");
	phoenix::Bytes patch; unsigned x;
	while (hex >> std::hex >> x) patch.push_back(x);
	CHECK(!patch.empty(), "patch fixture read");
	for (size_t p = 0; p < patch.size() && patch[p] != 255;) {
		unsigned chip = patch[p++], off = 0, n = 0;
		for (int i = 0; i < 3; i++) off = (off << 8) | patch[p++];
		for (int i = 0; i < 4; i++) n = (n << 8) | patch[p++];
		CHECK(!memcmp(b.ddr + chip * 0x1000000 + off, patch.data() + p, n), "full patch payload in DDR3"); p += n;
	}
	// Framework order: both ROMs, then boot0.vhd. Only C: is loaded.
	b.img1.assign(4u << 20, 255);
	r.emu__DOT__hps_io__DOT__sim_size = b.img1.size();
	r.emu__DOT__hps_io__DOT__sim_readonly = 0;
	r.emu__DOT__hps_io__DOT__sim_mounted = 2;
	b.ticks(100);
	CHECK(r.emu__DOT__cpu_reset && r.emu__DOT__fs_loading, "CPU held through C: load");
	uint64_t end = b.clocks + 20000000;
	while (r.emu__DOT__fs_loading && b.clocks < end) b.tick();
	CHECK(b.clocks < end, "4 MB mount finished");
	CHECK_EQ(b.s1_reads, 1024, "4 MB save reads");
	CHECK(!memcmp(b.ddr + 0x1400000, b.img1.data(), b.img1.size()), "C: image loaded");
	CHECK_EQ(b.ddr[0x1000003], 0x11, "save preserved Phoenix firmware");
	CHECK(r.emu__DOT__c_blank, "blank C: enables first-boot fast format");
	b.ticks(10000);
	CHECK(!r.emu__DOT__cpu_reset && b.cpu_writes.size() == 2, "CPU starts only after patch and save");
	// Reproduce the board's suspected single MCU resend during a running phone.
	// The warning must arrive after transfer and the diagnostics remain readable
	// with the CPU held in reset. Sending its companion restores the pair.
	b.download(1, mcu);
	CHECK(r.emu__DOT__cpu_reset && !r.emu__DOT__ph_ready, "single MCU resend waits for companion");
	CHECK_EQ(std::count(b.infos.begin(), b.infos.end(), 12), 1, "reload both OSD message");
	r.emu__DOT__hps_io__DOT__sim_status[0] = 1u << 8;
	b.frame(); auto reload = b.frame();
	reload.write_ppm(out + "/top_phoenix_reload.ppm");
	auto word = [](const auto &frame, int row) {
		uint32_t value = 0;
		for (int x = 16; x < 48; x++) value = (value << 1) | (frame.get(x, row) == 0xFFFFFF);
		return value;
	};
	CHECK_EQ(word(reload, 189), (1u << 28) | (1u << 22) | (4u << 19), "MCU-only pair and retained reload note");
	CHECK_EQ(word(reload, 193), 0x21000000u, "two MCU starts, one language start, no errors");
	b.download(2, phoenix::language()); b.ticks(10000);
	CHECK(r.emu__DOT__ph_ready && !r.emu__DOT__cpu_reset, "companion reload releases reset");
	CHECK_EQ(std::count(b.infos.begin(), b.infos.end(), 12), 1, "companion needs no reload warning");

	// Manual order: the save stays mounted while language arrives before MCU.
	// Picked in the OSD under their .rom names: the second extension of F2 and
	// F1 puts 1 in index bits 7:6 above the menu index (0x42, 0x41).
	b.download(0x42, phoenix::language());
	CHECK(r.emu__DOT__cpu_reset && !r.emu__DOT__ph_ready, "new pair invalidates old firmware");
	CHECK_EQ(std::count(b.infos.begin(), b.infos.end(), 12), 2, "language resend also requests both files");
	b.download(0x41, mcu);
	b.ticks(10000);
	CHECK(r.emu__DOT__ph_ready && !r.emu__DOT__cpu_reset, "reverse order with save already mounted");
	CHECK(!memcmp(b.ddr + 0x1400000, b.img1.data(), b.img1.size()), "firmware reload preserved C:");

	b.download(1, phoenix::mcu(false)); b.download(2, phoenix::language());
	CHECK(r.emu__DOT__cpu_reset && !r.emu__DOT__ph_ready, "unknown version holds CPU");
	CHECK_EQ(std::count(b.infos.begin(), b.infos.end(), 11), 1, "unknown version OSD message");
	CHECK_EQ(b.ddr[0x9E4D4], 255, "unknown version unpatched");
	b.download(1, phoenix::mcu(true, true));
	CHECK(r.emu__DOT__cpu_reset && !r.emu__DOT__ph_ready, "bad checksum holds CPU");
	CHECK_EQ(std::count(b.infos.begin(), b.infos.end(), 9), 1, "damaged file OSD message");
	CHECK(!b.ddr_stray && !b.dm.protocol_errors, "Phoenix shared DDR protocol");
	CHECK_EQ(b.s1_writes, 0, "firmware loads did not dirty C: save");
	// Read the appended words through the actual video pixels, including while
	// CPU reset. The first 12 words and counters 0..24 are unchanged. F4 counts saturate at 15.
	r.emu__DOT__hps_io__DOT__sim_status[0] = (1u << 8) | 1u;
	// boot2.rom and boot3.rom (0x80, 0xC0) are no firmware files: not counted.
	b.download(0x80, {}); b.download(0xC0, {});
	b.download(3, {}); b.download(3, {});
	for (int i = 0; i < 20; i++) b.download(4, {});
	b.frame(); auto diag = b.frame();
	diag.write_ppm(out + "/top_phoenix_loader.ppm");
	CHECK_EQ(word(diag, 189), (4u << 22) | (1u << 19), "loader status while CPU reset");
	CHECK_EQ(word(diag, 193), 0x542F0001u, "loader starts saturate; full error count visible");
	printf("Phoenix shell: records, patches, version/damage rejection, resend recovery, overlay history and C: isolation (%llu clocks)\n", (unsigned long long)b.clocks);
}

// The boot files as Main sends them when the core starts: its reset bit
// (status 0) is held, boot0.rom and boot1.rom go out back to back with no
// wait for the loader's verify and patch stage, boot0.vhd is mounted straight
// after them, the clock follows, and only then is the reset bit released.
static void test_boot_files() {
	Bench b;
	auto &r = *b.r;
	b.ticks(30000);
	r.emu__DOT__hps_io__DOT__sim_status[0] = 1;
	static const uint32_t prog[] = {0xE3A0040A,0xE59F1010,0xE5801000,0xE5902000,
	                                0xE2822001,0xE5802004,0xEAFFFFFE,0x12345678};
	phoenix::Bytes code(sizeof prog); memcpy(code.data(), prog, sizeof prog);
	auto mcu = phoenix::mcu(); phoenix::record(mcu, 0x14, 0, code);
	b.download(0, mcu, false);
	b.ticks(3000);
	b.download(0x40, phoenix::language(), false);
	b.ticks(300);
	b.img1.assign(4u << 20, 255);
	r.emu__DOT__hps_io__DOT__sim_size = b.img1.size();
	r.emu__DOT__hps_io__DOT__sim_readonly = 0;
	r.emu__DOT__hps_io__DOT__sim_mounted = 2;
	b.ticks(100);
	r.emu__DOT__hps_io__DOT__sim_rtc[0] = 0x01120000;    // Main's clock, after the mounts
	r.emu__DOT__hps_io__DOT__sim_rtc[1] = 0x00000406;
	r.emu__DOT__hps_io__DOT__sim_rtc[2] = 1;
	b.ticks(20);
	r.emu__DOT__hps_io__DOT__sim_status[0] = 0;
	uint64_t end = b.clocks + 40000000;
	while (r.emu__DOT__cpu_reset && b.clocks < end) b.tick();
	CHECK(b.clocks < end, "boot files: the CPU starts after both ROMs and boot0.vhd");
	CHECK(r.emu__DOT__ph_ready, "boot files: firmware pair ready");
	CHECK(!memcmp(b.ddr + 0x1400000, b.img1.data(), b.img1.size()), "boot files: C: image loaded");
	CHECK_EQ(b.ddr[0x80], 1, "boot files: MCU record data");
	CHECK_EQ(b.ddr[0xF00001], 6, "boot files: language mapped");
	b.ticks(10000);
	CHECK(b.cpu_writes.size() == 2, "boot files: the program ran");
	printf("boot files: both ROMs back to back, boot0.vhd, then the reset bit released (%llu clocks)\n", (unsigned long long)b.clocks);
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	std::string out = "sim/build/out";
	for (int i = 1; i < argc; i++)
		if (!strcmp(argv[i], "--out") && i + 1 < argc) out = argv[++i];
	test_boot_files();
	test_phoenix(out);
	Bench b;
	auto &R = *b.r;

	// the test picture, keys released
	b.frame();  // the one during which lcd_testgen draws
	sim::Image f = b.frame();
	f.write_ppm(out + "/top_portrait.ppm");
	printf("portrait frame %dx%d: %s\n", f.w, f.h, compare(f, 0, 0, "test picture") == 0 ? "matches" : "differs");
	CHECK_EQ(b.t->VIDEO_ARX, W, "aspect X");
	CHECK_EQ(b.t->VIDEO_ARY, H, "aspect Y");
	CHECK(b.t->LED_USER, "LED_USER off with the panel lit");

	// keys: Up and 5 on the joystick, Call (F3) and Power (F8) on the keyboard
	R.emu__DOT__hps_io__DOT__sim_joy0 = 1u << 3 | 1u << 4;
	auto key = [&](int code, bool down) {
		uint16_t k = R.emu__DOT__hps_io__DOT__sim_ps2_key;
		R.emu__DOT__hps_io__DOT__sim_ps2_key = (uint16_t)((~k & 0x400) | (down ? 0x200 : 0) | code);
		b.ticks(10);
	};
	key(0x04, true);
	key(0x0A, true);
	b.ticks(50000);
	// Up (ROW0/COL0), Call (ROW3/COL0) and 5 (ROW3/COL2) close a loop in the
	// matrix, so the scan also sees ROW0/COL2, the right soft key: a ghost,
	// as on the real keypad
	uint32_t st = 1u << 0 | 1u << 17 | 1u << 15 | 1u << 20 | 1u << 2;
	f = b.frame();
	f.write_ppm(out + "/top_keys.ppm");
	printf("keys held: %s\n", compare(f, st, 0, "keys held") == 0 ? "boxes match" : "boxes differ");
	R.emu__DOT__hps_io__DOT__sim_joy0 = 0;
	key(0x04, false);
	key(0x0A, false);
	b.ticks(50000);
	compare(b.frame(), 0, 0, "keys released");

	// rotation
	for (int rot : {1, 2}) {
		R.emu__DOT__hps_io__DOT__sim_status[0] = (uint32_t)rot << 1;
		b.frame();
		f = b.frame();
		f.write_ppm(out + (rot == 1 ? "/top_cw.ppm" : "/top_ccw.ppm"));
		compare(f, 0, rot, rot == 1 ? "turned clockwise" : "turned anticlockwise");
		CHECK_EQ(b.t->VIDEO_ARX, H, "aspect X turned");
		CHECK_EQ(b.t->VIDEO_ARY, W, "aspect Y turned");
	}
	R.emu__DOT__hps_io__DOT__sim_status[0] = 0;

	// the OSD's video options through video_freak, at 1080p: the aspect
	// ratio [ARC2] (status 122:121 = 3) is 2:0 to the scaler; V-Integer
	// scaling (status 14) asks for 5x, 880x1040 (bit 12 set: a size, not a
	// ratio); the vertical crop (status 9) cuts the 208 lines to 180 for 6x,
	// centred (lines 14-193), moved by the offset (status 13:10; 5 is +10
	// lines), whatever height Main reports (1040, the integer-scaled one
	// its vscale_mode 1-3 send, is the case on the user's MiSTer); turned,
	// the crop is not offered and the frame stays whole
	b.t->HDMI_WIDTH = 1920; b.t->HDMI_HEIGHT = 1080;
	R.emu__DOT__hps_io__DOT__sim_status[3] = 3u << (121 - 96);
	b.frame(); b.frame();
	CHECK_EQ(b.t->VIDEO_ARX, 2, "aspect X [ARC2]");
	CHECK_EQ(b.t->VIDEO_ARY, 0, "aspect Y [ARC2]");
	R.emu__DOT__hps_io__DOT__sim_status[3] = 0;
	R.emu__DOT__hps_io__DOT__sim_status[0] = 1u << 14;
	b.frame(); b.frame();
	CHECK_EQ(b.t->VIDEO_ARX, 0x1000 | 5 * W, "V-Integer X");
	CHECK_EQ(b.t->VIDEO_ARY, 0x1000 | 5 * H, "V-Integer Y");
	auto crop = [&](int off, int top, const char *what) {
		b.frame(); b.frame();
		sim::Image c = b.frame();
		if (c.w != W || c.h != 180) { sim::fail("%s: frame is %dx%d, want %dx180", what, c.w, c.h, W); return; }
		int bad = 0;
		for (int y = 0; y < 180; y++)
			for (int x = 0; x < W; x++)
				if (c.get(x, y) != sim::rgb565_to_888(to565(pattern(x, y + top, 0))) && bad++ < 4)
					sim::fail("%s: pixel (%d,%d) = %06x, want line %d of the picture", what, x, y, c.get(x, y), y + top);
		if (bad > 4) sim::fail("%s: %d pixels differ", what, bad);
		printf("vertical crop, offset %+d: %s (lines %d-%d)\n", off, bad ? "differs" : "matches", top, top + 179);
	};
	b.t->HDMI_HEIGHT = 1040;
	R.emu__DOT__hps_io__DOT__sim_status[0] = 1u << 9;
	crop(0, 14, "vertical crop");
	CHECK_EQ(b.t->VIDEO_ARX, 2288, "cropped aspect X");   // 176:180 (176*208 : 208*180, normalised)
	CHECK_EQ(b.t->VIDEO_ARY, 2340, "cropped aspect Y");
	R.emu__DOT__hps_io__DOT__sim_status[0] = 1u << 9 | 5u << 10;
	crop(10, 24, "vertical crop, offset +10");
	R.emu__DOT__hps_io__DOT__sim_status[0] = 1u << 9 | 1u << 1;
	b.frame(); b.frame();
	f = b.frame();
	if (f.w != H || f.h != W) sim::fail("turned with the crop on: frame is %dx%d, want %dx%d", f.w, f.h, H, W);
	R.emu__DOT__hps_io__DOT__sim_status[0] = 0;
	b.t->HDMI_WIDTH = 0; b.t->HDMI_HEIGHT = 0;
	b.frame(); b.frame();
	compare(b.frame(), 0, 0, "whole again");

	// MiSTer's clock, as hps_io sends it when the core starts (the CPU start
	// waits for it, up to 3 s): 2004-06-01 12:00:00 in BCD
	R.emu__DOT__hps_io__DOT__sim_rtc[0] = 0x01120000u;   // day 1, 12:00:00
	R.emu__DOT__hps_io__DOT__sim_rtc[1] = 0x00000406u;   // year 04, month 06
	b.ticks(4);
	R.emu__DOT__hps_io__DOT__sim_rtc[2] = 1;             // bit 64: the time is sent

	// Development flat images retain their own indexes.
	auto download = [&](int index, const std::vector<uint8_t> &data) { b.download(index, data); };
	std::vector<uint8_t> cs0(65536), cs1(32768);
	for (size_t i = 0; i < cs0.size(); i++) cs0[i] = (uint8_t)(i * 13 + (i >> 8));
	for (size_t i = 0; i < cs1.size(); i++) cs1[i] = (uint8_t)(i * 7 ^ 0xA5);
	// the CPU's program at the reset address:
	//   mov r0, #0x0A000000; ldr r1, =0x12345678; str r1, [r0]; ldr r2, [r0];
	//   add r2, r2, #1; str r2, [r0, #4]; b .
	static const uint32_t prog[] = {0xE3A0040A, 0xE59F1010, 0xE5801000, 0xE5902000,
	                                0xE2822001, 0xE5802004, 0xEAFFFFFE, 0x12345678};
	memcpy(cs0.data(), prog, sizeof prog);
	CHECK(R.emu__DOT__cpu_reset, "the CPU out of reset with no flash image");
	download(3, cs0);
	b.ticks(1000);
	CHECK(R.emu__DOT__cpu_reset, "the CPU out of reset with only CS0 loaded");
	CHECK(b.cpu_writes.empty(), "CPU writes before CS1 is loaded");
	download(4, cs1);
	CHECK(memcmp(&b.ddr[0], cs0.data(), cs0.size()) == 0, "CS0 image in DDR3 at 0x31000000");
	CHECK(memcmp(&b.ddr[0x01000000], cs1.data(), cs1.size()) == 0, "CS1 image in DDR3 at 0x32000000");
	CHECK_EQ(b.ddr[cs0.size()], 0x5A, "byte after the CS0 image");
	CHECK_EQ(b.ddr[0x01000000 + cs1.size()], 0x5A, "byte after the CS1 image");
	CHECK(!b.ddr_stray, "DDR3 write outside the flash windows");
	CHECK_EQ(b.ddr_writes, (cs0.size() + cs1.size()) / 2, "DDR3 writes");
	printf("flash images: %llu DDR3 writes\n", (unsigned long long)b.ddr_writes);
	// both images in: the CPU runs its program from CS0
	{
		uint64_t t1 = b.clocks;
		while (b.cpu_writes.size() < 2 && b.clocks < t1 + 200000) b.tick();
		CHECK(!R.emu__DOT__cpu_reset, "the CPU still in reset with both images loaded");
		CHECK_EQ(b.cpu_writes.size(), 2, "CPU writes");
		if (b.cpu_writes.size() >= 2) {
			CHECK(b.cpu_writes[0] == std::make_pair(0x0A000000u, 0x12345678u), "the CPU's first store");
			CHECK(b.cpu_writes[1] == std::make_pair(0x0A000004u, 0x12345679u), "the CPU's store of the value read back");
			printf("CPU: program ran, stores %llu clocks after the CS1 download\n", (unsigned long long)(b.clocks - t1));
		}
	}
	// the board restarts after a download and draws again; the CPU does not
	// touch the display, so the test picture stays
	b.frame();
	compare(b.frame(), 0, 0, "picture after loading flash", true);
	CHECK_EQ(std::count(b.infos.begin(), b.infos.end(), 7), 1, "one boot-start message");
	CHECK_EQ(std::count(b.infos.begin(), b.infos.end(), 8), 0, "testgen is not a firmware frame");
	CHECK(!R.emu__DOT__boot_done, "testgen must not end Boot only");
	CHECK(R.emu__DOT__activity_left > 0, "CPU bus beats stretch activity");
	R.emu__DOT__hps_io__DOT__sim_status[0] = 2u << 16;
	compare(b.frame(), 0, 0, "activity Off");
	R.emu__DOT__hps_io__DOT__sim_status[0] = 1u << 16;
	compare(b.frame(), 0, 0, "activity Always during boot", true);
	R.emu__DOT__hps_io__DOT__sim_status[0] = 0;

	// an MMC image: the card reads its sidecar block
	b.img.assign(4096 * 512 + 512, 0x11);
	memcpy(&b.img[4096 * 512], "NGAGEMMC", 8);
	R.emu__DOT__hps_io__DOT__sim_size = b.img.size();
	R.emu__DOT__hps_io__DOT__sim_mounted = 1;
	b.ticks(20000);
	CHECK_EQ(b.sd_lbas.size(), 1, "SD reads after mounting");
	if (!b.sd_lbas.empty()) CHECK_EQ(b.sd_lbas[0], 4096, "SD block read on mounting (the sidecar)");
	CHECK(b.disk_led, "LED_DISK never lit");

	// the CS1 save file on slot 1: copied into DDR3 at 0x32000000 while the
	// board is held, the OSD told; nothing changes it here, so nothing goes back
	{
		b.img1.resize(8u << 20);
		uint32_t x = 99;
		for (auto &c : b.img1) { x = x * 1664525u + 1013904223u; c = (uint8_t)(x >> 24); }
		b.infos.clear();
		b.disk_led = false;
		R.emu__DOT__hps_io__DOT__sim_size = b.img1.size();
		R.emu__DOT__hps_io__DOT__sim_readonly = 0;
		R.emu__DOT__hps_io__DOT__sim_mounted = 2;
		uint64_t t1 = b.clocks;
		b.ticks(100);
		CHECK(R.emu__DOT__fs_loading, "the board held while the CS1 save loads");
		while (R.emu__DOT__fs_loading && b.clocks < t1 + 30000000) b.tick();
		CHECK(!R.emu__DOT__fs_loading, "the CS1 save loaded");
		printf("CS1 save: loaded in %llu clocks, %llu requests\n", (unsigned long long)(b.clocks - t1), (unsigned long long)b.s1_reads);
		CHECK_EQ(b.s1_reads, 1024, "4 KB requests for upper 4 MB of legacy save");
		CHECK(memcmp(&b.ddr[0x01400000], b.img1.data() + (4u << 20), 4u << 20) == 0, "C: save image in DDR3 at 0x32400000");
		CHECK(memcmp(&b.ddr[0x01000000], cs1.data(), cs1.size()) == 0, "save did not overwrite CS1 firmware");
		b.ticks(20);
		CHECK_EQ(std::count(b.infos.begin(), b.infos.end(), 3), 1, "OSD message 3 (CS1 mounted)");
		CHECK_EQ(std::count(b.infos.begin(), b.infos.end(), 7), 1, "boot message after save loading");
		CHECK(b.disk_led, "LED_DISK while the save loads");
		// Save C: now with nothing changed: "C: saved" at once, nothing written
		R.emu__DOT__hps_io__DOT__sim_status[0] = 1u << 7;
		b.ticks(200);
		R.emu__DOT__hps_io__DOT__sim_status[0] = 0;
		b.ticks(200);
		CHECK_EQ(std::count(b.infos.begin(), b.infos.end(), 6), 1, "OSD message 6 (C: saved)");
		CHECK_EQ(b.s1_writes, 0, "no write-back with nothing changed");
		b.frame();
		compare(b.frame(), 0, 0, "picture after the CS1 save loaded", true);
	}

	// the memory system under the self-test, with the CPU held in reset
	R.emu__DOT__hps_io__DOT__sim_status[0] = 1u << 6;
	b.infos.clear();
	uint64_t t0 = b.clocks;
	b.ticks(10);
	b.cpu_writes.clear();
	CHECK(R.emu__DOT__cpu_reset, "the CPU out of reset during the memory test");
	while (b.infos.empty() && b.clocks < t0 + 3000000) b.tick();
	CHECK(R.emu__DOT__cpu_reset, "the CPU out of reset during the memory test");
	CHECK(b.infos.size() == 1 && b.infos[0] == 1, "memory test: no 'passed' message after the first pass");
	printf("memory test: first pass in %llu clocks\n", (unsigned long long)(b.clocks - t0));
	CHECK((b.t->LED_POWER & 2) != 0, "power LED not taken over by the memory test");
	{
		sim::Image f = b.frame();
		CHECK_EQ(f.get(0, 0), sim::rgb565_to_888(0x07E0), "status square after a passing pass (green)");
	}
	// flip SDRAM bits under the test: it must report the failure
	t0 = b.clocks;
	while (b.infos.size() < 2 && b.clocks < t0 + 3000000) {
		if (b.clocks % 64 == 0) b.chip.lin(b.rng.range(0, 8191)) ^= 0x0100;
		b.tick();
	}
	CHECK(b.infos.size() == 2 && b.infos[1] == 2, "memory test: no 'FAILED' message with SDRAM bits flipped");
	{
		sim::Image f = b.frame();
		CHECK_EQ(f.get(0, 0), sim::rgb565_to_888(0xF81F), "status square after errors (magenta)");
	}
	b.cpu_writes.clear();
	R.emu__DOT__hps_io__DOT__sim_status[0] = 0;
	b.ticks(2000);
	CHECK_EQ(b.t->LED_POWER, 0, "power LED after the memory test");
	// the memory test off again: the board restarts and the CPU runs again
	t0 = b.clocks;
	while (b.cpu_writes.size() < 2 && b.clocks < t0 + 200000) b.tick();
	CHECK(b.cpu_writes.size() == 2 && b.cpu_writes[1] == std::make_pair(0x0A000004u, 0x12345679u),
	      "the CPU's program after the memory test");
	// A synthetic ARM program drives the real LCD interface: RAMWR begins
	// a frame. Repeated commands must produce only one boot-up notification.
	// This is a peripheral smoke test, not the firmware boot bench.
	static const uint32_t lcd_prog[] = {
		0xE59F0010, 0xE59F1010, 0xE5801000, 0xE3A0102C,
		0xE5801008, 0xEAFFFFFC, 0x0C121200, 0x09280000
	};
	memcpy(cs0.data(), lcd_prog, sizeof lcd_prog);
	b.infos.clear();
	download(3, cs0);
	b.ticks(20000);
	CHECK(R.emu__DOT__boot_done, "firmware RAMWR ends Boot only");
	CHECK_EQ(std::count(b.infos.begin(), b.infos.end(), 7), 1, "LCD program boot-start message");
	CHECK_EQ(std::count(b.infos.begin(), b.infos.end(), 8), 1, "first firmware LCD frame message");
	// Taking over the LCD before testgen finishes can leave a blank/partial
	// picture. Compare the actual panel image across modes, not testgen.
	R.emu__DOT__hps_io__DOT__sim_status[0] = 2u << 16;
	sim::Image panel = b.frame();
	auto check_activity_frame = [&](bool dot, const char *what) {
		sim::Image got = b.frame();
		CHECK(got.w == panel.w && got.h == panel.h, "activity changes frame size");
		int bad = 0;
		for (int y = 0; y < panel.h; y++)
			for (int x = 0; x < panel.w; x++) {
				uint32_t want = dot && x >= 164 && x < 170 && y >= 4 && y < 10 ?
					sim::rgb565_to_888(0x07E0) : panel.get(x, y);
				if (got.get(x, y) != want) bad++;
			}
		CHECK_EQ(bad, 0, what);
	};
	R.emu__DOT__hps_io__DOT__sim_status[0] = 0;
	check_activity_frame(false, "Boot only hidden after firmware frame");
	R.emu__DOT__hps_io__DOT__sim_status[0] = 1u << 16;
	check_activity_frame(true, "Always after firmware frame");
	R.emu__DOT__hps_io__DOT__sim_status[0] = 2u << 16;
	check_activity_frame(false, "Off after firmware frame");
	CHECK_EQ(std::count(b.infos.begin(), b.infos.end(), 8), 1, "no repeat frame notification");

	// Overlay data rows keep their black/white encoding, while the dot
	// itself remains outside their x coordinates.
	R.emu__DOT__hps_io__DOT__sim_status[0] = (1u << 8) | (1u << 16);
	f = b.frame();
	CHECK_EQ(f.get(164, 4), sim::rgb565_to_888(0x07E0), "activity with debug overlay");
	for (int y = 0; y < 127; y++)
		for (int x = 16; x < 48; x++) {
			// Existing rows render only black/white; the green dot cannot intrude.
			if ((y < 3) || (y >= 8 && y % 4 != 3))
				CHECK(f.get(x, y) == 0 || f.get(x, y) == 0xFFFFFF, "dot overlaps debug row");
		}
	R.emu__DOT__hps_io__DOT__sim_status[0] = 1; // reset rearms messages and clears activity
	b.ticks(20);
	CHECK(!R.emu__DOT__boot_done && R.emu__DOT__activity_left == 0, "reset clears boot/activity");
	b.infos.clear();
	R.emu__DOT__hps_io__DOT__sim_status[0] = 0;
	b.ticks(20000);
	CHECK_EQ(std::count(b.infos.begin(), b.infos.end(), 7), 1, "boot message rearmed on reset");
	CHECK_EQ(std::count(b.infos.begin(), b.infos.end(), 8), 1, "frame message rearmed on reset");

	// A loop in I-cache stops bus traffic so the real 13,000,000-clock
	// hold time expires: mov r0,#0x1000; mcr p15,0,r0,c1,c0,0; b .
	// No CPU implementation changes are involved.
	static const uint32_t sleep_prog[] = {0xE3A00A01, 0xEE010F10, 0xEAFFFFFE};
	memcpy(cs0.data(), sleep_prog, sizeof sleep_prog);
	download(3, cs0);
	b.ticks(20000);
	uint32_t left = R.emu__DOT__activity_left;
	CHECK(left > 0 && left < 13000000, "activity countdown in cached loop");
	b.ticks(100);
	CHECK_EQ(R.emu__DOT__activity_left, left - 100, "activity decrements without beats");
	b.ticks(left);
	CHECK_EQ(R.emu__DOT__activity_left, 0, "activity expires after 1/8 second");
	compare(b.frame(), 0, 0, "quiet boot has no activity dot");
	printf("boot messages and activity modes: checked through CPU/LCD and video outputs\n");
	if (b.chip.errors) sim::fail("the SDRAM chip model reported %d error(s)", b.chip.errors);
	if (b.dm.protocol_errors) sim::fail("%d DDRAM port protocol error(s)", b.dm.protocol_errors);
	CHECK(!b.dm.bad_access, "DDR3 access outside the model");
	printf("SDRAM: %llu refreshes, %llu reads, %llu writes; DDR3: %llu reads\n", (unsigned long long)b.chip.refreshes,
		(unsigned long long)b.chip.reads, (unsigned long long)b.chip.writes, (unsigned long long)b.dm.reads);

	printf("%llu clocks\n", (unsigned long long)b.clocks);
	return sim::finish("emu");
}
