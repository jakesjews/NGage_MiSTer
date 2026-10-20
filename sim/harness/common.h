// Shared helpers for the Verilator benches: checks, a seeded RNG, PPM files.
#pragma once
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <string>
#include <vector>

namespace sim {

inline int &failures() {
	static int n = 0;
	return n;
}

// Report a failed check and keep going; the bench exits non-zero at the end.
inline void fail(const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "FAIL: ");
	vfprintf(stderr, fmt, ap);
	fprintf(stderr, "\n");
	va_end(ap);
	if (++failures() > 50) {
		fprintf(stderr, "too many failures, stopping\n");
		exit(1);
	}
}

#define CHECK(cond, ...) do { if (!(cond)) ::sim::fail(__VA_ARGS__); } while (0)
#define CHECK_EQ(got, want, what) do { \
	long long g_ = (long long)(got), w_ = (long long)(want); \
	if (g_ != w_) ::sim::fail("%s: got 0x%llx, want 0x%llx", what, g_, w_); } while (0)

inline int finish(const char *name) {
	if (failures()) {
		fprintf(stderr, "%s: %d check(s) failed\n", name, failures());
		return 1;
	}
	printf("%s: all checks passed\n", name);
	return 0;
}

struct Rng {
	std::mt19937 g;
	explicit Rng(uint32_t seed) : g(seed) {}
	uint32_t u32() { return g(); }
	int range(int lo, int hi) { return lo + (int)(g() % (uint32_t)(hi - lo + 1)); }
	bool chance(int pct) { return (int)(g() % 100) < pct; }
};

// RGB888 picture
struct Image {
	int w = 0, h = 0;
	std::vector<uint8_t> rgb;
	Image() = default;
	Image(int w_, int h_) : w(w_), h(h_), rgb((size_t)w_ * h_ * 3, 0) {}
	void set(int x, int y, uint8_t r, uint8_t g, uint8_t b) {
		size_t i = ((size_t)y * w + x) * 3;
		rgb[i] = r; rgb[i + 1] = g; rgb[i + 2] = b;
	}
	uint32_t get(int x, int y) const {
		size_t i = ((size_t)y * w + x) * 3;
		return (uint32_t)rgb[i] << 16 | (uint32_t)rgb[i + 1] << 8 | rgb[i + 2];
	}
	bool write_ppm(const std::string &path) const {
		FILE *f = fopen(path.c_str(), "wb");
		if (!f) return false;
		fprintf(f, "P6\n%d %d\n255\n", w, h);
		fwrite(rgb.data(), 1, rgb.size(), f);
		fclose(f);
		return true;
	}
};

// RGB565 to the 24-bit value the video output gives (top bits repeated)
inline uint32_t rgb565_to_888(uint16_t p) {
	uint32_t r = (p >> 11) & 31, g = (p >> 5) & 63, b = p & 31;
	r = (r << 3) | (r >> 2);
	g = (g << 2) | (g >> 4);
	b = (b << 3) | (b >> 2);
	return r << 16 | g << 8 | b;
}

inline void set565(Image &im, int x, int y, uint16_t p) {
	uint32_t c = rgb565_to_888(p);
	im.set(x, y, (uint8_t)(c >> 16), (uint8_t)(c >> 8), (uint8_t)c);
}

}  // namespace sim
