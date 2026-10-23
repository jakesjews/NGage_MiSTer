// Bench for rtl/mem/sdram.sv against the SDRAM chip model (sdram_model.h).
//
//   Vsdram [--seed N] [--cycles N] [--expect-fail] [--ras-ns N] [--rc-ns N]
// --ras-ns / --rc-ns match RTL timing overrides for long-timing stress runs.
//
//  * the power-up sequence, and every command afterwards, meet the chip's
//    timing (tRCD, tRP, tRAS, tRC, tRRD, tRFC, tWR, tMRD), the refresh
//    interval holds through traffic and long idle stretches, and the read
//    data is captured inside its window (CAS latency and board delay);
//  * random word reads, line reads (from any word, wrapping), word writes
//    and line writes with random byte enables, back to back and with gaps,
//    against a reference memory: every word read is right and comes in the
//    chip's order, the requests are taken in order;
//  * the port: busy, one request a time, the latencies in the header.
// --expect-fail inverts the result: the build has a deliberate timing fault
// (see sim/Makefile) that the chip model must report.
#include "Vsdram.h"
#include "verilated.h"
#include "common.h"
#include "sdram_model.h"

#include <cstring>
#include <deque>
#include <string>

namespace {

// Negative controls for the model itself. Each sequence violates one rule
// only, so a passing controller cannot hide a missing timing check.
void model_guards() {
	for (int test = 0; test < 7; test++) {
		SdramTiming timing;
		timing.powerup = 0;
		timing.init_refreshes = 1;
		if (test == 0) timing.ras = 100;
		if (test == 4) timing.refi = 200000;
		if (test == 5) timing.rc = 120;
		SdramChip chip(1, timing);
		chip.quiet = true;
		auto command = [&](uint64_t edge, int cmd, int addr = 0) {
			SdramPins p;
			p.cs_n = false; p.ras_n = cmd & 4; p.cas_n = cmd & 2; p.we_n = cmd & 1;
			p.a = addr; p.dq_oe = cmd == 4;
			chip.edge(edge, p);
		};
		command(0, 2, 1024);
		command(3, 1);
		command(11, 0, 0x223);
		CHECK_EQ(chip.errors, 0, "model guard setup");
		switch (test) {
		case 0: // tRAS still dates from ACTIVE after repeated column accesses
			command(13, 3); command(16, 5); command(22, 5); command(23, 2); break;
		case 1: // refresh must not silently close an open bank
			command(13, 3); command(22, 1); break;
		case 2: // PRECHARGE ALL to refresh needs tRP even if already closed
			command(13, 2, 1024); command(15, 1); break;
		case 3: // include the first runtime refresh deadline
			command(817, 7); break;
		case 4: // keep the original ACTIVE age until the row really closes
			command(13, 3); command(10414, 7); break;
		case 5: // tRP alone does not satisfy tRC
			command(13, 3); command(18, 2); command(21, 3); break;
		case 6: // recovery after the last of several writes
			command(13, 3); command(16, 4); command(17, 4); command(18, 2); break;
		}
		CHECK_EQ(chip.errors, 1, "model rejected exactly the injected violation");
	}
	printf("model guards: tRAS min/max, tRC, tWR, open-bank refresh, tRP and first refresh deadline checked\n");
}

struct Pending {
	uint32_t block;      // byte address of the 16-byte block
	int      word;       // next word expected
	int      left;
	uint8_t  data[16];   // the block when the read was taken
	uint64_t taken;
	bool     first;
	bool     line;
	uint64_t returned = 0;
};

// Shadow mappings see exactly the same accepted traffic and refreshes.
// They estimate locality only, without claiming a change in execution time.
struct Mapping {
	int shift;
	int rows[4] = {-1, -1, -1, -1};
	uint64_t hits = 0, total = 0;
	void access(uint32_t a) {
		int bank = (a >> shift) & 3;
		int row = int(((a >> (shift + 2)) << (shift - 10)) | ((a >> 10) & ((1u << (shift - 10)) - 1)));
		hits += rows[bank] == row;
		total++;
		rows[bank] = row;
	}
	void refresh() { for (auto &r : rows) r = -1; }
};

struct Bench {
	Vsdram *t = new Vsdram;
	SdramChip chip;
	sim::Rng rng;
	uint64_t cyc = 0;
	std::vector<uint8_t> ref;
	std::deque<Pending> rd;
	uint64_t words_checked = 0, taken[4] = {0, 0, 0, 0};
	uint64_t lat_word_min = ~0ull, lat_word_max = 0, lat_line_min = ~0ull, lat_line_max = 0, lat_line_last_max = 0;
	uint64_t ready_at = 0;
	uint64_t last_first = 0, last_word = 0, last_taken = 0;
	uint64_t row_hits = 0, row_closed = 0, row_misses = 0;
	uint64_t pre_all_at = 0, refresh_at = 0;
	Mapping maps[3] = {{23}, {10}, {12}};

	// the request presented to the controller
	bool     have = false;
	bool     r_we = false, r_line = false;
	uint32_t r_addr = 0;        // byte address, word aligned
	uint8_t  r_data[16];
	uint16_t r_be = 0;

	Bench(uint32_t seed, SdramTiming timing) : chip(seed * 7 + 1, timing), rng(seed), ref(32u << 20) {
		// the chip's power-up contents are random; the reference follows them
		for (uint32_t h = 0; h < (16u << 20); h++) {
			uint16_t v = chip.lin(h);
			ref[2 * h] = (uint8_t)v;
			ref[2 * h + 1] = (uint8_t)(v >> 8);
		}
		t->clk = 0; t->init = 1; t->req = 0; t->we = 0; t->line = 0; t->addr = 0; t->wbe = 0;
		for (int i = 0; i < 4; i++) t->wdata[i] = 0;
		t->sdram_dq_i = 0;
		t->eval();
	}
	~Bench() { t->final(); delete t; }

	void pins(SdramPins &p) {
		p.cs_n = t->sdram_cs_n; p.ras_n = t->sdram_ras_n; p.cas_n = t->sdram_cas_n; p.we_n = t->sdram_we_n;
		p.ba = t->sdram_ba; p.a = t->sdram_a;
		p.dqm = t->sdram_dqml | t->sdram_dqmh << 1;
		p.dq_oe = t->sdram_dq_oe != 0;
		p.dq_o = t->sdram_dq_o;
		if (t->sdram_dq_oe != 0 && t->sdram_dq_oe != 0xFFFF) sim::fail("DQ output enables differ: %04x", t->sdram_dq_oe);
		if (!t->sdram_cke) sim::fail("CKE low");
		int cmd = p.ras_n << 2 | p.cas_n << 1 | p.we_n;
		// MiSTer modules take DQM on A12:A11 during READ and WRITE
		if (!p.cs_n && (cmd == 5 || cmd == 4) && ((p.a >> 11) & 3) != p.dqm)
			sim::fail("A12:A11 = %d but DQM = %d during %s", (p.a >> 11) & 3, p.dqm, cmd == 5 ? "READ" : "WRITE");
	}

	void tick() {
		t->sdram_dq_i = chip.sample(cyc + 1);
		bool take = have && t->req && !t->busy;
		t->clk = 1;
		t->eval();
		cyc++;
		if (take) accepted();
		if (t->rvalid) got_word();
		if (t->ready && !ready_at) ready_at = cyc;
		SdramPins p;
		pins(p);
		chip.edge(cyc, p);
		int cmd = p.ras_n << 2 | p.cas_n << 1 | p.we_n;
		if (!p.cs_n && cmd == 2 && (p.a & 1024)) pre_all_at = cyc;
		if (!p.cs_n && cmd == 1) {
			refresh_at = cyc;
			for (auto &m : maps) m.refresh();
		}
		t->clk = 0;
		t->eval();
	}
	void ticks(uint64_t n) { while (n--) tick(); }

	void accepted() {
		last_taken = cyc;
		int row = chip.open_row((r_addr >> 23) & 3);
		if (row < 0) row_closed++;
		else if (row == int((r_addr >> 10) & 8191)) row_hits++;
		else row_misses++;
		for (auto &m : maps) m.access(r_addr);
		taken[(r_we ? 2 : 0) + (r_line ? 1 : 0)]++;
		uint32_t block = r_addr & ~15u;
		if (r_we) {
			for (int i = 0; i < 16; i++)
				if ((r_line || i / 4 == int((r_addr >> 2) & 3)) && (r_be >> i & 1)) ref[block + i] = r_data[i];
		} else {
			Pending q;
			q.block = block;
			q.word = (r_addr >> 2) & 3;
			q.left = r_line ? 4 : 1;
			memcpy(q.data, &ref[block], 16);
			q.taken = cyc;
			q.first = true;
			q.line = r_line;
			rd.push_back(q);
		}
		have = false;
		t->req = 0;
	}

	void got_word() {
		if (rd.empty()) { sim::fail("rvalid with no read outstanding (cycle %llu)", (unsigned long long)cyc); return; }
		Pending &q = rd.front();
		CHECK_EQ(t->rword, q.word, "rword");
		uint32_t want = 0;
		for (int i = 3; i >= 0; i--) want = want << 8 | q.data[4 * (t->rword & 3) + i];
		if (t->rdata != want)
			sim::fail("read of 0x%07x word %d (%s): got %08x, want %08x (cycle %llu)", q.block, t->rword,
				q.line ? "line" : "word", t->rdata, want, (unsigned long long)cyc);
		words_checked++;
		uint64_t lat = cyc - q.taken;
		if (!q.first) CHECK_EQ(cyc - q.returned, 2, "line words two clocks apart");
		q.returned = cyc;
		if (q.first) {
			last_first = lat;
			if (q.line) { lat_line_min = std::min(lat_line_min, lat); lat_line_max = std::max(lat_line_max, lat); }
			else { lat_word_min = std::min(lat_word_min, lat); lat_word_max = std::max(lat_word_max, lat); }
			q.first = false;
		}
		q.word = (q.word + 1) & 3;
		if (--q.left == 0) {
			last_word = lat;
			if (q.line) lat_line_last_max = std::max(lat_line_last_max, lat);
			rd.pop_front();
		}
	}

	void present(bool we, bool line, uint32_t addr, uint16_t be, const uint8_t *data) {
		have = true;
		r_we = we; r_line = line; r_addr = addr & ~3u; r_be = be;
		memcpy(r_data, data, 16);
		t->req = 1;
		t->we = we;
		t->line = line;
		t->addr = r_addr >> 2;
		t->wbe = be;
		for (int i = 0; i < 4; i++)
			t->wdata[i] = (uint32_t)data[4 * i] | (uint32_t)data[4 * i + 1] << 8 | (uint32_t)data[4 * i + 2] << 16 | (uint32_t)data[4 * i + 3] << 24;
	}

	uint32_t rand_addr() {
		// mostly a few hot rows, sometimes anywhere in the module
		if (rng.chance(60)) return (rng.u32() % 4) << 22 | (rng.u32() % 4) << 10 | (rng.u32() & 0x3FC);
		return rng.u32() & 0x1FFFFFC;
	}

	void random_request() {
		uint8_t d[16];
		for (auto &x : d) x = (uint8_t)rng.u32();
		uint32_t a = rand_addr();
		int k = rng.range(0, 99);
		if (k < 35) present(false, false, a, 0, d);
		else if (k < 60) present(false, true, a, 0, d);
		else if (k < 85) {
			int w = (a >> 2) & 3;
			uint16_t be = rng.chance(50) ? 0xF : (uint16_t)(rng.u32() & 0xF);
			present(true, false, a, (uint16_t)(be << (4 * w)), d);
		} else {
			uint16_t be = rng.chance(50) ? 0xFFFF : (uint16_t)rng.u32();
			present(true, true, a, be, d);
		}
	}

	// Finish on the cycle before the next possible acceptance, so repeated
	// calls exercise the minimum turnaround with no artificial idle cycles.
	uint64_t transfer(bool we, bool line, uint32_t addr, uint16_t be = 0xFFFF) {
		while (t->busy) tick();
		uint8_t data[16];
		for (int i = 0; i < 16; i++) data[i] = uint8_t(addr + i * 37 + cyc);
		present(we, line, addr, be, data);
		tick();
		while (t->busy) tick();
		CHECK(rd.empty(), "transfer completed with a read outstanding");
		return cyc + 1 - last_taken;
	}

	void fresh_refresh() {
		while (t->busy) tick();
		auto before = chip.refreshes;
		while (chip.refreshes == before) tick();
		while (t->busy) tick();
	}

	void timing_cases(bool exact) {
		for (int op = 0; op < 4; op++) {
			fresh_refresh();
			for (int kind = 0; kind < 3; kind++) {
				auto a = chip.activates, p = chip.precharges, stop = chip.stops;
				auto clocks = transfer(op & 2, op & 1, kind == 2 ? 0x400 : 0);
				printf("timing %s %s %s: first %llu last %llu next %llu ACTIVE %llu PRE %llu\n",
					op & 1 ? "line" : "word", op & 2 ? "write" : "read",
					kind == 0 ? "closed" : kind == 1 ? "hit" : "miss",
					(unsigned long long)(op & 2 ? 0 : last_first), (unsigned long long)(op & 2 ? 0 : last_word),
					(unsigned long long)clocks, (unsigned long long)(chip.activates - a), (unsigned long long)(chip.precharges - p));
				CHECK_EQ(chip.activates - a, kind == 1 ? 0 : 1, "ACTIVE only on closed/missing row");
				CHECK_EQ(chip.precharges - p, kind == 2 ? 1 : 0, "PRECHARGE only on row conflict");
				CHECK_EQ(chip.stops - stop, op == 0 ? 1 : 0, "BURST TERMINATE only for word reads");
				if (exact) {
					int setup = kind == 0 ? 3 : kind == 1 ? 0 : 6;
					CHECK_EQ(clocks, setup + ((op & 2) ? 3 : 6) + ((op & 1) ? 6 : 0), "access clocks");
					if (!(op & 2)) {
						CHECK_EQ(last_first, setup + 5, "first word clocks");
						CHECK_EQ(last_word, setup + 5 + ((op & 1) ? 6 : 0), "last word clocks");
					}
				}
			}
		}
	}

	void directed(bool exact) {
		timing_cases(exact);
		fresh_refresh();
		auto acts = chip.activates;
		for (int bank = 0; bank < 4; bank++) transfer(false, true, uint32_t(bank) << 23);
		CHECK_EQ(chip.activates - acts, 4, "four banks opened independently");
		acts = chip.activates;
		for (int bank = 3; bank >= 0; bank--) transfer(false, true, (uint32_t(bank) << 23) | 0x3FC);
		CHECK_EQ(chip.activates, acts, "bank switching preserves all four rows");
		for (int bank = 0; bank < 4; bank++) CHECK(chip.open_row(bank) == 0, "bank %d lost its row", bank);
		fresh_refresh();
		for (int bank = 0; bank < 4; bank++) CHECK(chip.open_row(bank) == -1, "refresh left bank %d open", bank);
		CHECK_EQ(refresh_at - pre_all_at, 3, "PRECHARGE ALL to REFRESH");
		CHECK_EQ(cyc + 2 - refresh_at, 8, "REFRESH to next command");
		printf("timing refresh: PRECHARGE ALL to REFRESH %llu, to next request %llu clocks\n",
			(unsigned long long)(refresh_at - pre_all_at), (unsigned long long)(cyc + 2 - pre_all_at));

		// All read/write and word/line transitions, on a hit, across banks,
		// and on a conflict. Partial/zero enables include bytes outside the
		// requested word: those must never be written by a word access.
		for (int prev = 0; prev < 4; prev++) for (int next = 0; next < 4; next++) {
			fresh_refresh();
			for (uint32_t dest : {0u, 0x800000u, 0x400u}) {
				transfer(false, true, dest);
				transfer(prev & 2, prev & 1, 0, 0xA55A);
				transfer(next & 2, next & 1, dest, 0);
				transfer(false, true, 0);
				transfer(false, true, dest);
			}
		}
		for (uint32_t a : {0u, 0x3F0u, 0x7FFFF0u, 0x800000u, 0xFFFFF0u, 0x1000000u, 0x1FFFFF0u}) {
			for (int word = 0; word < 4; word++) {
				transfer(true, true, a + 4 * word, 0x5AA5);
				transfer(false, true, a + 4 * word);
				for (int mask = 0; mask < 16; mask++) {
					transfer(true, false, a + 4 * word, uint16_t(mask * 0x1111));
					transfer(false, true, a + 4 * word);
				}
			}
		}

		// Cover every phase of the refresh timer, including a request on
		// the cycle the due flag is raised, and long conflict accesses.
		for (int offset = 0; offset < 800; offset++) {
			fresh_refresh();
			ticks(offset);
			transfer(true, false, 0);
			transfer(offset & 1, true, 0x400);
			transfer(!(offset & 1), true, 0x400, 0xAA55);
		}
		// Sustained locality still has to yield to refresh.
		auto hot_hits = row_hits;
		for (int i = 0; i < 1024; i++) transfer(i & 1, true, uint32_t(i * 16) & 1023);
		printf("sustained line traffic in one row: %llu/1024 hits (%.2f%%)\n",
			(unsigned long long)(row_hits - hot_hits), 100.0 * (row_hits - hot_hits) / 1024);
		printf("directed: transitions, masks, wrap/bank boundaries, 800 refresh phases and sustained hits passed\n");
	}
};

}  // namespace

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	uint32_t seed = 1;
	uint64_t cycles = 400000;
	bool expect_fail = false;
	bool exact = true;
	SdramTiming timing;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = (uint32_t)strtoul(argv[++i], nullptr, 0);
		else if (!strcmp(argv[i], "--cycles") && i + 1 < argc) cycles = strtoull(argv[++i], nullptr, 0);
		else if (!strcmp(argv[i], "--expect-fail")) expect_fail = true;
		else if (!strcmp(argv[i], "--ras-ns") && i + 1 < argc) { timing.ras = atof(argv[++i]); exact = false; }
		else if (!strcmp(argv[i], "--rc-ns") && i + 1 < argc) { timing.rc = atof(argv[++i]); exact = false; }
	}
	Bench b(seed, timing);
	if (expect_fail) b.chip.quiet = true;
	else model_guards();

	// power-up
	b.ticks(4);
	b.t->init = 0;
	while (!b.t->ready && b.cyc < 40000) b.tick();
	CHECK(b.t->ready, "never ready");
	CHECK(b.chip.initialised(), "the chip's mode register was not set");
	printf("ready after %llu clocks (%.1f us)\n", (unsigned long long)b.cyc, b.cyc * b.chip.tm.tck / 1000);
	CHECK(!b.t->busy || b.cyc < 30000, "busy after power-up");

	// a request is not taken while busy, and is taken when not
	uint8_t z[16] = {0};
	b.present(false, false, 0x100, 0, z);
	b.tick();
	CHECK(!b.have, "a read was not taken at once on an idle controller");
	b.present(false, false, 0x200, 0, z);
	b.tick();
	CHECK(b.have, "a request was taken while busy");
	while (b.have) b.tick();
	b.ticks(40);
	if (!expect_fail) b.directed(exact);
	b.row_hits = b.row_closed = b.row_misses = 0;
	for (auto &m : b.maps) m.hits = m.total = 0;

	// random traffic: bursts back to back, gaps, and long idle stretches
	uint64_t end = b.cyc + cycles;
	while (b.cyc < end) {
		if (!b.have) {
			int g = b.rng.range(0, 99);
			if (g < 1) b.ticks(b.rng.range(500, 6000));        // idle: refresh on its own
			else if (g < 40) b.ticks(b.rng.range(1, 12));
			b.random_request();
		}
		b.tick();
		if (sim::failures() > 20) break;
	}
	while (b.have) b.tick();
	b.ticks(64);
	CHECK(b.rd.empty(), "reads still outstanding at the end");

	// refreshes: one per REFRESH_CLKS, never more than tREFI apart
	double us = b.cyc * b.chip.tm.tck / 1000;
	printf("%llu clocks (%.0f us): %llu word reads, %llu line reads, %llu word writes, %llu line writes, %llu words checked\n",
		(unsigned long long)b.cyc, us, (unsigned long long)b.taken[0], (unsigned long long)b.taken[1],
		(unsigned long long)b.taken[2], (unsigned long long)b.taken[3], (unsigned long long)b.words_checked);
	printf("refreshes %llu, longest gap %.0f ns (tREFI %.1f ns)\n", (unsigned long long)b.chip.refreshes,
		b.chip.max_refresh_gap, b.chip.tm.refi);
	printf("random traffic rows: %llu hits, %llu closed, %llu conflicts (%.2f%% hits)\n",
		(unsigned long long)b.row_hits, (unsigned long long)b.row_closed, (unsigned long long)b.row_misses,
		100.0 * b.row_hits / (b.row_hits + b.row_closed + b.row_misses));
	for (auto &m : b.maps) printf("shadow mapping bank bits %d:%d: %.2f%% hits (%llu/%llu)\n", m.shift + 1, m.shift,
		100.0 * m.hits / m.total, (unsigned long long)m.hits, (unsigned long long)m.total);
	printf("latency from the request taken to rvalid: word %llu-%llu, line first word %llu-%llu, last word up to %llu clocks\n",
		(unsigned long long)b.lat_word_min, (unsigned long long)b.lat_word_max, (unsigned long long)b.lat_line_min,
		(unsigned long long)b.lat_line_max, (unsigned long long)b.lat_line_last_max);
	double run_us = (b.cyc - b.ready_at) * b.chip.tm.tck / 1000;
	CHECK(b.chip.refreshes - 8 + 2 > (uint64_t)(run_us / 7.8125), "too few refreshes");
	CHECK(b.taken[0] && b.taken[1] && b.taken[2] && b.taken[3], "not every kind of access was made");
	if (b.chip.errors) sim::fail("the chip model reported %d timing or protocol error(s)", b.chip.errors);

	if (expect_fail) {
		if (sim::failures() == 0) {
			fprintf(stderr, "sdram: the deliberate fault was not caught\n");
			return 1;
		}
		printf("sdram: the deliberate fault was caught (%d chip errors, %d failed checks)\n", b.chip.errors, sim::failures());
		return 0;
	}
	return sim::finish("sdram");
}
