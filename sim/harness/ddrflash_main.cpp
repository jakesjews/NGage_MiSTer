// Bench for rtl/mem/ddram_flash.sv: the two flash chips' memory ports and
// the image loader on the DDRAM port model (ddram_model.h).
//
//   Vddram_flash [--seed N] [--rounds N]
//
//  * reads from both chips, as sequential runs (code fetch) and at random,
//    answer with the DDR3 contents at 0x31000000 + 2a (CS0) and
//    0x32000000 + 2a (CS1): from the beat buffer, the cache and on a miss;
//  * writes (programs, erase runs of 0xFFFF) reach DDR3 with only their two
//    byte lanes, and later reads see them, cached or not;
//  * the loader's writes get the port when it is free and are never lost;
//    the cache is emptied after a download, so reads see the new image;
//  * a reset in the middle of requests drops them without an answer, and
//    the port's Avalon rules hold (commands left waiting are not changed);
//  * every answer comes while its request is up, and only one;
//  * the scrambled area: reads of CS0 words inside the area the image names
//    at 0x174 / 0x178 answer with the stored word decoded (the formulas of
//    model/hw/ngage_scramble.h), everywhere else with the stored word; the
//    area follows the header after a load or a reset and not before; headers
//    that are not whole pages, out of order or beyond the chip give no area;
//    a word written inside the area reads back decoded.
#include "Vddram_flash.h"
#include "verilated.h"
#include "common.h"
#include "ddram_model.h"
#include "../../model/hw/ngage_scramble.h"

#include <cstring>

namespace {

constexpr uint32_t CS_BASE[2] = {0x31000000u, 0x32000000u};
constexpr uint32_t CS_WORDS[2] = {1u << 23, 1u << 22};

struct Port {
	int      n;
	bool     req = false, we = false;
	uint32_t addr = 0;
	uint16_t wdata = 0;
	uint64_t since = 0;
	int      gap = 0;
	// traffic: runs of sequential reads in a hot window, random reads,
	// writes and reads of what was just written
	uint32_t hot = 0, next = 0, last_write = 0;
	int      left = 0;
	bool     wrote = false;
	// stats
	uint64_t reads = 0, writes = 0, lat0 = 0, lat2 = 0, latmiss = 0, latmax = 0;
};

struct Bench {
	Vddram_flash *t = new Vddram_flash;
	DdramModel ddr;
	sim::Rng rng;
	uint64_t cyc = 0;
	Port p[2];
	bool reset = false;
	// what the flash arrays should hold: changed only by the requests and the loader
	std::vector<uint16_t> shadow[2];
	// loader
	bool     ld = false;
	uint32_t ld_addr = 0;
	uint16_t ld_data = 0;
	uint64_t ld_writes = 0;
	// the scrambled area the core has to be using: what the header in DDR3
	// named when the core last read it (after a reset or a load)
	bool     win_on = false;
	uint32_t win_first = 0, win_end = 0;
	uint64_t win_reads = 0;

	void latch_window() {
		win_on = ngage_scr_window(&ddr.mem[CS_BASE[0] - DdramModel::BASE], CS_WORDS[0] * 2, &win_first, &win_end);
	}
	bool in_window(int n, uint32_t a) const { return n == 0 && win_on && 2 * a >= win_first && 2 * a < win_end; }
	// what a read of word a must answer
	uint16_t view(int n, uint32_t a) const {
		return in_window(n, a) ? ngage_descramble(shadow[n][a], 2 * a) : shadow[n][a];
	}
	static bool header_word(int n, uint32_t a) { return n == 0 && a >= NGAGE_SCR_HDR_FIRST / 2 && a < NGAGE_SCR_HDR_END / 2 + 2; }

	Bench(uint32_t seed, uint32_t first = 0xA000, uint32_t end = 0x2AD000) : ddr(48u << 20, seed * 3 + 1), rng(seed) {
		// the header RH-29 carries, in the junk DDR3 starts with
		for (int i = 0; i < 4; i++) {
			ddr.byte(CS_BASE[0] + NGAGE_SCR_HDR_FIRST + i) = first >> (8 * i);
			ddr.byte(CS_BASE[0] + NGAGE_SCR_HDR_END + i) = end >> (8 * i);
		}
		latch_window();
		p[0].n = 0; p[1].n = 1;
		for (int n = 0; n < 2; n++) {
			shadow[n].resize(CS_WORDS[n]);
			for (uint32_t a = 0; a < CS_WORDS[n]; a++) shadow[n][a] = ddr.half(phys(n, a));
		}
		ddr.prof.busy_pct = 15;
		ddr.prof.gap_pct = 10;
		ddr.prof.stall_pct_x1000 = 500;
		t->clk = 0; t->reset = 1;
		t->cs0_req = 0; t->cs0_lreq = 0; t->cs0_laddr = 0;
		t->cs1_req = 0; t->cs1_lreq = 0; t->cs1_laddr = 0;
		t->ld_rd = 0; t->ld_we = 0; t->bk_req = 0; t->bk_blk = 0;
		t->ddram_busy = 0; t->ddram_dout = 0; t->ddram_dout_ready = 0;
		t->eval();
	}
	~Bench() { t->final(); delete t; }

	uint32_t phys(int n, uint32_t a) const { return CS_BASE[n] + 2 * a; }

	void drive() {
		t->reset = reset;
		t->cs0_req = p[0].req; t->cs0_we = p[0].we; t->cs0_addr = p[0].addr; t->cs0_wdata = p[0].wdata;
		t->cs1_req = p[1].req; t->cs1_we = p[1].we; t->cs1_addr = p[1].addr; t->cs1_wdata = p[1].wdata;
		t->ld_we = ld;
		t->ld_addr = ld_addr >> 3;
		t->ld_din = (uint64_t)ld_data * 0x0001000100010001ull;
		t->ld_be = (uint8_t)(3u << (ld_addr & 6));
		t->ddram_busy = ddr.busy;
		t->ddram_dout = ddr.dout;
		t->ddram_dout_ready = ddr.dout_ready;
	}

	void tick() {
		drive();
		t->eval();
		bool ack[2] = {(bool)t->cs0_ack, (bool)t->cs1_ack};
		uint16_t rdata[2] = {(uint16_t)t->cs0_rdata, (uint16_t)t->cs1_rdata};
		bool ld_taken = ld && !t->ld_busy;
		ddr.step(t->ddram_rd, t->ddram_we, t->ddram_addr, t->ddram_burstcnt, t->ddram_din, t->ddram_be);
		t->clk = 1;
		t->eval();
		cyc++;
		for (int n = 0; n < 2; n++) {
			Port &q = p[n];
			if (ack[n] && !q.req) sim::fail("CS%d ack without a request (cycle %llu)", n, (unsigned long long)cyc);
			if (ack[n] && reset) sim::fail("CS%d ack during reset", n);
			if (ack[n] && q.req) {
				uint64_t lat = cyc - 1 - q.since;
				if (q.we) {
					q.writes++;
					shadow[n][q.addr] = q.wdata;
					CHECK_EQ(ddr.half(phys(n, q.addr)), q.wdata, "written word in DDR3");
				} else {
					q.reads++;
					uint16_t want = view(n, q.addr);
					if (in_window(n, q.addr)) win_reads++;
					if (rdata[n] != want)
						sim::fail("CS%d read of %06x: got %04x, want %04x (cycle %llu)", n, q.addr, rdata[n], want, (unsigned long long)cyc);
					if (lat == 0) q.lat0++;
					else if (lat <= 2) q.lat2++;
					else q.latmiss++;
					q.latmax = std::max(q.latmax, lat);
				}
				q.req = false;
				q.gap = rng.chance(30) ? 0 : rng.range(1, 4);
			}
		}
		if (ld_taken) {
			ld = false;
			ld_writes++;
			int n = ld_addr >= CS_BASE[1];
			shadow[n][(ld_addr - CS_BASE[n]) / 2] = ld_data;
		}
		t->clk = 0;
		t->eval();
	}

	// the next request of a port, nor_flash style: held until answered
	void traffic(Port &q, bool writes) {
		if (q.req || reset) return;
		if (q.gap > 0) { q.gap--; return; }
		const uint32_t mask = CS_WORDS[q.n] - 1;
		q.req = true;
		q.since = cyc;
		q.we = false;
		int k = rng.range(0, 99);
		if (q.wrote && k < 30) {
			// read back what was just written (beat buffer and cache copy)
			q.addr = q.last_write;
			q.wrote = false;
			return;
		}
		if (writes && k < 20) {
			q.we = true;
			q.addr = (q.hot + (rng.u32() & 1023)) & mask;
			// the header changes only through loads here; main() programs it
			// by itself at the end
			if (header_word(q.n, q.addr)) q.addr += 8;
			q.wdata = rng.chance(40) ? 0xFFFF : (uint16_t)rng.u32();
			q.last_write = q.addr;
			q.wrote = true;
			return;
		}
		if (k < 75) {
			if (q.left == 0) { q.left = rng.range(4, 64); q.next = (q.hot + (rng.u32() & 1023)) & mask; }
			q.left--;
			q.addr = q.next;
			q.next = (q.next + 1) & mask;
			return;
		}
		q.addr = (rng.chance(80) ? q.hot + (rng.u32() & 1023) : rng.u32()) & mask;
	}

	// move the hot windows; on request CS0's goes into the scrambled area
	// or across one of its edges
	void new_windows(bool area) {
		for (auto &q : p) { q.hot = rng.chance(50) ? 0 : (rng.u32() & ~1023u); q.left = 0; }
		if (win_on && area) {
			uint32_t w0 = win_first / 2, w1 = win_end / 2;
			switch (rng.range(0, 2)) {
			case 0:  p[0].hot = w0 - 512; break;
			case 1:  p[0].hot = w1 - 512; break;
			default: p[0].hot = w0 + rng.u32() % (w1 - w0); break;
			}
			p[0].hot &= CS_WORDS[0] - 1;
		}
	}

	void run(uint64_t n, bool writes) {
		for (uint64_t i = 0; i < n; i++) {
			traffic(p[0], writes);
			traffic(p[1], writes);
			tick();
		}
	}
	// let the requests in flight finish
	void settle() {
		for (int i = 0; i < 20000 && (p[0].req || p[1].req); i++) tick();   // a sweep is 4096 clocks
		CHECK(!p[0].req && !p[1].req, "requests not answered");
	}

	// a download: reset held, the loader writes words as ddram_loader does
	// (in_reset false: the loader writes while the chips keep reading
	// elsewhere, which the shell never does, but the port must share)
	void download(int n, uint32_t first, uint32_t words, bool in_reset = true) {
		reset = in_reset;
		if (in_reset) p[0].req = p[1].req = false;
		tick();
		for (uint32_t w = 0; w < words; w++) {
			ld = true;
			ld_addr = phys(n, (first + w) & (CS_WORDS[n] - 1));
			ld_data = (uint16_t)rng.u32();
			while (ld) {
				if (!in_reset) { traffic(p[0], false); traffic(p[1], false); }
				tick();
			}
			if (rng.chance(30)) tick();
		}
		for (int i = 0; i < 10; i++) tick();
		reset = false;
		latch_window();   // the core reads the header again before it answers
	}

	// load the two header words (reset held, as a download)
	void plant_window(uint32_t first, uint32_t end) {
		reset = true;
		p[0].req = p[1].req = false;
		tick();
		const uint32_t at[4] = {NGAGE_SCR_HDR_FIRST, NGAGE_SCR_HDR_FIRST + 2, NGAGE_SCR_HDR_END, NGAGE_SCR_HDR_END + 2};
		const uint16_t val[4] = {(uint16_t)first, (uint16_t)(first >> 16), (uint16_t)end, (uint16_t)(end >> 16)};
		for (int i = 0; i < 4; i++) {
			ld = true; ld_addr = CS_BASE[0] + at[i]; ld_data = val[i];
			while (ld) tick();
		}
		for (int i = 0, n = rng.range(1, 6); i < n; i++) tick();
		reset = false;
		latch_window();
	}

	// one request, answered: a read returns its word
	uint16_t one(int n, bool we, uint32_t addr, uint16_t wdata = 0) {
		Port &q = p[n];
		q.req = true; q.we = we; q.addr = addr; q.wdata = wdata; q.since = cyc;
		uint16_t got = 0;
		for (int i = 0; i < 20000 && q.req; i++) {
			drive(); t->eval();
			got = n ? t->cs1_rdata : t->cs0_rdata;
			tick();
		}
		CHECK(!q.req, "request not answered");
		q.we = false;
		return got;
	}

	// Version reads must work under reset and drain any preceding chip read.
	void loader_read(uint32_t address, bool in_reset) {
		reset = in_reset;
		ld_addr = address;
		t->ld_rd = 1;
		bool accepted = false, answered = false;
		uint64_t want = 0;
		memcpy(&want, &ddr.mem[address - DdramModel::BASE], 8);
		for (int guard = 0; guard < 20000 && !answered; guard++) {
			drive(); t->eval();
			bool took = t->ld_rd && !t->ld_busy;
			answered = t->ld_valid;
			if (answered) {
				CHECK(accepted, "loader response after its command");
				CHECK_EQ(t->ld_data, want, "loader readback data");
			}
			tick();
			if (took) { accepted = true; t->ld_rd = 0; }
		}
		CHECK(answered, "loader read answered");
		reset = false;
	}

	// test a 16-byte line read (two 64-bit beats) on CS0 or CS1
	void line_read(int n, uint32_t beat_addr, bool expect_hit_order) {
		if (n == 0) { t->cs0_lreq = 1; t->cs0_laddr = beat_addr; }
		else        { t->cs1_lreq = 1; t->cs1_laddr = beat_addr; }
		int got = 0;
		int first_beat = -1;
		uint64_t beats[2] = {0, 0};
		for (int guard = 0; guard < 1000 && got < 2; guard++) {
			drive();
			t->eval();
			bool ltaken  = n ? t->cs1_ltaken  : t->cs0_ltaken;
			bool lrvalid = n ? t->cs1_lrvalid : t->cs0_lrvalid;
			int  lrbeat  = n ? t->cs1_lrbeat  : t->cs0_lrbeat;
			uint64_t lrdata = n ? t->cs1_lrdata : t->cs0_lrdata;
			ddr.step(t->ddram_rd, t->ddram_we, t->ddram_addr, t->ddram_burstcnt, t->ddram_din, t->ddram_be);
			t->clk = 1;
			t->eval();
			cyc++;
			if (ltaken) {
				if (n == 0) t->cs0_lreq = 0;
				else        t->cs1_lreq = 0;
			}
			if (lrvalid) {
				if (got == 0) first_beat = lrbeat;
				beats[lrbeat] = lrdata;
				got++;
			}
			t->clk = 0;
			t->eval();
		}
		CHECK_EQ(got, 2, "line read returned 2 beats");
		if (expect_hit_order)
			CHECK_EQ(first_beat, (int)(beat_addr & 1), "cache-hit line read returns critical 8-byte beat first");
		uint32_t base_word = (beat_addr & ~1u) * 4;
		for (int b = 0; b < 2; b++) {
			uint64_t want = (uint64_t)view(n, base_word + 4 * b + 0)
			              | ((uint64_t)view(n, base_word + 4 * b + 1) << 16)
			              | ((uint64_t)view(n, base_word + 4 * b + 2) << 32)
			              | ((uint64_t)view(n, base_word + 4 * b + 3) << 48);
			CHECK_EQ(beats[b], want, "line read 64-bit beat matches what the CPU is to read");
		}
	}
};

void test_blank(uint32_t seed) {
	Bench b(seed);
	for (int i = 0; i < 4; i++) b.tick();
	b.reset = false;
	auto load = [&](uint32_t byte, uint16_t data) {
		b.ld = true; b.ld_addr = CS_BASE[1] + byte; b.ld_data = data;
		while (b.ld) b.tick();
	};
	auto write = [&](int chip, uint32_t byte, uint16_t data) {
		auto &p = b.p[chip];
		p.req = true; p.we = true; p.addr = byte / 2; p.wdata = data; p.since = b.cyc;
		b.settle();
	};
	load(0, 0x1234); // firmware data does not affect C: blankness
	load(0x400000, 0xFFFF);
	load(0x7FFFFE, 0xFFFF);
	CHECK(b.t->c_blank, "erased loaded C: is blank");
	write(0, 0x400100, 0); write(1, 0x3FFFFE, 0);
	CHECK(b.t->c_blank, "CS0/lower CS1 writes leave C: blank");
	write(1, 0x7FFFFE, 0xFFFF);
	CHECK(b.t->c_blank, "C: erase leaves blank set");
	write(1, 0x7FFFFE, 0x1234);
	CHECK(!b.t->c_blank, "C: data away from first word clears blank");
	write(1, 0x7FFFFE, 0xFFFF);
	write(1, 0x400000, 0xFFFF);
	b.reset = true; b.tick(); b.reset = false; b.tick();
	CHECK(!b.t->c_blank, "erase/reset cannot re-arm blank");
	load(0, 0xFFFF);
	CHECK(!b.t->c_blank, "firmware reload cannot re-arm a mounted C: save");
	load(0x400000, 0xFFFF);
	CHECK(b.t->c_blank, "new C: image re-arms blank");
	load(0x7FFFFE, 0xFFFE); // last enabled byte lanes, first word still FF
	CHECK(!b.t->c_blank, "loaded data anywhere in C: clears blank");
	load(0x7FFFFE, 0xFFFF);
	CHECK(!b.t->c_blank, "loader FF cannot re-arm blank mid-image");
	load(0, 0xFFFF); load(0x400000, 0xFFFF);
	CHECK(b.t->c_blank, "fresh blank image after formatted save");
	// Leave no write request flags for the read tests that follow.
	b.p[0].we = b.p[1].we = false;
}

}  // namespace

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	uint32_t seed = 1;
	int rounds = 12;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = (uint32_t)strtoul(argv[++i], nullptr, 0);
		else if (!strcmp(argv[i], "--rounds") && i + 1 < argc) rounds = atoi(argv[++i]);
	}
	test_blank(seed);
	Bench b(seed);
	for (int i = 0; i < 4; i++) b.tick();
	b.reset = false;

	// a first read: misses, then the rest of its beat hits the beat buffer
	b.p[0].req = true; b.p[0].we = false; b.p[0].addr = 0x100; b.p[0].since = b.cyc;
	b.settle();
	for (uint32_t a = 0x101; a < 0x104; a++) {
		b.p[0].req = true; b.p[0].addr = a; b.p[0].since = b.cyc;
		b.tick();
		CHECK(!b.p[0].req, "a read in the same beat was not answered in its clock");
	}
	b.settle();

	for (int r = 0; r < rounds && sim::failures() < 20; r++) {
		// every other round reads and writes in the scrambled area (RH-29's
		// when an earlier round left the image without one)
		if ((r & 1) && !b.win_on) { b.settle(); b.plant_window(0xA000, 0x2AD000); }
		b.new_windows(r & 1);
		b.run(20000, true);
		// a reset in the middle of things; nor_flash drops its requests
		if (r % 3 == 1) {
			b.reset = true;
			b.p[0].req = b.p[1].req = false;
			for (int i = 0, n = b.rng.range(1, 6); i < n; i++) b.tick();
			b.reset = false;
		}
		// a download over a part of the image the reads use
		if (r % 4 == 2) {
			b.settle();
			b.download(b.rng.range(0, 1), b.p[0].hot + b.rng.range(0, 512), b.rng.range(200, 2000));
		}
		// another header: RH-29's, a small area where CS0's reads are, the
		// whole chip, or one that must not count
		if (r % 4 == 0 && r) {
			b.settle();
			uint32_t at = (2 * b.p[0].hot) & 0xFFF000;
			switch (b.rng.range(0, 5)) {
			case 0:  b.plant_window(0xA000, 0x2AD000); break;
			case 1:  b.plant_window(at, at + 0x1000); break;
			case 2:  b.plant_window(0, 0x1000000); break;
			case 3:  b.plant_window(0xA000, 0x2AD800); break;       // not whole pages
			case 4:  b.plant_window(0x2AD000, 0xA000); break;       // out of order
			default: b.plant_window(0xF00000, 0x1001000); break;    // beyond the chip
			}
		}
		// loader writes outside reset into CS1's top 2 KB, which the reads
		// then cover: the cache must be emptied for them
		if (r % 4 == 3) {
			b.settle();
			for (auto &q : b.p) q.hot = (CS_WORDS[q.n] - 1024) & (CS_WORDS[q.n] - 1);
			b.run(3000, false);
			b.settle();
			for (auto &q : b.p) q.hot = 0;
			b.download(1, CS_WORDS[1] - 1024, 1024, false);
			b.settle();
			for (auto &q : b.p) q.hot = (CS_WORDS[q.n] - 1024) & (CS_WORDS[q.n] - 1);
			b.run(3000, false);
		}
	}
	b.settle();
	// line reads on CS0 and CS1: cold miss, then warm hit starting on both beat 0 and beat 1
	for (int n = 0; n < 2; n++) {
		b.line_read(n, 0x200, false);
		b.line_read(n, 0x200, true);
		b.line_read(n, 0x201, true);
		b.line_read(n, 0x203, true);
	}
	for (int i = 0; i < 24; i++) {
		b.settle();
		// Start an uncached CPU read just before the loader asks for the port.
		b.p[0].req = true; b.p[0].we = false; b.p[0].addr = 0x10000 + i * 256; b.p[0].since = b.cyc;
		b.tick(); b.tick();
		b.loader_read(CS_BASE[i & 1] + 0x8F08 + 8 * i, false);
		b.settle();
		b.loader_read(CS_BASE[i & 1] + 0x8F08 + 8 * i, true);
	}

	// ---- the scrambled area, step by step
	b.settle();
	b.plant_window(0xA000, 0x2AD000);
	CHECK(b.win_on && b.win_first == 0xA000 && b.win_end == 0x2AD000, "RH-29's header names its area");
	{
		// the edges: the last word before, the first and last inside, the first after
		const uint32_t edge[4] = {0xA000 / 2 - 1, 0xA000 / 2, 0x2AD000 / 2 - 1, 0x2AD000 / 2};
		for (int i = 0; i < 4; i++) {
			uint16_t stored = b.shadow[0][edge[i]], got = b.one(0, false, edge[i]);
			bool inside = i == 1 || i == 2;
			CHECK_EQ(got, inside ? ngage_descramble(stored, 2 * edge[i]) : stored, "read at an edge of the area");
		}
		// CS1 at the same addresses is never decoded
		CHECK_EQ(b.one(1, false, 0xA000 / 2), b.shadow[1][0xA000 / 2], "CS1 is not scrambled");
		// a word written in the area: stored as given, read back decoded, from
		// a cached line and a beat buffer that held the old word
		uint32_t a = 0x9E4C4 / 2;
		b.one(0, false, a); b.one(0, false, a + 1);
		b.one(0, true, a, 0x1234);
		CHECK_EQ(b.ddr.half(b.phys(0, a)), 0x1234, "a write in the area is stored as given");
		CHECK_EQ(b.one(0, false, a), ngage_descramble(0x1234, 2 * a), "and reads back decoded");
		CHECK_EQ(b.one(0, false, a + 1), ngage_descramble(b.shadow[0][a + 1], 2 * (a + 1)), "its neighbour is unchanged");
		b.one(0, true, a + 5, 0xFFFF);   // an erased word does not read FFFF there
		CHECK_EQ(b.one(0, false, a + 5), ngage_descramble(0xFFFF, 2 * (a + 5)), "an erased word in the area reads decoded");
		// line reads inside and across the end of the area (0x2AD000 is a line start)
		b.line_read(0, 0x9E4C0 / 8, false);
		b.line_read(0, 0x9E4C0 / 8 + 1, true);
		b.line_read(0, 0x2ACFF0 / 8, false);
		b.line_read(0, 0x2AD000 / 8, false);
		// The header programmed through the flash port (0x2AD000 -> 0x2A0000,
		// clearing bits only): the area stays as it was until the next reset.
		uint32_t probe = 0x2A8000 / 2;
		b.one(0, true, NGAGE_SCR_HDR_END / 2, 0x0000);
		CHECK_EQ(b.one(0, false, probe), ngage_descramble(b.shadow[0][probe], 2 * probe), "a programmed header does not move the area at once");
		b.reset = true; b.p[0].req = b.p[1].req = false;
		for (int i = 0; i < 3; i++) b.tick();
		b.reset = false;
		b.latch_window();
		CHECK(b.win_on && b.win_end == 0x2A0000, "the bench's own view of the new header");
		CHECK_EQ(b.one(0, false, probe), b.shadow[0][probe], "after a reset the area is the header's");
		CHECK_EQ(b.one(0, false, 0x29FFFE / 2), ngage_descramble(b.shadow[0][0x29FFFE / 2], 0x29FFFE), "the new last word is decoded");
		// an erased header: no area at all
		b.plant_window(0xFFFFFFFF, 0xFFFFFFFF);
		CHECK(!b.win_on, "an erased header names no area");
		CHECK_EQ(b.one(0, false, a), b.shadow[0][a], "no area: the stored word");
	}
	CHECK(b.win_reads > 2000, "too few reads inside the scrambled area (%llu)", (unsigned long long)b.win_reads);
	printf("scrambled area: %llu reads decoded\n", (unsigned long long)b.win_reads);

	for (int i = 0; i < 200; i++) b.tick();
	CHECK(b.ddr.idle(), "DDR3 reads still in flight at the end");
	// nothing else in DDR3 changed
	int bad = 0;
	for (int n = 0; n < 2; n++)
		for (uint32_t a = 0; a < CS_WORDS[n]; a++)
			if (b.ddr.half(b.phys(n, a)) != b.shadow[n][a] && bad++ < 5)
				sim::fail("DDR3 at CS%d word %06x holds %04x, want %04x", n, a, b.ddr.half(b.phys(n, a)), b.shadow[n][a]);
	CHECK(!b.ddr.bad_access, "DDR3 access outside the flash windows");
	if (b.ddr.protocol_errors) sim::fail("%d DDRAM port protocol error(s)", b.ddr.protocol_errors);

	for (int n = 0; n < 2; n++) {
		Port &q = b.p[n];
		printf("CS%d: %llu reads (%llu from the beat buffer, %llu cache hits, %llu misses or waits, slowest %llu clocks), %llu writes\n", n,
			(unsigned long long)q.reads, (unsigned long long)q.lat0, (unsigned long long)q.lat2,
			(unsigned long long)q.latmiss, (unsigned long long)q.latmax, (unsigned long long)q.writes);
		CHECK(q.reads > 1000 && q.writes > 100 && q.lat0 && q.lat2 && q.latmiss, "too little traffic of some kind");
	}
	printf("DDR3: %llu reads, %llu writes; loader %llu writes; %llu clocks\n", (unsigned long long)b.ddr.reads,
		(unsigned long long)b.ddr.writes, (unsigned long long)b.ld_writes, (unsigned long long)b.cyc);
	return sim::finish("ddram_flash");
}
