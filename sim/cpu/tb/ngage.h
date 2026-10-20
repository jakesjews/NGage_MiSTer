// SPDX-License-Identifier: GPL-3.0-or-later
//
// The N-Gage QD as the reference model (model/hw) presents it to the CPU, for
// running the real boot code on the RTL (main.cpp --machine ngage). It is a
// small port of the model's devices, enough for the bootstrap and the first
// part of the kernel start:
//
//   0x00000000  CS0 NOR flash, 16 MB   AMD commands: autoselect, CFI query,
//   0x02000000  CS1 NOR flash, 8 MB    program, erase (at once), reset
//   0x0A000000  SDRAM, 16 MB
//   0x0C000000  on-chip RAM, 256 KB
//   0x08000000  "emif" register block, 64 KB  } storage, read quirks from
//   0x0C100000  "upp" register block, 1 MB    } model/upp-quirks.txt
//   0x0C120040  OS-timer interrupt unit, 0x0C120100 interrupt controller,
//   0x0C120A00  timers 0-5 (ngage_intc.c), 0x0C150420 CBUS master and the
//               UEMK registers of model/cbus-regs.txt (ngage_cbus.c)
//   0x0C121200  LCD interface, only what the boot reads back: the panel ID
//               (RDDID, 0x290000 as the model's default) and status (RDDST)
//   anything else reads 0 and ignores writes (the model's probe)
//
// The register blocks log the first read and the first write of every
// register in the format of the model's regs.log, so the two can be
// compared (sim/cpu/boot/cmp_regs.py). The model's other devices inside the
// upp block (DMA, MMC, keypad, CTSI) are plain storage here and are left out
// of the log, as they are left out of the model's.
//
// Timers count at 104/3 MHz, one tick per TIMER_DIV CPU cycles (3 for a
// 104 MHz CPU). The power key reads as held, as at switch-on.
#pragma once

#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

class NGage {
public:
	struct Options {
		std::string flash0, flash1, quirks, cbus_regs, logdir;
		int timer_div = 3;
	};

	bool init(const Options &o) {
		opt = o;
		cs0.init(0x00000000u, 16u << 20, 0x22F8);
		cs1.init(0x02000000u, 8u << 20, 0x22FA);
		if (!cs0.load(o.flash0) || !cs1.load(o.flash1)) return false;
		sdram.assign(16u << 20, 0);
		iram.assign(256u << 10, 0);
		emif.init("emif", 0x08000000u, 0x10000u);
		upp.init("upp", 0x0C100000u, 0x100000u);
		if (!o.quirks.empty() && !load_quirks(o.quirks)) return false;
		if (!o.cbus_regs.empty() && !cbus.load(o.cbus_regs)) return false;
		std::string d = o.logdir.empty() ? "." : o.logdir;
		regs_log = fopen((d + "/regs.log").c_str(), "w");
		cbus.log = fopen((d + "/cbus.log").c_str(), "w");
		probe_log = fopen((d + "/probe.log").c_str(), "w");
		if (!regs_log || !cbus.log || !probe_log) {
			fprintf(stderr, "cannot write the logs in %s\n", d.c_str());
			return false;
		}
		return true;
	}

	~NGage() {
		if (regs_log) fclose(regs_log);
		if (cbus.log) fclose(cbus.log);
		if (probe_log) fclose(probe_log);
	}

	// Direct memory for cached line fills and the like (nullptr: a device).
	uint8_t *mem_ptr(uint32_t a) {
		if (cs0.has(a) && cs0.mode == Flash::READ) return &cs0.data[a - cs0.base];
		if (cs1.has(a) && cs1.mode == Flash::READ) return &cs1.data[a - cs1.base];
		if (a - 0x0A000000u < sdram.size()) return &sdram[a - 0x0A000000u];
		if (a - 0x0C000000u < iram.size()) return &iram[a - 0x0C000000u];
		return nullptr;
	}

	// One bus beat (word address a, byte enables be). pc: the instruction
	// that made it, for the logs.
	uint32_t access(uint32_t a, bool we, uint8_t be, uint32_t wdata, uint32_t pc) {
		cur_pc = pc;
		int off = be ? __builtin_ctz(be) : 0;
		unsigned size = (unsigned)__builtin_popcount(be);
		if (size == 0) size = 4;
		uint32_t mask = size == 4 ? 0xFFFFFFFFu : (1u << (8 * size)) - 1;
		uint32_t val = (wdata >> (8 * off)) & mask;    // value as the CPU sees it
		uint32_t pa = a + off;

		if (cs0.has(a) || cs1.has(a)) {
			Flash &f = cs0.has(a) ? cs0 : cs1;
			if (we) { f.write(pa - f.base, val, size); return 0; }
			if (f.mode == Flash::READ) return rd_mem(&f.data[a - f.base]);
			return f.read_id(pa - f.base, size) << (8 * off);
		}
		if (uint8_t *p = mem_ptr(a)) {
			if (we)
				for (int b = 0; b < 4; b++)
					if (be & (1 << b)) p[b] = (uint8_t)(wdata >> (8 * b));
			return rd_mem(p);
		}
		if (a - 0x0C150420u < 8) return cbus.access(pa, we, val, size) << (8 * off);
		if (a - 0x0C120100u < 0x180) return intc_access(a - 0x0C120100u, we, wdata);
		if (a - 0x0C120040u < 0x40) return ostu_access(a - 0x0C120040u, we, wdata);
		if (a - 0x0C120A00u < 0x20 * NTIMERS) return timer_access(a - 0x0C120A00u, we, wdata);
		if (a - 0x0C121200u < 0x10) return lcd.access(a - 0x0C121200u, we, wdata);
		if (emif.has(a)) return emif.access(this, a, off, size, we, val, logged(a));
		if (upp.has(a)) return upp.access(this, a, off, size, we, val, logged(a));
		// probe: nothing there
		if (probe_count++ < 200000)
			fprintf(probe_log, "%s pc=%08x addr=%08x size=%u val=%08x cycle=%" PRIu64 "\n", we ? "W" : "R", pc,
				pa, size, we ? val : 0, cycle);
		return 0;
	}

	// One CPU cycle.
	void tick() {
		if (++div < opt.timer_div) return;
		div = 0;
		now++;
		for (auto &t : timer)
			if (t.running && now >= t.expire) expire(t);
	}

	bool irq() const {
		for (int k = 0; k < NBANKS; k++)
			if (pending[k] & enable[0][k]) return true;
		return false;
	}
	bool fiq() const {
		for (int k = 0; k < NBANKS; k++)
			if (pending[k] & enable[1][k]) return true;
		return (ostu[0x10 >> 2] & ostu[0x04 >> 2] & 7) != 0;
	}

private:
	static uint32_t rd_mem(const uint8_t *p) {
		return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
	}

	// ------------------------------------------------------------ flash
	struct Flash {
		enum { READ, UNLOCK1, UNLOCK2, CMD80, CMD80_U1, CMD80_U2, PROGRAM, AUTOSELECT, CFI };
		uint32_t base = 0, size = 0;
		uint16_t device_id = 0;
		int state = READ, mode = READ;
		std::vector<uint8_t> data;

		void init(uint32_t b, uint32_t s, uint16_t id) {
			base = b; size = s; device_id = id;
			data.assign(s, 0xFF);
		}
		bool has(uint32_t a) const { return a - base < size; }
		bool load(const std::string &path) {
			FILE *f = fopen(path.c_str(), "rb");
			if (!f) { fprintf(stderr, "cannot open %s\n", path.c_str()); return false; }
			size_t n = fread(data.data(), 1, size, f);
			fclose(f);
			(void)n;
			return true;
		}
		uint32_t read_id(uint32_t addr, unsigned sz) const {
			uint32_t w = (addr >> 1) & 0xFF, v = 0;
			if (mode == AUTOSELECT) {
				v = w == 0 ? 0x00EC : w == 1 ? device_id : 0;
			} else {
				static const uint16_t q[] = { 'Q', 'R', 'Y', 0x02, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00 };
				if (w >= 0x10 && w < 0x10 + 11) v = q[w - 0x10];
				else if (w == 0x27) v = (uint32_t)__builtin_ctz(size);
			}
			if (sz == 4) v |= v << 16;
			return v;
		}
		void write(uint32_t addr, uint32_t val, unsigned sz) {
			uint32_t w = (addr >> 1) & 0x7FF;
			uint32_t d = val & 0xFFFF;
			if (state == PROGRAM) {
				for (unsigned i = 0; i < sz && addr + i < size; i++) data[addr + i] &= (uint8_t)(val >> (8 * i));
				state = READ;
				return;
			}
			if (d == 0xF0 || d == 0xFF) { state = READ; mode = READ; return; }
			switch (state) {
			case READ:
				if (w == 0x555 && (d & 0xFF) == 0xAA) state = UNLOCK1;
				else if (w == 0x55 && (d & 0xFF) == 0x98) mode = CFI;
				break;
			case UNLOCK1: state = (w == 0x2AA && (d & 0xFF) == 0x55) ? UNLOCK2 : READ; break;
			case UNLOCK2:
				state = READ;
				if ((d & 0xFF) == 0x90) mode = AUTOSELECT;
				else if ((d & 0xFF) == 0xA0) state = PROGRAM;
				else if ((d & 0xFF) == 0x80) state = CMD80;
				break;
			case CMD80: state = (w == 0x555 && (d & 0xFF) == 0xAA) ? CMD80_U1 : READ; break;
			case CMD80_U1: state = (w == 0x2AA && (d & 0xFF) == 0x55) ? CMD80_U2 : READ; break;
			case CMD80_U2:
				if ((d & 0xFF) == 0x30) {      // sector erase, done at once here
					uint32_t len = addr >= size - 0x10000u ? 0x2000u : 0x10000u;
					uint32_t o = addr & ~(len - 1);
					if (o < size) memset(&data[o], 0xFF, len);
				} else if ((d & 0xFF) == 0x10) {
					memset(data.data(), 0xFF, size);
				}
				state = READ;
				break;
			default: state = READ;
			}
		}
	};

	// ------------------------------------------------------------ register blocks
	struct Quirk { uint32_t pa, or_mask, and_mask; };
	std::vector<Quirk> quirks;

	bool load_quirks(const std::string &path) {
		FILE *f = fopen(path.c_str(), "r");
		if (!f) { fprintf(stderr, "cannot open %s\n", path.c_str()); return false; }
		char line[512];
		while (fgets(line, sizeof line, f)) {
			if (char *h = strchr(line, '#')) *h = 0;
			unsigned long a, o, n;
			if (sscanf(line, "%li %li %li", (long *)&a, (long *)&o, (long *)&n) == 3)
				quirks.push_back({ (uint32_t)a, (uint32_t)o, (uint32_t)n });
		}
		fclose(f);
		return true;
	}

	// Addresses that are other devices in the model (not in its regs.log).
	static bool logged(uint32_t a) {
		static const uint32_t other[][2] = {
			{ 0x0C120300, 0x0C120500 },     // DMA
			{ 0x0C120600, 0x0C120640 },     // MMC
			{ 0x0C121200, 0x0C121210 },     // LCD (ported below)
			{ 0x0C150100, 0x0C150104 },     // CTSI
			{ 0x0C150400, 0x0C150420 },     // UIF keypad
		};
		for (auto &r : other)
			if (a >= r[0] && a < r[1]) return false;
		return true;
	}

	struct Block {
		const char *name = "";
		uint32_t base = 0, size = 0;
		std::vector<uint32_t> regs;
		std::vector<uint8_t> seen;
		void init(const char *n, uint32_t b, uint32_t s) {
			name = n; base = b; size = s;
			regs.assign(s / 4, 0);
			seen.assign(s / 4, 0);
		}
		bool has(uint32_t a) const { return a - base < size; }
		uint32_t access(NGage *m, uint32_t a, int off, unsigned sz, bool we, uint32_t val, bool log) {
			uint32_t i = (a - base) >> 2;
			uint32_t mask = sz == 4 ? 0xFFFFFFFFu : ((1u << (8 * sz)) - 1) << (8 * off);
			if (we) {
				if (log) m->note(*this, i, true, val, sz);
				regs[i] = (regs[i] & ~mask) | ((val << (8 * off)) & mask);
				return 0;
			}
			uint32_t v = regs[i];
			for (auto &q : m->quirks)
				if (q.pa == a) v = (v | q.or_mask) & q.and_mask;
			if (log) m->note(*this, i, false, (v & mask) >> (8 * off), sz);
			return v;
		}
	};

	void note(Block &b, uint32_t i, bool we, uint32_t val, unsigned sz) {
		uint8_t bit = we ? 2 : 1;
		if (b.seen[i] & bit) return;
		b.seen[i] |= bit;
		fprintf(regs_log, "%s %-9s %08x size=%u val=%08x pc=%08x\n", we ? "W" : "R", b.name, b.base + 4 * i, sz,
			val, cur_pc);
		fflush(regs_log);
	}

	// ------------------------------------------------------------ CBUS
	struct Cbus {
		uint16_t len = 0, ctrl = 0, data_hi = 0, data_lo = 0;
		uint32_t regs[8][32] = {}, ro_val[8][32] = {};
		uint8_t is_ro[8][32] = {};
		uint16_t adc[16] = {};
		bool power_key = true;
		FILE *log = nullptr;
		uint32_t *pc = nullptr;

		bool load(const std::string &path) {
			FILE *f = fopen(path.c_str(), "r");
			if (!f) { fprintf(stderr, "cannot open %s\n", path.c_str()); return false; }
			char line[512];
			while (fgets(line, sizeof line, f)) {
				if (char *h = strchr(line, '#')) *h = 0;
				long d, r, v;
				char kind[8] = "";
				if (sscanf(line, " adc %li %li", &r, &v) == 2) { adc[r & 15] = (uint16_t)v; continue; }
				int n = sscanf(line, "%li %li %li %7s", &d, &r, &v, kind);
				if (n >= 3) {
					regs[d & 7][r & 31] = (uint32_t)v;
					if (n == 4 && !strcmp(kind, "ro")) { ro_val[d & 7][r & 31] = (uint32_t)v; is_ro[d & 7][r & 31] = 1; }
				}
			}
			fclose(f);
			return true;
		}
		unsigned bits() const { return (len & 0x1F) + 1u; }
		void logit(const char *what, unsigned dev, unsigned reg, unsigned b, uint32_t v) {
			fprintf(log, "%s dev=%u reg=%02x bits=%2u val=%05x len=%04x ctrl=%04x pc=%08x\n", what, dev, reg, b, v,
				len, ctrl, pc ? *pc : 0);
		}
		void do_read() {
			unsigned dev = (ctrl >> 5) & 7, reg = ctrl & 0x1F, b = bits();
			uint32_t v = is_ro[dev][reg] ? ro_val[dev][reg] : regs[dev][reg];
			if (dev == 1 && reg == 0x1F) v = (v & ~2u) | (power_key ? 2u : 0);
			if (b < 32) v &= (1u << b) - 1;
			data_lo = (uint16_t)v;
			data_hi = (uint16_t)(v >> 16);
			logit("R", dev, reg, b, v);
		}
		void do_write() {
			unsigned dev = (ctrl >> 5) & 7, reg = ctrl & 0x1F, b = bits();
			uint32_t v = data_lo | (b > 16 ? (uint32_t)data_hi << 16 : 0);
			if (b < 32) v &= (1u << b) - 1;
			logit("W", dev, reg, b, v);
			regs[dev][reg] = v;
			if (dev == 1 && reg == 0x19 && (v & 0x800) && !is_ro[1][0x1A]) {
				regs[1][0x1A] = adc[(v >> 12) & 15];
				fprintf(log, "  ADC channel %u -> %u\n", (v >> 12) & 15, regs[1][0x1A]);
			}
		}
		void write16(uint32_t off, uint16_t v) {
			switch (off & 6) {
			case 0: len = v; break;
			case 2: ctrl = v & 0x3FF; if (v & 0x100) do_read(); break;
			case 4: data_hi = v; break;
			case 6: data_lo = v; do_write(); break;
			}
		}
		// pa: byte address; returns the value as seen at pa
		uint32_t access(uint32_t pa, bool we, uint32_t val, unsigned sz) {
			uint32_t off = pa & 7;
			if (we) {
				write16(off, (uint16_t)val);
				if (sz == 4) write16(off + 2, (uint16_t)(val >> 16));
				return 0;
			}
			uint16_t r[4] = { len, (uint16_t)(ctrl | 0x400), data_hi, data_lo };
			uint32_t v = r[(off >> 1) & 3];
			if (sz == 4) v |= (uint32_t)r[((off >> 1) + 1) & 3] << 16;
			return v;
		}
	};

	// ------------------------------------------------------------ LCD (ngage_lcd.c)
	struct Lcd {
		uint32_t ctrl = 0, aux = 0, last = 0, id = 0x290000;
		uint8_t cmd = 0, rd[8] = {}, madctl = 0, colmod = 6;
		int rd_len = 0, rd_pos = 0, left = 0;
		bool sleep = true, on = false, idle = false, te = false;

		void command(uint8_t c) {
			cmd = c;
			switch (c) {
			case 0x01: madctl = 0; colmod = 6; sleep = true; on = false; break;
			case 0x10: sleep = true; break;
			case 0x11: sleep = false; break;
			case 0x28: on = false; break;
			case 0x29: on = true; break;
			case 0x38: idle = false; break;
			case 0x39: idle = true; break;
			case 0x34: te = false; break;
			case 0x35: te = true; break;
			case 0x04:
				rd[0] = 0; rd[1] = (uint8_t)(id >> 16); rd[2] = (uint8_t)(id >> 8); rd[3] = (uint8_t)id;
				rd_len = 4; rd_pos = 0;
				break;
			case 0x09:
				rd[0] = 0;
				rd[1] = (uint8_t)(0x80 | (madctl & 0xF4));
				rd[2] = (uint8_t)(((colmod & 7) << 4) | (idle ? 8 : 0) | (sleep ? 0 : 2) | 1);
				rd[3] = (uint8_t)((on ? 4 : 0) | (te ? 2 : 0));
				rd[4] = 0;
				rd_len = 5; rd_pos = 0;
				break;
			}
		}
		void byte(uint8_t b, bool first) {
			if (!first) return;
			if (cmd == 0x36) madctl = b;
			if (cmd == 0x3A) colmod = b;
		}
		void data(uint32_t w) {
			last = w;
			switch ((ctrl >> 18) & 3) {
			case 2: command((uint8_t)w); break;
			case 1: {
				uint32_t u0 = w & 0xFFF, u1 = (w >> 16) & 0xFFF, v = u0 | u1 << 12;
				uint8_t b0 = (ctrl & 0x80000000u) ? (uint8_t)(u0 >> 4) : (uint8_t)v;
				if (left) { byte(b0, true); left = 0; }
				break;
			}
			case 3:
				if (left) { byte((uint8_t)w, true); left = 0; }
				break;
			}
		}
		uint32_t access(uint32_t off, bool we, uint32_t v) {
			if (we) {
				if (off == 0x00) { ctrl = v; left = 1; }
				else if (off == 0x04) aux = v;
				else if (off == 0x08) data(v);
				return 0;
			}
			switch (off) {
			case 0x00: return ctrl | (1u << 30);
			case 0x04: return (aux & ~4u) | 4u;
			case 0x08:
				if ((ctrl & 0x0F000000u) == 0x07000000u) return rd_pos < rd_len ? rd[rd_pos++] : 0;
				return last;
			default: return 0;
			}
		}
	} lcd;

	// ------------------------------------------------------------ interrupts, timers
	static constexpr int NBANKS = 3, NTIMERS = 6;
	uint32_t pending[NBANKS] = {}, enable[2][NBANKS] = {}, other[2][NBANKS][16] = {}, ostu[16] = {};

	struct Timer {
		int n = 0;
		uint32_t regs[8] = {};
		bool running = false;
		uint32_t start_count = 0;
		uint64_t start = 0, expire = 0;
	} timer[NTIMERS];

	uint32_t count(const Timer &t) const {
		return t.running ? t.start_count - (uint32_t)(now - t.start) : t.regs[0x10 >> 2];
	}
	void schedule(Timer &t, uint32_t c) {
		t.start_count = c;
		t.start = now;
		t.expire = now + (c ? (uint64_t)c : (1ull << 32));
	}
	void expire(Timer &t) {
		pending[0] |= 1u << t.n;
		if (t.regs[0x04 >> 2] & 2) schedule(t, t.regs[0x18 >> 2]);
		else { t.running = false; t.regs[0x10 >> 2] = 0; }
	}

	uint32_t intc_access(uint32_t off, bool we, uint32_t val) {
		int plane = off >= 0xC0;
		uint32_t o = off - (plane ? 0xC0 : 0);
		int k = (int)(o >> 6);
		if (k >= NBANKS) return 0;
		if (we) {
			switch (o & 0x3F) {
			case 0x08: enable[plane][k] |= val; break;
			case 0x0C: enable[plane][k] &= ~val; break;
			default: other[plane][k][(o & 0x3F) >> 2] = val;
			}
			return 0;
		}
		switch (o & 0x3F) {
		case 0x08: return enable[plane][k];
		case 0x10: return pending[k];
		case 0x14: {
			uint32_t act = pending[k] & enable[plane][k];
			return act ? (uint32_t)__builtin_ctz(act) + 1 : 0;
		}
		default: return other[plane][k][(o & 0x3F) >> 2];
		}
	}

	uint32_t ostu_access(uint32_t off, bool we, uint32_t val) {
		if (!we) return ostu[(off >> 2) & 15];
		if (off == 0x10) ostu[4] &= ~val;
		else ostu[(off >> 2) & 15] = val;
		return 0;
	}

	uint32_t timer_access(uint32_t off, bool we, uint32_t val) {
		Timer &t = timer[(off >> 5) % NTIMERS];
		uint32_t o = off & 0x1F;
		if (!we) return o == 0x10 ? count(t) : t.regs[o >> 2];
		switch (o) {
		case 0x04:
			if ((val & 3) && !t.running) { t.running = true; schedule(t, t.regs[0x10 >> 2]); }
			else if (!(val & 3) && t.running) { t.regs[0x10 >> 2] = count(t); t.running = false; }
			break;
		case 0x08: pending[0] &= ~(1u << t.n); break;
		case 0x10:
			if (t.running) schedule(t, val);
			else if (t.regs[0x04 >> 2] & 3) { t.running = true; schedule(t, val); }
			break;
		}
		t.regs[o >> 2] = val;
		return 0;
	}

	Options opt;
	Flash cs0, cs1;
	std::vector<uint8_t> sdram, iram;
	Block emif, upp;
	Cbus cbus;
	FILE *regs_log = nullptr, *probe_log = nullptr;
	uint32_t probe_count = 0;
	uint32_t cur_pc = 0;
	uint64_t now = 0;
	int div = 0;

public:
	uint64_t cycle = 0;     // set by the bench, for the logs
	NGage() {
		for (int n = 0; n < NTIMERS; n++) timer[n].n = n;
		cbus.pc = &cur_pc;
	}
};
