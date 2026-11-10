// Boot bench for the whole core (module emu of NGage.sv, CPU included): the
// N-Gage firmware runs on the RTL with the SDRAM chip model on the SDRAM
// pins, the DDRAM port model behind DDR3, hps_io stood in for (sim/stubs)
// and, as on the MiSTer, the flash images in DDR3, an MMC image on SD slot 0
// and MiSTer's RTC.
//
//   Vemu --cs0 FILE --cs1 FILE [--mmc FILE] [--out DIR] [options]
//
// The images go into the DDRAM model's memory at 0x31000000 / 0x32000000 at
// once, and then a one-word ioctl download of each (the word the image has)
// marks it loaded as the OSD's load does; the CPU starts when both are in.
// Options:
//   --out DIR          logs and pictures (default .)
//   --cycles N         stop after N clocks (default 1e9)
//   --rtc "Y-M-D h:m:s"  MiSTer's RTC (default 2004-06-01 12:00:00, as
//                      sim/cpu/model/run_model.sh starts the model)
//   --keys FILE        key script, as the model's: lines "<seconds> down|up
//                      <key>", seconds of simulated time (104 MHz clocks)
//   --devlog           DIR/dev.log: every CPU access to a device, in the format
//                      of sim/cpu/model/trace_plugin.c ("M n R|W size pa value
//                      pc"; n = instructions executed, counted as QEMU's
//                      icount counts them), for sim/cpu/boot/cmp_dev.py, and
//                      every interrupt and exception ("X n exc from vector")
//   --trace FILE --trace-after N --trace-count M
//                      an instruction window (sim/cpu/boot/cmp_window.py)
//   --progress N       a line every N clocks (with wall-clock time)
//   --check-flash      compare every CPU read beat from CS0/CS1 with the
//                      image in the DDRAM model (the flash contents, writes
//                      included) when that chip was in read-array mode (no
//                      command, program or erase) from before the beat
//                      began; report the first mismatches and the count
//   --buslog FILE      one line per CPU beat to CS0/CS1/SDRAM: clock, R|W,
//                      address, SEL, data, CTI
//   --until TEXT       stop when the STI text ends with TEXT
//   --load-use FILE    the load-to-consumer mix and the modelled cost of the
//                      104 MHz pipeline cuts (sim/profile/load_use.h), per
//                      profile segment (needs a CPU_PROFILE build)
//   --ddr-lat MIN:MAX, --ddr-busy PCT, --ddr-gap PCT, --ddr-stall PCT_X1000
//                      the DDRAM port's timing (ddram_model.h's DdramProfile)
//   --fault-history N  retain N retirements in memory; dump on D/P/U and
//                      this ROM's Kern::Fault entry (0x5031e340), plus raw
//                      SDRAM and the generated RTL state (including caches).
//                      Observer only; the RTL state requires this build's header.
//   --save FILE --save-at N [--save-exit]
//                      write a snapshot when the clock count reaches N: the
//                      model through Verilator's save (the bench is built
//                      --savable) into FILE and the harness's state (the SDRAM
//                      and DDRAM models, the counters) into FILE.bench; then
//                      carry on, or stop with --save-exit
//   --restore FILE     start from that snapshot instead of booting: the same
//                      binary, --cs0/--cs1 not needed (the images and every
//                      write to them are in the snapshot), --mmc the same
//                      image, --keys with absolute times (events at or before
//                      the snapshot's clock have happened), --cycles absolute,
//                      --out a new directory (kern.log, dev.log and the
//                      pictures start afresh; audio.wav restarts)
// Always written: DIR/kern.log (the kernel's debug text through the STI
// window), DIR/lcd-<ms>.png each time the picture at the video outputs
// changes (and lcd-last.png), DIR/audio.wav (AUDIO_L/R at 48 kHz, once the
// HLE audio device has played something), DIR/run.log lines on stdout.
#include "Vemu.h"
#include "Vemu___024root.h"
#include "verilated.h"
#include "verilated_save.h"
#include "common.h"
#include "ddram_model.h"
#include "sdram_model.h"
#include "../profile/cpu_profile.h"
#include "../profile/load_use.h"

#include <chrono>
#include <cinttypes>
#include <cstring>
#include <map>
#include <string>
#include <vector>

namespace {

// ---------------------------------------------------------------- PNG
uint32_t crc32_tab[256];
void crc_init() {
	for (uint32_t n = 0; n < 256; n++) {
		uint32_t c = n;
		for (int k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
		crc32_tab[n] = c;
	}
}
uint32_t crc32(uint32_t c, const uint8_t *p, size_t n) {
	c = ~c;
	while (n--) c = crc32_tab[(c ^ *p++) & 0xFF] ^ (c >> 8);
	return ~c;
}
void put32(std::vector<uint8_t> &v, uint32_t x) {
	for (int i = 3; i >= 0; i--) v.push_back((uint8_t)(x >> (8 * i)));
}
void chunk(FILE *f, const char *type, const std::vector<uint8_t> &data) {
	std::vector<uint8_t> c;
	put32(c, (uint32_t)data.size());
	c.insert(c.end(), type, type + 4);
	c.insert(c.end(), data.begin(), data.end());
	put32(c, crc32(0, c.data() + 4, c.size() - 4));
	fwrite(c.data(), 1, c.size(), f);
}
// RGB888, deflate "stored" blocks (no compression)
bool write_png(const std::string &path, const sim::Image &im) {
	FILE *f = fopen(path.c_str(), "wb");
	if (!f) return false;
	static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', 13, 10, 26, 10};
	fwrite(sig, 1, 8, f);
	std::vector<uint8_t> hdr;
	put32(hdr, (uint32_t)im.w);
	put32(hdr, (uint32_t)im.h);
	hdr.insert(hdr.end(), {8, 2, 0, 0, 0});
	chunk(f, "IHDR", hdr);
	std::vector<uint8_t> raw;
	for (int y = 0; y < im.h; y++) {
		raw.push_back(0);
		raw.insert(raw.end(), im.rgb.begin() + (size_t)y * im.w * 3, im.rgb.begin() + (size_t)(y + 1) * im.w * 3);
	}
	std::vector<uint8_t> z = {0x78, 0x01};
	uint32_t a = 1, b = 0;
	for (uint8_t c : raw) { a = (a + c) % 65521; b = (b + a) % 65521; }
	for (size_t off = 0; off < raw.size() || off == 0;) {
		size_t n = std::min<size_t>(65535, raw.size() - off);
		z.push_back(off + n >= raw.size() ? 1 : 0);
		z.push_back((uint8_t)n); z.push_back((uint8_t)(n >> 8));
		z.push_back((uint8_t)~n); z.push_back((uint8_t)(~n >> 8));
		z.insert(z.end(), raw.begin() + off, raw.begin() + off + n);
		off += n;
		if (off >= raw.size()) break;
	}
	put32(z, b << 16 | a);
	chunk(f, "IDAT", z);
	chunk(f, "IEND", {});
	fclose(f);
	return true;
}

// ---------------------------------------------------------------- WAV
void write_wav(const std::string &path, const std::vector<int16_t> &s) {
	FILE *f = fopen(path.c_str(), "wb");
	if (!f) return;
	auto w32 = [&](uint32_t x) { fwrite(&x, 4, 1, f); };
	auto w16 = [&](uint16_t x) { fwrite(&x, 2, 1, f); };
	fwrite("RIFF", 1, 4, f); w32(36 + 2 * (uint32_t)s.size());
	fwrite("WAVEfmt ", 1, 8, f); w32(16); w16(1); w16(2); w32(48000); w32(48000 * 4); w16(4); w16(16);
	fwrite("data", 1, 4, f); w32(2 * (uint32_t)s.size());
	fwrite(s.data(), 2, s.size(), f);
	fclose(f);
}

std::vector<uint8_t> read_file(const std::string &path) {
	std::vector<uint8_t> d;
	FILE *f = fopen(path.c_str(), "rb");
	if (!f) { fprintf(stderr, "cannot read %s\n", path.c_str()); exit(2); }
	fseek(f, 0, SEEK_END);
	d.resize((size_t)ftell(f));
	fseek(f, 0, SEEK_SET);
	if (fread(d.data(), 1, d.size(), f) != d.size()) { fprintf(stderr, "short read %s\n", path.c_str()); exit(2); }
	fclose(f);
	return d;
}

// the CPU's banked registers (zap_register_file indices, as tb/main.cpp)
int phys_index(int r, uint32_t mode) {
	if (r < 8) return r;
	switch (mode & 0x1F) {
	case 0x11: if (r <= 14) return 18 + (r - 8); break;
	case 0x12: if (r == 13) return 25; if (r == 14) return 26; break;
	case 0x13: if (r == 13) return 27; if (r == 14) return 28; break;
	case 0x1B: if (r == 13) return 29; if (r == 14) return 30; break;
	case 0x17: if (r == 13) return 31; if (r == 14) return 32; break;
	default: break;
	}
	return r;
}

// a device as trace_plugin.c records them: 0x08000000-0x0DFFFFFF, not SDRAM
// or on-chip RAM
bool device(uint32_t a) {
	return a >= 0x08000000u && a < 0x0E000000u && !(a >= 0x0A000000u && a < 0x0B000000u) &&
	       !(a >= 0x0C000000u && a < 0x0C040000u);
}

#define PROFILE_TAP(n) emu__DOT__arm925t__DOT__profile_probe__DOT__##n

// Register snapshots and V2 held-read profiling use implementation-specific taps.
#define V2_TAP(n) emu__DOT__arm925t__DOT__u_zap__DOT__g_arm9__DOT__u_arm9_core__DOT__##n
#define CORE_REGS emu__DOT__arm925t__DOT__u_zap__DOT__g_arm9__DOT__u_arm9_core__DOT__u_zap_writeback__DOT__u_zap_register_file__DOT__mem
#define CORE_DATA_PC emu__DOT__arm925t__DOT__u_zap__DOT__g_arm9__DOT__u_arm9_core__DOT__data_pc8

// keys of the key script: a joystick bit (ngage_input.sv) or a PS/2 code
struct KeyName { const char *name; int joy; int ps2; };
const KeyName key_names[] = {
	{"right", 0, -1}, {"left", 1, -1}, {"down", 2, -1}, {"up", 3, -1}, {"5", 4, -1}, {"7", 5, -1},
	{"ok", 6, -1}, {"lsk", 7, -1}, {"rsk", 8, -1}, {"menu", 9, -1}, {"call", 10, -1}, {"end", 11, -1},
	{"star", 12, -1}, {"hash", 13, -1}, {"clear", 14, -1}, {"edit", 15, -1}, {"power", 16, -1},
	{"0", -1, 0x45}, {"1", -1, 0x16}, {"2", -1, 0x1E}, {"3", -1, 0x26}, {"4", -1, 0x25},
	{"6", -1, 0x36}, {"8", -1, 0x3E}, {"9", -1, 0x46},
};
struct KeyEvent { uint64_t clock; bool down; const KeyName *k; };

constexpr double CLK_HZ = 104e6;

struct Bench {
	Vemu *t = new Vemu;
	Vemu___024root *r;
	uint64_t clocks = 0;
	static constexpr uint32_t DDR_BASE = 0x31000000u;
	// --check-window (2026-10-25): loads from the C: drive's two aliases
	// (0x59200000 uncached, 0x59600000 cached) against the live flash image.
	// --check-copy: every Mem::Copy (0x503A1D38) out of those aliases: its
	// stores against the source bytes in the image, and the buffer's loads
	// for a while after. The data port reports the word's address and the
	// byte enables; a value is the selected bytes, shifted down, sign-extended
	// for LDRSB/H. --trace-on-bad FILE starts an instruction trace at the
	// first wrong value.
	bool check_window = false, check_copy = false, check_store = false;
	uint64_t ustores = 0, ustore_bad = 0;
	struct { uint32_t pa, data, sel; uint64_t clock; } ubeat[32] = {}; int ubeat_n = 0;
	uint64_t win_unc = 0, win_hit = 0, win_miss = 0, win_bad = 0, copies = 0, copy_stores = 0, copy_loads = 0;
	struct WinPend { uint32_t va, data, sel; uint64_t clock; bool used; char kind; } win_pend[16] = {};
	struct { uint32_t dst = 0, src = 0, n = 0, lr = 0; uint64_t clock = 0; bool active = false, dirty = false; } copy;
	std::string trace_on_bad;
#define WIN_FSM(x) emu__DOT__arm925t__DOT__u_zap__DOT__l_generate_with_cache_mmu__DOT__u_data_cache__DOT__u_zap_cache_fsm__DOT__##x
	uint8_t flash_byte(uint32_t va) {   // the live image behind a C: alias address
		uint32_t base = va < 0x59600000u ? 0x59200000u : 0x59600000u;
		uint32_t off = 0x400000u + (va - base);
		return dm.mem[DDR_BASE + 0x01000000u + off - DdramModel::BASE];
	}
	bool in_window(uint32_t va) { return va >= 0x59200000u && va < 0x59a00000u; }
	bool in_buffer(uint32_t va) { return copy.n && va >= copy.dst && va < copy.dst + copy.n; }
	// the word the image gives for a data-port access at VA (word address):
	// a window address directly; a buffer address through the copy's source
	uint32_t expected_word(uint32_t va, uint32_t got) {
		uint32_t w = 0;
		for (int k = 0; k < 4; k++) {
			uint32_t a = (va & ~3u) + k, b;
			if (in_window(a)) b = flash_byte(a);
			else if (copy.n && a >= copy.dst && a < copy.dst + copy.n) b = flash_byte(copy.src + (a - copy.dst));
			else b = (got >> (8 * k)) & 0xffu;
			w |= (uint32_t)b << (8 * k);
		}
		return w;
	}
	bool win_ok(uint32_t got, uint32_t img, uint32_t sel) {
		if (sel == 0xf || sel == 0)
			for (unsigned sh = 0; sh < 32; sh += 8)
				if (got == ((img >> sh) | (sh ? (img << (32 - sh)) : 0))) return true;
		if (sel == 0xf) return false;
		for (int lo = 0; lo < 4; lo++) {
			if (sel && lo != __builtin_ctz(sel)) continue;
			int n = sel ? __builtin_popcount(sel) : 1;
			for (int bytes = n; bytes <= (sel ? n : 2); bytes++) {
				if (lo + bytes > 4) break;
				uint32_t v = (img >> (8 * lo)) & (bytes == 1 ? 0xffu : 0xffffu);
				uint32_t sx = bytes == 1 ? (uint32_t)(int32_t)(int8_t)v : (uint32_t)(int32_t)(int16_t)v;
				if (got == v || got == sx) return true;
			}
		}
		return false;
	}
	void win_report(const char *kind, uint32_t va, uint32_t got, uint32_t sel, uint32_t img, uint64_t at) {
		win_bad++;
		if (win_bad <= 60)
			printf("WINDOW %s clock %" PRIu64 " VA %08x sel %x got %08x image %08x pc %08x copy dst %08x src %08x n %x\n", kind, at, va, sel, got, img,
			       (uint32_t)(r->CORE_DATA_PC - 8), copy.dst, copy.src, copy.n);
		if (win_bad == 1 && !trace_on_bad.empty() && !trace) {
			trace = fopen(trace_on_bad.c_str(), "w"); trace_after = retired; trace_count = 300000; trace_done = false;
			printf("trace started at retired %" PRIu64 "\n", retired);
		}
	}
	void win_check(const char *kind, uint32_t va, uint32_t got, uint32_t sel, uint64_t at) {
		uint32_t img = expected_word(va, got);
		bool ok;
		if (kind[0] == 's') {   // a store: the data bus carries the selected lanes in place
			uint32_t mask = 0;
			for (int k = 0; k < 4; k++) if (sel >> k & 1) mask |= 0xffu << (8 * k);
			ok = ((got ^ img) & mask) == 0;
		} else ok = win_ok(got, img, sel);
		if (!ok) win_report(kind, va, got, sel, img, at);
	}
	void copy_entry(uint32_t cpsr) {   // Mem::Copy retired: r0 dst, r1 src, r2 n
		uint32_t dst = reg(phys_index(0, cpsr)), src = reg(phys_index(1, cpsr)), n = reg(phys_index(2, cpsr));
		if (!in_window(src) || n == 0 || n > 0x10000) return;
		copies++; copy.dst = dst; copy.src = src; copy.n = n; copy.clock = clocks;
		copy.lr = reg(phys_index(14, cpsr)) & ~1u; copy.active = true; copy.dirty = false;
	}
	uint64_t win_last_cmd = 0;
	void win_watch() {
		// the CS1 chip answers commands (autoselect, status) instead of the
		// array: medint reads word 4 of every block in autoselect mode at
		// 0x503800ac; skip loads near any such mode, as flash_watch does
#define WIN_ARRAY (r->emu__DOT__ngage_mem__DOT__flash_cs1__DOT__mode == 0 && r->emu__DOT__ngage_mem__DOT__flash_cs1__DOT__cseq == 0 && \
                   r->emu__DOT__ngage_mem__DOT__flash_cs1__DOT__p_state == 0 && r->emu__DOT__ngage_mem__DOT__flash_cs1__DOT__e_state == 0)
		if (!WIN_ARRAY) win_last_cmd = clocks;
		bool quiet = clocks - win_last_cmd > 64;
		if (r->emu__DOT__tr_d_done) {
			uint32_t va = r->emu__DOT__tr_d_va, sel = r->emu__DOT__tr_d_sel;
			bool we = r->emu__DOT__tr_d_we;
			if (we) {
				if (check_store && va >= 0x59200000u && va < 0x59600000u) {
					// an uncached store completes after its beat: the beat with this PA
					uint32_t pa = 0x02400000u + (va - 0x59200000u), d = r->emu__DOT__tr_d_wdata;
					int found = -1;
					for (int i = 1; i <= 32 && i <= ubeat_n; i++)
						if ((ubeat[(ubeat_n - i) % 32].pa & ~3u) == (pa & ~3u) && clocks - ubeat[(ubeat_n - i) % 32].clock < 400) { found = (ubeat_n - i) % 32; break; }
					ustores++;
					uint32_t mask = 0; for (int k = 0; k < 4; k++) if (sel >> k & 1) mask |= 0xffu << (8 * k);
					if (found < 0 || ((ubeat[found].data ^ d) & mask) != 0 || ubeat[found].sel != sel) {
						ustore_bad++;
						if (ustore_bad <= 40)
							printf("USTORE clock %" PRIu64 " VA %08x sel %x data %08x : beat %s pc %08x\n", clocks, va, sel, d,
							       found < 0 ? "none" : "", (uint32_t)(r->CORE_DATA_PC - 8));
						if (found >= 0 && ustore_bad <= 40) printf("   beat clock %" PRIu64 " PA %07x sel %x data %08x\n", ubeat[found].clock, ubeat[found].pa, ubeat[found].sel, ubeat[found].data);
						if (ustore_bad == 1 && !trace_on_bad.empty() && !trace) {
							trace = fopen(trace_on_bad.c_str(), "w"); trace_after = retired; trace_count = 300000; trace_done = false;
							printf("trace started at retired %" PRIu64 "\n", retired);
						}
					}
				}
				// the copy's own stores are checked; a later store by other code
				// (the buffer is often on the stack) ends the buffer's checks
				if (check_copy && in_buffer(va)) {
					if (copy.active) { copy_stores++; win_check("store", va, r->emu__DOT__tr_d_wdata, sel, clocks); }
					else copy.dirty = true;
				}
			} else if (check_window && quiet && va >= 0x59200000u && va < 0x59600000u) {
				win_unc++; win_check("unc", va, r->emu__DOT__tr_d_rdata, sel, clocks);
			} else if ((check_window && quiet && va >= 0x59600000u && va < 0x59a00000u) ||
			           (check_copy && in_buffer(va) && !copy.active && !copy.dirty && clocks - copy.clock < 4000000)) {
				// a hit's data is here; a miss is acknowledged with the way's current
				// word and gets its data by the background write below
				int k = 0; while (k < 16 && win_pend[k].used) k++;
				if (k < 16) win_pend[k] = {va, r->emu__DOT__tr_d_rdata, sel, clocks, true, in_window(va) ? 'w' : 'b'};
			}
		}
		if (r->WIN_FSM(o_reg_idx)) {
			uint32_t va = r->WIN_FSM(address);
			for (int k = 0; k < 16; k++)
				if (win_pend[k].used && (win_pend[k].va & ~3u) == (va & ~3u)) {
					win_pend[k].used = false;
					if (win_pend[k].kind == 'w') win_miss++; else copy_loads++;
					win_check(win_pend[k].kind == 'w' ? "miss" : "bufmiss", va, r->WIN_FSM(reg_dat_ff), win_pend[k].sel, clocks);
					break;
				}
		}
		for (int k = 0; k < 16; k++)
			if (win_pend[k].used && clocks - win_pend[k].clock > 200) {
				win_pend[k].used = false;
				if (win_pend[k].kind == 'w') win_hit++; else copy_loads++;
				win_check(win_pend[k].kind == 'w' ? "hit" : "bufhit", win_pend[k].va, win_pend[k].data, win_pend[k].sel, win_pend[k].clock);
			}
	}
	DdramModel dm{40u << 20, 5};
	SdramChip chip{9};
	// MMC image on SD slot 0
	std::vector<uint8_t> img;
	int sd_state = 0, sd_delay = 0, sd_word = 0, sd_words = 0;
	uint32_t sd_lba = 0;
	uint64_t sd_reads = 0, sd_writes = 0;

	// the CPU
	uint64_t retired = 0;
	uint32_t last_r_pc = 0;
	char last_ev = 0;
	FILE *devlog = nullptr, *trace = nullptr, *exec_log = nullptr;
    bool was_user = false;
    uint64_t user_retired = 0, user_entries = 0, exec_calls = 0;
    uint64_t stall_clocks[8] = {}, dc_events[4] = {}, ic_events[8] = {};
    uint64_t fill_read_wait = 0;
    cpu_profile::Profile accounting{true};
    cpu_profile::Sample accounting_sample;
    load_use::Observer loaduse;
    bool profile_exec_seen=false,profile_was_user=false;
    unsigned profile_threads=0;
    void profile(const char *label) {
        printf("PROFILE %s clock=%" PRIu64 " retired=%" PRIu64 " stall=",label,clocks,retired);
        for (auto n : stall_clocks) printf("%" PRIu64 ",",n);
        printf(" dc="); for (auto n : dc_events) printf("%" PRIu64 ",",n);
        printf(" ic="); for (auto n : ic_events) printf("%" PRIu64 ",",n);
        printf(" fill_read_wait=%" PRIu64 "\n",fill_read_wait);
        fflush(stdout);
    }
	uint64_t trace_after = 0, trace_count = 0;
	bool trace_done = false;
    struct History {
        uint64_t clock, retired;
        uint32_t pc, cpsr, regs[15];
        char event;
    };
    std::vector<History> history;
    size_t history_pos = 0, history_used = 0;
    unsigned history_dumps = 0;
    void record_history(char event, uint32_t pc, uint32_t cpsr) {
        if (history.empty()) return;
        auto &entry = history[history_pos];
        entry.clock = clocks; entry.retired = retired;
        entry.pc = pc; entry.cpsr = cpsr; entry.event = event;
        for (int i = 0; i < 15; ++i) entry.regs[i] = reg(phys_index(i, cpsr));
        history_pos = (history_pos + 1) % history.size();
        history_used = std::min(history_used + 1, history.size());
        if (history_dumps >= 8 || !(event == 'D' || event == 'P' || event == 'U' ||
                                   (event == 'R' && pc == 0x5031e340))) return;
        char name[64];
        snprintf(name, sizeof name, "/fault-%u.log", ++history_dumps);
        FILE *f = fopen((out + name).c_str(), "w");
        if (!f) { perror("fault history"); exit(2); }
        for (size_t i = 0; i < history_used; ++i) {
            const auto &e = history[(history_pos + history.size() - history_used + i) % history.size()];
            fprintf(f, "%c %08x", e.event, e.pc);
            for (auto value : e.regs) fprintf(f, " %08x", value);
            fprintf(f, " %08x clock=%" PRIu64 " retired=%" PRIu64 "\n", e.cpsr, e.clock, e.retired);
        }
        fclose(f);
        snprintf(name, sizeof name, "/fault-%u.sdram.bin", history_dumps);
        f = fopen((out + name).c_str(), "wb");
        if (!f) { perror("fault SDRAM"); exit(2); }
        if (fwrite(chip.mem.data(), sizeof(uint16_t), chip.mem.size(), f) != chip.mem.size()) {
            perror("write fault SDRAM"); exit(2);
        }
        fclose(f);
        snprintf(name, sizeof name, "/fault-%u.rtl.bin", history_dumps);
        f = fopen((out + name).c_str(), "wb");
        if (!f) { perror("fault RTL state"); exit(2); }
        if (fwrite(r, sizeof(*r), 1, f) != 1) { perror("write fault RTL state"); exit(2); }
        fclose(f);
        printf("FAULT history %s clock=%" PRIu64 " pc=%08x event=%c\n", name + 1, clocks, pc, event);
        fflush(stdout);
    }
	uint64_t dev_accesses = 0;
	// --check-flash, --buslog, --until
	bool check_flash = false;
	uint64_t flash_checked[2] = {}, flash_bad = 0;
	uint64_t beat_start = 0, array_since[2] = {};
	bool beat_prev = false, ack_prev = false, array_prev[2] = {};
	FILE *buslog = nullptr;
	std::string until, sti_tail;
	bool stop = false;
	// STI debug text
	FILE *kern = nullptr;
	// video
	std::string out;
	std::vector<uint32_t> fr, row;
	int fr_rows = 0, fr_w = 0;
	bool fr_bad = false, de_prev = false, vs_prev = false;
	std::vector<uint8_t> last_png;
	int pictures = 0;
	uint64_t frames = 0;
	// audio
	std::vector<int16_t> audio;
	double audio_phase = 0;
	bool audio_on = false;
	// keys
	std::vector<KeyEvent> keys;
	size_t key_next = 0;
	uint32_t joy = 0;

	Bench() : r(t->rootp) {
		dm.prof.busy_pct = 5;
		t->CLK_50M = 0; t->RESET = 1; t->DDRAM_BUSY = 0; t->DDRAM_DOUT = 0; t->DDRAM_DOUT_READY = 0;
		t->HDMI_WIDTH = 0; t->HDMI_HEIGHT = 0; t->OSD_STATUS = 0; t->SD_MISO = 1; t->SD_CD = 1;
		t->UART_CTS = 0; t->UART_RXD = 1; t->UART_DSR = 0; t->USER_IN = 0x7F; t->CLK_AUDIO = 0;
		t->eval();
		for (int i = 0; i < 8; i++) tick();
		t->RESET = 0;
	}
	~Bench() { t->final(); delete t; }

	void sd_step() {
		auto &h = *r;
		h.emu__DOT__hps_io__DOT__sim_sd_wr_buf = 0;
		h.emu__DOT__hps_io__DOT__sim_mounted = 0;
		if (h.emu__DOT__hps_io__DOT__sim_sd_wr) sd_writes++;
		switch (sd_state) {
		case 0:
			if (h.emu__DOT__hps_io__DOT__sim_sd_rd) {
				sd_lba = h.emu__DOT__hps_io__DOT__sim_sd_lba;
				sd_words = 256 * (h.emu__DOT__hps_io__DOT__sim_sd_blk_cnt + 1);
				sd_delay = 100;
				sd_state = 1;
			}
			break;
		case 1:
			if (--sd_delay == 0) { h.emu__DOT__hps_io__DOT__sim_sd_ack = 1; sd_word = 0; sd_delay = 2; sd_state = 2; }
			break;
		case 2:
			if (--sd_delay > 0) break;
			sd_delay = 2;
			if (sd_word < sd_words) {
				size_t off = (size_t)sd_lba * 512 + sd_word * 2;
				h.emu__DOT__hps_io__DOT__sim_sd_addr = sd_word;
				h.emu__DOT__hps_io__DOT__sim_sd_dout = off + 1 < img.size() ? (uint16_t)(img[off] | img[off + 1] << 8) : 0;
				h.emu__DOT__hps_io__DOT__sim_sd_wr_buf = 1;
				sd_word++;
			} else {
				h.emu__DOT__hps_io__DOT__sim_sd_ack = 0;
				sd_reads++;
				sd_state = 0;
			}
			break;
		}
	}

	void sti_byte(uint8_t c) {
		if (c == 0xC0 || c == 0xE0 || c == '\r') return;
		if (c == '\n' || c == '\t' || (c >= 0x20 && c < 0x7F)) fputc(c, kern);
		else fprintf(kern, "<%02x>", c);
		if (c == '\n') fflush(kern);
		if (!until.empty()) {
			sti_tail += (char)c;
			if (sti_tail.size() > until.size()) sti_tail.erase(0, sti_tail.size() - until.size());
			if (sti_tail == until) stop = true;
		}
	}

	// what commits at the coming edge (the CPU's writeback stage)
	void cpu_before_edge() {
		auto &h = *r;
#ifdef CPU_PROFILE
        if(accounting.enabled) accounting_sample={h.PROFILE_TAP(flags),h.PROFILE_TAP(decode_pc),
            h.PROFILE_TAP(decode_ins),h.PROFILE_TAP(retire_ins),h.PROFILE_TAP(recovery_target),
            h.PROFILE_TAP(raw_stall),h.PROFILE_TAP(raw_icache),h.PROFILE_TAP(raw_dcache)};
#endif
        if (!h.emu__DOT__cpu_reset) {
            for (int n=0;n<8;n++) {
                stall_clocks[n]+=(h.emu__DOT__cpu_dbg_stall>>n)&1;
                ic_events[n]+=(h.emu__DOT__cpu_dbg_icache>>n)&1;
            }
            for (int n=0;n<4;n++) dc_events[n]+=(h.emu__DOT__cpu_dbg_dcache>>n)&1;
            // Upper bound: held reads during a fill include hits and uncached
            // accesses. This is not a counter of proven second misses.
            fill_read_wait+=h.V2_TAP(request)&&!h.V2_TAP(request_done)&&
                !h.V2_TAP(o_data_wb_we)&&h.V2_TAP(i_data_fill_busy);
        }
		uint32_t cpsr = h.emu__DOT__tr_wb_cpsr;
		bool thumb = cpsr >> 5 & 1;
		uint32_t pc = h.emu__DOT__tr_wb_pc -
		              (thumb ? 4 : 8);
		char ev = 0;
		auto dabt = h.emu__DOT__tr_wb_dabt;
		if (dabt & 2) ev = 0;
		else if (dabt & 1) ev = 'D';
		else if (h.emu__DOT__tr_wb_fiq) ev = 'F';
		else if (h.emu__DOT__tr_wb_irq) ev = 'I';
		else if (h.emu__DOT__tr_wb_pabt) ev = 'P';
		else if (h.emu__DOT__tr_wb_swi) ev = 'S';
		else if (h.emu__DOT__tr_wb_und) ev = 'U';
		else if ((h.emu__DOT__tr_wb_valid ||
		          h.emu__DOT__tr_wb_dvalid) &&
		         h.emu__DOT__tr_wb_uop_last)
			ev = 'R';
		if (!ev || h.emu__DOT__cpu_reset) { pending_ev = 0; return; }
		if(accounting.enabled) {
            bool user=(cpsr&31)==16;
            if(ev=='S'&&!profile_exec_seen){accounting.mark("first_exec",clocks);loaduse.mark("first_exec",clocks);profile_exec_seen=true;}
            if(user&&!profile_was_user&&pc==0x503247bc&&!reg(phys_index(14,cpsr))){
                char label[32];snprintf(label,sizeof label,"thread_%u",++profile_threads);accounting.mark(label,clocks);loaduse.mark(label,clocks);
            }
            profile_was_user=user;
        }
        if (exec_log) {
            bool user = (cpsr & 31) == 16;
            if (ev == 'R' && user) user_retired++;
            if ((user && !was_user) || ev == 'S' || ev == 'D' || ev == 'P' || ev == 'U') {
                if (user && !was_user) user_entries++;
                if (ev == 'S') { if (!exec_calls) profile("first_exec"); exec_calls++; }
                if (user && !was_user && pc==0x503247bc && !reg(phys_index(14,cpsr))) profile("thread_entry");
                fprintf(exec_log, "%c %" PRIu64 " %" PRIu64 " pc=%08x cpsr=%08x r0=%08x r1=%08x r2=%08x r3=%08x r12=%08x sp=%08x lr=%08x\n",
                    ev == 'R' ? 'T' : ev, clocks, retired, pc, cpsr,
                    reg(phys_index(0,cpsr)),reg(phys_index(1,cpsr)),reg(phys_index(2,cpsr)),reg(phys_index(3,cpsr)),
                    reg(phys_index(12,cpsr)),reg(phys_index(13,cpsr)),reg(phys_index(14,cpsr)));
            }
            was_user = user;
        }
        pending_ev = ev;
		pending_pc = pc;
		pending_thumb = thumb;
	}
	char pending_ev = 0;
	uint32_t pending_pc = 0;
	bool pending_thumb = false;

	uint32_t reg(int phys) {
		return r->CORE_REGS[phys];
	}

	// after the edge: the registers after the committed instruction
	void cpu_after_edge() {
		if (loaduse.enabled) loaduse.clock(accounting_sample.dcache);
		if (!pending_ev) {accounting.observe(accounting_sample,false,false,0,0);return;}
		char ev = pending_ev;
		uint32_t pc = pending_pc;
		uint32_t cpsr = r->emu__DOT__tr_wb_cpsr;
		// a Thumb BL pair counts once (QEMU's icount), as in tb/main.cpp
		bool bl_second = false;
		if (ev == 'R' && pending_thumb && last_ev == 'R' && pc == last_r_pc + 2 && (pc & 0x3FF))
			bl_second = reg(phys_index(14, cpsr)) == ((pc + 2) | 1);
		bool counted=(ev == 'R' && !bl_second) || ev == 'S' || ev == 'U';
        if(counted) retired++;
        record_history(ev, pc, cpsr);
        accounting.observe(accounting_sample,counted,bl_second,ev,pc);
        if (loaduse.enabled) {
            if (ev == 'R') loaduse.retire(accounting_sample.retire_ins, (accounting_sample.flags >> 24) & 1,
                                          (accounting_sample.flags >> 25) & 1);
            else loaduse.barrier();
        }
		if (devlog && ev != 'R') {
			// interrupts and exceptions as the plugin records them: "X n exc
			// from vector" (low vectors; n before an SWI or UND counts it)
			uint32_t vec = ev == 'U' ? 0x04 : ev == 'S' ? 0x08 : ev == 'P' ? 0x0C : ev == 'D' ? 0x10 : ev == 'I' ? 0x18 : 0x1C;
			fprintf(devlog, "X %" PRIu64 " exc %08x %08x\n", (ev == 'S' || ev == 'U') ? retired - 1 : retired, pc, vec);
		}
		if (trace && !trace_done && retired >= trace_after) {
			fprintf(trace, "%c %08x", ev, pc);
			for (int i = 0; i < 15; i++) fprintf(trace, " %08x", reg(phys_index(i, cpsr)));
			fprintf(trace, " %08x\n", cpsr);
			if (trace_count && retired >= trace_after + trace_count) { trace_done = true; fclose(trace); trace = nullptr; }
		}
		if (check_copy && ev == 'R') { if (pc == 0x503A1D38u) copy_entry(cpsr); else if (copy.active && pc == copy.lr) copy.active = false; }
		last_ev = ev;
		if (ev == 'R') last_r_pc = pc;
	}

	// a completed beat on the CPU's Wishbone port (after the edge: ack is
	// registered, so it is high with the beat's data in this clock)
	void bus_watch() {
		auto &h = *r;
		if (!h.emu__DOT__wb_cyc || !h.emu__DOT__wb_ack) return;
		uint32_t a = h.emu__DOT__wb_adr;
		if (check_store && h.emu__DOT__wb_we && a >= 0x02400000u && a < 0x02800000u) {
			ubeat[ubeat_n % 32] = {a, (uint32_t)h.emu__DOT__wb_dat_w, (uint32_t)h.emu__DOT__wb_sel, clocks}; ubeat_n++;
		}
		if (!device(a)) return;
		bool we = h.emu__DOT__wb_we;
		unsigned be = h.emu__DOT__wb_sel;
		int off = be ? __builtin_ctz(be) : 0;
		unsigned size = (unsigned)__builtin_popcount(be);
		if (size == 0) size = 4;
		uint32_t mask = size == 4 ? 0xFFFFFFFFu : (1u << (8 * size)) - 1;
		uint32_t v = ((we ? h.emu__DOT__wb_dat_w : h.emu__DOT__wb_dat_r) >> (8 * off)) & mask;
		uint32_t pa = a + off;
		dev_accesses++;
		if (we && pa - 0x0DE00000u < 0x200000u)
			for (unsigned i = 0; i < size; i++) sti_byte((uint8_t)(v >> (8 * i)));
		if (devlog) {
			uint32_t cpsr = h.emu__DOT__tr_wb_cpsr;
			uint32_t pc = h.CORE_DATA_PC - ((cpsr >> 5 & 1) ? 4 : 8);
			fprintf(devlog, "M %" PRIu64 " %c %u %08x %08x %08x\n", retired, we ? 'W' : 'R', size, pa, v, pc);
		}
	}

	// --check-flash / --buslog: a completed beat on the CPU's port to the
	// flash chips (and SDRAM for the log), against the DDRAM model's image
	void flash_watch() {
		auto &h = *r;
		// when the current beat began, and since when each chip has been in
		// read-array mode (M_READ, no command sequence, program or erase): a
		// read is checked only if that held before the beat began (a status
		// read can end in the clock the operation ends)
		bool beat = h.emu__DOT__wb_cyc && h.emu__DOT__wb_stb, ack = h.emu__DOT__wb_ack;
		if (beat && (!beat_prev || ack_prev)) beat_start = clocks;
		beat_prev = beat;
		ack_prev = ack;
#define FL_ARRAY(f) (h.emu__DOT__ngage_mem__DOT__##f##__DOT__mode == 0 && h.emu__DOT__ngage_mem__DOT__##f##__DOT__cseq == 0 && \
                     h.emu__DOT__ngage_mem__DOT__##f##__DOT__p_state == 0 && h.emu__DOT__ngage_mem__DOT__##f##__DOT__e_state == 0)
		for (int c = 0; c < 2; c++) {
			bool arr = c ? FL_ARRAY(flash_cs1) : FL_ARRAY(flash_cs0);
			if (arr && !array_prev[c]) array_since[c] = clocks;
			array_prev[c] = arr;
		}
		if (!h.emu__DOT__wb_cyc || !h.emu__DOT__wb_ack) return;
		uint32_t a = h.emu__DOT__wb_adr;
		bool we = h.emu__DOT__wb_we;
		unsigned be = h.emu__DOT__wb_sel;
		uint32_t d = we ? h.emu__DOT__wb_dat_w : h.emu__DOT__wb_dat_r;
		bool fl = a < 0x04000000u, sd = a >= 0x0A000000u && a < 0x0C000000u;
		if (buslog && (fl || sd))
			fprintf(buslog, "%" PRIu64 " %c %08x %x %08x %u\n", clocks, we ? 'W' : 'R', a, be, d,
			        (unsigned)h.emu__DOT__wb_cti);
		if (!check_flash || we || !fl) return;
		int chip_n = a >= 0x02000000u;
		if (!array_prev[chip_n] || array_since[chip_n] >= beat_start) return;
		uint32_t off = chip_n ? ((a - 0x02000000u) & 0x7FFFFFu) : (a & 0xFFFFFFu);
		uint32_t base = DDR_BASE + (chip_n ? 0x01000000u : 0) + (off & ~3u) - DdramModel::BASE;
		uint32_t want = 0, mask = 0;
		for (int i = 0; i < 4; i++)
			if (be >> i & 1) { want |= (uint32_t)dm.mem[base + i] << (8 * i); mask |= 0xFFu << (8 * i); }
		flash_checked[chip_n]++;
		if ((d & mask) != want) {
			if (flash_bad < 20)
				printf("FLASH MISMATCH clock %" PRIu64 " CS%d %08x sel %x cti %u: read %08x, image %08x\n",
				       clocks, chip_n, a, be, (unsigned)h.emu__DOT__wb_cti, d & mask, want);
			flash_bad++;
		}
	}

	// the picture at the video outputs, a PNG each time it changes
	void video_watch() {
		bool vs = t->VGA_VS;
		if (vs && !vs_prev) {
			frames++;
			if (!fr_bad && fr_rows > 0 && fr_w > 0) {
				sim::Image im(fr_w, fr_rows);
				for (int y = 0; y < fr_rows; y++)
					for (int x = 0; x < fr_w; x++) {
						uint32_t p = fr[(size_t)y * fr_w + x];
						im.set(x, y, (uint8_t)(p >> 16), (uint8_t)(p >> 8), (uint8_t)p);
					}
				if (im.rgb != last_png) {
					char name[64];
					snprintf(name, sizeof name, "/lcd-%08" PRIu64 ".png", (uint64_t)(clocks / (CLK_HZ / 1000)));
					write_png(out + name, im);
					write_png(out + "/lcd-last.png", im);
					last_png = im.rgb;
					pictures++;
					printf("picture %d at %.3f s (%s)\n", pictures, clocks / CLK_HZ, name + 1);
					fflush(stdout);
				}
			}
			fr.clear();
			row.clear();
			fr_rows = 0;
			fr_w = 0;
			fr_bad = false;
		}
		vs_prev = vs;
		if (!t->CE_PIXEL) return;
		if (t->VGA_DE) row.push_back((uint32_t)t->VGA_R << 16 | (uint32_t)t->VGA_G << 8 | t->VGA_B);
		else if (de_prev) {
			if (fr_rows == 0) fr_w = (int)row.size();
			else if ((int)row.size() != fr_w) fr_bad = true;
			fr.insert(fr.end(), row.begin(), row.end());
			fr_rows++;
			row.clear();
		}
		de_prev = t->VGA_DE;
	}

	void audio_watch() {
		audio_phase += 48000.0 / CLK_HZ;
		if (audio_phase < 1.0) return;
		audio_phase -= 1.0;
		int16_t lft = (int16_t)t->AUDIO_L, rgt = (int16_t)t->AUDIO_R;
		if (lft || rgt) audio_on = true;
		if (audio_on) { audio.push_back(lft); audio.push_back(rgt); }
	}

	void key_watch() {
		while (key_next < keys.size() && keys[key_next].clock <= clocks) {
			const KeyEvent &e = keys[key_next++];
			if (e.k->joy >= 0) {
				if (e.down) joy |= 1u << e.k->joy;
				else joy &= ~(1u << e.k->joy);
				r->emu__DOT__hps_io__DOT__sim_joy0 = joy;
			} else {
				uint16_t k = r->emu__DOT__hps_io__DOT__sim_ps2_key;
				r->emu__DOT__hps_io__DOT__sim_ps2_key = (uint16_t)((~k & 0x400) | (e.down ? 0x200 : 0) | e.k->ps2);
				printf("key %s %s at %.3f s\n", e.k->name, e.down ? "down" : "up", clocks / CLK_HZ);
				return;      // one PS/2 event a clock
			}
			printf("key %s %s at %.3f s\n", e.k->name, e.down ? "down" : "up", clocks / CLK_HZ);
		}
	}

	void tick() {
		t->DDRAM_BUSY = dm.busy;
		t->DDRAM_DOUT = dm.dout;
		t->DDRAM_DOUT_READY = dm.dout_ready;
		t->SDRAM_DQ = chip.sample(clocks + 1);
		t->eval();
		if (clocks > 16)
			dm.step(t->DDRAM_RD, t->DDRAM_WE, t->DDRAM_ADDR, t->DDRAM_BURSTCNT, t->DDRAM_DIN, t->DDRAM_BE);
		cpu_before_edge();
		t->CLK_50M = 1; t->eval();
		clocks++;
		SdramPins p;
		p.cs_n = t->SDRAM_nCS; p.ras_n = t->SDRAM_nRAS; p.cas_n = t->SDRAM_nCAS; p.we_n = t->SDRAM_nWE;
		p.ba = t->SDRAM_BA; p.a = t->SDRAM_A; p.dqm = t->SDRAM_DQML | t->SDRAM_DQMH << 1;
		p.dq_oe = t->SDRAM_DQ__en != 0; p.dq_o = t->SDRAM_DQ__out;
		if (clocks > 2) chip.edge(clocks, p);
		cpu_after_edge();
		bus_watch();
		if (check_flash || buslog) flash_watch();
		if (check_window || check_copy || check_store) win_watch();
		video_watch();
		audio_watch();
		key_watch();
		sd_step();
		t->CLK_50M = 0; t->eval();
	}
	void ticks(uint64_t n) { while (n--) tick(); }

	// ---- snapshots: the model through Verilator, the rest of the bench raw
	void save_bench(FILE *f) const {
		snap::mark(f, 0xB3ACB301u);
		snap::put(f, clocks);
		dm.save(f);
		chip.save(f);
		snap::put(f, sd_state); snap::put(f, sd_delay); snap::put(f, sd_word); snap::put(f, sd_lba);
		snap::put(f, sd_reads); snap::put(f, sd_writes);
		snap::put(f, retired); snap::put(f, last_r_pc); snap::put(f, last_ev); snap::put(f, dev_accesses);
		snap::put(f, fr); snap::put(f, row); snap::put(f, fr_rows); snap::put(f, fr_w); snap::put(f, fr_bad);
		snap::put(f, de_prev); snap::put(f, vs_prev); snap::put(f, last_png); snap::put(f, pictures); snap::put(f, frames);
		snap::put(f, audio_phase); snap::put(f, joy);
		snap::put(f, pending_ev); snap::put(f, pending_pc); snap::put(f, pending_thumb);
		snap::mark(f, 0xB3ACB302u);
	}
	void load_bench(FILE *f) {
		snap::check(f, 0xB3ACB301u);
		snap::get(f, clocks);
		dm.load(f);
		chip.load(f);
		snap::get(f, sd_state); snap::get(f, sd_delay); snap::get(f, sd_word); snap::get(f, sd_lba);
		snap::get(f, sd_reads); snap::get(f, sd_writes);
		snap::get(f, retired); snap::get(f, last_r_pc); snap::get(f, last_ev); snap::get(f, dev_accesses);
		snap::get(f, fr); snap::get(f, row); snap::get(f, fr_rows); snap::get(f, fr_w); snap::get(f, fr_bad);
		snap::get(f, de_prev); snap::get(f, vs_prev); snap::get(f, last_png); snap::get(f, pictures); snap::get(f, frames);
		snap::get(f, audio_phase); snap::get(f, joy);
		snap::get(f, pending_ev); snap::get(f, pending_pc); snap::get(f, pending_thumb);
		snap::check(f, 0xB3ACB302u);
		audio.clear();
		audio_on = false;
	}
	void save(const std::string &path) {
		{
			VerilatedSave os;
			os.open(path);
			os << Verilated::threadContextp();
			os << *t;
			os.close();
		}
		FILE *f = fopen((path + ".bench").c_str(), "wb");
		if (!f) snap::fail("cannot write the bench file");
		save_bench(f);
		fclose(f);
		printf("snapshot written at clock %" PRIu64 " (%.3f s), %" PRIu64 " instructions retired: %s, %s.bench\n", clocks, clocks / CLK_HZ, retired, path.c_str(), path.c_str());
		fflush(stdout);
	}
	void restore(const std::string &path) {
		{
			VerilatedRestore is;
			is.open(path);
			is >> Verilated::threadContextp();
			is >> *t;
			is.close();
		}
		FILE *f = fopen((path + ".bench").c_str(), "rb");
		if (!f) snap::fail("cannot read the bench file");
		load_bench(f);
		fclose(f);
		printf("snapshot restored at clock %" PRIu64 " (%.3f s): %s\n", clocks, clocks / CLK_HZ, path.c_str());
		fflush(stdout);
	}

	// a one-word ioctl download: the image is already in the DDRAM model
	void mark_loaded(int index, const std::vector<uint8_t> &data) {
		auto &h = *r;
		h.emu__DOT__hps_io__DOT__sim_index = index;
		h.emu__DOT__hps_io__DOT__sim_download = 1;
		ticks(5);
		while (h.emu__DOT__hps_io__DOT__sim_wait) tick();
		h.emu__DOT__hps_io__DOT__sim_addr = 0;
		h.emu__DOT__hps_io__DOT__sim_dout = (uint16_t)(data[0] | data[1] << 8);
		h.emu__DOT__hps_io__DOT__sim_wr = 1;
		tick();
		h.emu__DOT__hps_io__DOT__sim_wr = 0;
		ticks(4);
		while (h.emu__DOT__hps_io__DOT__sim_wait) tick();
		ticks(5);
		h.emu__DOT__hps_io__DOT__sim_download = 0;
		ticks(5);
	}
};

int bcd(int v) { return (v / 10) << 4 | (v % 10); }

}  // namespace

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	crc_init();
	std::string cs0p, cs1p, mmcp, out = ".", keysp, tracep, rtc = "2004-06-01 12:00:00";
	uint64_t max_cycles = 1000000000ull, progress = 50000000ull, trace_after = 0, trace_count = 0;
	bool devlog = false, profile_enabled = true, check_flash = false, check_window = false, check_copy = false, check_store = false;
	std::string trace_on_bad;
	std::string buslogp, until, loadusep;
	DdramProfile ddr;
	bool ddr_set = false;
    size_t fault_history = 0;
    std::vector<uint64_t> profile_marks;size_t profile_mark_index=0;
	std::string savep, restorep;
	uint64_t save_at = 0;
	bool save_exit = false;
	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		auto next = [&]() -> const char * {
			if (i + 1 >= argc) { fprintf(stderr, "%s needs a value\n", a.c_str()); exit(2); }
			return argv[++i];
		};
		if (a == "--cs0") cs0p = next();
		else if (a == "--cs1") cs1p = next();
		else if (a == "--mmc") mmcp = next();
		else if (a == "--out") out = next();
		else if (a == "--cycles") max_cycles = strtoull(next(), nullptr, 0);
		else if (a == "--rtc") rtc = next();
		else if (a == "--keys") keysp = next();
		else if (a == "--devlog") devlog = true;
        else if(a=="--no-profile") profile_enabled=false;
        else if(a=="--profile-at") profile_marks.push_back(strtoull(next(),nullptr,0));
		else if (a == "--trace") tracep = next();
		else if (a == "--trace-after") trace_after = strtoull(next(), nullptr, 0);
		else if (a == "--trace-count") trace_count = strtoull(next(), nullptr, 0);
		else if (a == "--progress") progress = strtoull(next(), nullptr, 0);
        else if (a == "--fault-history") fault_history = strtoull(next(), nullptr, 0);
		else if (a == "--check-flash") check_flash = true;
		else if (a == "--check-window") check_window = true;
		else if (a == "--check-copy") check_copy = true;
		else if (a == "--check-store") check_store = true;
		else if (a == "--trace-on-bad") trace_on_bad = next();
		else if (a == "--load-use") loadusep = next();
		else if (a == "--buslog") buslogp = next();
		else if (a == "--until") until = next();
		else if (a == "--ddr-lat") { ddr_set = true; if (sscanf(next(), "%d:%d", &ddr.lat_min, &ddr.lat_max) != 2) return 2; }
		else if (a == "--ddr-busy") { ddr_set = true; ddr.busy_pct = atoi(next()); }
		else if (a == "--ddr-gap") { ddr_set = true; ddr.gap_pct = atoi(next()); }
		else if (a == "--ddr-stall") { ddr_set = true; ddr.stall_pct_x1000 = atoi(next()); }
		else if (a == "--save") savep = next();
		else if (a == "--save-at") save_at = strtoull(next(), nullptr, 0);
		else if (a == "--save-exit") save_exit = true;
		else if (a == "--restore") restorep = next();
		else if (a[0] == '+') continue;
		else { fprintf(stderr, "unknown option %s\n", a.c_str()); return 2; }
	}
	if (restorep.empty() && (cs0p.empty() || cs1p.empty())) { fprintf(stderr, "--cs0 and --cs1 are needed\n"); return 2; }
	if (!savep.empty() && !save_at) { fprintf(stderr, "--save needs --save-at\n"); return 2; }

	std::sort(profile_marks.begin(),profile_marks.end());
	Bench b;
	auto &R = *b.r;
	b.out = out;
    b.history.resize(fault_history);
#ifdef CPU_PROFILE
    if(profile_enabled){b.accounting.open(out+"/profile.csv");b.accounting.total.clocks=b.clocks;b.accounting.total.why[cpu_profile::Reset]=b.clocks;}
#else
    (void)profile_enabled;
#endif
	b.kern = fopen((out + "/kern.log").c_str(), "w");
	b.check_flash = check_flash;
	b.check_window = check_window;
	b.check_copy = check_copy;
	b.check_store = check_store;
	b.trace_on_bad = trace_on_bad;
	if (!loadusep.empty()) b.loaduse.open(loadusep);
	if (ddr_set) b.dm.prof = ddr;
	b.until = until;
	if (!buslogp.empty() && !(b.buslog = fopen(buslogp.c_str(), "w"))) { fprintf(stderr, "cannot write %s\n", buslogp.c_str()); return 2; }
	if (devlog) {
        b.devlog = fopen((out + "/dev.log").c_str(), "w");
        b.exec_log = fopen((out + "/exec.log").c_str(), "w");
    }
	if (!tracep.empty()) { b.trace = fopen(tracep.c_str(), "w"); b.trace_after = trace_after; b.trace_count = trace_count; }
	if (!keysp.empty()) {
		FILE *f = fopen(keysp.c_str(), "r");
		if (!f) { fprintf(stderr, "cannot read %s\n", keysp.c_str()); return 2; }
		char line[256];
		while (fgets(line, sizeof line, f)) {
			double s; char dir[16], name[32];
			if (line[0] == '#' || sscanf(line, "%lf %15s %31s", &s, dir, name) != 3) continue;
			const KeyName *k = nullptr;
			for (auto &kn : key_names) if (!strcmp(kn.name, name)) k = &kn;
			if (!k) { fprintf(stderr, "unknown key %s\n", name); return 2; }
			b.keys.push_back({(uint64_t)(s * CLK_HZ), !strcmp(dir, "down"), k});
		}
		fclose(f);
		std::stable_sort(b.keys.begin(), b.keys.end(), [](const KeyEvent &x, const KeyEvent &y) { return x.clock < y.clock; });
	}

	uint64_t start = 0;
	if (!restorep.empty()) {
		b.restore(restorep);
		if (!mmcp.empty()) b.img = read_file(mmcp);
		while (b.key_next < b.keys.size() && b.keys[b.key_next].clock <= b.clocks) b.key_next++;
		start = b.clocks;
	} else {
	// MiSTer's RTC (hps_io sends it when the core starts)
	{
		int Y, M, D, h, m, s;
		if (sscanf(rtc.c_str(), "%d-%d-%d %d:%d:%d", &Y, &M, &D, &h, &m, &s) != 6) { fprintf(stderr, "bad --rtc\n"); return 2; }
		uint64_t v = (uint64_t)bcd(s) | (uint64_t)bcd(m) << 8 | (uint64_t)bcd(h) << 16 | (uint64_t)bcd(D) << 24 |
		             (uint64_t)bcd(M) << 32 | (uint64_t)bcd(Y % 100) << 40;
		R.emu__DOT__hps_io__DOT__sim_rtc[0] = (uint32_t)v;
		R.emu__DOT__hps_io__DOT__sim_rtc[1] = (uint32_t)(v >> 32);
		b.ticks(4);
		R.emu__DOT__hps_io__DOT__sim_rtc[2] = 1;      // bit 64: the time is sent
	}

	// the MMC card
	if (!mmcp.empty()) {
		b.img = read_file(mmcp);
		R.emu__DOT__hps_io__DOT__sim_size = b.img.size();
		R.emu__DOT__hps_io__DOT__sim_readonly = 1;
		R.emu__DOT__hps_io__DOT__sim_mounted = 1;
		b.ticks(20000);
		printf("MMC image %s mounted (%zu bytes, %" PRIu64 " SD reads)\n", mmcp.c_str(), b.img.size(), b.sd_reads);
	}

	// the flash images
	std::vector<uint8_t> cs0 = read_file(cs0p), cs1 = read_file(cs1p);
	if (cs0.size() != (16u << 20) || cs1.size() != (8u << 20)) { fprintf(stderr, "images must be 16 MB and 8 MB\n"); return 2; }
	memcpy(&b.dm.mem[b.DDR_BASE - DdramModel::BASE], cs0.data(), cs0.size());
	memcpy(&b.dm.mem[b.DDR_BASE + 0x01000000u - DdramModel::BASE], cs1.data(), cs1.size());
	b.mark_loaded(3, cs0);
	b.mark_loaded(4, cs1);
	start = b.clocks;
	printf("flash images in DDR3; the CPU starts at clock %" PRIu64 "\n", start);
	fflush(stdout);
	}

	auto t0 = std::chrono::steady_clock::now();
	uint64_t last_c = b.clocks;
	auto last_t = t0;
	while (b.clocks < max_cycles && !b.stop) {
		b.tick();
        if(b.accounting.enabled && b.clocks%104000000==0)b.accounting.second(b.clocks);
        if(profile_mark_index<profile_marks.size()&&b.clocks==profile_marks[profile_mark_index]){
            char label[48];snprintf(label,sizeof label,"clock_%" PRIu64,b.clocks);b.accounting.mark(label,b.clocks);profile_mark_index++;
        }
		if (save_at && b.clocks == save_at) {
			b.save(savep);
			if (save_exit) break;
		}
		if (progress && b.clocks % progress == 0) {
			auto now = std::chrono::steady_clock::now();
			double wall = std::chrono::duration<double>(now - t0).count();
			double dt = std::chrono::duration<double>(now - last_t).count();
			printf("clock %" PRIu64 " (%.3f s) retired %" PRIu64 " pc %08x dev %" PRIu64 " pictures %d | wall %.0f s, %.0f k clocks/s\n",
			       b.clocks, b.clocks / CLK_HZ, b.retired, b.last_r_pc, b.dev_accesses, b.pictures, wall,
			       (b.clocks - last_c) / dt / 1000);
			fflush(stdout);
			last_c = b.clocks;
			last_t = now;
			if (b.devlog) fflush(b.devlog);
			if (b.exec_log) fflush(b.exec_log);
			fflush(b.kern);
			if (b.audio_on) write_wav(out + "/audio.wav", b.audio);
		}
	}
	if (b.audio_on) write_wav(out + "/audio.wav", b.audio);
	double wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
	printf("END after %" PRIu64 " clocks (%.3f s simulated), %" PRIu64 " instructions, %" PRIu64 " device accesses, "
	       "%d pictures, %zu audio frames, %.0f s wall clock\n",
	       b.clocks, b.clocks / CLK_HZ, b.retired, b.dev_accesses, b.pictures, b.audio.size() / 2, wall);
    b.profile("end");
    b.accounting.finish(b.clocks);
    b.loaduse.finish(b.clocks);
	if (b.chip.errors) printf("the SDRAM chip model reported %d error(s)\n", b.chip.errors);
	if (b.dm.protocol_errors) printf("%d DDRAM port protocol error(s)\n", b.dm.protocol_errors);
	if (b.check_flash)
		printf("flash check: %" PRIu64 " CS0 and %" PRIu64 " CS1 read beats in array mode, %" PRIu64 " mismatch(es)\n",
		       b.flash_checked[0], b.flash_checked[1], b.flash_bad);
	if (b.check_window)
		printf("window check: %" PRIu64 " uncached, %" PRIu64 " cached-hit, %" PRIu64 " cached-miss loads of the C: drive, %" PRIu64 " wrong\n",
		       b.win_unc, b.win_hit, b.win_miss, b.win_bad);
	if (b.check_store)
		printf("store check: %" PRIu64 " stores through the uncached C: alias, %" PRIu64 " not matching their bus beat\n", b.ustores, b.ustore_bad);
	if (b.check_copy)
		printf("copy check: %" PRIu64 " Mem::Copy calls out of the C: drive, %" PRIu64 " stores and %" PRIu64 " loads of their buffers checked\n",
		       b.copies, b.copy_stores, b.copy_loads);
	if (b.buslog) fclose(b.buslog);
	if (b.exec_log) {
        printf("User execution: %" PRIu64 " instructions, %" PRIu64 " entries, %" PRIu64 " exec calls\n",
            b.user_retired,b.user_entries,b.exec_calls);
        fclose(b.exec_log);
    }
    if (b.devlog) fclose(b.devlog);
	if (b.trace) fclose(b.trace);
	fclose(b.kern);
	return 0;
}
