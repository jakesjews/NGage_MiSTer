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
//                      icount counts them), for sim/cpu/boot/cmp_dev.py
//   --trace FILE --trace-after N --trace-count M
//                      an instruction window (sim/cpu/boot/cmp_window.py)
//   --progress N       a line every N clocks (with wall-clock time)
// Always written: DIR/kern.log (the kernel's debug text through the STI
// window), DIR/lcd-<ms>.png each time the picture at the video outputs
// changes (and lcd-last.png), DIR/audio.wav (AUDIO_L/R at 48 kHz, once the
// HLE audio device has played something), DIR/run.log lines on stdout.
#include "Vemu.h"
#include "Vemu___024root.h"
#include "verilated.h"
#include "common.h"
#include "ddram_model.h"
#include "sdram_model.h"

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
	DdramModel dm{40u << 20, 5};
	SdramChip chip{9};
	// MMC image on SD slot 0
	std::vector<uint8_t> img;
	int sd_state = 0, sd_delay = 0, sd_word = 0;
	uint32_t sd_lba = 0;
	uint64_t sd_reads = 0, sd_writes = 0;

	// the CPU
	uint64_t retired = 0;
	uint32_t last_r_pc = 0;
	char last_ev = 0;
	FILE *devlog = nullptr, *trace = nullptr;
	uint64_t trace_after = 0, trace_count = 0;
	bool trace_done = false;
	uint64_t dev_accesses = 0;
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
			if (sd_word < 256) {
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
	}

	// what commits at the coming edge (the CPU's writeback stage)
	void cpu_before_edge() {
		auto &h = *r;
		uint32_t cpsr = h.emu__DOT__arm925t__DOT__u_zap__DOT__u_zap_core__DOT__u_zap_writeback__DOT__cpsr_ff;
		bool thumb = cpsr >> 5 & 1;
		uint32_t pc = h.emu__DOT__arm925t__DOT__u_zap__DOT__u_zap_core__DOT__u_zap_writeback__DOT__i_pc_plus_8_buf_ff -
		              (thumb ? 4 : 8);
		char ev = 0;
		auto dabt = h.emu__DOT__arm925t__DOT__u_zap__DOT__u_zap_core__DOT__u_zap_writeback__DOT__i_data_abt;
		if (dabt & 2) ev = 0;
		else if (dabt & 1) ev = 'D';
		else if (h.emu__DOT__arm925t__DOT__u_zap__DOT__u_zap_core__DOT__u_zap_writeback__DOT__i_fiq) ev = 'F';
		else if (h.emu__DOT__arm925t__DOT__u_zap__DOT__u_zap_core__DOT__u_zap_writeback__DOT__i_irq) ev = 'I';
		else if (h.emu__DOT__arm925t__DOT__u_zap__DOT__u_zap_core__DOT__u_zap_writeback__DOT__i_instr_abt) ev = 'P';
		else if (h.emu__DOT__arm925t__DOT__u_zap__DOT__u_zap_core__DOT__u_zap_writeback__DOT__i_swi) ev = 'S';
		else if (h.emu__DOT__arm925t__DOT__u_zap__DOT__u_zap_core__DOT__u_zap_writeback__DOT__i_und) ev = 'U';
		else if ((h.emu__DOT__arm925t__DOT__u_zap__DOT__u_zap_core__DOT__u_zap_writeback__DOT__i_valid ||
		          h.emu__DOT__arm925t__DOT__u_zap__DOT__u_zap_core__DOT__u_zap_writeback__DOT__i_decompile_valid) &&
		         h.emu__DOT__arm925t__DOT__u_zap__DOT__u_zap_core__DOT__u_zap_writeback__DOT__i_uop_last)
			ev = 'R';
		if (!ev || h.emu__DOT__cpu_reset) { pending_ev = 0; return; }
		pending_ev = ev;
		pending_pc = pc;
		pending_thumb = thumb;
	}
	char pending_ev = 0;
	uint32_t pending_pc = 0;
	bool pending_thumb = false;

	uint32_t reg(int phys) {
		return r->emu__DOT__arm925t__DOT__u_zap__DOT__u_zap_core__DOT__u_zap_writeback__DOT__u_zap_register_file__DOT__mem[phys];
	}

	// after the edge: the registers after the committed instruction
	void cpu_after_edge() {
		if (!pending_ev) return;
		char ev = pending_ev;
		uint32_t pc = pending_pc;
		uint32_t cpsr = r->emu__DOT__arm925t__DOT__u_zap__DOT__u_zap_core__DOT__u_zap_writeback__DOT__cpsr_ff;
		// a Thumb BL pair counts once (QEMU's icount), as in tb/main.cpp
		bool bl_second = false;
		if (ev == 'R' && pending_thumb && last_ev == 'R' && pc == last_r_pc + 2 && (pc & 0x3FF))
			bl_second = reg(phys_index(14, cpsr)) == ((pc + 2) | 1);
		if ((ev == 'R' && !bl_second) || ev == 'S' || ev == 'U') retired++;
		if (trace && !trace_done && retired >= trace_after) {
			fprintf(trace, "%c %08x", ev, pc);
			for (int i = 0; i < 15; i++) fprintf(trace, " %08x", reg(phys_index(i, cpsr)));
			fprintf(trace, " %08x\n", cpsr);
			if (trace_count && retired >= trace_after + trace_count) { trace_done = true; fclose(trace); trace = nullptr; }
		}
		last_ev = ev;
		if (ev == 'R') last_r_pc = pc;
	}

	// a completed beat on the CPU's Wishbone port (after the edge: ack is
	// registered, so it is high with the beat's data in this clock)
	void bus_watch() {
		auto &h = *r;
		if (h.emu__DOT__test_on || !h.emu__DOT__wb_cyc || !h.emu__DOT__wb_ack) return;
		uint32_t a = h.emu__DOT__wb_adr;
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
			uint32_t cpsr = h.emu__DOT__arm925t__DOT__u_zap__DOT__u_zap_core__DOT__u_zap_writeback__DOT__cpsr_ff;
			uint32_t pc = h.emu__DOT__arm925t__DOT__u_zap__DOT__u_zap_core__DOT__postalu_pc_plus_8_ff - ((cpsr >> 5 & 1) ? 4 : 8);
			fprintf(devlog, "M %" PRIu64 " %c %u %08x %08x %08x\n", retired, we ? 'W' : 'R', size, pa, v, pc);
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
		video_watch();
		audio_watch();
		key_watch();
		sd_step();
		t->CLK_50M = 0; t->eval();
	}
	void ticks(uint64_t n) { while (n--) tick(); }

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
	bool devlog = false;
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
		else if (a == "--trace") tracep = next();
		else if (a == "--trace-after") trace_after = strtoull(next(), nullptr, 0);
		else if (a == "--trace-count") trace_count = strtoull(next(), nullptr, 0);
		else if (a == "--progress") progress = strtoull(next(), nullptr, 0);
		else if (a[0] == '+') continue;
		else { fprintf(stderr, "unknown option %s\n", a.c_str()); return 2; }
	}
	if (cs0p.empty() || cs1p.empty()) { fprintf(stderr, "--cs0 and --cs1 are needed\n"); return 2; }

	Bench b;
	auto &R = *b.r;
	b.out = out;
	b.kern = fopen((out + "/kern.log").c_str(), "w");
	if (devlog) b.devlog = fopen((out + "/dev.log").c_str(), "w");
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
	b.mark_loaded(1, cs0);
	b.mark_loaded(2, cs1);
	uint64_t start = b.clocks;
	printf("flash images in DDR3; the CPU starts at clock %" PRIu64 "\n", start);
	fflush(stdout);

	auto t0 = std::chrono::steady_clock::now();
	uint64_t last_c = b.clocks;
	auto last_t = t0;
	while (b.clocks < max_cycles) {
		b.tick();
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
			fflush(b.kern);
			if (b.audio_on) write_wav(out + "/audio.wav", b.audio);
		}
	}
	if (b.audio_on) write_wav(out + "/audio.wav", b.audio);
	double wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
	printf("END after %" PRIu64 " clocks (%.3f s simulated), %" PRIu64 " instructions, %" PRIu64 " device accesses, "
	       "%d pictures, %zu audio frames, %.0f s wall clock\n",
	       b.clocks, b.clocks / CLK_HZ, b.retired, b.dev_accesses, b.pictures, b.audio.size() / 2, wall);
	if (b.chip.errors) printf("the SDRAM chip model reported %d error(s)\n", b.chip.errors);
	if (b.dm.protocol_errors) printf("%d DDRAM port protocol error(s)\n", b.dm.protocol_errors);
	if (b.devlog) fclose(b.devlog);
	if (b.trace) fclose(b.trace);
	fclose(b.kern);
	return 0;
}
