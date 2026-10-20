// Bench for the memory system (rtl/upp/ngage_mem.sv: upp_bus with the SDRAM
// controller, the two NOR flash chips and their DDR3 path) driven by a
// scripted Wishbone B3 master, against the SDRAM chip model, the DDRAM port
// model, a peripheral responder with random wait states, and reference
// memories for every region of the map.
//
//   Vngage_mem [--seed N] [--txns N]
//
//  * classic single reads and writes with every SEL pattern (byte, halfword,
//    word) to every region, back to back and with gaps, mirrors included;
//  * bursts as ZAP makes them (4-beat incrementing line fills and
//    write-backs at 16-byte boundaries), longer linear bursts that cross a
//    line, and wrap-4 bursts from the middle of a line;
//  * CS2/CS3 read as no flash, the unmapped space reads 0 and is flagged;
//  * the peripheral bus carries the address, data and byte enables, holds
//    p_sel through p_wait, and drops it between accesses;
//  * a flash word program and a parameter-sector erase through the AMD
//    command set reach DDR3, and the autoselect IDs read back;
//  * the latency of each kind of access, printed.
#include "Vngage_mem.h"
#include "verilated.h"
#include "common.h"
#include "ddram_model.h"
#include "sdram_model.h"

#include <cstring>
#include <map>
#include <string>

namespace {

uint32_t OC_BYTES = 64u << 10;   // --onchip: the build's ONCHIP_BYTES
constexpr uint32_t EMIF_BYTES = 256;

enum Region { R_CS0, R_CS1, R_EMPTY, R_EMIF, R_SDRAM, R_ONCHIP, R_PERIPH, R_UNMAPPED };

Region region(uint32_t a) {
	if (a >> 28) return R_UNMAPPED;
	switch ((a >> 25) & 7) {
	case 0: return R_CS0;
	case 1: return R_CS1;
	case 2: case 3: return R_EMPTY;
	case 4: return R_EMIF;
	case 5: return R_SDRAM;
	case 6: return ((a >> 20) & 31) == 0 ? R_ONCHIP : R_PERIPH;
	default: return R_UNMAPPED;
	}
}

struct Beat { uint32_t adr; uint32_t dat; uint8_t sel; uint8_t cti; };
struct Txn {
	bool we = false;
	uint8_t bte = 0;
	std::vector<Beat> beats;
	std::string what;
};

struct Bench {
	Vngage_mem *t = new Vngage_mem;
	SdramChip chip;
	DdramModel ddr;
	sim::Rng rng;
	uint64_t cyc = 0;

	// references
	std::vector<uint8_t> sdram = std::vector<uint8_t>(16u << 20);
	std::vector<uint8_t> oc, oc_known;
	std::vector<uint8_t> emif = std::vector<uint8_t>(EMIF_BYTES), emif_known = std::vector<uint8_t>(EMIF_BYTES, 0);
	std::map<uint32_t, uint32_t> periph;       // by word address 27:2
	uint64_t unmapped_pulses = 0, unmapped_txn_beats = 0;

	// the master
	bool  raw = false;            // reads not checked; the data is kept in last_rdat
	uint32_t last_rdat = 0;
	std::string lat_prefix;
	bool  busy = false;
	Txn   cur;
	size_t bi = 0;
	uint64_t start = 0, beat_seen = 0;
	uint64_t acks = 0;
	// latency (clocks from the beat on the bus to its ack) by region and kind
	struct Lat { uint64_t n = 0, sum = 0, min = ~0ull, max = 0; void add(uint64_t v) { n++; sum += v; min = std::min(min, v); max = std::max(max, v); } };
	std::map<std::string, Lat> lat;

	// peripheral responder
	int  p_wait_left = 0;
	bool p_prev = false;
	uint64_t p_accesses = 0;

	Bench(uint32_t seed) : chip(seed * 5 + 3), ddr(48u << 20, seed * 11 + 7), rng(seed) {
		oc.assign(OC_BYTES, 0);
		oc_known.assign(OC_BYTES, 0);
		for (uint32_t b = 0; b < (16u << 20); b += 2) {
			uint16_t v = chip.lin(b >> 1);
			sdram[b] = (uint8_t)v;
			sdram[b + 1] = (uint8_t)(v >> 8);
		}
		ddr.prof.busy_pct = 10;
		ddr.prof.gap_pct = 5;
		t->clk = 0; t->reset = 1; t->sdram_init = 1; t->flash_rst_n = 1;
		t->wb_cyc = 0; t->wb_stb = 0; t->wb_we = 0; t->wb_adr = 0; t->wb_dat_i = 0; t->wb_sel = 0; t->wb_cti = 0; t->wb_bte = 0;
		t->p_rdata = 0; t->p_wait = 0;
		t->ld_we = 0; t->ld_addr = 0; t->ld_din = 0; t->ld_be = 0;
		t->ddram_busy = 0; t->ddram_dout = 0; t->ddram_dout_ready = 0; t->sdram_dq_i = 0;
		t->eval();
	}
	~Bench() { t->final(); delete t; }

	uint16_t flash_half(int cs, uint32_t word) { return ddr.half((cs ? 0x32000000u : 0x31000000u) + 2 * word); }

	// ---------------- the reference ----------------
	// expected read data of a beat; mask: lanes whose value is known
	uint32_t expect(uint32_t a, uint8_t sel, uint32_t &mask) {
		uint32_t v = 0;
		mask = 0;
		uint32_t w = a & ~3u;
		for (int i = 0; i < 4; i++) {
			uint8_t byte = 0;
			bool known = true;
			uint32_t b = w + i;
			switch (region(a)) {
			case R_CS0: { uint16_t h = flash_half(0, (b >> 1) & 0x7FFFFF); byte = (uint8_t)(h >> (8 * (b & 1))); break; }
			case R_CS1: { uint16_t h = flash_half(1, (b >> 1) & 0x3FFFFF); byte = (uint8_t)(h >> (8 * (b & 1))); break; }
			case R_SDRAM: byte = sdram[b & 0xFFFFFF]; break;
			case R_ONCHIP: byte = oc[b % OC_BYTES]; known = oc_known[b % OC_BYTES]; break;
			case R_EMIF: byte = emif[b % EMIF_BYTES]; known = emif_known[b % EMIF_BYTES]; break;
			case R_PERIPH: { auto it = periph.find((a & 0x0FFFFFFF) >> 2); byte = it == periph.end() ? 0 : (uint8_t)(it->second >> (8 * i)); known = it != periph.end(); break; }
			default: byte = 0; break;
			}
			// flash reads only the halfwords SEL asks for; the others read 0
			if ((region(a) == R_CS0 || region(a) == R_CS1) && sel != 0) {
				bool half_hi = i >= 2;
				bool wanted = half_hi ? (sel & 0xC) : (sel & 0x3);
				if (!wanted) byte = 0;
			}
			v |= (uint32_t)byte << (8 * i);
			if (known && (sel >> i & 1)) mask |= 0xFFu << (8 * i);
		}
		return v;
	}
	void apply_write(uint32_t a, uint8_t sel, uint32_t d) {
		uint32_t w = a & ~3u;
		for (int i = 0; i < 4; i++) {
			if (!(sel >> i & 1)) continue;
			uint8_t byte = (uint8_t)(d >> (8 * i));
			uint32_t b = w + i;
			switch (region(a)) {
			case R_SDRAM: sdram[b & 0xFFFFFF] = byte; break;
			case R_ONCHIP: oc[b % OC_BYTES] = byte; oc_known[b % OC_BYTES] = 1; break;
			case R_EMIF: emif[b % EMIF_BYTES] = byte; emif_known[b % EMIF_BYTES] = 1; break;
			default: break;   // flash writes are commands; the peripheral model keeps its own
			}
		}
	}

	// ---------------- the clock ----------------
	void drive_master() {
		if (!busy) { t->wb_cyc = 0; t->wb_stb = 0; return; }
		const Beat &b = cur.beats[bi];
		t->wb_cyc = 1; t->wb_stb = 1; t->wb_we = cur.we;
		t->wb_adr = b.adr; t->wb_dat_i = b.dat; t->wb_sel = b.sel; t->wb_cti = b.cti; t->wb_bte = cur.bte;
	}

	void tick() {
		drive_master();
		t->ddram_busy = ddr.busy;
		t->ddram_dout = ddr.dout;
		t->ddram_dout_ready = ddr.dout_ready;
		t->sdram_dq_i = chip.sample(cyc + 1);
		// the peripheral: a new access gets 0-4 wait clocks
		bool psel = t->p_sel;
		if (p_prev && !psel) sim::fail("p_sel dropped before the access completed (cycle %llu)", (unsigned long long)cyc);
		if (psel && !p_prev) p_wait_left = rng.chance(40) ? 0 : rng.range(1, 4);
		t->p_wait = psel && p_wait_left > 0;
		uint32_t pw = (t->p_addr & 0x0FFFFFFF) >> 2;
		{
			auto it = periph.find(pw);
			uint32_t v = it == periph.end() ? (uint32_t)(pw * 2654435761u) : it->second;
			if (psel && it == periph.end()) periph[pw] = v;
			// the data is only good in the clock that completes the access
			t->p_rdata = (psel && !t->p_wait) ? v : rng.u32();
		}
		t->eval();

		bool ack = t->wb_ack, err = t->wb_err;
		uint32_t rdat = t->wb_dat_o;
		bool p_done = psel && !t->p_wait;
		if (p_done) {
			p_accesses++;
			if (busy) {
				const Beat &b = cur.beats[bi];
				CHECK_EQ(t->p_addr, b.adr & 0x0FFFFFFF, "p_addr");
				CHECK_EQ(t->p_we, cur.we, "p_we");
				CHECK_EQ(t->p_be, b.sel, "p_be");
				if (cur.we) CHECK_EQ(t->p_wdata, b.dat, "p_wdata");
			} else {
				sim::fail("a peripheral access with no transaction on the bus");
			}
		}
		ddr.step(t->ddram_rd, t->ddram_we, t->ddram_addr, t->ddram_burstcnt, t->ddram_din, t->ddram_be);

		t->clk = 1;
		t->eval();
		cyc++;
		SdramPins sp;
		sp.cs_n = t->sdram_cs_n; sp.ras_n = t->sdram_ras_n; sp.cas_n = t->sdram_cas_n; sp.we_n = t->sdram_we_n;
		sp.ba = t->sdram_ba; sp.a = t->sdram_a; sp.dqm = t->sdram_dqml | t->sdram_dqmh << 1;
		sp.dq_oe = t->sdram_dq_oe != 0; sp.dq_o = t->sdram_dq_o;
		chip.edge(cyc, sp);
		if (t->unmapped) unmapped_pulses++;

		// the peripheral access completed at this edge
		if (p_done && cur.we) {
			uint32_t &v = periph[pw];
			for (int i = 0; i < 4; i++)
				if (t->p_be >> i & 1) v = (v & ~(0xFFu << (8 * i))) | (t->p_wdata & (0xFFu << (8 * i)));
		}
		if (psel && p_wait_left > 0) p_wait_left--;
		p_prev = psel && !p_done;

		if (ack || err) {
			if (!busy) sim::fail("ack with no transaction (cycle %llu)", (unsigned long long)cyc);
			else beat_done(rdat, err);
		}
		t->clk = 0;
		t->eval();
	}

	void beat_done(uint32_t rdat, bool err) {
		Beat &b = cur.beats[bi];
		Region r = region(b.adr);
		acks++;
		if (err) sim::fail("%s: ERR at %08x", cur.what.c_str(), b.adr);
		if (r == R_UNMAPPED) unmapped_txn_beats++;
		if (cur.we) {
			apply_write(b.adr, b.sel, b.dat);
		} else if (raw) {
			last_rdat = rdat;
		} else {
			uint32_t mask;
			uint32_t want = expect(b.adr, b.sel, mask);
			if ((rdat & mask) != (want & mask))
				sim::fail("%s: beat %zu read %08x sel %x: got %08x, want %08x (mask %08x, cycle %llu)", cur.what.c_str(), bi,
					b.adr, b.sel, rdat, want, mask, (unsigned long long)cyc);
		}
		static const char *rn[] = {"cs0", "cs1", "empty", "emif", "sdram", "onchip", "periph", "unmapped"};
		std::string k = lat_prefix + rn[r] + (cur.we ? " write" : " read") + (cur.beats.size() > 1 ? (bi == 0 ? " burst first" : " burst next") : "");
		lat[k].add(cyc - 1 - beat_seen);
		beat_seen = cyc;
		if (++bi == cur.beats.size()) busy = false;
	}

	void run(const Txn &x) {
		cur = x;
		bi = 0;
		busy = true;
		start = beat_seen = cyc;
		uint64_t limit = cyc + 20000;
		while (busy && cyc < limit) tick();
		if (busy) { sim::fail("%s at %08x: no answer", x.what.c_str(), x.beats[bi].adr); busy = false; }
	}

	// ---------------- transactions ----------------
	Txn single(bool we, uint32_t a, uint8_t sel, uint32_t d, const char *what) {
		Txn x;
		x.we = we;
		x.beats.push_back({a, d, sel, (uint8_t)(rng.chance(50) ? 0 : 7)});
		x.what = what;
		return x;
	}
	Txn burst(bool we, uint32_t a, int n, uint8_t bte, const char *what) {
		Txn x;
		x.we = we;
		x.bte = bte;
		x.what = what;
		for (int i = 0; i < n; i++) {
			x.beats.push_back({a, rng.u32(), 0xF, (uint8_t)(i == n - 1 ? 7 : 2)});
			switch (bte) {
			case 1: a = (a & ~0xFu) | ((a + 4) & 0xF); break;
			case 2: a = (a & ~0x1Fu) | ((a + 4) & 0x1F); break;
			case 3: a = (a & ~0x3Fu) | ((a + 4) & 0x3F); break;
			default: a += 4;
			}
		}
		return x;
	}

	uint32_t rand_addr(Region r) {
		uint32_t u = rng.u32();
		switch (r) {
		case R_CS0: return (rng.chance(10) ? 0x01000000u : 0) | (u & 0x3FFFC) | (rng.chance(30) ? (u & 0xFF0000) : 0);
		case R_CS1: return 0x02000000u | (rng.chance(10) ? 0x01000000u : 0) | (u & 0x1FFFC);
		case R_EMPTY: return 0x04000000u | (u & 0x03FFFFFC);
		case R_EMIF: return 0x08000000u | (u & 0xFC) | (rng.chance(10) ? (u & 0x01FFFF00) : 0);
		case R_SDRAM: return 0x0A000000u | (rng.chance(10) ? 0x01000000u : 0) | (rng.chance(70) ? (u & 0xFFFC) : (u & 0xFFFFFC));
		case R_ONCHIP: return 0x0C000000u | (u & (OC_BYTES - 4)) | (rng.chance(10) ? (u & 0xF0000 & ~(OC_BYTES - 1)) : 0);
		case R_PERIPH: return (rng.chance(70) ? 0x0C100000u : 0x0D000000u) | (u & 0x000FFFFC);
		default: return rng.chance(50) ? (0x0E000000u | (u & 0x01FFFFFC)) : (0x10000000u | (u & 0xEFFFFFFC));
		}
	}
	uint8_t rand_sel(uint32_t &a) {
		int k = rng.range(0, 9);
		if (k < 5) return 0xF;
		if (k < 8) return (uint8_t)(3 << (2 * rng.range(0, 1)));
		return (uint8_t)(1 << rng.range(0, 3));
	}
	Region rand_region(bool writes_ok) {
		int k = rng.range(0, 99);
		if (k < 35) return R_SDRAM;
		if (k < 55) return R_ONCHIP;
		if (k < 68) return R_CS0;
		if (k < 73) return R_CS1;
		if (k < 78) return R_EMIF;
		if (k < 90) return R_PERIPH;
		if (k < 95) return R_EMPTY;
		(void)writes_ok;
		return R_UNMAPPED;
	}

	void random_txn() {
		Region r = rand_region(true);
		bool flash = r == R_CS0 || r == R_CS1;
		bool we = !flash && rng.chance(40);
		bool can_burst = r == R_SDRAM || r == R_ONCHIP || flash || r == R_EMIF;
		uint32_t a = rand_addr(r);
		if (can_burst && rng.chance(40)) {
			int k = rng.range(0, 9);
			if (k < 6) run(burst(we, a & ~0xFu, 4, 0, we ? "line write-back" : "line fill"));
			else if (k < 8) run(burst(we, a, rng.range(2, 10), 0, we ? "linear write burst" : "linear read burst"));
			else run(burst(we, a, 4, 1, we ? "wrap-4 write burst" : "wrap-4 read burst"));
		} else {
			uint8_t sel = rand_sel(a);
			run(single(we, a, sel, rng.u32(), we ? "single write" : "single read"));
		}
		if (rng.chance(30)) for (int i = 0, n = rng.range(1, 8); i < n; i++) tick();
	}
};

// the AMD command set on CS0 through the bus: autoselect, a word program, a
// parameter-sector erase
void flash_commands(Bench &b) {
	auto w16 = [&](uint32_t word, uint16_t v) { b.run(b.single(true, 2 * word, (word & 1) ? 0xC : 0x3, (uint32_t)v * 0x10001u, "flash command")); };
	// status and ID reads are checked here, not against the array
	auto r16 = [&](uint32_t word) -> uint16_t {
		b.raw = true;
		b.run(b.single(false, 2 * word, (word & 1) ? 0xC : 0x3, 0, "flash status"));
		b.raw = false;
		return (uint16_t)(b.last_rdat >> ((word & 1) * 16));
	};
	auto unlock = [&]() { w16(0x555, 0xAA); w16(0x2AA, 0x55); };

	// autoselect
	unlock(); w16(0x555, 0x90);
	CHECK_EQ(r16(0), 0x00EC, "CS0 manufacturer ID through the bus");
	CHECK_EQ(r16(1), 0x22F8, "CS0 device ID through the bus");
	w16(0, 0xF0);

	// program a word in the top parameter sector (4K words at 0x7FF000):
	// only 1s may become 0s; data polling on DQ7 until it shows the data
	uint32_t pa = 0x7FF123;
	uint16_t old = b.flash_half(0, pa), val = (uint16_t)(old & 0x5AA5);
	unlock(); w16(0x555, 0xA0); w16(pa, val);
	int polls = 0;
	while (((r16(pa) ^ val) & 0x80) && polls < 2000) polls++;
	CHECK(polls > 0, "no busy status after a program");
	CHECK_EQ(b.flash_half(0, pa), val, "programmed word in DDR3");
	b.run(b.single(false, 2 * pa, 0xC, 0, "read after program"));
	printf("flash program: %d status polls\n", polls);

	// erase that sector: every word becomes 0xFFFF
	unlock(); w16(0x555, 0x80); unlock(); w16(0x7FF000, 0x30);
	polls = 0;
	while (r16(0x7FF000) != 0xFFFF && polls < 200000) polls++;
	int bad = 0;
	for (uint32_t a = 0x7FF000; a < 0x800000; a++) if (b.flash_half(0, a) != 0xFFFF) bad++;
	CHECK_EQ(bad, 0, "words of the erased sector in DDR3 not 0xFFFF");
	b.run(b.burst(false, 2 * 0x7FF100, 4, 0, "line fill after erase"));
	printf("flash erase: %d status polls, %llu clocks so far\n", polls, (unsigned long long)b.cyc);
}

}  // namespace

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	uint32_t seed = 1;
	int txns = 30000;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = (uint32_t)strtoul(argv[++i], nullptr, 0);
		else if (!strcmp(argv[i], "--txns") && i + 1 < argc) txns = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--onchip") && i + 1 < argc) OC_BYTES = (uint32_t)strtoul(argv[++i], nullptr, 0);
	}
	Bench b(seed);
	for (int i = 0; i < 4; i++) b.tick();
	b.t->sdram_init = 0;
	while (!b.t->sdram_ready && b.cyc < 30000) b.tick();
	CHECK(b.t->sdram_ready, "SDRAM never ready");
	b.t->reset = 0;
	for (int i = 0; i < 600; i++) b.tick();     // the flash cache empties itself

	// the boot code's memory-controller set-up, read back
	const uint32_t emif_init[][2] = {{0x00, 0x7037F800}, {0x04, 0xB2950489}, {0x08, 0x37}, {0x10, 0x20202112}, {0x14, 0x20202112}, {0x18, 0x01100000}};
	for (auto &e : emif_init) b.run(b.single(true, 0x08000000u + e[0], 0xF, e[1], "EMIF set-up"));
	for (auto &e : emif_init) b.run(b.single(false, 0x08000000u + e[0], 0xF, 0, "EMIF read-back"));
	// the CS2 ID probe finds nothing
	b.run(b.single(false, 0x04000000u, 0x3, 0, "CS2 manufacturer"));
	b.run(b.single(false, 0x04000002u, 0xC, 0, "CS2 device"));

	// fill the on-chip RAM and EMIF block with write-back bursts so that every
	// byte is known
	for (uint32_t a = 0; a < OC_BYTES; a += 16) b.run(b.burst(true, 0x0C000000u + a, 4, 0, "on-chip RAM fill"));
	for (uint32_t a = 0; a < EMIF_BYTES; a += 16) b.run(b.burst(true, 0x08000000u + a, 4, 0, "EMIF fill"));

	// latencies on a quiet bus
	b.lat_prefix = "quiet ";
	auto quiet = [&](Txn x) { for (int i = 0; i < 40; i++) b.tick(); b.run(x); };
	quiet(b.single(false, 0x0A001000, 0xF, 0, "single read"));
	quiet(b.burst(false, 0x0A002000, 4, 0, "line fill"));
	quiet(b.single(false, 0x0C000100, 0xF, 0, "single read"));
	quiet(b.burst(false, 0x0C000200, 4, 0, "line fill"));
	quiet(b.burst(false, 0x00010000, 4, 0, "line fill"));
	quiet(b.burst(false, 0x00010010, 4, 0, "line fill"));
	b.lat_prefix = "";

	for (int i = 0; i < txns && sim::failures() < 20; i++) b.random_txn();

	flash_commands(b);
	for (int i = 0; i < 2000 && sim::failures() < 20; i++) b.random_txn();

	for (int i = 0; i < 100; i++) b.tick();
	CHECK_EQ(b.unmapped_pulses, b.unmapped_txn_beats, "unmapped pulses");
	if (b.chip.errors) sim::fail("the SDRAM chip model reported %d error(s)", b.chip.errors);
	if (b.ddr.protocol_errors) sim::fail("%d DDRAM port protocol error(s)", b.ddr.protocol_errors);
	CHECK(!b.ddr.bad_access, "DDR3 access outside the model");

	printf("%llu beats acked, %llu peripheral accesses, %llu clocks\n", (unsigned long long)b.acks,
		(unsigned long long)b.p_accesses, (unsigned long long)b.cyc);
	printf("clocks from a beat on the bus to its ack (min / mean / max):\n");
	for (auto &kv : b.lat)
		printf("  %-26s %6llu x  %3llu / %5.1f / %llu\n", kv.first.c_str(), (unsigned long long)kv.second.n,
			(unsigned long long)kv.second.min, (double)kv.second.sum / kv.second.n, (unsigned long long)kv.second.max);
	return sim::finish("ngage_mem");
}
