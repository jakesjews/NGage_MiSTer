// Bench for rtl/mister/pmm_date.sv: the walk over the QD's PMM that puts
// today's date into records 0 and 1 of group 212, against a C++ walk of the
// same image and a calendar of its own.
//
//   Vpmm_date [--seed N]
//
//  * the time for a date: 2004-01-01 is the value read from a phone's PMM
//    (0x00E0AD82988E4000 at 00:00:00), the leap days, the first and the last
//    day the HPS clock can give, and random dates;
//  * images: an erased PMM and one with only the first-start record (nothing
//    is written), one as the firmware leaves it (replaced records, the alarm
//    record, records at every byte offset of a beat, a second sector in use),
//    a record whose data would run off its sector, chains that go backward,
//    stand still or leave the sector, and random bytes behind a sector mark;
//  * the loader port holds commands back at random and answers reads late;
//    every write must be one byte of a date record, and after the walk the
//    image must be the model's.
#include "Vpmm_date.h"
#include "verilated.h"
#include "common.h"

#include <cstring>
#include <deque>

namespace {

constexpr uint32_t PMM_BASE = 0x06640000;
constexpr size_t SECTOR = 0x2000, SIZE = 8 * SECTOR;
constexpr uint64_t DAY_US = 86400000000ull;

bool leap(int y) { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0; }
int month_days(int y, int m) {
	static const int d[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
	return d[m - 1] + (m == 2 && leap(y));
}
// EUser's time of a date at 00:00:00: days counted one by one from
// 2004-01-01, whose day number is the one a phone's PMM held
uint64_t ttime(int y, int m, int d) {
	long days = 731958;
	for (int yy = 2004; yy < y; yy++) days += leap(yy) ? 366 : 365;
	for (int yy = y; yy < 2004; yy++) days -= leap(yy) ? 366 : 365;
	for (int mm = 1; mm < m; mm++) days += month_days(y, mm);
	return (uint64_t)(days + d - 1) * DAY_US;
}

struct Pmm {
	std::vector<uint8_t> b = std::vector<uint8_t>(SIZE, 0xFF);
	size_t end[8] = {};
	void catalogue(int s, uint32_t word = 0) {
		static const uint8_t head[] = {0xF0, 0xF0, 0xF8, 0xFF, 0x02, 0x00, 'P', 'M', 'M', 'C', 'A', 'T', 1, 0, 0, 0};
		memcpy(&b[s * SECTOR], head, sizeof head);
		memcpy(&b[s * SECTOR + 16], &word, 4);
		b[s * SECTOR + 24] = 2; b[s * SECTOR + 25] = 0;
		end[s] = 0x20;
	}
	void spare(int s) {
		b[s * SECTOR] = 0xF0; b[s * SECTOR + 1] = 0xF0; b[s * SECTOR + 2] = 0xFE;
		b[s * SECTOR + 12] = 1; b[s * SECTOR + 13] = b[s * SECTOR + 14] = b[s * SECTOR + 15] = 0;
	}
	// a record at the end of sector s's chain; next = -1 for the usual link
	size_t record(int s, int group, int number, const std::vector<uint8_t> &data, uint8_t tag = 0xF4, int next = -1) {
		size_t at = end[s], p = s * SECTOR + at;
		size_t nx = next >= 0 ? (size_t)next : at + 12 + data.size();
		uint8_t h[12] = {tag, (uint8_t)group, (uint8_t)number, (uint8_t)(number >> 8), 0x55, 0xFF, 0xFF, 0xFF,
		                 (uint8_t)data.size(), (uint8_t)(data.size() >> 8), (uint8_t)nx, (uint8_t)(nx >> 8)};
		for (size_t i = 0; i < 12 && p + i < SIZE; i++) b[p + i] = h[i];
		for (size_t i = 0; i < data.size() && p + 12 + i < SIZE; i++) b[p + 12 + i] = data[i];
		end[s] = at + 12 + data.size();
		return p + 12;
	}
};

// the walk, as the header of pmm_date.sv gives it
int model(std::vector<uint8_t> &b, uint64_t t) {
	int n = 0;
	for (int s = 0; s < 8; s++) {
		const uint8_t *sec = &b[s * SECTOR];
		if (memcmp(sec + 6, "PMMCAT", 6)) continue;
		size_t p = 0x20;
		for (;;) {
			uint8_t tag = sec[p];
			unsigned number = sec[p + 2] | sec[p + 3] << 8, len = sec[p + 8] | sec[p + 9] << 8, next = sec[p + 10] | sec[p + 11] << 8;
			bool date = tag == 0xF4 && sec[p + 1] == 212 && number <= 1 && len == 8 && p <= SECTOR - 20;
			if (date) { memcpy(&b[s * SECTOR + p + 12], &t, 8); n++; }
			if ((!date && tag == 0xFF) || next <= p || next > SECTOR - 12) break;
			p = next;
		}
	}
	return n;
}

struct Bench {
	Vpmm_date *t = new Vpmm_date;
	sim::Rng rng;
	std::vector<uint8_t> mem;
	std::deque<std::pair<int, uint64_t>> answers;   // clocks to go, beat
	uint64_t clocks = 0;
	int writes = 0, reads = 0;
	std::vector<size_t> written;
	int busy_pct = 30;

	explicit Bench(uint32_t seed) : rng(seed) {
		t->clk = 0; t->reset = 1; t->start = 0; t->date = 0; t->ld_busy = 1; t->ld_valid = 0; t->ld_data = 0;
		for (int i = 0; i < 4; i++) tick();
		t->reset = 0;
		tick();
	}
	~Bench() { t->final(); delete t; }

	void tick() {
		// the port's answer to this clock's command, decided before the edge
		bool busy = rng.chance(busy_pct);
		t->ld_busy = busy;
		t->ld_valid = 0;
		if (!answers.empty() && --answers.front().first <= 0) {
			t->ld_valid = 1;
			t->ld_data = answers.front().second;
			answers.pop_front();
		}
		t->eval();
		CHECK(!(t->ld_rd && t->ld_we), "a read and a write in one clock");
		if (!busy && (t->ld_rd || t->ld_we)) {
			uint32_t beat = t->ld_addr - PMM_BASE;
			CHECK(t->ld_addr >= PMM_BASE && beat < SIZE / 8, "a command outside the PMM window: 0x%x", (unsigned)t->ld_addr);
			if (beat < SIZE / 8) {
				if (t->ld_rd) {
					uint64_t v;
					memcpy(&v, &mem[beat * 8], 8);
					answers.push_back({rng.range(1, 6), v});
					reads++;
				} else {
					CHECK(__builtin_popcount(t->ld_be) == 1, "a write of %d bytes", __builtin_popcount(t->ld_be));
					for (int i = 0; i < 8; i++)
						if (t->ld_be >> i & 1) { mem[beat * 8 + i] = (uint8_t)(t->ld_din >> (8 * i)); written.push_back(beat * 8 + i); }
					writes++;
				}
			}
		}
		t->clk = 1; t->eval();
		t->clk = 0; t->eval();
		clocks++;
	}

	// one walk over img on the given date; returns the records written
	int walk(const std::vector<uint8_t> &img, int y, int m, int d, const char *what) {
		mem = img;
		writes = reads = 0;
		written.clear();
		t->date = (uint32_t)y << 16 | m << 8 | d;
		t->start = 1; tick(); t->start = 0;
		uint64_t t0 = clocks;
		while (t->busy && clocks < t0 + 12000000) tick();
		CHECK(!t->busy, "%s: the walk does not end", what);
		for (int i = 0; i < 8; i++) tick();
		CHECK(answers.empty() && !t->ld_rd && !t->ld_we, "%s: a command after the walk", what);

		std::vector<uint8_t> want = img;
		int n = model(want, ttime(y, m, d));
		CHECK_EQ(t->patched, n, what);
		CHECK_EQ(writes, 8 * n, what);
		CHECK(mem == want, "%s: the image after the walk is not the model's", what);
		return n;
	}
};

}  // namespace

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	uint32_t seed = 1;
	for (int i = 1; i < argc; i++)
		if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = (uint32_t)strtoul(argv[++i], nullptr, 0);
	Bench b(seed);

	CHECK_EQ(ttime(2004, 1, 1), 0x00E0AD82988E4000ull, "the bench's calendar: 2004-01-01");
	CHECK_EQ(ttime(2000, 1, 1), 730497ull * DAY_US, "the bench's calendar: 2000-01-01");

	const std::vector<uint8_t> t8a = {0x00, 0x16, 0x35, 0xD1, 0x90, 0xAD, 0xE0, 0x00};   // 2004-01-01 16:58
	const std::vector<uint8_t> t8b = {0x00, 0x8F, 0xA1, 0xCD, 0x90, 0xAD, 0xE0, 0x00};   // a minute before

	// an erased PMM, and a phone before its first start
	Pmm erased;
	CHECK_EQ(b.walk(erased.b, 2026, 11, 26, "an erased PMM"), 0, "an erased PMM");
	CHECK_EQ(b.reads, 16, "an erased PMM: two beats a sector");
	Pmm first;
	first.catalogue(0); first.catalogue(6, 0x00020000);
	for (int s : {1, 2, 3, 4, 5, 7}) first.spare(s);
	first.record(0, 212, 3, {105, 0});
	CHECK_EQ(b.walk(first.b, 2026, 11, 26, "before the first start"), 0, "before the first start");

	// as the firmware leaves it: records of other groups of every length up
	// to 40 (so the date records fall at every offset in a beat), replaced
	// date records, the alarm, and a date record in the seventh sector
	for (int shift = 0; shift < 8; shift++) {
		Pmm used = first;
		for (int i = 0; i < 30; i++)
			used.record(0, 10 + (i % 3), i, std::vector<uint8_t>((size_t)((i * 7 + shift) % 41), (uint8_t)i));
		used.record(0, 212, 0, t8a, 0xA4);
		used.record(0, 212, 1, t8b, 0xA4);
		used.record(0, 211, 0, t8a);
		used.record(0, 212, 0, t8a);
		used.record(0, 213, 1, t8b);
		used.record(0, 212, 1, t8b);
		used.record(0, 212, 2, std::vector<uint8_t>(8, 0));
		used.record(0, 212, 0, {1, 2, 3, 4});                      // not eight bytes
		used.record(0, 212, 256, t8a);                             // record 0x0100
		used.record(6, 4, 0, {1});
		used.record(6, 212, 1, t8a);
		static const int dates[][3] = {{2004, 1, 1}, {2000, 1, 1}, {2000, 2, 29}, {2000, 3, 1}, {2004, 2, 29}, {2026, 11, 26}, {2099, 12, 31}, {2100 - 1, 1, 1}};
		CHECK_EQ(b.walk(used.b, dates[shift][0], dates[shift][1], dates[shift][2], "a used PMM"), 3, "a used PMM: three date records");
	}
	// the value itself, once, from the image
	{
		Pmm p = first;
		size_t at = p.record(0, 212, 0, t8a);
		b.walk(p.b, 2004, 1, 1, "2004-01-01");
		uint64_t v;
		memcpy(&v, &b.mem[at], 8);
		CHECK_EQ(v, 0x00E0AD82988E4000ull, "2004-01-01 in the record");
	}

	// a date record whose data would run off the sector; chains that go wrong
	{
		Pmm p = first;
		p.record(0, 10, 0, {1}, 0xF4, (int)SECTOR - 19);
		p.end[0] = SECTOR - 19;
		p.record(0, 212, 0, t8a);
		CHECK_EQ(b.walk(p.b, 2026, 11, 26, "a record at the sector's end"), 0, "a record at the sector's end");
		Pmm q = first;
		q.record(0, 10, 0, {1}, 0xF4, (int)SECTOR - 20);
		q.end[0] = SECTOR - 20;
		q.record(0, 212, 0, t8a);
		CHECK_EQ(b.walk(q.b, 2026, 11, 26, "the last place a date record fits"), 1, "the last place a date record fits");
		for (int next : {0, 0x20, 0x21, 0x1FF5, 0x2000, 0x4000, 0xFFFF}) {
			Pmm r = first;
			r.record(0, 212, 0, t8a);
			r.record(0, 212, 1, t8b, 0xF4, next);
			r.record(0, 212, 0, t8a);
			b.walk(r.b, 2026, 11, 26, "a chain that goes wrong");
		}
	}

	// random bytes behind sector marks, and random dates
	for (int n = 0; n < 60; n++) {
		Pmm p;
		for (auto &x : p.b) x = (uint8_t)b.rng.u32();
		for (int s = 0; s < 8; s++) {
			if (b.rng.chance(60)) memcpy(&p.b[s * SECTOR + 6], "PMMCAT", 6);
			// some records that look like dates, where the random chain may or may not reach them
			for (int k = 0; k < 6; k++) {
				size_t at = s * SECTOR + (size_t)b.rng.range(0x20, (int)SECTOR - 24);
				p.b[at] = 0xF4; p.b[at + 1] = 212; p.b[at + 2] = (uint8_t)b.rng.range(0, 1); p.b[at + 3] = 0; p.b[at + 8] = 8; p.b[at + 9] = 0;
			}
			if (b.rng.chance(50)) { p.b[s * SECTOR + 0x20] = 0xF4; p.b[s * SECTOR + 0x2A] = (uint8_t)b.rng.range(0x2C, 0x60); p.b[s * SECTOR + 0x2B] = 0; }
		}
		b.busy_pct = b.rng.range(0, 90);
		int y = b.rng.range(2000, 2099), m = b.rng.range(1, 12);
		b.walk(p.b, y, m, b.rng.range(1, month_days(y, m)), "random bytes");
	}
	printf("pmm_date: %llu clocks\n", (unsigned long long)b.clocks);
	return sim::finish("pmm_date");
}
