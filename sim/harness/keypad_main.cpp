// Bench for rtl/board/keypad_matrix.sv.
//
//   Vkeypad_matrix [--seed N]
//
//  * every fitted key alone, found by the firmware's scan (one column driven
//    low at a time, the rest released, rows read), at its position in the
//    firmware's table, with the scan the other way round as well;
//  * positions without a switch never connect anything;
//  * the classic ghost: three corners of a rectangle held make the fourth
//    read as pressed;
//  * random keys and random drive patterns against a reference that joins
//    lines into nets (union-find): a net is low if any line in it is driven
//    low;
//  * the power key is outside the matrix and only moves PWRONX.
#include "Vkeypad_matrix.h"
#include "verilated.h"
#include "common.h"

#include <cstring>

namespace {

constexpr int ROWS = 6, COLS = 5;
// the firmware's table (INPUT.md section 3.2): name per row * 5 + column
const char *const NAMES[30] = {
	"Up", "Left", "RSoft", "Clear", "Menu",
	"Down", "Right", "End", "Edit", "OK",
	"LSoft", nullptr, "1", "6", "8",
	"Call", nullptr, "5", "7", "#",
	nullptr, nullptr, "9", "0", "3",
	nullptr, nullptr, "*", "2", "4",
};

struct Ref {
	int parent[11];
	int find(int x) { return parent[x] == x ? x : parent[x] = find(parent[x]); }
	// nodes 0-4 columns, 5-10 rows
	void levels(uint32_t keys, int coe, int cout, int roe, int rout, int &cin, int &rin) {
		for (int i = 0; i < 11; i++) parent[i] = i;
		for (int r = 0; r < ROWS; r++)
			for (int c = 0; c < COLS; c++)
				if (keys >> (r * COLS + c) & 1 && NAMES[r * COLS + c]) parent[find(c)] = find(COLS + r);
		bool low[11] = {};
		for (int c = 0; c < COLS; c++) if (coe >> c & 1 && !(cout >> c & 1)) low[find(c)] = true;
		for (int r = 0; r < ROWS; r++) if (roe >> r & 1 && !(rout >> r & 1)) low[find(COLS + r)] = true;
		cin = 0; rin = 0;
		for (int c = 0; c < COLS; c++) if (!low[find(c)]) cin |= 1 << c;
		for (int r = 0; r < ROWS; r++) if (!low[find(COLS + r)]) rin |= 1 << r;
	}
};

struct Bench {
	Vkeypad_matrix *t = new Vkeypad_matrix;
	~Bench() { t->final(); delete t; }
	void set(uint32_t keys, int coe, int cout, int roe, int rout) {
		t->keys = keys; t->col_oe = coe; t->col_out = cout; t->row_oe = roe; t->row_out = rout;
		t->eval();
	}
	// the firmware's way: each column low in turn, rows read active-low
	uint32_t scan_cols(uint32_t keys) {
		uint32_t seen = 0;
		for (int c = 0; c < COLS; c++) {
			set(keys, 1 << c, 0, 0, 0);
			for (int r = 0; r < ROWS; r++) if (!(t->row_in >> r & 1)) seen |= 1u << (r * COLS + c);
		}
		return seen;
	}
	uint32_t scan_rows(uint32_t keys) {
		uint32_t seen = 0;
		for (int r = 0; r < ROWS; r++) {
			set(keys, 0, 0, 1 << r, 0);
			for (int c = 0; c < COLS; c++) if (!(t->col_in >> c & 1)) seen |= 1u << (r * COLS + c);
		}
		return seen;
	}
};

}  // namespace

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	uint32_t seed = 1;
	for (int i = 1; i < argc; i++)
		if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = (uint32_t)atoi(argv[++i]);
	Bench b;
	sim::Rng rng(seed);
	b.t->power = 0;

	// nothing pressed: every line high whatever is driven high or released
	b.set(0, 0x1F, 0x1F, 0, 0);
	CHECK_EQ(b.t->row_in, 0x3F, "rows with nothing pressed");
	CHECK_EQ(b.t->col_in, 0x1F, "columns with nothing pressed");

	int fitted = 0;
	for (int i = 0; i < 30; i++) {
		uint32_t k = 1u << i;
		uint32_t seen = b.scan_cols(k), seen2 = b.scan_rows(k);
		if (NAMES[i]) {
			fitted++;
			if (seen != k) sim::fail("key %s alone: column scan sees %08x", NAMES[i], seen);
			if (seen2 != k) sim::fail("key %s alone: row scan sees %08x", NAMES[i], seen2);
		} else {
			if (seen || seen2) sim::fail("unfitted position %d connects lines", i);
		}
	}
	CHECK_EQ(fitted, 24, "fitted keys");

	// 5 (ROW3/COL2) and 7 (ROW3/COL3), the game keys, together: no ghost
	{
		uint32_t k = 1u << 17 | 1u << 18;
		CHECK_EQ(b.scan_cols(k), k, "5 and 7 held together");
	}
	// ghost: Up (0,0), Left (0,1), Right (1,1) held -> Down (1,0) reads pressed
	{
		uint32_t k = 1u << 0 | 1u << 1 | 1u << 6;
		CHECK_EQ(b.scan_cols(k), k | 1u << 5, "ghost key in the column scan");
	}
	// a long chain: rows and columns alternating through six keys
	{
		uint32_t k = 1u << (0 * 5 + 0) | 1u << (1 * 5 + 0) | 1u << (1 * 5 + 1) | 1u << (0 * 5 + 1) |
			1u << (0 * 5 + 2) | 1u << (2 * 5 + 2) | 1u << (2 * 5 + 3) | 1u << (3 * 5 + 3) |
			1u << (3 * 5 + 4) | 1u << (4 * 5 + 4) | 1u << (5 * 5 + 4);
		b.set(k, 1, 0, 0, 0);
		CHECK_EQ(b.t->row_in, 0x00, "rows along a chain from column 0");
		CHECK_EQ(b.t->col_in, 0x00, "columns along a chain from column 0");
		b.set(k, 0, 0, 1 << 5, 0);
		CHECK_EQ(b.t->col_in, 0x00, "columns along a chain from row 5");
	}

	Ref ref;
	for (int i = 0; i < 200000; i++) {
		uint32_t keys = rng.u32() & 0x3FFFFFFF;
		int n = rng.range(0, 3);  // mostly few keys
		if (n < 3) { keys = 0; for (int j = 0; j < n + 1; j++) keys |= 1u << rng.range(0, 29); }
		int coe = rng.u32() & 31, cout = rng.u32() & 31, roe = rng.chance(30) ? rng.u32() & 63 : 0, rout = rng.u32() & 63;
		int cin, rin;
		ref.levels(keys, coe, cout, roe, rout, cin, rin);
		b.set(keys, coe, cout, roe, rout);
		if (b.t->col_in != cin || b.t->row_in != rin) {
			sim::fail("keys %08x col oe/out %02x/%02x row oe/out %02x/%02x: cols %02x rows %02x, want %02x %02x",
				keys, coe, cout, roe, rout, b.t->col_in, b.t->row_in, cin, rin);
		}
	}

	b.set(0, 0, 0, 0, 0);
	CHECK_EQ(b.t->pwronx, 1, "PWRONX released");
	b.t->power = 1;
	b.set(0, 0x1F, 0, 0, 0);
	CHECK_EQ(b.t->pwronx, 0, "PWRONX with the power key held");
	CHECK_EQ(b.t->row_in, 0x3F, "the power key in the matrix");
	return sim::finish("keypad_matrix");
}
