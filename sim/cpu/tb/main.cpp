// SPDX-License-Identifier: GPL-3.0-or-later
//
// CPU bench driver: memory and a few bench registers on the arm925t bus,
// a retirement trace from the writeback probes, and the test result.
//
//   Vtb_cpu --bin test.bin [options]
//     --bin FILE        raw image loaded at 0 (the test, see tests/crt0.S)
//     --load ADDR:FILE  extra raw image at ADDR (RAM or high RAM)
//     --halt ADDR       address of the halt loop (default 0x40); the test
//                       ends when the instruction there retires
//     --sig FILE        dump the signature area (--sig-base, --sig-size)
//     --trace FILE      write one line per retired instruction or exception
//     --trace-after N   start the trace and the bus log after N retired
//                       instructions
//     --trace-count N   end the run N instructions after that
//     --dcdbg           also trace the D-cache state machine every cycle
//     --pddbg           also trace the branch prediction every cycle
//     --buslog FILE     write one line per bus access
//     --lat MIN:MAX     bus latency, cycles from request to ack (default 0:3)
//     --icache-quarantine  force conservative I-fill class (negative test)
//     --read-error ADDR  inject a bus error on reads of ADDR (repeatable)
//     --seed N          RNG seed for the latency (default 1)
//     --max-cycles N    give up after N cycles (default 50,000,000)
//     --quiet           no console echo
//     --progress N      print the cycle count and PC every N cycles
//     --watch ADDR      print the registers whenever the instruction at ADDR
//                       retires (repeatable)
//     --dump ADDR:LEN:FILE  write memory (as the CPU's bus sees it) at the end
//   N-Gage machine (ngage.h) instead of the test memory map:
//     --machine ngage   the reference model's memory map and devices; the
//                       CPU boots from CS0; no signature, --halt optional
//     --flash0 FILE     CS0 image (16 MB)       --flash1 FILE  CS1 image (8 MB)
//     --quirks FILE     model/upp-quirks.txt    --cbus-regs FILE  model/cbus-regs.txt
//     --logdir DIR      where regs.log, cbus.log and probe.log go
//     --time icount|cycles  guest time from instructions (16 ns each, idle
//                       skipped: the model's -icount shift=4,sleep=off; the
//                       default) or from the CPU clock
//     --timer-div N     with --time cycles: CPU cycles per timer tick (3)
//     --devlog          write dev.log: every device access (for model traces)
//     --power-release N release the power key after N instructions
//                       (default 187500000, as the model; 0 = hold it)
//
// Memory map seen by the CPU (physical):
//   0x00000000-0x00FFFFFF  16 MB RAM (QEMU -M none -m 16M has the same)
//   0xFFFF0000-0xFFFFFFFF  64 KB RAM, for high vectors with the MMU off
//   0xF0000000-0xF00000FF  bench registers (RTL only):
//      +00 W  console character
//      +04 W  stop the simulation now; the value is the exit code
//      +08 RW interrupt lines: bit 0 IRQ, bit 1 FIQ (level, active high)
//      +0C W  raise IRQ (bit 0 of +08) after this many cycles
//      +10 W  raise FIQ (bit 1 of +08) after this many cycles
//      +14 R  cycle counter
//      +18 R  retired instruction counter
//      +1C RW scratch word
//      +20 RW fixed bus latency when nonzero (overrides --lat), for tests
//      +24 R  watched-line loads completed during a D-cache fill
//      +28 R  watched-line stores completed during a D-cache fill
//      +2C W  select watched VA line and reset the two counters
//      +30..+3C R D-cache load fills, store fills, line write-backs,
//                uncached accesses (monotonic event counters)
//      +40 R  instructions retired during background store transactions
//      +44 W  select I-fill VA line and clear its early-retirement word mask
//      +48 R  watched-line words retired before their I-fill completed
//   anything else          bus error (external abort)
// Bus protocol checks: a request must stay unchanged until acked, and a
// burst beat must be followed by the next word of the same line.
#include "Vtb_cpu.h"
#include "ngage.h"
#include "verilated.h"

#include <algorithm>
#include <cinttypes>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>

namespace {

constexpr uint32_t RAM_SIZE = 16u << 20;
constexpr uint32_t HIRAM_BASE = 0xFFFF0000u;
constexpr uint32_t HIRAM_SIZE = 0x10000u;
constexpr uint32_t MMIO_BASE = 0xF0000000u;

std::vector<uint8_t> ram(RAM_SIZE), hiram(HIRAM_SIZE);

int errors = 0;
void error(const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "ERROR: ");
	vfprintf(stderr, fmt, ap);
	fprintf(stderr, "\n");
	va_end(ap);
	if (++errors > 20) exit(3);
}

uint8_t *mem_ptr(uint32_t a) {
	if (a < RAM_SIZE) return &ram[a];
	if (a >= HIRAM_BASE) return &hiram[a - HIRAM_BASE];
	return nullptr;
}

bool load_file(uint32_t addr, const char *path) {
	FILE *f = fopen(path, "rb");
	if (!f) { fprintf(stderr, "cannot open %s\n", path); return false; }
	uint8_t buf[4096];
	size_t n;
	uint32_t a = addr;
	while ((n = fread(buf, 1, sizeof buf, f)) > 0) {
		for (size_t i = 0; i < n; i++, a++) {
			uint8_t *p = mem_ptr(a);
			if (!p) { fprintf(stderr, "%s does not fit at 0x%08x\n", path, addr); fclose(f); return false; }
			*p = buf[i];
		}
	}
	fclose(f);
	return true;
}

uint32_t rd32(uint32_t a) {
	uint8_t *p = mem_ptr(a);
	return p ? (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24 : 0;
}

// Current-mode view of ZAP's physical registers (zap_localparams.svh).
int phys_index(int r, uint32_t mode) {
	if (r < 8) return r;
	switch (mode & 0x1F) {
	case 0x11: // FIQ
		if (r <= 14) return 18 + (r - 8);
		break;
	case 0x12: if (r == 13) return 25; if (r == 14) return 26; break; // IRQ
	case 0x13: if (r == 13) return 27; if (r == 14) return 28; break; // SVC
	case 0x1B: if (r == 13) return 29; if (r == 14) return 30; break; // UND
	case 0x17: if (r == 13) return 31; if (r == 14) return 32; break; // ABT
	default: break;
	}
	return r;
}

uint32_t reg_word(const Vtb_cpu *t, int phys) {
	return t->p_regs[phys];
}

}  // namespace

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);

	std::vector<std::pair<uint32_t, std::string>> loads;
	uint32_t halt = 0x40;
	uint32_t sig_base = 0x00F00000, sig_size = 0x10000;
	const char *sig_path = nullptr, *trace_path = nullptr, *buslog_path = nullptr;
	int lat_min = 0, lat_max = 3;
	uint32_t seed = 1;
	uint64_t max_cycles = 50000000;
	uint64_t progress = 0;
	uint64_t trace_after = 0, trace_count = 0;
	bool dcdbg = false, pddbg = false;
	bool quiet = false, icache_quarantine = false;
	bool halt_given = false;
	std::string machine;
	NGage::Options nopt;
	std::vector<uint32_t> watch, read_errors;
	struct Dump { uint32_t addr, len; std::string path; };
	std::vector<Dump> dumps;

	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		auto next = [&]() -> const char * {
			if (i + 1 >= argc) { fprintf(stderr, "%s needs a value\n", a.c_str()); exit(2); }
			return argv[++i];
		};
		if (a == "--bin") loads.push_back({0, next()});
		else if (a == "--load") {
			std::string v = next();
			size_t c = v.find(':');
			if (c == std::string::npos) { fprintf(stderr, "--load ADDR:FILE\n"); return 2; }
			loads.push_back({(uint32_t)strtoul(v.substr(0, c).c_str(), nullptr, 0), v.substr(c + 1)});
		}
		else if (a == "--halt") { halt = (uint32_t)strtoul(next(), nullptr, 0); halt_given = true; }
		else if (a == "--sig") sig_path = next();
		else if (a == "--sig-base") sig_base = (uint32_t)strtoul(next(), nullptr, 0);
		else if (a == "--sig-size") sig_size = (uint32_t)strtoul(next(), nullptr, 0);
		else if (a == "--trace") trace_path = next();
		else if (a == "--icache-quarantine") icache_quarantine = true;
		else if (a == "--read-error") read_errors.push_back((uint32_t)strtoul(next(), nullptr, 0));
		else if (a == "--buslog") buslog_path = next();
		else if (a == "--lat") {
			if (sscanf(next(), "%d:%d", &lat_min, &lat_max) != 2 || lat_min < 0 || lat_max < lat_min) {
				fprintf(stderr, "--lat MIN:MAX\n");
				return 2;
			}
		}
		else if (a == "--seed") seed = (uint32_t)strtoul(next(), nullptr, 0);
		else if (a == "--max-cycles") max_cycles = strtoull(next(), nullptr, 0);
		else if (a == "--quiet") quiet = true;
		else if (a == "--progress") progress = strtoull(next(), nullptr, 0);
		else if (a == "--trace-after") trace_after = strtoull(next(), nullptr, 0);
		else if (a == "--trace-count") trace_count = strtoull(next(), nullptr, 0);
		else if (a == "--dcdbg") dcdbg = true;
		else if (a == "--pddbg") pddbg = true;
		else if (a == "--watch") watch.push_back((uint32_t)strtoul(next(), nullptr, 0));
		else if (a == "--dump") {
			std::string v = next();
			size_t c1 = v.find(':'), c2 = v.find(':', c1 + 1);
			if (c1 == std::string::npos || c2 == std::string::npos) { fprintf(stderr, "--dump ADDR:LEN:FILE\n"); return 2; }
			dumps.push_back({ (uint32_t)strtoul(v.substr(0, c1).c_str(), nullptr, 0),
					  (uint32_t)strtoul(v.substr(c1 + 1, c2 - c1 - 1).c_str(), nullptr, 0), v.substr(c2 + 1) });
		}
		else if (a == "--machine") machine = next();
		else if (a == "--flash0") nopt.flash0 = next();
		else if (a == "--flash1") nopt.flash1 = next();
		else if (a == "--quirks") nopt.quirks = next();
		else if (a == "--cbus-regs") nopt.cbus_regs = next();
		else if (a == "--logdir") nopt.logdir = next();
		else if (a == "--timer-div") nopt.timer_div = atoi(next());
		else if (a == "--time") nopt.icount = std::string(next()) != "cycles";
		else if (a == "--devlog") nopt.dev_log = true;
		else if (a == "--power-release") nopt.power_release = strtoull(next(), nullptr, 0);
		else if (a[0] == '+') continue;  // Verilator's own
		else { fprintf(stderr, "unknown option %s\n", a.c_str()); return 2; }
	}
	NGage *ng = nullptr;
	if (machine == "ngage") {
		ng = new NGage;
		if (!ng->init(nopt)) return 2;
		if (!halt_given) halt = 0xFFFFFFFFu;
	} else if (!machine.empty()) {
		fprintf(stderr, "unknown machine %s\n", machine.c_str());
		return 2;
	} else if (loads.empty()) { fprintf(stderr, "no --bin given\n"); return 2; }
	for (auto &l : loads)
		if (!load_file(l.first, l.second.c_str())) return 2;

	FILE *trace = nullptr;
	if (trace_path && !(trace = fopen(trace_path, "w"))) { fprintf(stderr, "cannot write %s\n", trace_path); return 2; }

	FILE *buslog = nullptr;
	if (buslog_path && !(buslog = fopen(buslog_path, "w"))) { fprintf(stderr, "cannot write %s\n", buslog_path); return 2; }

	std::mt19937 rng(seed);
	Vtb_cpu *t = new Vtb_cpu;

	// bus responder state
	bool busy = false, ack_out = false, err_out = false;
	int wait = 0;
	uint32_t req_addr = 0, req_wdata = 0, req_pc = 0;
	uint8_t req_be = 0, req_bte = 0, prev_bte = 0;
	bool req_we = false, req_burst = false;
	bool prev_burst_beat = false;
	uint32_t prev_burst_addr = 0;
	uint64_t expected_dc_write = 0, dc_writes = 0, dc_early_writes = 0;
	// bench registers
	uint32_t irq_lines = 0, scratch = 0, fixed_lat = 0;
	uint32_t hum_watch = 0, hum_loads = 0, hum_stores = 0;
	uint64_t hum_total_loads = 0, hum_total_stores = 0;
	uint64_t dcache_events[4] = {};
	uint64_t icache_events[8] = {};
	uint32_t store_fill_retired = 0;
	uint32_t ic_watch = ~15u, ic_early_mask = 0;
	uint64_t dirty_fill_first = 0, dirty_write_first = 0;
	bool dirty_first_pending = false;
	int64_t irq_timer = -1, fiq_timer = -1;
	bool stop = false;
	int exit_code = -1;
	uint64_t cycle = 0, retired = 0, replays = 0;
	uint64_t stall_clocks[6] = {}, alu_flushes = 0, early_flushes = 0, uops = 0;
	uint64_t multiply_clocks = 0, multiply_releases = 0, multiply_next = 0;
	bool multiply_pending = false;
	std::string console;

	auto mmio_read = [&](uint32_t off) -> uint32_t {
		switch (off) {
		case 0x08: return irq_lines;
		case 0x14: return (uint32_t)cycle;
		case 0x18: return (uint32_t)retired;
		case 0x1C: return scratch;
		case 0x20: return fixed_lat;
		case 0x24: return hum_loads;
		case 0x28: return hum_stores;
		case 0x30: return (uint32_t)dcache_events[0];
		case 0x34: return (uint32_t)dcache_events[1];
		case 0x38: return (uint32_t)dcache_events[2];
		case 0x3C: return (uint32_t)dcache_events[3];
		case 0x40: return store_fill_retired;
		case 0x48: return ic_early_mask;
		default: return 0;
		}
	};
	auto mmio_write = [&](uint32_t off, uint32_t v, uint8_t be) {
		switch (off) {
		case 0x44: ic_watch = v & ~15u; ic_early_mask = 0; break;
		case 0x00:
			if (be & 1) {
				char c = (char)(v & 0xFF);
				if (!quiet) fputc(c, stdout);
				console += c;
			}
			break;
		case 0x04: stop = true; exit_code = (int)v; break;
		case 0x08: irq_lines = v & 3; break;
		case 0x0C: irq_timer = v; break;
		case 0x10: fiq_timer = v; break;
		case 0x1C: scratch = v; break;
		case 0x20: fixed_lat = v; break;
		case 0x2C: hum_watch = v & ~15u; hum_loads = hum_stores = 0; break;
		default: break;
		}
	};

	// reset
	t->clk = 0;
	t->reset = 1;
	t->irq = 0;
	t->fiq = 0;
	t->bus_ack = 0;
	t->bus_err = 0;
	t->bus_no_late_error = 0;
	t->bus_rdata = 0;
	t->eval();
	for (int i = 0; i < 8; i++) {
		t->clk = 1; t->eval();
		t->clk = 0; t->eval();
	}
	t->reset = 0;
	t->eval();

	bool halted = false;
	uint32_t last_pc = 0, last_r_pc = 0;
	char last_ev = 0;
	while (!stop && cycle < max_cycles) {
		// ---- before the rising edge: sample what commits at this edge ----
		// Observe the external request/acknowledge, not the implementation's
		// eligibility bit. Negative tests can prove an access was withheld.
		if ((t->p_dc_state & ((1u << 3) | (1u << 4) | (1u << 10))) &&
		    (t->p_dc_flags & 4) && (t->p_dc_flags & 3)) {
			bool store = t->p_dc_flags & 2;
			hum_total_loads += !store;
			hum_total_stores += store;
			if ((t->p_dc_addr & ~15u) == hum_watch) {
				hum_loads += !store;
				hum_stores += store;
			}
		}
		if ((t->p_dc_state & ((1u << 3) | (1u << 4))) &&
		    (t->p_dc_events & 2) && (t->p_valid || t->p_cfail)) store_fill_retired++;
		if (t->p_dc_events & 1) dirty_first_pending = t->p_dc_events & 4;
		if (dirty_first_pending && (t->p_dc_events & 0x18)) {
			dirty_fill_first += (t->p_dc_events & 8) != 0;
			dirty_write_first += (t->p_dc_events & 16) != 0;
			dirty_first_pending = false;
		}
		for (int b = 0; b < 6; b++) stall_clocks[b] += (t->p_stall >> b) & 1;
		for (int b = 0; b < 4; b++) dcache_events[b] += (t->p_dcache >> b) & 1;
		for (int b = 0; b < 8; b++) icache_events[b] += (t->p_icache >> b) & 1;
		if (((t->p_icache & 3) != 0) != ((t->p_stall & 2) != 0) ||
		    bool(t->p_icache & 8) != ((t->p_icache & 3) == 2))
			error("instruction-side debug taps disagree with code stall");
		// A held redirect is counted on its accepting edge, not every held clock.
		alu_flushes += (t->p_alu_flags & 0x30) == 0x20;
		early_flushes += (t->p_stall & 0x41) == 0x40 && !(t->p_alu_flags & 0x20);
		uops += t->p_valid || t->p_cfail;
		multiply_clocks += t->p_mult_state & 1;
		if (t->p_mult_state & 8) {
			multiply_pending = false;
		} else if (t->p_mult_state & 1) {
			multiply_pending = true;
		} else if (multiply_pending && !(t->p_mult_state & 2)) {
			multiply_releases++;
			multiply_next += (t->p_mult_state >> 2) & 1;
			multiply_pending = false;
		}
		uint32_t cpsr_before = t->p_cpsr;
		bool thumb = (cpsr_before >> 5) & 1;
		uint32_t pc = t->p_pc8 - (thumb ? 4 : 8);
		char ev = 0;
		if (t->p_dabt & 2) { replays++; ev = 0; } // replay: no architectural effect
		else if (t->p_dabt & 1) ev = 'D';
		else if (t->p_fiq) ev = 'F';
		else if (t->p_irq) ev = 'I';
		else if (t->p_iabt) ev = 'P';
		else if (t->p_swi) ev = 'S';
		else if (t->p_und) ev = 'U';
		else if ((t->p_valid || t->p_cfail) && t->p_last) ev = 'R';

		if (ev == 'R' && t->p_ic_fill_active && (pc & ~15u) == ic_watch &&
			(t->p_ic_fill_addr & ~15u) == ic_watch)
			ic_early_mask |= 1u << ((pc >> 2) & 3);

		// bus: protocol checks and the responder
		bool req = t->bus_req;
		if (busy && !ack_out) {
			if (!req) error("cycle %" PRIu64 ": request at 0x%08x withdrawn before ack", cycle, req_addr);
			else if (t->bus_addr != req_addr || t->bus_we != req_we || t->bus_be != req_be ||
				 (req_we && t->bus_wdata != req_wdata) || t->bus_burst != req_burst || t->bus_bte != req_bte)
				error("cycle %" PRIu64 ": request at 0x%08x changed before ack (now 0x%08x)", cycle, req_addr,
				      (uint32_t)t->bus_addr);
		}
		bool complete = false;
		if (ack_out) {
			complete = true;  // this edge completes the request
		} else if (req && !busy) {
			busy = true;
			req_addr = t->bus_addr;
			req_we = t->bus_we;
			req_be = t->bus_be;
			req_wdata = t->bus_wdata;
			req_burst = t->bus_burst;
			req_bte = t->bus_bte;
			req_pc = t->p_dpc8 - (((t->p_cpsr >> 5) & 1) ? 4 : 8);
			// BTE wraps only the word index; CTI still counts the four beats.
			uint32_t mask = prev_bte ? ((1u << (prev_bte + 3)) - 1) : 0xFFFFFFFFu;
			uint32_t next_addr = (prev_burst_addr & ~mask) | ((prev_burst_addr + 4) & mask);
			if (prev_burst_beat && (req_addr != next_addr || req_bte != prev_bte))
				error("cycle %" PRIu64 ": burst continued at 0x%08x after 0x%08x", cycle, req_addr, prev_burst_addr);
			if ((req_addr & 3) != 0) error("cycle %" PRIu64 ": unaligned bus address 0x%08x", cycle, req_addr);
			wait = fixed_lat ? (int)fixed_lat - 1 : lat_min + (int)(rng() % (uint32_t)(lat_max - lat_min + 1));
		}
		bool respond = false;
		if (busy && !ack_out) {
			if (wait <= 0) respond = true;
			else wait--;
		}

		if (buslog && retired >= trace_after && t->p_dreq)
			fprintf(buslog, "%" PRIu64 " d va=%08x%s\n", cycle, (uint32_t)t->p_dva, t->p_dalign ? " ALIGN" : "");

		// pre-decoder and ALU prediction state before the edge (--pddbg)
		if (pddbg && trace && retired >= trace_after)
			fprintf(trace, "P %" PRIu64 " pc %08x i %08x ppc %08x w %08x bp %08x f %04x | alu ppc %08x f %02x"
				" | uop %010" PRIx64 " f %x | res %08x dst %02x | sh %016" PRIx64 "\n",
				cycle, (uint32_t)t->p_pd_pc, (uint32_t)t->p_pd_ins, (uint32_t)t->p_pd_ppc,
				(uint32_t)t->p_pd_wpc, (uint32_t)t->p_pd_pred, (unsigned)t->p_pd_flags,
				(uint32_t)t->p_alu_ppc, (unsigned)t->p_alu_flags, (uint64_t)t->p_uop_ins,
				(unsigned)t->p_uop_flags, (uint32_t)t->p_alu_res, (unsigned)t->p_alu_dst, (uint64_t)t->p_sh_dbg);
		// D-cache state machine before the edge, in the trace window (--dcdbg)
		if (dcdbg && trace && retired >= trace_after)
			fprintf(trace, "C %" PRIu64 " st %04x f %04x a %08x d %08x o %08x\n", cycle, (unsigned)t->p_dc_state,
				(unsigned)t->p_dc_flags, (uint32_t)t->p_dc_addr, (uint32_t)t->p_dc_din, (uint32_t)t->p_dc_dat);

		// ---- rising edge ----
		// A background write must follow the requested beat by exactly one
		// edge, and the destination stays locked until that write reaches RF.
		uint64_t dc_write = t->p_dc_reg_wr;
		uint32_t dc_data = t->p_dc_reg_data;
		uint64_t lock_before = t->p_lock;
		if (dc_write != expected_dc_write)
			error("cycle %" PRIu64 ": background write %016" PRIx64 " expected %016" PRIx64,
			      cycle, dc_write, expected_dc_write);
		if ((dc_write & lock_before) != dc_write)
			error("cycle %" PRIu64 ": background write destination was not locked", cycle);
		expected_dc_write = t->p_dc_fill_take &&
			((t->bus_addr & ~3u) == (t->p_dc_fill_addr & ~3u)) ? lock_before : 0;
		if (dc_write) {
			dc_writes++;
			if (t->p_dc_state & (1u << 4)) dc_early_writes++;
		}
		t->clk = 1;
		t->eval();
		cycle++;
		if ((lock_before & ~uint64_t(t->p_lock)) != dc_write)
			error("cycle %" PRIu64 ": load lock cleared without its register write", cycle);
		for (int r = 0; dc_write && r < 40; r++)
			if ((dc_write >> r) & 1)
				if ((t->p_lock & dc_write) || reg_word(t, r) != dc_data)
					error("cycle %" PRIu64 ": early load write did not reach unlocked r%d", cycle, r);

		// ---- after the edge: state after the committed instruction ----
		if (ev) {
			uint32_t cpsr = t->p_cpsr;
			// N-Gage machine: count instructions as QEMU's icount does, so that
			// guest time and instruction numbers follow the model. An SWI or
			// undefined instruction counts (it completes; an aborted one does
			// not), and a Thumb BL pair counts once: QEMU runs the two halves as
			// one instruction, ZAP as two (QEMU splits it too when the first
			// half ends a 1 KB page, its smallest page size, as in
			// tools/cmp_trace.py). The second half is recognised by its
			// position (right after the first) and its effect (LR = next | 1).
			bool bl_second = false;
			if (ng && ev == 'R' && thumb && last_ev == 'R' && pc == last_r_pc + 2 && (pc & 0x3FF)) {
				int lr = phys_index(14, cpsr);
				bl_second = !((t->p_lock >> lr) & 1) && reg_word(t, lr) == ((pc + 2) | 1);
			}
			if ((ev == 'R' && !bl_second) || (ng && (ev == 'S' || ev == 'U'))) retired++;
			if (trace && retired >= trace_after) {
				fprintf(trace, "%c %08x", ev, pc);
				for (int r = 0; r < 15; r++) {
					int p = phys_index(r, cpsr);
					bool locked = (t->p_lock >> p) & 1;
					if (locked) fprintf(trace, " --------");
					else fprintf(trace, " %08x", reg_word(t, p));
				}
				fprintf(trace, " %08x\n", cpsr);
			}
			if (ev == 'R' && pc == halt) halted = true;
			if (trace_count && retired >= trace_after + trace_count) halted = true;
			for (uint32_t w : watch) {
				if (ev != 'R' || pc != w) continue;
				fprintf(stderr, "watch %08x cycle %" PRIu64 " retired %" PRIu64 ":", pc, cycle, retired);
				for (int r = 0; r < 15; r++) fprintf(stderr, " %08x", reg_word(t, phys_index(r, cpsr)));
				fprintf(stderr, " cpsr %08x ttb %08x dacr %08x mmu %d\n", cpsr, (uint32_t)t->p_ttb,
					(uint32_t)t->p_dacr, (int)t->p_mmu);
			}
			last_pc = pc;
			last_ev = ev;
			if (ev == 'R') last_r_pc = pc;
		}

		// bus outputs for the next cycle
		t->bus_ack = 0;
		t->bus_err = 0;
		t->bus_no_late_error = 0;
		if (complete) {
			busy = false;
			ack_out = false;
			err_out = false;
			prev_burst_beat = req_burst;
			prev_burst_addr = req_addr;
			prev_bte = req_bte;
		} else if (respond) {
			uint32_t a = req_addr & ~3u;
			uint8_t *p = ng ? nullptr : mem_ptr(a);
			bool mmio = !ng && (a & 0xFFFFFF00u) == MMIO_BASE;
			uint32_t rdata = 0;
			if (ng) {
				ng->cycle = cycle;
				rdata = ng->access(a, req_we, req_be, req_wdata, req_pc);
			} else if (p) {
				if (req_we) {
					for (int b = 0; b < 4; b++)
						if (req_be & (1 << b)) p[b] = (uint8_t)(req_wdata >> (8 * b));
				}
				rdata = (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
			} else if (mmio) {
				if (req_we) mmio_write(a & 0xFF, req_wdata, req_be);
				rdata = mmio_read(a & 0xFF);
			} else {
				err_out = true;
			}
			if (!req_we && std::find(read_errors.begin(), read_errors.end(), a) != read_errors.end())
				err_out = true;
			ack_out = true;
			if (buslog && retired >= trace_after)
				fprintf(buslog, "%" PRIu64 " %c %08x be=%x %08x%s%s\n", cycle, req_we ? 'W' : 'R', a, req_be,
					req_we ? req_wdata : rdata, req_burst ? " burst" : "", err_out ? " ERR" : "");
			// Ordinary bench RAM models an SDRAM-class target. A line
			// configured with an injected error is an error-capable target
			// for ALL its beats, including successful beats before the error.
			bool error_line = std::any_of(read_errors.begin(), read_errors.end(),
			    [a](uint32_t e) { return (e & ~15u) == (a & ~15u); });
			t->bus_no_late_error = !icache_quarantine && p && !req_we && req_bte == 1 && !error_line && !err_out;
			t->bus_ack = !err_out;
			t->bus_err = err_out;
			t->bus_rdata = err_out ? 0xDEADBEEFu : rdata;
		}
		if (irq_timer >= 0 && --irq_timer < 0) irq_lines |= 1;
		if (fiq_timer >= 0 && --fiq_timer < 0) irq_lines |= 2;
		t->irq = irq_lines & 1;
		t->fiq = (irq_lines >> 1) & 1;
		if (ng) {
			ng->retired = retired;
			ng->cycle = cycle;
			ng->wfi = t->p_wfi;
			ng->tick();
			t->irq = ng->irq();
			t->fiq = ng->fiq();
		}
		if (progress && cycle % progress == 0) {
			if (ng) ng->flush();
			fprintf(stderr, "cycle %" PRIu64 " retired %" PRIu64 " pc %08x cpsr %08x\n", cycle, retired, last_pc,
				(uint32_t)t->p_cpsr);
		}

		t->clk = 0;
		t->eval();

		if (halted) break;
	}

	if (trace) fclose(trace);
	if (buslog) fclose(buslog);
	for (auto &d : dumps) {
		FILE *f = fopen(d.path.c_str(), "wb");
		if (!f) { fprintf(stderr, "cannot write %s\n", d.path.c_str()); return 2; }
		for (uint32_t a = d.addr; a < d.addr + d.len; a++) {
			uint8_t *p = ng ? ng->mem_ptr(a) : mem_ptr(a);
			fputc(p ? *p : 0, f);
		}
		fclose(f);
	}

	uint32_t result = rd32(sig_base);
	if (sig_path) {
		FILE *f = fopen(sig_path, "wb");
		if (!f) { fprintf(stderr, "cannot write %s\n", sig_path); return 2; }
		for (uint32_t a = sig_base; a < sig_base + sig_size; a++) {
			uint8_t *p = mem_ptr(a);
			fputc(p ? *p : 0, f);
		}
		fclose(f);
	}

	int rc;
	if (ng) {
		if (errors) printf("BENCH ERROR (%d bus protocol errors)\n", errors);
		else if (halted) printf("HALT at 0x%08x, cycle %" PRIu64 ", %" PRIu64 " instructions\n", halt, cycle, retired);
		else printf("END after %" PRIu64 " cycles, %" PRIu64 " instructions, last pc 0x%08x\n", cycle, retired, last_pc);
		rc = errors ? 3 : 0;
		delete ng;
	} else if (errors) {
		printf("BENCH ERROR (%d bus protocol errors)\n", errors);
		rc = 3;
	} else if (stop) {
		printf("STOP code %d at cycle %" PRIu64 "\n", exit_code, cycle);
		rc = exit_code == 0 ? 0 : 1;
	} else if (!halted) {
		printf("TIMEOUT after %" PRIu64 " cycles, last retired pc 0x%08x\n", cycle, last_pc);
		rc = 1;
	} else if (result == 1) {
		printf("Uops: %" PRIu64 "\n", uops);
		printf("Multiply: busy_clocks=%" PRIu64 " releases=%" PRIu64
		       " younger_waiting=%" PRIu64 "\n", multiply_clocks, multiply_releases, multiply_next);
		printf("Pipeline: data=%" PRIu64 " code=%" PRIu64 " fifo_empty=%" PRIu64
		       " issue=%" PRIu64 " shifter=%" PRIu64 " decode=%" PRIu64
		       " alu_flushes=%" PRIu64 " early_flushes=%" PRIu64 "\n", stall_clocks[0], stall_clocks[1],
		       stall_clocks[2], stall_clocks[3], stall_clocks[4], stall_clocks[5], alu_flushes, early_flushes);
		printf("Replays: %" PRIu64 "\n", replays);
		printf("Hit under miss: loads=%" PRIu64 " stores=%" PRIu64 "\n", hum_total_loads, hum_total_stores);
		printf("D-cache events: load_fills=%" PRIu64 " store_fills=%" PRIu64
		       " writebacks=%" PRIu64 " uncached=%" PRIu64 "\n",
		       dcache_events[0], dcache_events[1], dcache_events[2], dcache_events[3]);
		printf("I-cache events: fifo_full=%" PRIu64 " fetch_wait=%" PRIu64
		       " fills=%" PRIu64 " true_wait=%" PRIu64 " merger_wait=%" PRIu64
		       " bus_wait=%" PRIu64 " itlb_beats=%" PRIu64 " dtlb_beats=%" PRIu64 "\n",
		       icache_events[0], icache_events[1], icache_events[2], icache_events[3],
		       icache_events[4], icache_events[5], icache_events[6], icache_events[7]);
		printf("Background writes: %" PRIu64 ", during fill: %" PRIu64 "\n", dc_writes, dc_early_writes);
		printf("D-cache overlap: store_fill_retired=%u dirty_fill_first=%" PRIu64
		       " dirty_write_first=%" PRIu64 "\n", store_fill_retired, dirty_fill_first, dirty_write_first);
		printf("PASS (%" PRIu64 " cycles, %" PRIu64 " instructions)\n", cycle, retired);
		rc = 0;
	} else {
		printf("FAIL result 0x%08x (check %u) at cycle %" PRIu64 "\n", result, result & 0xFFFF, cycle);
		rc = 1;
	}
	t->final();
	delete t;
	return rc;
}
