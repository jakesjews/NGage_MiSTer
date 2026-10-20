// Bench for rtl/board/video_out.sv: timing and frame capture.
//
//   Vvideo_out [--out DIR]
//
// The bench plays the panel's scan port (answer four clocks after a request,
// held) from a test picture, samples the outputs at every pixel clock, and
// checks:
//  * a pixel every CE_DIV clocks; H_TOTAL pixels a line with hsync for H_SYNC;
//    V_TOTAL lines a frame with vsync for V_SYNC; 15.7 kHz and 60 Hz at
//    104 MHz;
//  * DE exactly over the picture (176x208, or 208x176 turned), centred on
//    H_CENTER / V_CENTER, HBlank/VBlank its complement, black outside;
//  * the captured picture against the test picture, unturned and turned
//    both ways;
//  * scan requests only for visible pixels, inside the panel;
//  * a change of orientation waits for the next frame.
// Captures go to DIR as PPM: the three orientations and one whole raster
// with the blanking shown.
#include "Vvideo_out.h"
#include "verilated.h"
#include "common.h"

#include <cstring>
#include <string>

namespace {

constexpr int CE_DIV = 16, H_TOTAL = 413, H_SYNC = 31, H_CENTER = 242;
constexpr int V_TOTAL = 262, V_SYNC = 3, V_CENTER = 140;
constexpr double CLK_HZ = 104e6;
constexpr int PW = 176, PH = 208;
constexpr int SRC_LAT = 4;

uint16_t source(int x, int y) {
	if (x < 8 && y < 8) return 0xF800;
	if (x == 0 || y == 0 || x == PW - 1 || y == PH - 1) return 0xFFFF;
	return (uint16_t)(((x * 31 / (PW - 1)) << 11) | ((y * 63 / (PH - 1)) << 5) | ((x ^ y) & 31));
}

struct Sample {
	bool hs, vs, hb, vb, de;
	uint32_t rgb;
};

struct Bench {
	Vvideo_out *t = new Vvideo_out;
	uint64_t clocks = 0;
	// the source's pipeline: a value enters when a request is seen
	struct Stage { bool v; uint16_t px; } pipe[SRC_LAT] = {};
	uint16_t held = 0;
	uint64_t last_ce = 0;
	bool bad_req = false;
	Sample last = {};

	Bench() {
		t->clk = 0; t->reset = 1; t->rotate = 0; t->scan_rgb = 0;
		t->eval();
		for (int i = 0; i < 3; i++) tick();
		t->reset = 0;
	}
	~Bench() { t->final(); delete t; }

	// one clock; returns true and fills s when the outputs hold a new pixel
	bool tick(Sample *s = nullptr) {
		bool req = t->scan_en && !t->reset;  // before the first clock the outputs are random
		int rx = t->scan_x, ry = t->scan_y;
		t->clk = 1; t->eval();
		// the source registers the request at this edge and answers SRC_LAT edges on
		for (int i = SRC_LAT - 1; i > 0; i--) pipe[i] = pipe[i - 1];
		pipe[0].v = req;
		if (req) {
			if (rx >= PW || ry >= PH) bad_req = true;
			pipe[0].px = source(rx < PW ? rx : 0, ry < PH ? ry : 0);
		}
		if (pipe[SRC_LAT - 1].v) held = pipe[SRC_LAT - 1].px;
		t->scan_rgb = held;
		t->clk = 0; t->eval();
		clocks++;
		if (t->ce_pix) {
			if (last_ce && clocks - last_ce != CE_DIV) sim::fail("pixel clock period %llu", (unsigned long long)(clocks - last_ce));
			last_ce = clocks;
			last = {(bool)t->hsync, (bool)t->vsync, (bool)t->hblank, (bool)t->vblank, (bool)t->de,
				(uint32_t)t->red << 16 | (uint32_t)t->green << 8 | t->blue};
			if (s) *s = last;
			return true;
		}
		return false;
	}
	// run to the first pixel of the next frame (vsync rising)
	void to_frame() {
		Sample s;
		bool prev = last.vs;
		for (;;) {
			if (tick(&s)) {
				if (s.vs && !prev) return;
				prev = s.vs;
			}
		}
	}
	// one whole frame of samples, starting with the vsync rising edge to_frame saw
	void frame(std::vector<Sample> &out) {
		out.clear();
		out.push_back(last);
		Sample s;
		while ((int)out.size() < H_TOTAL * V_TOTAL) if (tick(&s)) out.push_back(s);
	}
};

// Check one frame's timing and picture; returns the picture.
sim::Image check_frame(const std::vector<Sample> &f, int rot, const char *name) {
	bool turned = rot == 1 || rot == 2;
	int aw = turned ? PH : PW, ah = turned ? PW : PH;
	int h0 = H_CENTER - aw / 2, v0 = V_CENTER - ah / 2;
	sim::Image pic(aw, ah);
	int bad = 0;
	for (int v = 0; v < V_TOTAL; v++)
		for (int h = 0; h < H_TOTAL; h++) {
			const Sample &s = f[(size_t)v * H_TOTAL + h];
			bool hact = h >= h0 && h < h0 + aw, vact = v >= v0 && v < v0 + ah;
			if (s.hs != (h < H_SYNC) || s.vs != (v < V_SYNC) || s.hb != !hact || s.vb != !vact || s.de != (hact && vact)) {
				if (bad++ < 5)
					sim::fail("%s: at h=%d v=%d hs=%d vs=%d hb=%d vb=%d de=%d", name, h, v, s.hs, s.vs, s.hb, s.vb, s.de);
				continue;
			}
			if (!s.de) {
				if (s.rgb && bad++ < 5) sim::fail("%s: colour %06x in the blanking at h=%d v=%d", name, s.rgb, h, v);
				continue;
			}
			int ox = h - h0, oy = v - v0, sx, sy;
			if (rot == 1) { sx = oy; sy = PH - 1 - ox; }
			else if (rot == 2) { sx = PW - 1 - oy; sy = ox; }
			else { sx = ox; sy = oy; }
			uint32_t want = sim::rgb565_to_888(source(sx, sy));
			pic.set(ox, oy, (uint8_t)(s.rgb >> 16), (uint8_t)(s.rgb >> 8), (uint8_t)s.rgb);
			if (s.rgb != want && bad++ < 5)
				sim::fail("%s: picture (%d,%d) = %06x, want %06x", name, ox, oy, s.rgb, want);
		}
	if (bad > 5) sim::fail("%s: %d samples wrong", name, bad);
	printf("%s: %dx%d at (%d,%d), %s\n", name, aw, ah, h0, v0, bad ? "FAILED" : "ok");
	return pic;
}

}  // namespace

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	std::string out = "sim/build/out";
	for (int i = 1; i < argc; i++)
		if (!strcmp(argv[i], "--out") && i + 1 < argc) out = argv[++i];

	Bench b;
	std::vector<Sample> f;

	// rates from the clocks between frames
	b.to_frame();
	uint64_t c0 = b.clocks;
	b.frame(f);
	b.to_frame();
	uint64_t per_frame = b.clocks - c0;
	double fps = CLK_HZ / per_frame, lps = fps * V_TOTAL;
	printf("frame: %llu clocks, %.3f Hz, line %.3f kHz, pixel %.3f MHz\n",
		(unsigned long long)per_frame, fps, lps / 1e3, CLK_HZ / CE_DIV / 1e6);
	CHECK_EQ(per_frame, (uint64_t)CE_DIV * H_TOTAL * V_TOTAL, "clocks a frame");
	CHECK(fps > 59.8 && fps < 60.2, "frame rate %.3f Hz", fps);
	CHECK(lps > 15620 && lps < 15850, "line rate %.1f Hz", lps);
	// the vsync rising edge comes with the hsync rising edge
	CHECK(f[0].hs && f[0].vs, "vsync does not start with hsync");

	sim::Image raster(H_TOTAL, V_TOTAL);
	auto shoot = [&](int rot, const char *name, const char *file) {
		b.t->rotate = rot;
		b.to_frame();  // the setting is taken at a frame boundary
		b.to_frame();
		b.frame(f);
		sim::Image pic = check_frame(f, rot, name);
		pic.write_ppm(out + "/" + file);
		if (rot == 0) {
			for (int v = 0; v < V_TOTAL; v++)
				for (int h = 0; h < H_TOTAL; h++) {
					const Sample &s = f[(size_t)v * H_TOTAL + h];
					if (s.de) raster.set(h, v, (uint8_t)(s.rgb >> 16), (uint8_t)(s.rgb >> 8), (uint8_t)s.rgb);
					else if (s.hs || s.vs) raster.set(h, v, 96, 0, 0);
					else raster.set(h, v, 32, 32, 48);
				}
			raster.write_ppm(out + "/video_raster.ppm");
		}
	};
	shoot(0, "portrait", "video_portrait.ppm");
	shoot(1, "turned clockwise", "video_cw.ppm");
	shoot(2, "turned anticlockwise", "video_ccw.ppm");
	shoot(3, "rotate=3 (portrait)", "video_rot3.ppm");

	// a change in the middle of a frame waits for the next one
	b.t->rotate = 0;
	b.to_frame();
	b.to_frame();
	for (int px = 0; px < H_TOTAL * 100;) if (b.tick()) px++;
	b.t->rotate = 1;
	for (int px = 0; px < H_TOTAL * 10;) if (b.tick()) px++;
	CHECK(!b.t->rotated, "orientation changed in the middle of a frame");
	b.to_frame();
	b.frame(f);
	check_frame(f, 1, "turned after a change mid-frame");

	CHECK(!b.bad_req, "scan request outside the panel");
	return sim::finish("video_out");
}
