// Bench for rtl/board/nor_flash.sv: the AMD command set over a memory with
// random latency.
//
//   Vnor_flash_cs0 --aw 23 --id 0x22F8 [--seed N]
//   Vnor_flash_cs1 --aw 22 --id 0x22FA [--seed N]
//
// The bench must be built with -GPROGRAM_CLKS=40 -GSECTOR_ERASE_CLKS=3000
// -GERASE_WINDOW_CLKS=200 and the -GAW / -GDEVICE_ID it is told.
//
// The memory behind the port is a word array filled with a pattern; it
// answers after 1-6 clocks and checks that a request does not change while it
// waits. On the bus side the bench checks:
//  * array reads anywhere; autoselect (manufacturer 0xEC, device ID, no
//    protection) and the CFI table, with its sector map;
//  * word program: status while busy (DQ7 = not data bit 7, DQ6 toggling),
//    the busy time, read-while-write in another bank, the result in memory,
//    and the DQ5 failure for a 0 to 1 program until F0;
//  * sector erase of a main and a parameter sector: DQ3 in and after the
//    window, DQ2 only in the selected sector, the busy time, the sector
//    erased and its neighbours kept; several sectors in one window; a window
//    ended by another command; erase suspend with reads and a program, and
//    resume; chip erase;
//  * unlock bypass, reset in the middle of a sequence, and RP#;
//  * Samsung block lock/unlock (60, 60, 60 at the block with A6 choosing;
//    the firmware's medint.pdd sequence):
//    autoselect +02 shows it (main and parameter sectors), programs and
//    erases skip locked sectors, also a chip erase; RP# unlocks.
#include "Vnor_flash.h"
#include "verilated.h"
#include "common.h"

#include <cstring>
#include <deque>

namespace {

constexpr int PROGRAM_CLKS = 40, SECTOR_ERASE_CLKS = 3000, ERASE_WINDOW_CLKS = 200;

struct Bench {
	Vnor_flash *t = new Vnor_flash;
	sim::Rng rng;
	int aw;
	uint32_t words;
	std::vector<uint16_t> mem;
	uint64_t clocks = 0;
	// memory responder
	bool serving = false;
	int wait = 0;
	uint32_t s_addr = 0;
	bool s_we = false;
	uint16_t s_data = 0;
	bool ack_now = false;
	uint64_t mem_writes = 0;

	Bench(int aw_, uint32_t seed) : rng(seed), aw(aw_), words(1u << aw_), mem(words) {
		for (uint32_t i = 0; i < words; i++) mem[i] = pattern(i);
		t->clk = 0; t->reset = 1; t->rst_n = 1; t->bus_req = 0; t->bus_we = 0; t->bus_addr = 0;
		t->bus_wdata = 0; t->bus_lreq = 0; t->bus_laddr = 0;
		t->mem_rdata = 0; t->mem_ack = 0; t->mem_ltaken = 0; t->mem_lrvalid = 0; t->mem_lrbeat = 0; t->mem_lrdata = 0;
		t->eval();
		for (int i = 0; i < 4; i++) tick();
		t->reset = 0;
		tick();
	}
	~Bench() { t->final(); delete t; }

	static uint16_t pattern(uint32_t i) { return (uint16_t)(i * 2654435761u >> 9) | 0x0101; }

	void tick() {
		// the responder decides on what it sees before the edge
		bool ack = false;
		uint16_t rdata = t->mem_rdata;
		if (ack_now) {
			ack_now = false;  // the ack clock: req is still the old request
		} else if (serving) {
			if (!t->mem_req || t->mem_addr != s_addr || t->mem_we != s_we || (s_we && t->mem_wdata != s_data))
				sim::fail("memory request changed while waiting (addr %06x)", s_addr);
			if (--wait <= 0) {
				ack = true;
				serving = false;
				if (s_we) { mem[s_addr] = s_data; mem_writes++; }
				else rdata = mem[s_addr];
			}
		} else if (t->mem_req && !t->reset) {  // before the first clock the outputs are random
			serving = true;
			s_addr = t->mem_addr; s_we = t->mem_we; s_data = t->mem_wdata;
			wait = rng.chance(10) ? rng.range(5, 12) : rng.range(1, 3);
		}
		t->clk = 1; t->eval();
		t->mem_ack = ack;
		t->mem_rdata = rdata;
		if (ack) ack_now = true;
		t->clk = 0; t->eval();
		clocks++;
	}
	void ticks(int n) { while (n-- > 0) tick(); }

	uint16_t access(bool we, uint32_t addr, uint16_t data) {
		t->bus_req = 1; t->bus_we = we; t->bus_addr = addr; t->bus_wdata = data;
		int guard = 0;
		do {
			tick();
			if (++guard > 1000) { sim::fail("bus access to %06x not acknowledged", addr); break; }
		} while (!t->bus_ack);
		uint16_t v = t->bus_rdata;
		t->bus_req = 0;
		if (rng.chance(30)) ticks(rng.range(1, 3));
		return v;
	}
	uint16_t rd(uint32_t a) { return access(false, a, 0); }
	void wr(uint32_t a, uint16_t d) { access(true, a, d); }
	void unlock() { wr(0x555, 0xAA); wr(0x2AA, 0x55); }

	// poll with the toggle bit until the operation at a is over; returns clocks
	uint64_t wait_done(uint32_t a, int limit = 50000000) {
		uint64_t c0 = clocks;
		uint16_t prev = rd(a);
		for (int i = 0; i < limit; i++) {
			uint16_t v = rd(a);
			if (((v ^ prev) & 0x40) == 0) {
				// two equal reads: done unless both were status with DQ6 the same
				uint16_t again = rd(a);
				if (again == v) return clocks - c0;
				v = again;
			}
			prev = v;
		}
		sim::fail("operation at %06x never finished", a);
		return clocks - c0;
	}
};

int sectors(int aw) { return (1 << (aw - 15)) - 1 + 8; }
uint32_t sector_base(int aw, int s) {
	int nmain = (1 << (aw - 15)) - 1;
	return s < nmain ? (uint32_t)s << 15 : ((uint32_t)nmain << 15) + ((uint32_t)(s - nmain) << 12);
}
uint32_t sector_size(int aw, int s) { return s < (1 << (aw - 15)) - 1 ? 32768u : 4096u; }

void check_range(Bench &b, uint32_t a0, uint32_t n, bool erased, const char *what) {
	int bad = 0;
	for (uint32_t a = a0; a < a0 + n; a++) {
		uint16_t want = erased ? 0xFFFF : Bench::pattern(a);
		if (b.mem[a] != want && bad++ < 3) sim::fail("%s: word %06x = %04x, want %04x", what, a, b.mem[a], want);
	}
}

void test_reads(Bench &b) {
	for (int i = 0; i < 2000; i++) {
		uint32_t a = b.rng.u32() & (b.words - 1);
		uint16_t v = b.rd(a);
		if (v != b.mem[a]) sim::fail("array read %06x = %04x, want %04x", a, v, b.mem[a]);
	}
}

void test_ids(Bench &b, uint16_t id) {
	b.unlock(); b.wr(0x555, 0x90);
	CHECK_EQ(b.rd(0x000), 0x00EC, "manufacturer");
	CHECK_EQ(b.rd(0x001), id, "device ID");
	CHECK_EQ(b.rd(0x002), 0x0000, "sector protection");
	CHECK_EQ(b.rd(0x00E), 0x0000, "device ID 2");
	CHECK_EQ(b.rd(0x00F), 0x0000, "device ID 3");
	CHECK_EQ(b.rd((b.words - 1) & ~0xFFu | 0x01), id, "device ID at the top of the chip");
	// CFI from autoselect, then back to the array
	b.wr(0x55, 0x98);
	CHECK_EQ(b.rd(0x10), 'Q', "CFI Q");
	b.wr(0x000, 0xF0);
	CHECK_EQ(b.rd(0x001), b.mem[1], "array after autoselect");

	b.wr(0x55, 0x98);
	const char *qry = "QRY";
	for (int i = 0; i < 3; i++) CHECK_EQ(b.rd(0x10 + i), qry[i], "CFI QRY");
	CHECK_EQ(b.rd(0x13), 0x02, "CFI command set");
	CHECK_EQ(b.rd(0x15), 0x40, "CFI extended table");
	CHECK_EQ(b.rd(0x27), b.aw + 1, "CFI device size");
	CHECK_EQ(b.rd(0x28), 0x01, "CFI interface");
	CHECK_EQ(b.rd(0x2C), 0x02, "CFI regions");
	int nmain = (1 << (b.aw - 15)) - 1;
	CHECK_EQ(b.rd(0x2D) | b.rd(0x2E) << 8, nmain - 1, "CFI region 1 count - 1");
	CHECK_EQ(b.rd(0x2F) | b.rd(0x30) << 8, 0x100, "CFI region 1 size / 256");
	CHECK_EQ(b.rd(0x31) | b.rd(0x32) << 8, 7, "CFI region 2 count - 1");
	CHECK_EQ(b.rd(0x33) | b.rd(0x34) << 8, 0x20, "CFI region 2 size / 256");
	const char *pri = "PRI13";
	for (int i = 0; i < 5; i++) CHECK_EQ(b.rd(0x40 + i), pri[i], "CFI PRI");
	CHECK_EQ(b.rd(0x4F), 0x03, "CFI top boot");
	// the sizes add up to the chip
	uint32_t bytes = (uint32_t)nmain * 65536 + 8 * 8192;
	CHECK_EQ(bytes, 2u << b.aw, "sector map size");
	b.wr(0x1234, 0xF0);
	CHECK_EQ(b.rd(0x10), b.mem[0x10], "array after CFI");
}

void test_program(Bench &b) {
	uint32_t a = 0x012345 & (b.words - 1);
	uint32_t other = a ^ (b.words >> 1);  // another bank
	b.mem[a] = 0xFFFF;
	uint64_t c0 = b.clocks;
	b.unlock(); b.wr(0x555, 0xA0); b.wr(a, 0x1234);
	uint16_t s1 = b.rd(a), s2 = b.rd(a);
	CHECK_EQ(s1 & 0x80, (~0x1234) & 0x80, "program status DQ7");
	CHECK((s1 ^ s2) & 0x40, "program status DQ6 does not toggle");
	CHECK_EQ(s1 & 0x20, 0, "program status DQ5");
	CHECK(b.t->busy, "busy not set while programming");
	CHECK_EQ(b.rd(other), b.mem[other], "read in another bank while programming");
	b.wait_done(a);
	CHECK(b.clocks - c0 >= (uint64_t)PROGRAM_CLKS, "program took %llu clocks", (unsigned long long)(b.clocks - c0));
	CHECK(!b.t->busy, "busy after programming");
	CHECK_EQ(b.rd(a), 0x1234, "programmed word");
	CHECK_EQ(b.mem[a], 0x1234, "programmed word in memory");

	// only zeros can be programmed: asking for ones fails with DQ5
	b.unlock(); b.wr(0x555, 0xA0); b.wr(a, 0x00FF);
	b.ticks(PROGRAM_CLKS * 4);
	uint16_t s = b.rd(a);
	CHECK(s & 0x20, "DQ5 not set after programming 0 to 1 (status %04x)", s);
	CHECK((s ^ b.rd(a)) & 0x40, "DQ6 does not toggle after a failed program");
	b.unlock(); b.wr(0x555, 0xA0); b.wr(a + 1, 0x0000);  // ignored while failed
	b.wr(0, 0xF0);
	CHECK_EQ(b.rd(a), 0x1234 & 0x00FF, "word after a failed program");
	CHECK_EQ(b.mem[a + 1], Bench::pattern(a + 1), "program accepted while failed");
	b.mem[a] = Bench::pattern(a);

	// a sequence broken by F0 does nothing
	b.unlock(); b.wr(0x777, 0xF0); b.wr(0x555, 0xA0); b.wr(a, 0x0000);
	CHECK_EQ(b.rd(a), b.mem[a], "program after a broken sequence");
	CHECK_EQ(b.mem[a], Bench::pattern(a), "memory after a broken sequence");
	// wrong unlock address
	b.wr(0x554, 0xAA); b.wr(0x2AA, 0x55); b.wr(0x555, 0xA0); b.wr(a, 0x0000);
	CHECK_EQ(b.mem[a], Bench::pattern(a), "program after a wrong unlock address");
}

void erase_cmd(Bench &b, uint32_t sa) {
	b.unlock(); b.wr(0x555, 0x80); b.unlock(); b.wr(sa, 0x30);
}

void test_erase(Bench &b) {
	int n = sectors(b.aw), nmain = (1 << (b.aw - 15)) - 1;
	// a main sector in the middle, with its bank's other sectors
	int s = nmain / 2 + 1;
	uint32_t base = sector_base(b.aw, s), size = sector_size(b.aw, s);
	uint32_t same_bank = base + size;  // the next sector, same bank (16 banks of 2^(aw-4) words)
	uint32_t other_bank = (base + (b.words >> 1)) & (b.words - 1);
	uint64_t c0 = b.clocks;
	erase_cmd(b, base + 77);
	uint16_t w = b.rd(base);
	CHECK_EQ(w & 0x08, 0, "DQ3 in the erase window");
	CHECK_EQ(w & 0x80, 0, "erase status DQ7");
	b.ticks(ERASE_WINDOW_CLKS + 20);
	uint16_t e1 = b.rd(base + 5), e2 = b.rd(base + 9);
	CHECK(e1 & 0x08, "DQ3 after the erase window");
	CHECK((e1 ^ e2) & 0x44, "DQ6/DQ2 do not toggle in the erasing sector (%04x %04x)", e1, e2);
	uint16_t n1 = b.rd(same_bank), n2 = b.rd(same_bank);
	CHECK((n1 ^ n2) & 0x40, "DQ6 does not toggle in the erasing bank");
	CHECK(((n1 ^ n2) & 0x04) == 0, "DQ2 toggles outside the selected sector");
	CHECK_EQ(b.rd(other_bank), b.mem[other_bank], "read in another bank while erasing");
	b.wait_done(base);
	CHECK(b.clocks - c0 >= (uint64_t)SECTOR_ERASE_CLKS, "sector erase took %llu clocks", (unsigned long long)(b.clocks - c0));
	check_range(b, base, size, true, "erased main sector");
	check_range(b, base - 4096, 4096, false, "word below the erased sector");
	check_range(b, base + size, 4096, false, "word above the erased sector");
	for (uint32_t a = base; a < base + size; a += 1111) CHECK_EQ(b.rd(a), 0xFFFF, "read of an erased word");
	for (uint32_t a = base; a < base + size; a++) b.mem[a] = Bench::pattern(a);

	// a parameter sector at the top
	int ps = n - 3;
	uint32_t pb = sector_base(b.aw, ps);
	erase_cmd(b, pb + 4095);
	b.wait_done(pb);
	check_range(b, pb, 4096, true, "erased parameter sector");
	check_range(b, pb - 4096, 4096, false, "parameter sector below");
	check_range(b, pb + 4096, 4096, false, "parameter sector above");
	for (uint32_t a = pb; a < pb + 4096; a++) b.mem[a] = Bench::pattern(a);

	// two sectors in two banks in one window
	int sa = 3, sb = nmain - 5;
	erase_cmd(b, sector_base(b.aw, sa));
	b.ticks(ERASE_WINDOW_CLKS / 2);
	b.wr(sector_base(b.aw, sb) + 100, 0x30);
	b.ticks(ERASE_WINDOW_CLKS / 2 + 10);  // still inside the restarted window
	CHECK_EQ(b.rd(sector_base(b.aw, sb)) & 0x08, 0, "the window restarts on another sector");
	b.wait_done(sector_base(b.aw, sa));
	b.wait_done(sector_base(b.aw, sb));
	check_range(b, sector_base(b.aw, sa), 32768, true, "first of two sectors");
	check_range(b, sector_base(b.aw, sb), 32768, true, "second of two sectors");
	check_range(b, sector_base(b.aw, sa + 1), 32768, false, "sector after the first");
	for (int k : {sa, sb})
		for (uint32_t a = sector_base(b.aw, k); a < sector_base(b.aw, k) + 32768; a++) b.mem[a] = Bench::pattern(a);

	// another command in the window ends it: nothing is erased
	erase_cmd(b, sector_base(b.aw, 7));
	b.ticks(20);
	b.wr(0x555, 0xAA);
	b.ticks(ERASE_WINDOW_CLKS * 2);
	CHECK(!b.t->busy, "busy after an aborted erase");
	check_range(b, sector_base(b.aw, 7), 32768, false, "sector after an aborted erase");
	CHECK_EQ(b.rd(sector_base(b.aw, 7)), b.mem[sector_base(b.aw, 7)], "read after an aborted erase");
	b.wr(0, 0xF0);
}

void test_suspend(Bench &b) {
	int s = 9;
	uint32_t base = sector_base(b.aw, s);
	uint32_t near = base + 32768 + 500;  // next sector, same bank
	erase_cmd(b, base);
	b.ticks(ERASE_WINDOW_CLKS + 2000);
	b.wr(0x123, 0xB0);
	b.ticks(20);
	CHECK(!b.t->busy, "busy while erase-suspended");
	uint16_t s1 = b.rd(base + 3), s2 = b.rd(base + 3);
	CHECK(s1 & 0x80, "suspended status DQ7");
	CHECK(((s1 ^ s2) & 0x40) == 0, "DQ6 toggles while suspended");
	CHECK((s1 ^ s2) & 0x04, "DQ2 does not toggle while suspended");
	CHECK_EQ(b.rd(near), b.mem[near], "array read in a suspended bank");
	uint64_t writes = b.mem_writes;
	b.ticks(5000);
	CHECK_EQ(b.mem_writes, writes, "memory written while suspended");
	// program outside the suspended sector, then try inside it
	b.unlock(); b.wr(0x555, 0xA0); b.wr(near, 0x0000);
	b.wait_done(near);
	CHECK_EQ(b.mem[near], 0x0000, "program during erase suspend");
	b.unlock(); b.wr(0x555, 0xA0); b.wr(base + 1, 0x0000);
	b.ticks(PROGRAM_CLKS * 2);
	CHECK(b.rd(base + 3) & 0x80, "still suspended after a refused program");
	// erase commands are refused while suspended
	erase_cmd(b, sector_base(b.aw, s + 3));
	b.ticks(ERASE_WINDOW_CLKS + 100);
	// resume
	b.wr(0x0, 0x30);
	b.wait_done(base);
	check_range(b, base, 32768, true, "sector erased after a resume");
	check_range(b, sector_base(b.aw, s + 3), 32768, false, "sector erase given while suspended");
	CHECK_EQ(b.mem[near], 0x0000, "word programmed while suspended");
	for (uint32_t a = base; a < base + 32768; a++) b.mem[a] = Bench::pattern(a);
	b.mem[near] = Bench::pattern(near);
}

void test_bypass(Bench &b) {
	uint32_t a = 0x2000;
	b.unlock(); b.wr(0x555, 0x20);
	const uint16_t masks[3] = {0x0000, 0x0F0F, 0x7FFE};
	for (int i = 0; i < 3; i++) { b.wr(0x999, 0xA0); b.wr(a + i, Bench::pattern(a + i) & masks[i]); b.wait_done(a + i); }
	for (int i = 0; i < 3; i++) CHECK_EQ(b.rd(a + i), Bench::pattern(a + i) & masks[i], "bypass program");
	for (int i = 0; i < 3; i++) CHECK_EQ(b.mem[a + i], Bench::pattern(a + i) & masks[i], "bypass program in memory");
	uint32_t sb = sector_base(b.aw, 20);
	b.wr(0x0, 0x80); b.wr(sb, 0x30);
	b.wait_done(sb);
	check_range(b, sb, 32768, true, "bypass sector erase");
	b.wr(0x0, 0x90); b.wr(0x0, 0x00);
	// out of bypass: A0 alone does nothing
	b.wr(0x999, 0xA0); b.wr(a + 5, 0x0000);
	CHECK_EQ(b.mem[a + 5], Bench::pattern(a + 5), "program without unlock after leaving bypass");
	for (uint32_t x = sb; x < sb + 32768; x++) b.mem[x] = Bench::pattern(x);
	for (int i = 0; i < 3; i++) b.mem[a + i] = Bench::pattern(a + i);
}

void test_rp(Bench &b) {
	uint32_t base = sector_base(b.aw, 30);
	erase_cmd(b, base);
	b.ticks(ERASE_WINDOW_CLKS + 3000);
	b.t->rst_n = 0;
	b.ticks(5);
	CHECK_EQ(b.rd(base), 0xFFFF, "bus read during RP#");
	b.t->rst_n = 1;
	b.ticks(2);
	CHECK(!b.t->busy, "busy after RP#");
	uint64_t writes = b.mem_writes;
	b.ticks(2000);
	CHECK(b.mem_writes - writes <= 1, "memory written after RP#");
	CHECK_EQ(b.rd(base + 32767), b.mem[base + 32767], "array read after RP#");
	for (uint32_t a = base; a < base + 32768; a++) b.mem[a] = Bench::pattern(a);
}

uint16_t lock_status(Bench &b, uint32_t a) {
	b.unlock(); b.wr(0x555, 0x90);
	uint16_t v = b.rd((a & ~0xFFu) | 0x02);
	b.wr(0, 0xF0);
	return v;
}

void test_lock(Bench &b) {
	uint32_t base = sector_base(b.aw, 40), other = sector_base(b.aw, 41);
	CHECK_EQ(lock_status(b, base), 0, "sector locked at power-up");
	b.wr(0x123, 0x60); b.wr(base, 0x60); b.wr(base + 0x1000, 0x60);   // A6 = 0: lock
	CHECK_EQ(lock_status(b, base + 77), 1, "lock status after locking");
	CHECK_EQ(lock_status(b, other), 0, "the next sector locked too");
	b.unlock(); b.wr(0x555, 0xA0); b.wr(base + 5, 0x0000);
	CHECK(!b.t->busy, "program of a locked sector started");
	b.ticks(PROGRAM_CLKS * 2);
	CHECK_EQ(b.mem[base + 5], Bench::pattern(base + 5), "locked sector programmed");
	erase_cmd(b, base);
	b.ticks(ERASE_WINDOW_CLKS + 2000);
	b.wait_done(base);
	check_range(b, base, 32768, false, "locked sector erased");
	b.wr(0x0, 0x60); b.wr(base, 0x60); b.wr(base + 0x40, 0x60);       // A6 = 1: unlock
	CHECK_EQ(lock_status(b, base), 0, "lock status after unlocking");
	b.unlock(); b.wr(0x555, 0xA0); b.wr(base + 5, 0x0000);
	b.wait_done(base + 5);
	CHECK_EQ(b.mem[base + 5], 0x0000, "program after unlocking");
	b.mem[base + 5] = Bench::pattern(base + 5);
	// medint.pdd's unlock (0x50380020): 60 and 60 at the block, 60 at its
	// word 0x42 (byte 0x84, A6 = 1), F0; the driver faults unless +02 reads 0
	b.wr(0x0, 0x60); b.wr(base, 0x60); b.wr(base, 0x60);
	CHECK_EQ(lock_status(b, base), 1, "locked before medint's unlock");
	b.wr(base, 0x60); b.wr(base, 0x60); b.wr(base + 0x42, 0x60); b.wr(base, 0xF0);
	CHECK_EQ(lock_status(b, base), 0, "lock status after medint's unlock sequence");
	// a parameter sector has its own bit
	uint32_t pa = sector_base(b.aw, sectors(b.aw) - 3), pn = sector_base(b.aw, sectors(b.aw) - 2);
	b.wr(0x0, 0x60); b.wr(pa, 0x60); b.wr(pa, 0x60);
	CHECK_EQ(lock_status(b, pa + 9), 1, "parameter sector's lock status after locking");
	CHECK_EQ(lock_status(b, pn), 0, "the next parameter sector locked too");
	b.wr(0x0, 0x60); b.wr(pa, 0x60); b.wr(pa + 0x40, 0x60);
	CHECK_EQ(lock_status(b, pa), 0, "parameter sector's lock status after unlocking");
	// RP# unlocks everything
	b.wr(0x0, 0x60); b.wr(other, 0x60); b.wr(other, 0x60);
	CHECK_EQ(lock_status(b, other), 1, "lock before RP#");
	b.t->rst_n = 0; b.ticks(3); b.t->rst_n = 1; b.ticks(2);
	CHECK_EQ(lock_status(b, other), 0, "lock after RP#");
}

void test_line_port(Bench &b) {
	// Idle in read-array mode: bus_array is high and a line read passes through
	CHECK_EQ(b.t->bus_array, 1, "bus_array high when idle in read-array mode");
	uint32_t laddr = 0x1234u;
	b.t->bus_lreq = 1;
	b.t->bus_laddr = laddr;
	b.t->eval();
	CHECK_EQ(b.t->mem_lreq, 1, "mem_lreq high when bus_lreq asserted in read-array mode");
	CHECK_EQ(b.t->mem_laddr, laddr, "mem_laddr matches bus_laddr");
	b.t->mem_ltaken = 1;
	b.tick();
	b.t->bus_lreq = 0;
	b.t->mem_ltaken = 0;
	b.t->eval();
	CHECK_EQ(b.t->bus_array, 0, "bus_array low while line read beats are pending");

	// Beat 0 and beat 1 return from memory
	for (int beat = 0; beat < 2; beat++) {
		uint64_t want = 0xCAFEBABE00000000ull | ((uint64_t)beat << 32) | (laddr + beat);
		b.t->mem_lrvalid = 1;
		b.t->mem_lrbeat = beat;
		b.t->mem_lrdata = want;
		b.t->eval();
		CHECK_EQ(b.t->bus_lrvalid, 1, "bus_lrvalid high on line beat");
		CHECK_EQ(b.t->bus_lrbeat, beat, "bus_lrbeat matches mem_lrbeat");
		CHECK_EQ(b.t->bus_lrdata, want, "bus_lrdata matches mem_lrdata");
		b.tick();
	}
	b.t->mem_lrvalid = 0;
	b.t->eval();
	CHECK_EQ(b.t->bus_lrvalid, 0, "bus_lrvalid low after 2 beats");
	CHECK_EQ(b.t->bus_array, 1, "bus_array high again after line read completes");

	// Non-read-array states must deassert bus_array and block mem_lreq
	b.wr(0x555, 0xAA);
	CHECK_EQ(b.t->bus_array, 0, "bus_array low mid-unlock (C_U1)");
	b.wr(0x2AA, 0x55);
	b.wr(0x555, 0x90);
	CHECK_EQ(b.t->bus_array, 0, "bus_array low in autoselect mode");
	b.t->bus_lreq = 1; b.t->eval();
	CHECK_EQ(b.t->mem_lreq, 0, "mem_lreq blocked in autoselect mode");
	b.t->bus_lreq = 0;
	b.wr(0x0, 0xF0);
	CHECK_EQ(b.t->bus_array, 1, "bus_array high after F0 reset");
}

void test_chip_erase(Bench &b) {
	// a locked parameter sector survives the chip erase
	int locked = sectors(b.aw) - 1;
	uint32_t lb = sector_base(b.aw, locked);
	b.wr(0x0, 0x60); b.wr(lb, 0x60); b.wr(lb, 0x60);
	b.unlock(); b.wr(0x555, 0x80); b.unlock(); b.wr(0x555, 0x10);
	uint16_t s1 = b.rd(0), s2 = b.rd(0);
	CHECK((s1 ^ s2) & 0x40, "chip erase status");
	uint64_t t = b.wait_done(0);
	int bad = 0;
	for (uint32_t a = 0; a < lb; a++) if (b.mem[a] != 0xFFFF && bad++ < 3) sim::fail("chip erase left %06x = %04x", a, b.mem[a]);
	check_range(b, lb, 4096, false, "locked sector in a chip erase");
	CHECK(t >= (uint64_t)SECTOR_ERASE_CLKS * (sectors(b.aw) - 1), "chip erase took %llu clocks", (unsigned long long)t);
	printf("chip erase: %llu clocks for %d sectors\n", (unsigned long long)t, sectors(b.aw));
}

}  // namespace

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	int aw = 23;
	uint16_t id = 0x22F8;
	uint32_t seed = 1;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--aw") && i + 1 < argc) aw = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--id") && i + 1 < argc) id = (uint16_t)strtol(argv[++i], nullptr, 0);
		else if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = (uint32_t)atoi(argv[++i]);
	}
	Bench b(aw, seed);
	test_reads(b);
	test_ids(b, id);
	test_program(b);
	test_erase(b);
	test_suspend(b);
	test_bypass(b);
	test_rp(b);
	test_lock(b);
	test_reads(b);
	test_line_port(b);
	test_chip_erase(b);
	printf("%d-word chip, %llu clocks\n", 1 << aw, (unsigned long long)b.clocks);
	char name[32];
	snprintf(name, sizeof name, "nor_flash (%d MB)", 2 << aw >> 20);
	return sim::finish(name);
}
