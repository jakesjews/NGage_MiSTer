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
//  * every answer comes while its request is up, and only one.
#include "Vddram_flash.h"
#include "verilated.h"
#include "common.h"
#include "ddram_model.h"

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

	Bench(uint32_t seed) : ddr(48u << 20, seed * 3 + 1), rng(seed) {
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
		t->ld_we = 0; t->bk_req = 0; t->bk_blk = 0;
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
					uint16_t want = shadow[n][q.addr];
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

	// move the hot windows
	void new_windows() {
		for (auto &q : p) { q.hot = rng.chance(50) ? 0 : (rng.u32() & ~1023u); q.left = 0; }
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
			uint64_t want = (uint64_t)shadow[n][base_word + 4 * b + 0]
			              | ((uint64_t)shadow[n][base_word + 4 * b + 1] << 16)
			              | ((uint64_t)shadow[n][base_word + 4 * b + 2] << 32)
			              | ((uint64_t)shadow[n][base_word + 4 * b + 3] << 48);
			CHECK_EQ(beats[b], want, "line read 64-bit beat matches shadow");
		}
	}
};

}  // namespace

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	uint32_t seed = 1;
	int rounds = 12;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = (uint32_t)strtoul(argv[++i], nullptr, 0);
		else if (!strcmp(argv[i], "--rounds") && i + 1 < argc) rounds = atoi(argv[++i]);
	}
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
		b.new_windows();
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
