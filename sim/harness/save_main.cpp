// Bench for the CS1 save path (rtl/mister/flash_save.sv with ngage_mem and
// ddram_flash's marks and block reads; sim/harness/save_tb.sv): a scripted
// CPU drives the AMD command set on CS1 through the bus, with the DDRAM port
// model behind the flash arrays and a model of hps_io's SD slot holding the
// 8 MB save file.
//
//   Vsave_tb [--seed N]
//
//  * a mount of a file that is not 8 MB is refused (note 2) and loads nothing;
//  * mounting the 8 MB file copies it into DDR3 at 0x32000000 in 4 KB
//    requests while the memory system is held, byte for byte, and the CPU
//    reads it through the flash;
//  * nothing is written back while nothing changes;
//  * word programs (two in one block) and a parameter-sector erase in the C:
//    area: once the quiet time has passed, exactly the blocks they touched are
//    written back, each once, and the file equals the chip;
//  * a block written again while its write-back is on its way to the file is
//    written back a second time, with the new data;
//  * "Save C: now" writes back at once and reports it; with nothing to save it
//    reports at once;
//  * a stream of changes is written back at the latest MAX_CLKS after the
//    first;
//  * unsaved changes survive a core reset;
//  * after a detach (an ioctl load of CS1) nothing is written back;
//  * a read-only mount loads but never writes back (note 3).
#include "Vsave_tb.h"
#include "verilated.h"
#include "common.h"
#include "ddram_model.h"
#include "sdram_model.h"

#include <cstring>
#include <map>
#include <set>
#include <vector>

namespace {

constexpr uint32_t CS1_BYTES = 8u << 20;
constexpr uint32_t CS1_DDR = 0x32000000u;
constexpr int QUIET = 80000, MAXC = 300000;     // save_tb's QUIET_CLKS / MAX_CLKS
constexpr int SCAN = 2 * 16384 + 5000;          // a bitmap pass, a block read and an HPS delay

struct Hps {
	std::vector<uint8_t> img;
	enum { IDLE, DELAY, XFER, END } st = IDLE;
	bool wr = false;
	uint32_t lba = 0;
	int blocks = 0, delay = 0, word = 0, gap = 0, phase = 0;
	uint64_t reads = 0, writes = 0;
	std::vector<uint32_t> written;   // block numbers, in order
	std::vector<int> read_sizes;
	uint32_t hold_lba = ~0u;         // a write of this block waits hold_clks before its ack
	int hold_clks = 0;
	bool held = false;
};

struct Bench {
	Vsave_tb *t = new Vsave_tb;
	SdramChip chip;
	DdramModel ddr;
	Hps hps;
	sim::Rng rng;
	uint64_t cyc = 0;
	uint64_t last_mark = 0, marks = 0;
	int notes[4] = {0, 0, 0, 0};
	int saved_pulses = 0;
	uint64_t first_wr_req = 0;       // the clock of the first write request seen since cleared

	explicit Bench(uint32_t seed) : chip(seed * 5 + 3), ddr(48u << 20, seed * 11 + 7), rng(seed) {
		ddr.prof.busy_pct = 10;
		t->clk = 0; t->por = 1; t->reset = 1; t->sdram_init = 1;
		t->wb_cyc = 0; t->wb_stb = 0; t->wb_we = 0; t->wb_adr = 0; t->wb_dat_i = 0; t->wb_sel = 0; t->wb_cti = 7; t->wb_bte = 0;
		t->ddram_busy = 0; t->ddram_dout = 0; t->ddram_dout_ready = 0; t->sdram_dq_i = 0;
		t->img_mounted = 0; t->img_readonly = 0; t->img_size = 0; t->sd_ack = 0; t->sd_buff_addr = 0;
		t->sd_buff_dout = 0; t->sd_buff_wr = 0; t->detach = 0; t->save_now = 0;
		t->eval();
		for (int i = 0; i < 4; i++) tick();
		t->sdram_init = 0; t->por = 0;
		for (int i = 0; i < 4; i++) tick();
		t->reset = 0;
		for (int i = 0; i < 40000 && !t->sdram_ready; i++) tick();
		CHECK(t->sdram_ready, "SDRAM not ready");
		run(20000);                  // the bitmap clears after power-on
	}
	~Bench() { t->final(); delete t; }

	void hps_step() {
		Hps &h = hps;
		t->sd_buff_wr = 0;
		switch (h.st) {
		case Hps::IDLE:
			if (t->sd_rd || t->sd_wr) {
				if (t->sd_rd && t->sd_wr) sim::fail("sd_rd and sd_wr together");
				h.wr = t->sd_wr;
				h.lba = t->sd_lba;
				h.blocks = t->sd_blk_cnt + 1;
				if ((uint64_t)(h.lba + h.blocks) * 512 > h.img.size()) sim::fail("HPS asked for blocks %u+%d past the file", h.lba, h.blocks);
				h.delay = rng.chance(10) ? rng.range(300, 1500) : rng.range(20, 150);
				if (h.wr && h.lba == h.hold_lba) { h.delay = h.hold_clks; h.held = true; }
				if (h.wr && !first_wr_req) first_wr_req = cyc;
				if (!h.wr) h.read_sizes.push_back(h.blocks);
				h.st = Hps::DELAY;
			}
			break;
		case Hps::DELAY:
			if (--h.delay <= 0) {
				t->sd_ack = 1;
				h.word = 0; h.gap = 3; h.phase = 0;
				t->sd_buff_addr = 0;
				h.st = Hps::XFER;
			}
			break;
		case Hps::XFER:
			if (h.gap == 1 && (t->sd_rd || t->sd_wr)) sim::fail("sd_rd/sd_wr still high during the transfer");
			if (--h.gap > 0) break;
			h.gap = rng.range(2, 3);
			if (h.word < 256 * h.blocks) {
				size_t off = (size_t)h.lba * 512 + h.word * 2;
				if (!h.wr) {
					t->sd_buff_addr = h.word;
					t->sd_buff_dout = (uint16_t)(h.img[off] | h.img[off + 1] << 8);
					t->sd_buff_wr = 1;
				} else {
					// hps_io takes the word at the current address, then moves on
					uint16_t w = t->sd_buff_din;
					h.img[off] = (uint8_t)w; h.img[off + 1] = (uint8_t)(w >> 8);
					t->sd_buff_addr = h.word + 1;
				}
				h.word++;
			} else {
				t->sd_ack = 0;
				if (h.wr) { h.writes++; h.written.push_back(h.lba); } else h.reads++;
				h.st = Hps::END;
				h.delay = 3;
			}
			break;
		case Hps::END:
			if (--h.delay <= 0) h.st = Hps::IDLE;
			break;
		}
	}

	void tick() {
		t->ddram_busy = ddr.busy;
		t->ddram_dout = ddr.dout;
		t->ddram_dout_ready = ddr.dout_ready;
		t->sdram_dq_i = chip.sample(cyc + 1);
		t->eval();
		if (t->mark && t->bk_taken) sim::fail("a mark and a block read in the same clock");
		if (t->mark) { last_mark = cyc; marks++; }
		if (t->note) notes[t->note]++;
		if (t->saved) saved_pulses++;
		ddr.step(t->ddram_rd, t->ddram_we, t->ddram_addr, t->ddram_burstcnt, t->ddram_din, t->ddram_be);
		t->clk = 1;
		t->eval();
		cyc++;
		SdramPins sp;
		sp.cs_n = t->sdram_cs_n; sp.ras_n = t->sdram_ras_n; sp.cas_n = t->sdram_cas_n; sp.we_n = t->sdram_we_n;
		sp.ba = t->sdram_ba; sp.a = t->sdram_a; sp.dqm = t->sdram_dqml | t->sdram_dqmh << 1;
		sp.dq_oe = t->sdram_dq_oe != 0; sp.dq_o = t->sdram_dq_o;
		chip.edge(cyc, sp);
		hps_step();
		t->clk = 0;
		t->eval();
	}
	void run(uint64_t n) { while (n--) tick(); }

	uint32_t access(bool we, uint32_t a, uint32_t d, uint8_t sel) {
		t->wb_cyc = 1; t->wb_stb = 1; t->wb_we = we; t->wb_adr = a & ~3u; t->wb_dat_i = d; t->wb_sel = sel; t->wb_cti = 7;
		uint64_t limit = cyc + 200000;
		uint32_t v = 0;
		for (;;) {
			t->eval();
			bool ack = t->wb_ack || t->wb_err;
			if (ack) v = t->wb_dat_o;
			tick();
			if (ack) break;
			if (cyc > limit) { sim::fail("no answer at %08x", a); break; }
		}
		t->wb_cyc = 0; t->wb_stb = 0;
		tick();
		return v;
	}
	// CS1 by word address in the chip
	void w16(uint32_t word, uint16_t v) { access(true, 0x02000000u + 2 * word, (uint32_t)v * 0x10001u, (word & 1) ? 0xC : 0x3); }
	uint16_t r16(uint32_t word) { return (uint16_t)(access(false, 0x02000000u + 2 * word, 0, (word & 1) ? 0xC : 0x3) >> ((word & 1) * 16)); }
	void unlock() { w16(0x555, 0xAA); w16(0x2AA, 0x55); }

	uint16_t chip_word(uint32_t word) { return ddr.half(CS1_DDR + 2 * word); }
	// program a word with the bits of v that are 1 in it now cleared as v
	// says (a program can only clear bits; asking for a 0-to-1 is DQ5's error)
	void program(uint32_t word, uint16_t v) {
		uint16_t want = chip_word(word) & v;
		unlock(); w16(0x555, 0xA0); w16(word, want);
		int polls = 0;
		while (((r16(word) ^ want) & 0x80) && ++polls < 5000) {}
		run(100);
		CHECK_EQ(chip_word(word), want, "programmed word");
	}
	void erase_sector(uint32_t word) {
		unlock(); w16(0x555, 0x80); unlock(); w16(word, 0x30);
		int polls = 0;
		while (r16(word) != 0xFFFF && ++polls < 100000) {}
		run(100);
	}

	void mount(const std::vector<uint8_t> *img, uint64_t size, bool ro) {
		if (img) hps.img = *img;
		t->img_size = size;
		t->img_readonly = ro;
		t->img_mounted = 1;
		tick();
		t->img_mounted = 0;
		tick();
	}
	// the file equals the chip
	int file_mismatches() {
		int bad = 0;
		for (uint32_t i = 0; i < CS1_BYTES; i++)
			if (hps.img[i] != ddr.byte(CS1_DDR + i) && bad++ < 3)
				sim::fail("file byte 0x%06x is %02x, the chip has %02x", i, hps.img[i], ddr.byte(CS1_DDR + i));
		return bad;
	}
	// until nothing is left to save and no transfer is on
	void settle(uint64_t limit) {
		uint64_t end = cyc + limit;
		while (cyc < end && (t->unsaved || t->active || hps.st != Hps::IDLE)) tick();
		run(4);                      // the pulses that end it
		CHECK(!t->unsaved && !t->active, "write-back finished");
	}
};

std::vector<uint8_t> pattern(uint32_t seed) {
	std::vector<uint8_t> v(CS1_BYTES);
	uint32_t x = seed;
	for (auto &c : v) { x = x * 1664525u + 1013904223u; c = (uint8_t)(x >> 24); }
	// an erased C: area here and there, as on a fresh image
	for (uint32_t i = 0x7F0000; i < 0x800000; i++) v[i] = 0xFF;
	return v;
}

void check_written(Bench &b, const std::set<uint32_t> &want, const char *what) {
	std::map<uint32_t, int> got;
	for (uint32_t l : b.hps.written) got[l]++;
	for (uint32_t l : want)
		if (got[l] != 1) sim::fail("%s: block 0x%04x written %d times, want once", what, l, got[l]);
	for (auto &kv : got)
		if (!want.count(kv.first)) sim::fail("%s: block 0x%04x written but not changed", what, kv.first);
	printf("  %s: %zu blocks written back\n", what, b.hps.written.size());
}

}  // namespace

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	uint32_t seed = 1;
	for (int i = 1; i < argc; i++)
		if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = (uint32_t)strtoul(argv[++i], nullptr, 0);
	Bench b(seed);

	// a file that is not 8 MB is refused
	printf("mount of a 4 MB file\n");
	std::vector<uint8_t> small(4u << 20, 0);
	b.mount(&small, small.size(), false);
	b.run(5000);
	CHECK_EQ(b.notes[2], 1, "note 2: the save file must be 8 MB");
	CHECK(!b.t->loading && !b.t->saving_on, "not mounted");
	CHECK_EQ(b.hps.reads, 0, "nothing read");

	// mount: the file into DDR3, the memory system held meanwhile
	printf("mount of the 8 MB file\n");
	std::vector<uint8_t> img = pattern(seed * 7 + 1);
	uint64_t t0 = b.cyc;
	b.mount(&img, CS1_BYTES, false);
	CHECK(b.t->loading, "loading after the mount");
	CHECK_EQ(b.notes[1], 1, "note 1: mounted");
	while (b.t->loading && b.cyc < t0 + 60000000) b.tick();
	CHECK(!b.t->loading, "the load finished");
	printf("  loaded in %llu clocks, %llu requests\n", (unsigned long long)(b.cyc - t0), (unsigned long long)b.hps.reads);
	CHECK_EQ(b.hps.reads, 2048, "4 KB requests");
	for (int n : b.hps.read_sizes) if (n != 8) { sim::fail("a load request of %d blocks", n); break; }
	int bad = 0;
	for (uint32_t i = 0; i < CS1_BYTES; i++)
		if (b.ddr.byte(CS1_DDR + i) != img[i] && bad++ < 3) sim::fail("DDR3 byte 0x%06x is %02x, want %02x", i, b.ddr.byte(CS1_DDR + i), img[i]);
	CHECK_EQ(bad, 0, "loaded bytes wrong");
	for (int i = 0; i < 64; i++) {
		uint32_t w = b.rng.u32() & 0x3FFFFF;
		CHECK_EQ(b.r16(w), img[2 * w] | img[2 * w + 1] << 8, "CS1 word through the bus");
	}
	CHECK(b.t->saving_on, "saving on");

	// nothing changed: nothing is written back
	printf("idle\n");
	b.run(3 * MAXC);
	CHECK_EQ(b.hps.writes, 0, "no write-back while nothing changed");
	CHECK(!b.t->unsaved, "nothing unsaved");

	// programs and a parameter-sector erase in the C: area
	printf("program and erase\n");
	std::set<uint32_t> want;
	for (uint32_t w : {0x200123u, 0x2FF000u, 0x3A0010u, 0x3A00FEu}) { b.program(w, 0x1234); want.insert(w >> 8); }
	b.erase_sector(0x3F8000);
	for (uint32_t blk = 0x3F80; blk < 0x3F90; blk++) want.insert(blk);
	CHECK(b.t->unsaved, "unsaved after the changes");
	uint64_t last = b.last_mark;
	b.first_wr_req = 0;
	b.settle(4000000);
	CHECK(b.first_wr_req >= last + QUIET, "write-back waits for the quiet time");
	check_written(b, want, "programs and erase");
	CHECK_EQ(b.file_mismatches(), 0, "file bytes wrong after the write-back");

	// a block written again while its write-back is on its way
	printf("change during the write-back\n");
	b.hps.written.clear();
	b.program(0x300200, 0x00FF);
	b.hps.hold_lba = 0x3002;
	b.hps.hold_clks = 6000;
	while (!b.hps.held && b.cyc < b.last_mark + 10 * MAXC) b.tick();
	CHECK(b.hps.held, "the write-back reached the file");
	b.program(0x300201, 0x0F0F);             // the same block, while the file waits
	b.hps.hold_lba = ~0u;
	b.settle(4000000);
	{
		int n = 0;
		for (uint32_t l : b.hps.written) n += l == 0x3002;
		CHECK_EQ(n, 2, "the block written again goes out again");
	}
	CHECK_EQ(b.hps.img[2 * 0x300201] | b.hps.img[2 * 0x300201 + 1] << 8, b.chip_word(0x300201), "the later word reached the file");
	CHECK_EQ(b.file_mismatches(), 0, "file bytes wrong after a change during the write-back");

	// Save C: now
	printf("save now\n");
	b.hps.written.clear();
	b.saved_pulses = 0;
	b.program(0x380000, 0xAAAA);
	uint64_t ts = b.cyc;
	b.first_wr_req = 0;
	b.t->save_now = 1; b.run(10); b.t->save_now = 0;
	b.settle(1000000);
	CHECK(b.first_wr_req && b.first_wr_req < ts + SCAN, "save now does not wait for the quiet time");
	CHECK_EQ(b.saved_pulses, 1, "save now reports when done");
	check_written(b, {0x3800}, "save now");
	b.t->save_now = 1; b.run(10); b.t->save_now = 0;
	b.run(100);
	CHECK_EQ(b.saved_pulses, 2, "save now with nothing to save reports at once");

	// a stream of changes: written back MAX_CLKS after the first at the latest
	printf("stream of changes\n");
	b.hps.written.clear();
	b.first_wr_req = 0;
	uint64_t tf = b.cyc;
	for (int i = 0; i < 20 && !b.first_wr_req; i++) {
		b.program(0x390000 + 0x100 * i, 0x5555);
		b.run(QUIET / 2);
	}
	CHECK(b.first_wr_req && b.first_wr_req < tf + MAXC + SCAN, "write-back within MAX_CLKS of the first change");
	b.settle(4000000);
	CHECK_EQ(b.file_mismatches(), 0, "file bytes wrong after the stream");

	// unsaved changes survive a core reset
	printf("core reset\n");
	b.hps.written.clear();
	b.program(0x3B0000, 0x0001);
	b.t->reset = 1; b.run(2000); b.t->reset = 0;
	b.settle(4000000);
	check_written(b, {0x3B00}, "after a core reset");

	// detached by an ioctl load of CS1: nothing more goes to the file
	printf("detach\n");
	b.hps.written.clear();
	b.t->detach = 1; b.tick(); b.t->detach = 0;
	CHECK(!b.t->saving_on, "saving off after a detach");
	b.program(0x3C0000, 0x0002);
	b.run(2 * MAXC);
	CHECK_EQ(b.hps.written.size(), 0, "no write-back after a detach");

	// read-only: loads, never writes back
	printf("read-only mount\n");
	std::vector<uint8_t> img2 = pattern(seed * 13 + 5);
	b.hps.reads = 0;
	b.mount(&img2, CS1_BYTES, true);
	CHECK_EQ(b.notes[3], 1, "note 3: read-only");
	while (b.t->loading && b.cyc < b.last_mark + 60000000) b.tick();
	CHECK_EQ(b.hps.reads, 2048, "the read-only image loads");
	CHECK_EQ(b.ddr.byte(CS1_DDR + 0x123456), img2[0x123456], "the read-only image is in DDR3");
	b.program(0x3D0000, 0x0003);
	b.t->save_now = 1; b.run(10); b.t->save_now = 0;
	b.run(2 * MAXC);
	CHECK_EQ(b.hps.written.size(), 0, "no write-back from a read-only mount");

	CHECK_EQ(b.chip.errors, 0, "SDRAM chip model errors");
	CHECK_EQ(b.ddr.protocol_errors, 0, "DDRAM port protocol errors");
	printf("save: %llu clocks, %llu marks\n", (unsigned long long)b.cyc, (unsigned long long)b.marks);
	return sim::finish("flash_save");
}
