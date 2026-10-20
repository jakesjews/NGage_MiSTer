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

#include <cstring>
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
	int sd_state = 0, sd_delay = 0, sd_word = 0;
	std::vector<uint32_t> sd_lbas;
	bool disk_led = false;

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

	void sd_step() {
		r->emu__DOT__hps_io__DOT__sim_sd_wr_buf = 0;
		r->emu__DOT__hps_io__DOT__sim_mounted = 0;
		switch (sd_state) {
		case 0:
			if (r->emu__DOT__hps_io__DOT__sim_sd_rd) {
				sd_lbas.push_back(r->emu__DOT__hps_io__DOT__sim_sd_lba);
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
			if (sd_word < 256) {
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

// colour of the memory-test status square (panel pixels x, y < 12), RGB565:
// blue = test off, yellow = running, green = passed, magenta = errors
uint16_t square565 = 0x001F;

// compare a captured frame with the pattern for key state st, turned by rot
int compare(const sim::Image &got, uint32_t st, int rot, const char *what) {
	bool turned = rot == 1 || rot == 2;
	int w = turned ? H : W, h = turned ? W : H;
	if (got.w != w || got.h != h) { sim::fail("%s: frame is %dx%d, want %dx%d", what, got.w, got.h, w, h); return -1; }
	int bad = 0;
	for (int y = 0; y < h; y++)
		for (int x = 0; x < w; x++) {
			int sx = x, sy = y;
			if (rot == 1) { sx = y; sy = H - 1 - x; }
			if (rot == 2) { sx = W - 1 - y; sy = x; }
			uint32_t want = sim::rgb565_to_888((sx < 12 && sy < 12) ? square565 : to565(pattern(sx, sy, st)));
			if (got.get(x, y) != want && bad++ < 4)
				sim::fail("%s: pixel (%d,%d) = %06x, want %06x", what, x, y, got.get(x, y), want);
		}
	if (bad > 4) sim::fail("%s: %d pixels differ", what, bad);
	return bad;
}

}  // namespace

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	std::string out = "sim/build/out";
	for (int i = 1; i < argc; i++)
		if (!strcmp(argv[i], "--out") && i + 1 < argc) out = argv[++i];
	Bench b;
	auto &R = *b.r;

	// the test picture, keys released
	b.frame();  // the one during which lcd_testgen draws
	sim::Image f = b.frame();
	f.write_ppm(out + "/top_portrait.ppm");
	printf("portrait frame %dx%d: %s\n", f.w, f.h, compare(f, 0, 0, "test picture") == 0 ? "matches" : "differs");
	CHECK_EQ(b.t->VIDEO_ARX, 11, "aspect X");
	CHECK_EQ(b.t->VIDEO_ARY, 13, "aspect Y");
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
		CHECK_EQ(b.t->VIDEO_ARX, 13, "aspect X turned");
		CHECK_EQ(b.t->VIDEO_ARY, 11, "aspect Y turned");
	}
	R.emu__DOT__hps_io__DOT__sim_status[0] = 0;

	// flash images through ioctl into DDR3
	auto download = [&](int index, const std::vector<uint8_t> &data) {
		R.emu__DOT__hps_io__DOT__sim_index = index;
		R.emu__DOT__hps_io__DOT__sim_download = 1;
		b.ticks(5);
		for (size_t a = 0; a < data.size(); a += 2) {
			while (R.emu__DOT__hps_io__DOT__sim_wait) b.tick();
			R.emu__DOT__hps_io__DOT__sim_addr = (uint32_t)a;
			R.emu__DOT__hps_io__DOT__sim_dout = (uint16_t)(data[a] | data[a + 1] << 8);
			R.emu__DOT__hps_io__DOT__sim_wr = 1;
			b.tick();
			R.emu__DOT__hps_io__DOT__sim_wr = 0;
			b.ticks(b.rng.range(1, 6));
		}
		while (R.emu__DOT__hps_io__DOT__sim_wait) b.tick();
		b.ticks(5);
		R.emu__DOT__hps_io__DOT__sim_download = 0;
		b.ticks(5);
	};
	std::vector<uint8_t> cs0(65536), cs1(32768);
	for (size_t i = 0; i < cs0.size(); i++) cs0[i] = (uint8_t)(i * 13 + (i >> 8));
	for (size_t i = 0; i < cs1.size(); i++) cs1[i] = (uint8_t)(i * 7 ^ 0xA5);
	download(1, cs0);
	download(2, cs1);
	CHECK(memcmp(&b.ddr[0], cs0.data(), cs0.size()) == 0, "CS0 image in DDR3 at 0x31000000");
	CHECK(memcmp(&b.ddr[0x01000000], cs1.data(), cs1.size()) == 0, "CS1 image in DDR3 at 0x32000000");
	CHECK_EQ(b.ddr[cs0.size()], 0x5A, "byte after the CS0 image");
	CHECK_EQ(b.ddr[0x01000000 + cs1.size()], 0x5A, "byte after the CS1 image");
	CHECK(!b.ddr_stray, "DDR3 write outside the flash windows");
	CHECK_EQ(b.ddr_writes, (cs0.size() + cs1.size()) / 2, "DDR3 writes");
	printf("flash images: %llu DDR3 writes\n", (unsigned long long)b.ddr_writes);
	// the board restarts after a download and draws again
	b.frame();
	compare(b.frame(), 0, 0, "picture after loading flash");

	// an MMC image: the card reads its sidecar block
	b.img.assign(4096 * 512 + 512, 0x11);
	memcpy(&b.img[4096 * 512], "NGAGEMMC", 8);
	R.emu__DOT__hps_io__DOT__sim_size = b.img.size();
	R.emu__DOT__hps_io__DOT__sim_mounted = 1;
	b.ticks(20000);
	CHECK_EQ(b.sd_lbas.size(), 1, "SD reads after mounting");
	if (!b.sd_lbas.empty()) CHECK_EQ(b.sd_lbas[0], 4096, "SD block read on mounting (the sidecar)");
	CHECK(b.disk_led, "LED_DISK never lit");

	// the memory system under the self-test
	R.emu__DOT__hps_io__DOT__sim_status[0] = 1u << 6;
	b.infos.clear();
	uint64_t t0 = b.clocks;
	while (b.infos.empty() && b.clocks < t0 + 3000000) b.tick();
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
	R.emu__DOT__hps_io__DOT__sim_status[0] = 0;
	b.ticks(2000);
	CHECK_EQ(b.t->LED_POWER, 0, "power LED after the memory test");
	if (b.chip.errors) sim::fail("the SDRAM chip model reported %d error(s)", b.chip.errors);
	if (b.dm.protocol_errors) sim::fail("%d DDRAM port protocol error(s)", b.dm.protocol_errors);
	CHECK(!b.dm.bad_access, "DDR3 access outside the model");
	printf("SDRAM: %llu refreshes, %llu reads, %llu writes; DDR3: %llu reads\n", (unsigned long long)b.chip.refreshes,
		(unsigned long long)b.chip.reads, (unsigned long long)b.chip.writes, (unsigned long long)b.dm.reads);

	printf("%llu clocks\n", (unsigned long long)b.clocks);
	return sim::finish("emu");
}
