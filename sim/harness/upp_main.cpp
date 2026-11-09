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
	int safe_fill = -1; // explicit first-ACK class expectation for mode tests
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
	std::vector<uint32_t> raw_beats;
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
		t->dma_cyc = 0; t->dma_stb = 0; t->dma_we = 0; t->dma_adr = 0; t->dma_dat_i = 0; t->dma_sel = 0;
		t->save_rd = 0; t->save_blk = 0;
		t->ld_we = 0; t->ld_rd = 0; t->ld_addr = 0; t->ld_din = 0; t->ld_be = 0;
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
		bool safe_fill = t->wb_no_late_error;
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
			else beat_done(rdat, err, safe_fill);
		}
		t->clk = 0;
		t->eval();
	}

	void beat_done(uint32_t rdat, bool err, bool safe_fill) {
		Beat &b = cur.beats[bi];
		Region r = region(b.adr);
		acks++;
		if (bi == 0) {
			// Only the first ACK carries the contract. Non-raw flash reads
			// are array reads; raw command/status tests give explicit classes.
			bool wrap_read = !cur.we && cur.bte == 1 && b.cti == 2 && b.sel == 15;
			int want_safe = cur.safe_fill;
			if (want_safe < 0 && (!raw || (r != R_CS0 && r != R_CS1) || !wrap_read))
				want_safe = wrap_read && (r == R_SDRAM || r == R_ONCHIP || r == R_CS0 || r == R_CS1);
			if (want_safe >= 0 && safe_fill != bool(want_safe))
				sim::fail("%s: first-ACK no-late-error=%d, expected %d", cur.what.c_str(), safe_fill, want_safe);
		}
		if (err) sim::fail("%s: ERR at %08x", cur.what.c_str(), b.adr);
		if (r == R_UNMAPPED) unmapped_txn_beats++;
		if (cur.we) {
			apply_write(b.adr, b.sel, b.dat);
		} else if (raw) {
			last_rdat = rdat;
			raw_beats.push_back(rdat);
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
		if (raw) raw_beats.clear();
		start = beat_seen = cyc;
		uint64_t limit = cyc + 20000;
		while (busy && cyc < limit) tick();
		if (busy) { sim::fail("%s at %08x: no answer", x.what.c_str(), x.beats[bi].adr); busy = false; }
	}

	void run_class(Txn x, bool safe_fill) {
		x.safe_fill = safe_fill;
		run(x);
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

// Directed checks for the wide flash line-read path and its fallback to the
// halfword engine:
//  * read-array line bursts (linear and wrap-4 from all 4 critical-word
//    offsets, cold miss and warm hit, CS0/CS1 and their address mirrors)
//    checked word-for-word against the halfword path;
//  * line bursts while a chip is in autoselect, CFI, program-busy status,
//    read-while-write in another bank, and erase-busy/erase-suspend status;
//  * bursts that cross a chip window boundary (CS1 -> CS2/CS3 empty window in
//    both read-array and status modes, and CS0 -> CS1).
void flash_line_bursts(Bench &b) {
	auto settle_idle = [&]() { for (int i = 0; i < 40; i++) b.tick(); };
	auto w16_at = [&](uint32_t base, uint32_t word, uint16_t v) {
		b.run(b.single(true, base + 2 * word, (word & 1) ? 0xC : 0x3, (uint32_t)v * 0x10001u, "flash cmd"));
	};
	auto r16_at = [&](uint32_t base, uint32_t word) -> uint16_t {
		b.raw = true;
		b.run(b.single(false, base + 2 * word, (word & 1) ? 0xC : 0x3, 0, "flash halfword read"));
		b.raw = false;
		return (uint16_t)(b.last_rdat >> ((word & 1) * 16));
	};
	// Read a 32-bit word via two halfword accesses on the halfword path (S_FLASH)
	auto r32_halfpath = [&](uint32_t byte_addr) -> uint32_t {
		uint32_t w = byte_addr & ~3u;
		b.raw = true;
		b.run(b.single(false, w, 0x3, 0, "halfpath lo"));
		uint32_t lo = b.last_rdat & 0xFFFFu;
		b.run(b.single(false, w, 0xC, 0, "halfpath hi"));
		uint32_t hi = (b.last_rdat >> 16) & 0xFFFFu;
		b.raw = false;
		return lo | (hi << 16);
	};
	auto unlock_at = [&](uint32_t base) { w16_at(base, 0x555, 0xAA); w16_at(base, 0x2AA, 0x55); };

	// 1. Measure quiet-bus clocks per 4-beat line in read-array mode (cold miss,
	//    second half of 32B cache line, warm hit linear, warm hit wrap-4 for
	//    offsets +0/+4/+8/+12) and compare every word against the halfword path.
	uint32_t bases[] = {
		0x00020000u, // CS0 canonical
		0x01020000u, // CS0 +16 MB mirror
		0x02010000u, // CS1 canonical
		0x02810000u, // CS1 +8 MB mirror
		0x03810000u  // CS1 +24 MB mirror
	};
	uint64_t cold_line_clks = 0, sibling_line_clks = 0, warm_line_clks = 0;
	uint64_t wrap_warm_clks[4] = {0, 0, 0, 0};
	uint64_t halfpath_line_clks = 0;

	for (size_t bi = 0; bi < sizeof(bases) / sizeof(bases[0]); bi++) {
		uint32_t base = bases[bi] + (uint32_t)(bi * 0x100u);
		// Evict the direct-mapped 128 KB cache line by reading the same index at +4 MB
		b.raw = true;
		b.run(b.single(false, base ^ 0x00400000u, 0x3, 0, "evict cache line"));
		b.raw = false;
		// Cold 16-byte line fill (misses 32-byte M10K cache line)
		settle_idle();
		Txn t_cold = b.burst(false, base, 4, 0, "flash cold line burst");
		b.raw = true;
		uint64_t c0 = b.cyc;
		b.run(t_cold);
		uint64_t dt_cold = b.cyc - c0;
		std::vector<uint32_t> got_cold = b.raw_beats;
		b.raw = false;
		if (bi == 0) cold_line_clks = dt_cold;

		// Next 16-byte line in the same 32-byte M10K cache line (already filled)
		settle_idle();
		Txn t_sib = b.burst(false, base + 0x10, 4, 0, "flash sibling line burst");
		b.raw = true;
		c0 = b.cyc;
		b.run(t_sib);
		uint64_t dt_sib = b.cyc - c0;
		std::vector<uint32_t> got_sib = b.raw_beats;
		b.raw = false;
		if (bi == 0) sibling_line_clks = dt_sib;

		// Warm 16-byte line fill (linear)
		settle_idle();
		b.raw = true;
		c0 = b.cyc;
		b.run(t_cold);
		uint64_t dt_warm = b.cyc - c0;
		std::vector<uint32_t> got_warm = b.raw_beats;
		b.raw = false;
		if (bi == 0) warm_line_clks = dt_warm;

		// Check all words against the halfword path
		settle_idle();
		c0 = b.cyc;
		for (int w = 0; w < 4; w++) {
			uint32_t want = r32_halfpath(base + 4 * w);
			CHECK_EQ(got_cold[w], want, "cold line burst vs halfword path");
			CHECK_EQ(got_warm[w], want, "warm line burst vs halfword path");
		}
		if (bi == 0) halfpath_line_clks = b.cyc - c0;
		for (int w = 0; w < 4; w++) {
			uint32_t want = r32_halfpath(base + 0x10 + 4 * w);
			CHECK_EQ(got_sib[w], want, "sibling line burst vs halfword path");
		}

		// Wrap-4 bursts starting at each critical-word offset (+0, +4, +8, +12),
		// both on a cold line and a warm line
		for (int off = 0; off < 4; off++) {
			uint32_t line_addr = base + 0x40 + 0x20 * off;
			uint32_t start_addr = line_addr + 4 * off;
			Txn t_wrap = b.burst(false, start_addr, 4, 1, "flash wrap-4 burst");

			// Evict cache line so the first wrap-4 burst is a cold DDR3 miss
			b.raw = true;
			b.run(b.single(false, line_addr ^ 0x00400000u, 0x3, 0, "evict wrap-4 cache line"));
			b.raw = false;

			// Cold wrap-4
			settle_idle();
			b.raw = true;
			b.run_class(t_wrap, true);
			std::vector<uint32_t> got_wcold = b.raw_beats;
			b.raw = false;

			// Warm wrap-4
			settle_idle();
			b.raw = true;
			c0 = b.cyc;
			b.run_class(t_wrap, true);
			uint64_t dt_wwarm = b.cyc - c0;
			std::vector<uint32_t> got_wwarm = b.raw_beats;
			b.raw = false;
			if (bi == 0) wrap_warm_clks[off] = dt_wwarm;

			for (int i = 0; i < 4; i++) {
				uint32_t widx = (off + i) & 3;
				uint32_t want = r32_halfpath(line_addr + 4 * widx);
				CHECK_EQ(got_wcold[i], want, "cold wrap-4 burst vs halfword path");
				CHECK_EQ(got_wwarm[i], want, "warm wrap-4 burst vs halfword path");
			}
		}
	}

	// 2. Line bursts in non-read-array modes (must take the halfword path):
	// 2a. Autoselect mode on CS0 and CS1 (linear and wrap-4)
	for (int cs = 0; cs < 2; cs++) {
		uint32_t base = cs ? 0x02000000u : 0x00000000u;
		uint16_t dev_id = cs ? 0x22FAu : 0x22F8u;
		unlock_at(base); w16_at(base, 0x555, 0x90);
		b.raw = true;
		b.run(b.burst(false, base, 4, 0, "autoselect linear burst"));
		std::vector<uint32_t> auto_lin = b.raw_beats;
		b.run_class(b.burst(false, base + 4, 4, 1, "autoselect wrap-4 burst"), false);
		std::vector<uint32_t> auto_wrap = b.raw_beats;
		b.raw = false;
		CHECK_EQ(auto_lin[0], 0x000000ECu | ((uint32_t)dev_id << 16), "autoselect burst word 0 (mfg + dev)");
		CHECK_EQ(auto_lin[1], 0x00000000u, "autoselect burst word 1 (lock=0)");
		CHECK_EQ(auto_wrap[0], auto_lin[1], "autoselect wrap-4 beat 0 (+4)");
		CHECK_EQ(auto_wrap[3], auto_lin[0], "autoselect wrap-4 beat 3 (+0)");
		w16_at(base, 0, 0xF0);
		// Immediately after F0 returns to read-array mode, a wrap-4 burst must read array data
		b.raw = true;
		b.run_class(b.burst(false, base + 8, 4, 1, "array wrap-4 after F0"), true);
		std::vector<uint32_t> after_f0 = b.raw_beats;
		b.raw = false;
		for (int i = 0; i < 4; i++) {
			uint32_t widx = (2 + i) & 3;
			CHECK_EQ(after_f0[i], r32_halfpath(base + 4 * widx), "array wrap-4 after F0 vs halfword path");
		}
	}

	// 2b. CFI mode on CS0
	w16_at(0, 0x55, 0x98);
	b.raw = true;
	b.run(b.burst(false, 2 * 0x10, 4, 0, "CFI linear burst"));
	std::vector<uint32_t> cfi_beats = b.raw_beats;
	b.raw = false;
	CHECK_EQ(cfi_beats[0], 0x00520051u, "CFI burst 'Q','R'");
	CHECK_EQ(cfi_beats[1], 0x00020059u, "CFI burst 'Y',0x02");
	w16_at(0, 0, 0xF0);

	// 2c. Program status mode (busy bank) and read-while-write (other bank)
	uint32_t pa = 0x7FF120; // top parameter sector in bank 15
	uint16_t old_w = b.flash_half(0, pa), new_w = (uint16_t)(old_w & 0x3CC3u);
	// Warm the line in cache before programming
	b.run(b.burst(false, 2 * (pa & ~7u), 4, 0, "warm line before program"));
	unlock_at(0); w16_at(0, 0x555, 0xA0); w16_at(0, pa, new_w);
	// Immediately do a 4-beat burst in the busy bank: must use S_FLASH status reads
	b.raw = true;
	b.run_class(b.burst(false, 2 * (pa & ~7u), 4, 1, "program status burst"), false);
	std::vector<uint32_t> pstat = b.raw_beats;
	b.raw = false;
	for (int i = 0; i < 4; i++) {
		uint16_t lo = (uint16_t)pstat[i], hi = (uint16_t)(pstat[i] >> 16);
		// In program status, DQ6 (bit 6) toggles on every halfword read
		CHECK_EQ((lo ^ hi) & 0x0040u, 0x0040u, "program status burst DQ6 toggles between halves");
		if (i > 0) {
			uint16_t prev_hi = (uint16_t)(pstat[i - 1] >> 16);
			CHECK_EQ((prev_hi ^ lo) & 0x0040u, 0x0040u, "program status burst DQ6 toggles between beats");
		}
	}
	while (((r16_at(0, pa) ^ new_w) & 0x80) != 0) {}
	// Verify coherent line burst after program against halfword path
	b.raw = true;
	b.run_class(b.burst(false, 2 * (pa & ~7u) + 4, 4, 1, "wrap-4 burst after program"), true);
	std::vector<uint32_t> post_prog = b.raw_beats;
	b.raw = false;
	for (int i = 0; i < 4; i++) {
		uint32_t widx = (1 + i) & 3;
		CHECK_EQ(post_prog[i], r32_halfpath(2 * (pa & ~7u) + 4 * widx), "coherent wrap-4 after program");
	}

	// 2d. Erase status burst and erase-suspend burst
	unlock_at(0); w16_at(0, 0x555, 0x80); unlock_at(0); w16_at(0, 0x7FF000, 0x30);
	b.raw = true;
	b.run_class(b.burst(false, 2 * 0x7FF008, 4, 1, "erase status wrap-4 burst"), false);
	std::vector<uint32_t> estat = b.raw_beats;
	b.raw = false;
	for (int i = 0; i < 4; i++) {
		uint16_t lo = (uint16_t)estat[i], hi = (uint16_t)(estat[i] >> 16);
		CHECK_EQ((lo ^ hi) & 0x0044u, 0x0044u, "erase status burst DQ6 and DQ2 toggle between halves");
	}
	// Suspend erase (B0): selected sector reads status (DQ7=1, DQ6 steady, DQ2 toggles),
	// other sectors read the array via the halfword path
	w16_at(0, 0x7FF000, 0xB0);
	b.raw = true;
	b.run(b.burst(false, 2 * 0x7FF000, 4, 0, "erase-suspend status burst"));
	std::vector<uint32_t> sstat = b.raw_beats;
	b.run_class(b.burst(false, 0x00001000, 4, 1, "erase-suspend other-bank array burst"), false);
	std::vector<uint32_t> sarray = b.raw_beats;
	b.raw = false;
	for (int i = 0; i < 4; i++) {
		uint16_t lo = (uint16_t)sstat[i], hi = (uint16_t)(sstat[i] >> 16);
		CHECK_EQ(lo & 0x0080u, 0x0080u, "erase-suspend DQ7=1");
		CHECK_EQ((lo ^ hi) & 0x0044u, 0x0004u, "erase-suspend DQ6 steady, DQ2 toggles");
		CHECK_EQ(sarray[i], r32_halfpath(0x00001000 + 4 * i), "erase-suspend array burst vs halfword path");
	}
	// Resume erase (30) and wait for completion
	w16_at(0, 0x7FF000, 0x30);
	while (r16_at(0, 0x7FF000) != 0xFFFF) {}

	// 3. Bursts crossing chip window boundaries:
	// 3a. CS1 -> CS2/CS3 (0x03FFFFF8, 0x03FFFFFC, 0x04000000, 0x04000004) in read-array mode
	b.raw = true;
	b.run(b.burst(false, 0x03FFFFF8u, 4, 0, "CS1 to CS2/CS3 crossing burst (read-array)"));
	std::vector<uint32_t> cross_arr = b.raw_beats;
	b.raw = false;
	CHECK_EQ(cross_arr[0], r32_halfpath(0x03FFFFF8u), "CS1->CS2 crossing beat 0 (CS1)");
	CHECK_EQ(cross_arr[1], r32_halfpath(0x03FFFFFCu), "CS1->CS2 crossing beat 1 (CS1)");
	CHECK_EQ(cross_arr[2], 0x00000000u, "CS1->CS2 crossing beat 2 (CS2 empty)");
	CHECK_EQ(cross_arr[3], 0x00000000u, "CS1->CS2 crossing beat 3 (CS2 empty)");

	// 3b. CS1 -> CS2/CS3 crossing burst while CS1 is in autoselect mode (halfword path)
	unlock_at(0x02000000u); w16_at(0x02000000u, 0x555, 0x90);
	b.raw = true;
	b.run(b.burst(false, 0x03FFFFF8u, 4, 0, "CS1 to CS2/CS3 crossing burst (autoselect)"));
	std::vector<uint32_t> cross_auto = b.raw_beats;
	b.raw = false;
	uint32_t want_auto_f8 = (uint32_t)r16_at(0x02000000u, 0x3FFFFCu) | ((uint32_t)r16_at(0x02000000u, 0x3FFFFDu) << 16);
	uint32_t want_auto_fc = (uint32_t)r16_at(0x02000000u, 0x3FFFFEu) | ((uint32_t)r16_at(0x02000000u, 0x3FFFFFu) << 16);
	CHECK_EQ(cross_auto[0], want_auto_f8, "CS1->CS2 autoselect crossing beat 0");
	CHECK_EQ(cross_auto[1], want_auto_fc, "CS1->CS2 autoselect crossing beat 1");
	CHECK_EQ(cross_auto[2], 0x00000000u, "CS1->CS2 autoselect crossing beat 2 (CS2 empty)");
	CHECK_EQ(cross_auto[3], 0x00000000u, "CS1->CS2 autoselect crossing beat 3 (CS2 empty)");
	w16_at(0x02000000u, 0, 0xF0);

	// 3c. CS0 -> CS1 (0x01FFFFF8, 0x01FFFFFC, 0x02000000, 0x02000004) in read-array mode
	b.raw = true;
	b.run(b.burst(false, 0x01FFFFF8u, 4, 0, "CS0 to CS1 crossing burst"));
	std::vector<uint32_t> cross_cs01 = b.raw_beats;
	b.raw = false;
	CHECK_EQ(cross_cs01[0], r32_halfpath(0x01FFFFF8u), "CS0->CS1 crossing beat 0 (CS0)");
	CHECK_EQ(cross_cs01[1], r32_halfpath(0x01FFFFFCu), "CS0->CS1 crossing beat 1 (CS0)");
	CHECK_EQ(cross_cs01[2], r32_halfpath(0x02000000u), "CS0->CS1 crossing beat 2 (CS1)");
	CHECK_EQ(cross_cs01[3], r32_halfpath(0x02000004u), "CS0->CS1 crossing beat 3 (CS1)");

	printf("flash 16B line clocks (quiet): cold miss %llu, sibling hit %llu, warm hit %llu "
		"(wrap-4 warm +0/+4/+8/+12: %llu/%llu/%llu/%llu), 8x halfword path %llu\n",
		(unsigned long long)cold_line_clks, (unsigned long long)sibling_line_clks,
		(unsigned long long)warm_line_clks,
		(unsigned long long)wrap_warm_clks[0], (unsigned long long)wrap_warm_clks[1],
		(unsigned long long)wrap_warm_clks[2], (unsigned long long)wrap_warm_clks[3],
		(unsigned long long)halfpath_line_clks);
	CHECK(warm_line_clks <= 12 && sibling_line_clks <= 12, "warm flash line fill exceeded 12 clocks");
	for (int off = 0; off < 4; off++)
		CHECK(wrap_warm_clks[off] <= 12, "warm wrap-4 flash line fill exceeded 12 clocks");
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
	for (uint32_t base : {0x00000000u, 0x02000000u, 0x04000000u, 0x08000000u,
							 0x0A000000u, 0x0C000000u, 0x0C100000u, 0x10000000u})
		for (uint32_t off = 0; off < 16; off += 4)
			b.run(b.burst(false, base + off, 4, 1, "first-ACK target class"));
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
	flash_line_bursts(b);
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
