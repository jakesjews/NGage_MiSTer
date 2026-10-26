// Behavioural model of the MiSTer DDRAM port (Avalon-MM: BUSY is
// waitrequest, DOUT_READY is readdatavalid), as the core sees it through
// sys_top's f2sdram bridge. Memory is a flat byte image of the physical
// range from BASE (0x30000000, the block MiSTer cores use), little-endian on
// the 64-bit bus.
//
// From Cray1_MiSTer's sim/harness/ddram_model.h (same author), with the
// Cray word helpers dropped and checks of the Avalon rules added: a command
// left waiting must be presented again unchanged, and DOUT_READY beats only
// follow accepted reads.
#pragma once
#include <algorithm>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <random>
#include <string>
#include <vector>
#include "snapshot.h"

struct DdramProfile {
	int lat_min = 14, lat_max = 16;  // clocks from accepting a read to the first word (about 15 at 105 MHz on a DE10-Nano)
	int busy_pct = 5;                // chance per clock that the port is busy
	int gap_pct = 0;                 // chance of an idle clock between burst words
	int stall_pct_x1000 = 0;         // chance per command of a long stall
	int stall_min = 30, stall_max = 100;
};

class DdramModel {
public:
	static constexpr uint32_t BASE = 0x30000000u;
	std::vector<uint8_t> mem;
	DdramProfile prof;
	uint64_t reads = 0, writes = 0;
	bool bad_access = false;
	int protocol_errors = 0;

	explicit DdramModel(size_t bytes = 48u << 20, uint32_t seed = 1) : mem(bytes, 0), rng(seed) {
		// DDR3 is not cleared when a core loads; start with junk to catch reliance on zeros
		for (auto &b : mem) b = (uint8_t)rng();
	}

	uint8_t &byte(uint32_t phys) { return mem[phys - BASE]; }
	uint16_t half(uint32_t phys) const { return (uint16_t)(mem[phys - BASE] | mem[phys - BASE + 1] << 8); }

	// Outputs of the model for the next clock
	bool     busy = false;
	bool     dout_ready = false;
	uint64_t dout = 0;

	// Call once per clock with the values the core drove during the clock that
	// just ended and the BUSY it saw. Updates busy/dout/dout_ready for the next.
	void step(bool rd, bool we, uint32_t addr29, uint8_t burstcnt, uint64_t din, uint8_t be) {
		if (rd && we) err("RD and WE together");
		// a command left waiting must be presented again, unchanged
		if (waiting) {
			if (!(rd || we)) err("a command left waiting was withdrawn");
			else if (rd != w_rd || we != w_we || addr29 != w_addr || burstcnt != w_cnt || (we && (din != w_din || be != w_be)))
				err("a command left waiting changed (addr %08x -> %08x)", w_addr << 3, addr29 << 3);
		}
		bool accepted = (rd || we) && !busy;
		waiting = (rd || we) && busy;
		w_rd = rd; w_we = we; w_addr = addr29; w_cnt = burstcnt; w_din = din; w_be = be;
		if (accepted) {
			uint64_t byte_addr = (uint64_t)addr29 << 3;
			if (byte_addr < BASE || byte_addr - BASE + 8ull * (burstcnt ? burstcnt : 1) > mem.size()) {
				fprintf(stderr, "ddram: access outside the model at 0x%llx\n", (unsigned long long)byte_addr);
				bad_access = true;
			} else {
				size_t off = (size_t)(byte_addr - BASE);
				if (we) {
					if (burstcnt != 1) err("write burst of %d (only single writes are expected)", burstcnt);
					for (int i = 0; i < 8; i++)
						if (be & (1 << i)) mem[off + i] = (uint8_t)(din >> (8 * i));
					writes++;
				} else {
					if (burstcnt == 0) err("read burst of 0");
					int lat = range(prof.lat_min, prof.lat_max);
					if (prof.stall_pct_x1000 && (int)(rng() % 100000) < prof.stall_pct_x1000)
						lat += range(prof.stall_min, prof.stall_max);
					// the words are read now, as the bridge serves its requests in
					// order: a write taken after this read does not reach them
					uint64_t when = std::max(now + lat, last_data + 1);
					for (int b = 0; b < burstcnt; b++) {
						if (b && prof.gap_pct && (int)(rng() % 100) < prof.gap_pct) when += range(1, 3);
						uint64_t d = 0;
						for (int i = 7; i >= 0; i--) d = (d << 8) | mem[off + 8u * b + i];   // little-endian bus
						pending.push_back({when, d});
						last_data = when;
						when++;
					}
					reads++;
				}
			}
		}
		now++;
		dout_ready = false;
		if (!pending.empty() && pending.front().when <= now) {
			dout = pending.front().data;
			pending.pop_front();
			dout_ready = true;
		} else {
			dout = ((uint64_t)rng() << 32) | rng();   // junk between beats
		}
		busy = prof.busy_pct && (int)(rng() % 100) < prof.busy_pct;
	}

	bool idle() const { return pending.empty() && !waiting; }

	// the whole model state to and from a snapshot file (snapshot.h)
	void save(FILE *f) const {
		snap::mark(f, 0xDD3A4D01u);
		snap::put(f, mem); snap::put(f, prof); snap::put(f, reads); snap::put(f, writes);
		snap::put(f, bad_access); snap::put(f, protocol_errors);
		snap::put(f, busy); snap::put(f, dout_ready); snap::put(f, dout);
		snap::put(f, pending); snap::put(f, rng); snap::put(f, now); snap::put(f, last_data);
		snap::put(f, waiting); snap::put(f, w_rd); snap::put(f, w_we); snap::put(f, w_addr);
		snap::put(f, w_cnt); snap::put(f, w_be); snap::put(f, w_din);
		snap::mark(f, 0xDD3A4D02u);
	}
	void load(FILE *f) {
		snap::check(f, 0xDD3A4D01u);
		snap::get(f, mem); snap::get(f, prof); snap::get(f, reads); snap::get(f, writes);
		snap::get(f, bad_access); snap::get(f, protocol_errors);
		snap::get(f, busy); snap::get(f, dout_ready); snap::get(f, dout);
		snap::get(f, pending); snap::get(f, rng); snap::get(f, now); snap::get(f, last_data);
		snap::get(f, waiting); snap::get(f, w_rd); snap::get(f, w_we); snap::get(f, w_addr);
		snap::get(f, w_cnt); snap::get(f, w_be); snap::get(f, w_din);
		snap::check(f, 0xDD3A4D02u);
	}

private:
	struct Beat { uint64_t when; uint64_t data; };
	std::deque<Beat> pending;
	std::mt19937 rng;
	uint64_t now = 0, last_data = 0;
	bool waiting = false, w_rd = false, w_we = false;
	uint32_t w_addr = 0;
	uint8_t w_cnt = 0, w_be = 0;
	uint64_t w_din = 0;
	int range(int a, int b) { return a + (int)(rng() % (uint32_t)(b - a + 1)); }
	void err(const char *fmt, ...) __attribute__((format(printf, 2, 3))) {
		protocol_errors++;
		if (protocol_errors > 10) return;
		va_list ap;
		va_start(ap, fmt);
		fprintf(stderr, "ddram: ");
		vfprintf(stderr, fmt, ap);
		fprintf(stderr, "\n");
		va_end(ap);
	}
};
