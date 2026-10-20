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
//               UEMK registers of model/cbus-regs.txt, with the UEMK RTC
//               (registers 0x11-0x13 and 0x01; ngage_cbus.c)
//   0x0C1F0100  the HLE RTC date register (ngage_cbus.c)
//   0x0C121200  LCD interface, only what the boot reads back: the panel ID
//               (RDDID, 0x290000 as the model's default) and status (RDDST)
//   0x0DE00000  STI trace window: the kernel's debug text goes to kern.log,
//               filtered as the model's ngage_sti.c does
//   0x0C150400  UIF ports D/E with the key matrix and the CTSI register at
//               0x0C150100 (ngage_keypad.c), with no key pressed
//   anything else reads 0 and ignores writes (the model's probe)
//
// The register blocks log the first read and the first write of every
// register in the format of the model's regs.log, so the two can be
// compared (sim/cpu/boot/cmp_regs.py). The model's other devices inside the
// upp block (DMA, MMC) are plain storage here and are left out of the log,
// as they are left out of the model's. With --devlog every device access
// also goes to dev.log, in the format of sim/cpu/model/trace_plugin.c, for
// sim/cpu/boot/cmp_dev.py.
//
// Timers count at 104/3 MHz (34,666,667 Hz) as in ngage_intc.c. Guest time
// follows retired instructions, 16 ns each, and jumps ahead to the next
// timer expiry while the CPU waits for an interrupt (WFI), as the model's
// -icount shift=4,sleep=off does; --time cycles uses the CPU clock instead
// (TIMER_DIV cycles per tick). The RTCs start at 2004-06-01 12:00:00, as
// sim/cpu/model/run_model.sh starts the model. The power key reads as held
// from reset, as at switch-on, and is released after 187,500,000
// instructions: the model holds it for 3 guest seconds.
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
		bool icount = true;                   // time from instructions (as the model)
		bool dev_log = false;                 // dev.log: every device access
		uint64_t power_release = 187500000;   // retired instructions; 0 = never
		// RTC at reset, as sim/cpu/model/run_model.sh starts the model
		// (-rtc base=2004-06-01T12:00:00): HLE RTC date and time of day
		uint32_t rtc_date = 2004u << 16 | 6u << 8 | 1u, rtc_tod = 12 * 3600;
	};

	bool init(const Options &o) {
		opt = o;
		cbus.rtc_tod0 = o.rtc_tod;
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
		kern_log = fopen((d + "/kern.log").c_str(), "w");
		if (o.dev_log) dev_log = fopen((d + "/dev.log").c_str(), "w");
		if (!regs_log || !cbus.log || !probe_log || !kern_log) {
			fprintf(stderr, "cannot write the logs in %s\n", d.c_str());
			return false;
		}
		return true;
	}

	~NGage() {
		if (regs_log) fclose(regs_log);
		if (cbus.log) fclose(cbus.log);
		if (probe_log) fclose(probe_log);
		if (kern_log) fclose(kern_log);
		if (dev_log) fclose(dev_log);
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
	// that made it, for the logs. Device accesses (everything but flash,
	// SDRAM and on-chip RAM) also go to the device log, in the format of
	// the model's trace plugin (sim/cpu/model/trace_plugin.c): "M n R|W size
	// pa value pc", n = instructions retired.
	uint32_t access(uint32_t a, bool we, uint8_t be, uint32_t wdata, uint32_t pc) {
		uint32_t r = access_(a, we, be, wdata, pc);
		if (dev_log && !cs0.has(a) && !cs1.has(a) && !mem_ptr(a)) {
			int off = be ? __builtin_ctz(be) : 0;
			unsigned size = (unsigned)__builtin_popcount(be);
			if (size == 0) size = 4;
			uint32_t mask = size == 4 ? 0xFFFFFFFFu : (1u << (8 * size)) - 1;
			fprintf(dev_log, "M %" PRIu64 " %c %u %08x %08x %08x\n", retired, we ? 'W' : 'R', size, a + off,
				((we ? wdata : r) >> (8 * off)) & mask, pc);
		}
		return r;
	}

	uint32_t access_(uint32_t a, bool we, uint8_t be, uint32_t wdata, uint32_t pc) {
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
		if (a - 0x0C1F0100u < 0x10) return !we && a == 0x0C1F0100u ? opt.rtc_date : 0;
		if (a - 0x0C120100u < 0x180) return intc_access(a - 0x0C120100u, we, wdata);
		if (a - 0x0C120040u < 0x40) return ostu_access(a - 0x0C120040u, we, wdata);
		if (a - 0x0C120A00u < 0x20 * NTIMERS) return timer_access(a - 0x0C120A00u, we, wdata);
		if (a - 0x0C121200u < 0x10) return lcd.access(a - 0x0C121200u, we, wdata);
		if (a - 0x0C150400u < 0x20 || a - 0x0C150100u < 4) {
			// 16-bit registers: a word access is two halfword accesses
			uint32_t v = 0;
			for (int h = 0; h < 2; h++) {
				if (!(be & (3 << (2 * h)))) continue;
				uint32_t ha = a + 2 * h;
				uint16_t hv = (uint16_t)(wdata >> (16 * h));
				uint16_t r = ha - 0x0C150100u < 4 ? keypad.ctsi(ha - 0x0C150100u, we, hv)
								 : keypad.uif(ha - 0x0C150400u, we, hv);
				v |= (uint32_t)r << (16 * h);
			}
			return v;
		}
		if (emif.has(a)) return emif.access(this, a, off, size, we, val, logged(a));
		if (upp.has(a)) return upp.access(this, a, off, size, we, val, logged(a));
		if (a - 0x0DE00000u < 0x200000u) {
			if (we)
				for (unsigned i = 0; i < size; i++) sti_byte((uint8_t)(val >> (8 * i)));
			return 0;
		}
		// probe: nothing there
		if (probe_count++ < 200000)
			fprintf(probe_log, "%s pc=%08x addr=%08x size=%u val=%08x cycle=%" PRIu64 "\n", we ? "W" : "R", pc,
				pa, size, we ? val : 0, cycle);
		return 0;
	}

	// One CPU cycle.
	void tick() {
		if (cbus.power_key && opt.power_release && retired >= opt.power_release) cbus.power_key = false;
		if (opt.icount) {
			now = retired * 16 + warp;
			if (wfi && !irq() && !fiq()) {
				// idle: jump to the next timer expiry (sleep=off)
				uint64_t next = UINT64_MAX;
				for (auto &t : timer)
					if (t.running && t.expire < next) next = t.expire;
				if (next != UINT64_MAX && next > now) { warp += next - now; now = next; }
			}
		} else {
			now = cycle * (uint64_t)opt.timer_div * 1000000000ull / TIMER_HZ;
		}
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
		const uint64_t *now = nullptr;   // guest time, ns
		uint32_t rtc_tod0 = 0;           // seconds since midnight at reset
		int32_t rtc_day_off = 0;         // day counter - days since that midnight

		uint64_t rtc_now() const { return rtc_tod0 + *now / 1000000000ull; }

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
			if (dev == 1) {
				uint64_t t = rtc_now();
				switch (reg) {
				case 0x11: v = (uint32_t)(t % 60); break;
				case 0x12: v = (uint32_t)(t / 60 % 60); break;
				case 0x13: v = (uint32_t)(t / 3600 % 24); break;
				case 0x01: v = (uint8_t)(rtc_day_off + (int64_t)(t / 86400)); break;
				}
			}
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
			if (dev == 1 && reg == 0x01) rtc_day_off = (int32_t)(v & 0xFF) - (int32_t)(rtc_now() / 86400);
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

	// ------------------------------------------------------------ keypad (ngage_keypad.c)
	struct Keypad {
		uint16_t data[2] = {}, dir[2] = {}, ien[2] = {}, misc[2] = {}, pull[2] = {}, reg18 = 0;
		uint16_t ctsi100 = 0, last_r = 0, last_c = 0;
		NGage *m = nullptr;

		static void setclr(uint16_t &r, uint16_t v) { r = (uint16_t)((r | (v & 0xFF)) & ~(v >> 8)); }
		void pins(uint16_t &c, uint16_t &r) const {      // no key is pressed
			c = 0x1F;
			r = 0x3F;
			for (int i = 0; i < 5; i++)
				if (dir[0] & (1 << i)) c = (uint16_t)((c & ~(1 << i)) | (data[0] & (1 << i)));
			for (int i = 0; i < 6; i++)
				if (dir[1] & (1 << i)) r = (uint16_t)((r & ~(1 << i)) | (data[1] & (1 << i)));
		}
		void update() {
			uint16_t c, r;
			pins(c, r);
			if (last_r & ~r & ien[1] & ~dir[1] & 0x3F) ctsi100 |= 1u << 2;
			if (last_c & ~c & ien[0] & ~dir[0] & 0x1F) ctsi100 |= 1u << 3;
			last_r = r;
			last_c = c;
			m->set_source(25, (ctsi100 & 0xC) != 0);
		}
		uint16_t uif(uint32_t off, bool we, uint16_t v) {
			if (we) {
				switch (off & ~1u) {
				case 0x00: data[0] = v & 0x1F; break;
				case 0x02: setclr(dir[0], v); break;
				case 0x04: setclr(ien[0], v); break;
				case 0x08: setclr(misc[0], v); break;
				case 0x0A: setclr(pull[0], v); break;
				case 0x0C: data[1] = v & 0x3F; break;
				case 0x0E: setclr(dir[1], v); break;
				case 0x10: setclr(ien[1], v); break;
				case 0x14: setclr(misc[1], v); break;
				case 0x16: setclr(pull[1], v); break;
				case 0x18: reg18 = v; break;
				}
				update();
				return 0;
			}
			uint16_t c, r;
			pins(c, r);
			switch (off & ~1u) {
			case 0x00: return c;
			case 0x02: return dir[0];
			case 0x04: return ien[0];
			case 0x08: return misc[0];
			case 0x0A: return pull[0];
			case 0x0C: return r;
			case 0x0E: return dir[1];
			case 0x10: return ien[1];
			case 0x14: return misc[1];
			case 0x16: return pull[1];
			case 0x18: return reg18;
			default: return 0;
			}
		}
		uint16_t ctsi(uint32_t off, bool we, uint16_t v) {
			if (off >= 2) return 0;
			if (!we) return ctsi100;
			ctsi100 &= (uint16_t)~(v & 0xC);
			ctsi100 = (uint16_t)((ctsi100 & 0xC) | (v & ~0xC));
			update();
			return 0;
		}
	} keypad;

	void set_source(int src, bool level) {
		uint32_t bit = 1u << (src & 31);
		if (level) pending[src >> 5] |= bit;
		else pending[src >> 5] &= ~bit;
	}

	// ------------------------------------------------------------ interrupts, timers
	static constexpr int NBANKS = 3, NTIMERS = 6;
	uint32_t pending[NBANKS] = {}, enable[2][NBANKS] = {}, other[2][NBANKS][16] = {}, ostu[16] = {};

	// times in ns, as ngage_intc.c (muldiv64 rounds down)
	static constexpr uint64_t TIMER_HZ = 34666667;
	struct Timer {
		int n = 0;
		uint32_t regs[8] = {};
		bool running = false;
		uint32_t start_count = 0;
		uint64_t start = 0, expire = 0;
	} timer[NTIMERS];

	static uint64_t muldiv(uint64_t a, uint64_t b, uint64_t c) {
		return (uint64_t)((unsigned __int128)a * b / c);
	}
	uint32_t count(const Timer &t) const {
		return t.running ? t.start_count - (uint32_t)muldiv(now - t.start, TIMER_HZ, 1000000000ull)
				 : t.regs[0x10 >> 2];
	}
	void schedule(Timer &t, uint32_t c) {
		t.start_count = c;
		t.start = now;
		t.expire = now + muldiv(c ? (uint64_t)c : (1ull << 32), 1000000000ull, TIMER_HZ);
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
	FILE *regs_log = nullptr, *probe_log = nullptr, *kern_log = nullptr, *dev_log = nullptr;

	void sti_byte(uint8_t c) {
		if (c == 0xC0 || c == 0xE0 || c == '\r') return;
		if (c == '\n' || c == '\t' || (c >= 0x20 && c < 0x7F)) fputc(c, kern_log);
		else fprintf(kern_log, "<%02x>", c);
		if (c == '\n') fflush(kern_log);
	}
	uint32_t probe_count = 0;
	uint32_t cur_pc = 0;
	uint64_t now = 0, warp = 0;      // guest time (ns), idle time skipped

public:
	uint64_t cycle = 0;     // set by the bench, for the logs
	uint64_t retired = 0;   // set by the bench: instructions retired
	bool wfi = false;       // set by the bench: the CPU waits for an interrupt
	NGage() {
		for (int n = 0; n < NTIMERS; n++) timer[n].n = n;
		keypad.m = this;
		cbus.pc = &cur_pc;
		cbus.now = &now;
	}
};
