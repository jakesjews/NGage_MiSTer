// Bench for rtl/board/lcd_panel.sv: the display module driven through its
// 8080 bus.
//
//   Vlcd_panel [--seed N] [--rounds N] [--out DIR]
//
// 1. Firmware-style start-up (the sequence lcd.ldd sends: RGBSET, GAMSET,
//    SLPOUT, TEON, DISPON, the vendor 0x24, COLMOD 3, MADCTL 0xD4) and a whole
//    picture in 12 bpp; then a window written the way the other module
//    variant does it (MADCTL 0x00, coordinates mirrored in software, 16 bpp),
//    and one with rows and columns exchanged (MV) in 18 bpp. Every path puts
//    logical (x, y) at the viewer's (x, y), so the frame read back through the
//    scan port must equal the reference picture built from the three source
//    pictures alone. Both are written as PPM files.
// 2. Random command streams against a model of the controller written from
//    the datasheets: windows, MADCTL, pixel formats, odd byte counts, RGBSET,
//    inversion, idle, partial and scroll modes, BGR, sleep, SWRESET,
//    undefined opcodes, and reads (RAMRD, RDDID, RDDST, RDDPM and friends)
//    checked byte by byte. The whole viewer frame is compared after each round.
// 3. TE: period, high time, mode 1 line pulses, TEOFF and sleep.
// 4. /RES: registers back to their defaults, frame memory kept.
#include "Vlcd_panel.h"
#include "verilated.h"
#include "common.h"

#include <cstring>
#include <string>

using sim::Rng;

namespace {

constexpr int W = 176, H = 208;
constexpr int CLK_HZ = 2000000;  // the bench's -GCLK_HZ: short TE frames
constexpr int TE_HZ = 74, TE_VBLANK = 12, TE_HPULSE = 4;
constexpr uint16_t BLANK = 0x0000, PARTIAL = 0x0000;
constexpr uint8_t ID1 = 0x45, ID2 = 0x83, ID3 = 0x5A;  // the bench's -G values

// ---------------------------------------------------------------------------
// Model of the controller, from the MC2PA8201 / ST7637 descriptions
// ---------------------------------------------------------------------------
struct Model {
	uint16_t fm[W * H];
	uint8_t cmd = 0;
	int pidx = 0;
	bool sleep, disp, inv, idle, ptl, scroll, te_on, te_mode;
	int gamma;
	uint8_t madctl, colmod;
	uint16_t xs, xe, ys, ye, sr, er, tfa, vsa, bfa, ssa;
	uint8_t lr[16], lg[16], lb[16];
	uint16_t c = 0, p = 0;
	int pph = 0;
	uint8_t b0 = 0, b1 = 0;
	enum { NONE, REG, RAM } rk = NONE;
	int ridx = 0;
	bool rlo = false;

	Model() {
		memset(fm, 0, sizeof fm);
		hw_reset();
	}
	void defaults() {
		cmd = 0; pidx = 0;
		sleep = true; disp = inv = idle = ptl = scroll = te_on = te_mode = false;
		gamma = 0; madctl = 0; colmod = 0x05;
		xs = 0; xe = W - 1; ys = 0; ye = H - 1;
		sr = 0; er = H - 1; tfa = 0; vsa = H; bfa = 0; ssa = 0;
		c = p = 0; pph = 0; rk = NONE; ridx = 0; rlo = false;
	}
	void hw_reset() {
		defaults();
		for (int i = 0; i < 16; i++) {
			lr[i] = lb[i] = i == 15 ? 31 : i * 2;
			lg[i] = i == 15 ? 63 : i * 4;
		}
	}
	// counter position -> memory index, -1 when outside the memory
	int map(uint16_t cc, uint16_t pp) const {
		bool my = madctl & 0x80, mx = madctl & 0x40, mv = madctl & 0x20;
		int col, row;
		if (!mv) {
			if (cc >= W || pp >= H) return -1;
			col = mx ? W - 1 - cc : cc;
			row = my ? H - 1 - pp : pp;
		} else {
			if (cc >= H || pp >= W) return -1;
			row = my ? H - 1 - cc : cc;
			col = mx ? W - 1 - pp : pp;
		}
		return row * W + col;
	}
	void step() {
		if (c >= xe) { c = xs; p = p >= ye ? ys : p + 1; }
		else c++;
	}
	void pixel(uint16_t v) {
		int a = map(c, p);
		if (a >= 0) fm[a] = v;
		step();
	}
	void write_cmd(uint8_t b) {
		cmd = b; pidx = 0; rk = NONE; ridx = 0; rlo = false;
		switch (b) {
		case 0x01: defaults(); break;
		case 0x04: case 0x09: case 0x0A: case 0x0B: case 0x0C: case 0x0D: case 0x0E: case 0x0F:
		case 0xDA: case 0xDB: case 0xDC: rk = REG; break;
		case 0x10: sleep = true; break;
		case 0x11: sleep = false; break;
		case 0x12: ptl = true; scroll = false; break;
		case 0x13: ptl = false; scroll = false; break;
		case 0x20: inv = false; break;
		case 0x21: inv = true; break;
		case 0x28: disp = false; break;
		case 0x29: disp = true; break;
		case 0x2C: c = xs; p = ys; pph = 0; break;
		case 0x2E: c = xs; p = ys; rk = RAM; break;
		case 0x34: te_on = false; break;
		case 0x35: te_on = true; break;
		case 0x37: scroll = true; break;
		case 0x38: idle = false; break;
		case 0x39: idle = true; break;
		default: break;
		}
	}
	static void set16(uint16_t &r, int idx, uint8_t b) {
		if (idx == 0) r = (uint16_t)((r & 0x00FF) | b << 8);
		else r = (uint16_t)((r & 0xFF00) | b);
	}
	void write_par(uint8_t b) {
		int i = pidx;
		if (pidx < 63) pidx++;
		switch (cmd) {
		case 0x26:
			if (i == 0) {
				if (b == 1) gamma = 0; else if (b == 2) gamma = 1;
				else if (b == 4) gamma = 2; else if (b == 8) gamma = 3;
			}
			break;
		case 0x2A: if (i < 2) set16(xs, i, b); else if (i < 4) set16(xe, i - 2, b); break;
		case 0x2B: if (i < 2) set16(ys, i, b); else if (i < 4) set16(ye, i - 2, b); break;
		case 0x2C: {
			int fmt = colmod & 7;
			if (fmt == 3) {
				if (pph == 0) { b0 = b; pph = 1; }
				else if (pph == 1) {
					pixel((uint16_t)(lr[b0 >> 4] << 11 | lg[b0 & 15] << 5 | lb[b >> 4]));
					b1 = b; pph = 2;
				} else {
					pixel((uint16_t)(lr[b1 & 15] << 11 | lg[b >> 4] << 5 | lb[b & 15]));
					pph = 0;
				}
			} else if (fmt == 6) {
				if (pph == 0) { b0 = b; pph = 1; }
				else if (pph == 1) { b1 = b; pph = 2; }
				else { pixel((uint16_t)((b0 >> 3) << 11 | (b1 >> 2) << 5 | (b >> 3))); pph = 0; }
			} else {
				if (pph == 0) { b0 = b; pph = 1; }
				else { pixel((uint16_t)(b0 << 8 | b)); pph = 0; }
			}
			break;
		}
		case 0x2D:
			if (i < 16) lr[i] = b & 31;
			else if (i < 32) lg[i - 16] = b & 63;
			else if (i < 48) lb[i - 32] = b & 31;
			break;
		case 0x30: if (i < 2) set16(sr, i, b); else if (i < 4) set16(er, i - 2, b); break;
		case 0x33:
			if (i < 2) set16(tfa, i, b); else if (i < 4) set16(vsa, i - 2, b);
			else if (i < 6) set16(bfa, i - 4, b);
			break;
		case 0x35: if (i == 0) te_mode = b & 1; break;
		case 0x36: if (i == 0) madctl = b; break;
		case 0x37: if (i < 2) set16(ssa, i, b); break;
		case 0x3A: if (i == 0) colmod = b; break;
		default: break;
		}
	}
	uint32_t status() const {
		bool normal = !ptl && !scroll;
		uint32_t s = 0;
		s |= (uint32_t)!sleep << 31;
		s |= (uint32_t)(madctl >> 2 & 0x3F) << 25;  // MY MX MV ML BGR MH
		s |= (uint32_t)(colmod & 7) << 20;
		s |= (uint32_t)idle << 19 | (uint32_t)ptl << 18 | (uint32_t)!sleep << 17 | (uint32_t)normal << 16;
		s |= (uint32_t)scroll << 15 | (uint32_t)inv << 13 | (uint32_t)disp << 10 | (uint32_t)te_on << 9;
		s |= (uint32_t)gamma << 6 | (uint32_t)te_mode << 5;
		return s;
	}
	uint8_t reg_byte() const {
		bool normal = !ptl && !scroll;
		switch (cmd) {
		case 0x04: return ridx == 1 ? ID1 : ridx == 2 ? ID2 : ridx == 3 ? ID3 : 0;
		case 0x09: return ridx >= 1 && ridx <= 4 ? (uint8_t)(status() >> (8 * (4 - ridx))) : 0;
		case 0x0A: return ridx == 1 ? (uint8_t)(!sleep << 7 | idle << 6 | ptl << 5 | !sleep << 4 | normal << 3 | disp << 2) : 0;
		case 0x0B: return ridx == 1 ? madctl : 0;
		case 0x0C: return ridx == 1 ? colmod : 0;
		case 0x0D: return ridx == 1 ? (uint8_t)(scroll << 7 | inv << 5 | gamma) : 0;
		case 0x0E: return ridx == 1 ? (uint8_t)(te_on << 7 | te_mode << 6) : 0;
		case 0x0F: return ridx == 1 ? 0xC0 : 0;
		case 0xDA: return ridx == 1 ? ID1 : 0;
		case 0xDB: return ridx == 1 ? ID2 : 0;
		case 0xDC: return ridx == 1 ? ID3 : 0;
		default: return 0;
		}
	}
	uint8_t read() {
		uint8_t v = 0;
		if (rk == REG) {
			v = reg_byte();
			if (ridx < 7) ridx++;
		} else if (rk == RAM) {
			if (ridx == 0) { v = 0; ridx = 1; }
			else {
				int a = map(c, p);
				uint16_t px = a >= 0 ? fm[a] : 0;
				if (!rlo) { v = px >> 8; rlo = true; }
				else { v = px & 0xFF; rlo = false; step(); }
			}
		}
		return v;
	}
	uint16_t view(int x, int y) const {
		int nx = W - 1 - x, ny = H - 1 - y;  // PANEL_ROT180
		int line = ny, mrow = line;
		if (scroll && line >= tfa && line < tfa + vsa) {
			int sum = (uint16_t)(ssa + (line - tfa));
			mrow = sum >= tfa + vsa ? sum - vsa : sum;
			mrow &= 0xFFFF;
		}
		bool in_ptl = sr <= er ? (mrow >= sr && mrow <= er) : (mrow >= sr || mrow <= er);
		bool show = !sleep && disp && mrow < H;
		uint16_t px = show ? fm[mrow * W + nx] : 0;
		if (madctl & 0x08) px = (uint16_t)((px & 31) << 11 | (px & 0x07E0) | px >> 11);
		if (idle) px = (uint16_t)((px & 0x8000 ? 0xF800 : 0) | (px & 0x0400 ? 0x07E0 : 0) | (px & 0x10 ? 0x1F : 0));
		if (inv) px = ~px;
		if (ptl && !in_ptl) px = PARTIAL;
		if (!show) px = BLANK;
		return px;
	}
};

// ---------------------------------------------------------------------------
// Bench
// ---------------------------------------------------------------------------
struct Bench {
	Vlcd_panel *t;
	Rng rng;
	uint64_t clocks = 0;
	bool fast = false;  // shortest bus cycles
	bool bg_scan = false;  // the video's scan requests, one every 16 clocks

	Bench(uint32_t seed) : t(new Vlcd_panel), rng(seed) {
		t->clk = 0; t->reset = 1; t->csx = 1; t->dcx = 1; t->wrx = 1; t->rdx = 1; t->resx = 1;
		t->d_i = 0; t->te_ext_sel = 0; t->te_ext = 0; t->scan_en = 0; t->scan_x = 0; t->scan_y = 0;
		t->eval();
		for (int i = 0; i < 4; i++) tick();
		t->reset = 0;
		tick();
	}
	~Bench() { t->final(); delete t; }

	void tick() {
		if (bg_scan) {
			t->scan_en = clocks % 16 == 0;
			t->scan_x = (uint8_t)(clocks / 16 % W);
			t->scan_y = (uint8_t)(clocks / 16 / W % H);
		}
		t->clk = 1; t->eval();
		t->clk = 0; t->eval();
		clocks++;
	}
	void ticks(int n) { while (n-- > 0) tick(); }
	int len(int lo, int hi) { return fast ? lo : rng.range(lo, hi); }

	void write(bool dc, uint8_t b) {
		t->csx = 0; t->dcx = dc; t->d_i = b; t->wrx = 0;
		ticks(len(1, 3));
		t->wrx = 1;
		// a host may change the bus as /WR rises
		if (!fast && rng.chance(30)) { t->d_i = (uint8_t)rng.u32(); t->dcx = rng.chance(50); }
		ticks(len(1, 3));
		if (!fast && rng.chance(10)) { t->csx = 1; ticks(rng.range(1, 3)); }
	}
	void cmd(uint8_t c) { write(false, c); }
	void par(uint8_t b) { write(true, b); }
	void cmd(uint8_t c, std::initializer_list<int> ps) { cmd(c); for (int b : ps) par((uint8_t)b); }
	uint8_t read() {
		t->csx = 0; t->dcx = 1; t->rdx = 0;
		ticks(len(1, 4));
		CHECK(t->d_oe, "d_oe low during a read");
		uint8_t v = t->d_o;
		t->rdx = 1;
		ticks(len(5, 8));
		return v;
	}
	uint16_t scan(int x, int y) {
		bg_scan = false;
		t->scan_en = 1; t->scan_x = x; t->scan_y = y;
		tick();
		t->scan_en = 0;
		ticks(3);
		return t->scan_rgb;
	}
	// the whole viewer frame, one request a clock
	void frame(std::vector<uint16_t> &out) {
		bg_scan = false;
		out.assign(W * H, 0);
		int n = W * H;
		for (int i = 0; i < n + 3; i++) {
			if (i < n) { t->scan_en = 1; t->scan_x = i % W; t->scan_y = i / W; }
			else t->scan_en = 0;
			tick();
			if (i >= 3) out[i - 3] = t->scan_rgb;
		}
		t->scan_en = 0;
	}
	void hw_reset_pin() {
		t->resx = 0; ticks(rng.range(2, 6)); t->resx = 1; ticks(2);
	}
};

// Drive the same bus transaction into the RTL and the model
struct Both {
	Bench &b;
	Model &m;
	void cmd(uint8_t c) { b.cmd(c); m.write_cmd(c); }
	void par(uint8_t p) { b.par(p); m.write_par(p); }
	void cmd(uint8_t c, std::initializer_list<int> ps) { cmd(c); for (int p : ps) par((uint8_t)p); }
	void read_check(const char *what) {
		uint8_t want = m.read();
		uint8_t got = b.read();
		if (got != want) sim::fail("%s: read 0x%02x, model 0x%02x (cmd 0x%02x)", what, got, want, m.cmd);
	}
};

void compare_frame(Bench &b, const Model &m, const char *what) {
	std::vector<uint16_t> fr;
	b.frame(fr);
	int bad = 0;
	for (int y = 0; y < H; y++)
		for (int x = 0; x < W; x++) {
			uint16_t want = m.view(x, y), got = fr[y * W + x];
			if (got != want && bad++ < 5)
				sim::fail("%s: pixel (%d,%d) = %04x, model %04x", what, x, y, got, want);
		}
	if (bad > 5) sim::fail("%s: %d pixels differ", what, bad);
}

// ---------------------------------------------------------------------------
// 1. Reference picture through three write paths
// ---------------------------------------------------------------------------
// source pictures, 12 bpp (0x0RGB)
uint16_t pic_p(int x, int y) {
	if (x < 8 && y < 8) return 0xF00;  // marker at the logical top-left
	if (x == 0 || y == 0 || x == W - 1 || y == H - 1) return 0xFFF;
	if (y < 64) {
		static const uint16_t bars[8] = {0xFFF, 0xFF0, 0x0FF, 0x0F0, 0xF0F, 0xF00, 0x00F, 0x000};
		return bars[x * 8 / W];
	}
	int r = x * 16 / W, g = (y - 64) * 16 / (H - 64), b = 15 - r;
	return (uint16_t)(r << 8 | g << 4 | b);
}
// window pictures, RGB565
uint16_t pic_q(int x, int y) { return (uint16_t)((x * 7) << 8 ^ (y * 13) ^ 0x5A5A); }
uint16_t pic_r(int x, int y) { return (uint16_t)(((x * 5) & 31) << 11 | ((y * 3) & 63) << 5 | ((x + y) & 31)); }

void test_reference(Bench &b, const std::string &out) {
	// the ideal 4-to-5/6 bit expansion, not the reset table
	uint8_t lr[16], lg[16];
	for (int i = 0; i < 16; i++) { lr[i] = (uint8_t)((i * 31 + 7) / 15); lg[i] = (uint8_t)((i * 63 + 7) / 15); }

	b.hw_reset_pin();
	b.cmd(0x2D);
	for (int i = 0; i < 16; i++) b.par(lr[i]);
	for (int i = 0; i < 16; i++) b.par(lg[i]);
	for (int i = 0; i < 16; i++) b.par(lr[i]);
	b.cmd(0x26, {0x04});
	b.cmd(0x11);
	b.cmd(0x35, {0x00});
	b.cmd(0x29);
	b.cmd(0x38);
	b.cmd(0x13);
	b.cmd(0x2A, {0, 0, 0, 175});
	b.cmd(0x24, {0x1E});
	b.cmd(0x3A, {0x03});
	b.cmd(0x36, {0xD4});
	b.cmd(0x2A, {0, 0, 0, 175});
	b.cmd(0x2B, {0, 0, 0, 207});
	b.cmd(0x2C);
	for (int y = 0; y < H; y++)
		for (int x = 0; x < W; x += 2) {
			uint16_t a = pic_p(x, y), c = pic_p(x + 1, y);
			b.par((uint8_t)(a >> 4));                     // R1 G1
			b.par((uint8_t)((a & 15) << 4 | c >> 8));     // B1 R2
			b.par((uint8_t)(c & 0xFF));                   // G2 B2
		}

	// variant-4 path: MADCTL 0x00, mirrored coordinates, 16 bpp
	const int qx0 = 20, qx1 = 99, qy0 = 30, qy1 = 129;
	b.cmd(0x36, {0x00});
	b.cmd(0x3A, {0x05});
	b.cmd(0x2A, {0, W - 1 - qx1, 0, W - 1 - qx0});
	b.cmd(0x2B, {0, H - 1 - qy1, 0, H - 1 - qy0});
	b.cmd(0x2C);
	for (int mr = H - 1 - qy1; mr <= H - 1 - qy0; mr++)
		for (int mc = W - 1 - qx1; mc <= W - 1 - qx0; mc++) {
			uint16_t v = pic_q(W - 1 - mc, H - 1 - mr);
			b.par((uint8_t)(v >> 8)); b.par((uint8_t)v);
		}

	// rows and columns exchanged (MADCTL 0x20), 18 bpp
	const int rx0 = 110, rx1 = 169, ry0 = 140, ry1 = 199;
	b.cmd(0x36, {0x20});
	b.cmd(0x3A, {0x06});
	b.cmd(0x2A, {0, H - 1 - ry1, 0, H - 1 - ry0});   // the column counter walks memory rows
	b.cmd(0x2B, {0, W - 1 - rx1, 0, W - 1 - rx0});   // the page counter walks memory columns
	b.cmd(0x2C);
	for (int pc = W - 1 - rx1; pc <= W - 1 - rx0; pc++)
		for (int cc = H - 1 - ry1; cc <= H - 1 - ry0; cc++) {
			uint16_t v = pic_r(W - 1 - pc, H - 1 - cc);
			b.par((uint8_t)((v >> 11) << 3)); b.par((uint8_t)(((v >> 5) & 63) << 2)); b.par((uint8_t)((v & 31) << 3));
		}

	// the reference, from the source pictures alone
	sim::Image ref(W, H), got(W, H);
	std::vector<uint16_t> want(W * H);
	for (int y = 0; y < H; y++)
		for (int x = 0; x < W; x++) {
			uint16_t v;
			if (x >= rx0 && x <= rx1 && y >= ry0 && y <= ry1) v = pic_r(x, y);
			else if (x >= qx0 && x <= qx1 && y >= qy0 && y <= qy1) v = pic_q(x, y);
			else {
				uint16_t p = pic_p(x, y);
				v = (uint16_t)(lr[p >> 8] << 11 | lg[(p >> 4) & 15] << 5 | lr[p & 15]);
			}
			want[y * W + x] = v;
			sim::set565(ref, x, y, v);
		}
	std::vector<uint16_t> fr;
	b.frame(fr);
	int bad = 0;
	for (int i = 0; i < W * H; i++) {
		sim::set565(got, i % W, i / W, fr[i]);
		if (fr[i] != want[i] && bad++ < 5)
			sim::fail("reference picture: (%d,%d) = %04x, want %04x", i % W, i / W, fr[i], want[i]);
	}
	if (bad > 5) sim::fail("reference picture: %d pixels differ", bad);
	ref.write_ppm(out + "/lcd_reference.ppm");
	got.write_ppm(out + "/lcd_panel.ppm");
	printf("reference picture: %s (%d pixels differ)\n", bad ? "FAILED" : "matches", bad);
}

// ---------------------------------------------------------------------------
// 2. Random command streams against the model
// ---------------------------------------------------------------------------
void random_window(Both &d, Rng &r) {
	bool mv = d.m.madctl & 0x20;
	int cmax = mv ? H : W, pmax = mv ? W : H;
	int c0 = r.range(0, cmax - 1), c1 = r.range(c0, cmax - 1);
	int p0 = r.range(0, pmax - 1), p1 = r.range(p0, pmax - 1);
	if (r.chance(10)) c1 = r.range(c0, cmax + 30);  // past the memory: ignored writes
	if (r.chance(10)) p1 = r.range(p0, pmax + 30);
	if (r.chance(15)) { c1 = std::min(c0 + r.range(0, 5), cmax - 1); }
	d.cmd(0x2A, {c0 >> 8, c0 & 255, c1 >> 8, c1 & 255});
	d.cmd(0x2B, {p0 >> 8, p0 & 255, p1 >> 8, p1 & 255});
}

void random_round(Both &d, Rng &r) {
	int n = r.range(4, 14);
	for (int k = 0; k < n; k++) {
		switch (r.range(0, 19)) {
		case 0: case 1: case 2: case 3: {  // a RAMWR
			if (r.chance(50)) random_window(d, r);
			static const uint8_t fmts[] = {0x03, 0x05, 0x06, 0x55, 0x03, 0x07};
			if (r.chance(50)) d.cmd(0x3A, {fmts[r.range(0, 5)]});
			d.cmd(0x2C);
			int bytes = r.range(0, 900);
			uint32_t seed = r.u32();
			for (int i = 0; i < bytes; i++) d.par((uint8_t)((seed = seed * 1103515245u + 12345u) >> 16));
			break;
		}
		case 4: d.cmd(0x36, {(int)(r.u32() & 0xFC)}); break;
		case 5: {  // RAMRD of a window
			if (r.chance(70)) random_window(d, r);
			d.cmd(0x2E);
			int bytes = r.range(1, 60);
			for (int i = 0; i < bytes; i++) d.read_check("RAMRD");
			break;
		}
		case 6: {
			d.cmd(0x2D);
			int bytes = r.range(0, 52);
			for (int i = 0; i < bytes; i++) d.par((uint8_t)r.u32());
			break;
		}
		case 7: d.cmd(r.chance(50) ? 0x21 : 0x20); break;
		case 8: d.cmd(r.chance(30) ? 0x39 : 0x38); break;
		case 9: {
			int s = r.range(0, H - 1), e = r.range(0, H - 1);
			d.cmd(0x30, {s >> 8, s & 255, e >> 8, e & 255});
			d.cmd(r.chance(50) ? 0x12 : 0x13);
			break;
		}
		case 10: {
			int t = r.range(0, 60), v = r.range(1, H - t), bb = H - t - v;
			d.cmd(0x33, {t >> 8, t & 255, v >> 8, v & 255, bb >> 8, bb & 255});
			int s = r.range(t, t + v - 1);
			d.cmd(0x37, {s >> 8, s & 255});
			break;
		}
		case 11: {  // register reads
			static const uint8_t rcmds[] = {0x04, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0xDA, 0xDB, 0xDC};
			d.cmd(rcmds[r.range(0, 10)]);
			int bytes = r.range(1, 7);
			for (int i = 0; i < bytes; i++) d.read_check("register read");
			break;
		}
		case 12: d.cmd(r.chance(70) ? 0x29 : 0x28); break;
		case 13: d.cmd(r.chance(70) ? 0x11 : 0x10); break;
		case 14: {  // undefined opcodes and the vendor 0x24, with parameters
			static const uint8_t odd[] = {0x24, 0x24, 0x00, 0x02, 0x3B, 0x3C, 0x45, 0xB0, 0xC5, 0xFF};
			d.cmd(odd[r.range(0, 9)]);
			int bytes = r.range(0, 5);
			for (int i = 0; i < bytes; i++) d.par((uint8_t)r.u32());
			break;
		}
		case 15: d.cmd(0x26, {1 << r.range(0, 4)}); break;
		case 16: d.cmd(r.chance(50) ? 0x35 : 0x34, {r.range(0, 1)}); break;
		case 17: if (r.chance(15)) d.cmd(0x01); break;
		default: d.cmd(0x13); break;
		}
	}
	// make most rounds visible
	if (r.chance(80)) { d.cmd(0x11); d.cmd(0x29); }
}

// ---------------------------------------------------------------------------
// 3. TE
// ---------------------------------------------------------------------------
void test_te(Bench &b) {
	const int lines = H + TE_VBLANK;
	const int line_clks = CLK_HZ / (TE_HZ * lines);
	const int frame = line_clks * lines;
	b.fast = true;
	b.cmd(0x11);
	b.cmd(0x35, {0x00});
	// rising edges and high time over three frames
	auto measure = [&](int cycles, std::vector<uint64_t> &rises, uint64_t &high) {
		rises.clear(); high = 0;
		int prev = b.t->te;
		for (int i = 0; i < cycles; i++) {
			b.tick();
			int te = b.t->te;
			if (te) high++;
			if (te && !prev) rises.push_back(b.clocks);
			prev = te;
		}
	};
	std::vector<uint64_t> rises;
	uint64_t high;
	measure(frame * 3 + 10, rises, high);
	CHECK(rises.size() >= 2, "TE mode 0: %zu rising edges in three frames", rises.size());
	for (size_t i = 1; i < rises.size(); i++)
		CHECK_EQ(rises[i] - rises[i - 1], frame, "TE period (clocks)");
	CHECK(high >= (uint64_t)(line_clks * TE_VBLANK * 3 - line_clks) && high <= (uint64_t)(line_clks * TE_VBLANK * 3 + line_clks),
		"TE mode 0 high time %llu clocks, want about %d", (unsigned long long)high, line_clks * TE_VBLANK * 3);
	printf("TE: period %d clocks = %.2f Hz at %d Hz clock\n", frame, (double)CLK_HZ / frame, CLK_HZ);

	// mode 1: a pulse every line as well
	b.cmd(0x35, {0x01});
	measure(frame * 2 + 10, rises, high);
	CHECK((int)rises.size() >= 2 * H - 4, "TE mode 1: %zu rising edges in two frames", rises.size());

	b.cmd(0x34);
	measure(frame + 10, rises, high);
	CHECK(high == 0, "TE high after TEOFF");
	b.cmd(0x35, {0x00});
	b.cmd(0x10);
	measure(frame + 10, rises, high);
	CHECK(high == 0, "TE high in sleep");
	b.cmd(0x11);
	// TE from outside
	b.t->te_ext_sel = 1;
	b.t->te_ext = 1; b.ticks(2);
	CHECK(b.t->te == 1, "TE does not follow te_ext");
	b.t->te_ext = 0; b.ticks(2);
	CHECK(b.t->te == 0, "TE does not follow te_ext low");
	b.t->te_ext_sel = 0;
	b.cmd(0x34);
	b.fast = false;
}

}  // namespace

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	uint32_t seed = 1;
	int rounds = 40;
	std::string out = "sim/build/out";
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = (uint32_t)atoi(argv[++i]);
		else if (!strcmp(argv[i], "--rounds") && i + 1 < argc) rounds = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--out") && i + 1 < argc) out = argv[++i];
	}
	Bench b(seed);
	Rng r(seed * 7 + 3);

	// power-on state: asleep, display off, all registers at their defaults
	{
		Model m;
		Both d{b, m};
		d.cmd(0x09);
		for (int i = 0; i < 5; i++) d.read_check("RDDST after power-on");
		d.cmd(0x04);
		for (int i = 0; i < 4; i++) d.read_check("RDDID");
		CHECK_EQ(b.scan(10, 10), BLANK, "picture while asleep");
	}

	test_reference(b, out);

	// random rounds against the model, which starts from the reference state
	{
		Model m;
		b.hw_reset_pin();
		Both d{b, m};
		// start from a known memory: clear it through the bus in 16 bpp
		d.cmd(0x3A, {0x05});
		d.cmd(0x2A, {0, 0, 0, W - 1});
		d.cmd(0x2B, {0, 0, 0, H - 1});
		d.cmd(0x2C);
		b.fast = true;
		for (int i = 0; i < W * H; i++) { d.par((uint8_t)(i >> 3)); d.par((uint8_t)i); }
		b.fast = false;
		d.cmd(0x11);
		d.cmd(0x29);
		compare_frame(b, m, "after clearing");
		for (int k = 0; k < rounds; k++) {
			// half the rounds with the video scanning, as in the core
			b.bg_scan = k % 2 == 1;
			random_round(d, r);
			char what[32];
			snprintf(what, sizeof what, "round %d", k);
			compare_frame(b, m, what);
			d.cmd(0x09);
			for (int i = 0; i < 5; i++) d.read_check("RDDST after a round");
		}
		printf("random rounds: %d done, %llu clocks so far\n", rounds, (unsigned long long)b.clocks);

		// /RES: registers back to their defaults, memory kept
		std::vector<uint16_t> before;
		d.cmd(0x13); d.cmd(0x20); d.cmd(0x38); d.cmd(0x36, {0x00});
		b.frame(before);
		b.hw_reset_pin();
		m.hw_reset();
		d.cmd(0x09);
		for (int i = 0; i < 5; i++) d.read_check("RDDST after /RES");
		d.cmd(0x11); d.cmd(0x29);
		std::vector<uint16_t> after;
		b.frame(after);
		CHECK(before == after, "frame memory changed across /RES");
	}

	test_te(b);

	printf("%llu clocks\n", (unsigned long long)b.clocks);
	return sim::finish("lcd_panel");
}
