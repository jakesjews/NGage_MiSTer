// Bench for rtl/upp/upp_haudio.sv, the HLE audio device, against a C++ port
// of the reference model (model/hw/ngage_audio.c), whose time here is clock
// edges at CLK_HZ: frames due since RUN (or the last rate change) at edge t
// are floor((t - start) * RATE / CLK_HZ), caught up before every access.
//
//   Vupp_haudio [--seed N] [--clk-hz N] [--cycles N] [--wav model.wav] [--out DIR]
//
// Checked every clock: the interrupt line against the model (so the clock
// edge of each DONE, buffer by buffer); every frame the block reads, in
// order, against the frames the model plays (silence, samples, volume, the
// buffer order); every register read; the 48 kHz output against an
// independent model of its interpolation. Bus reads come back after a random
// latency.
//  * registers: reset values, clamps, the rest of the window;
//  * directed: mono and stereo play, aligned and not, the DONE edges against
//    their formula, starving and resuming, stop, rate and volume changes;
//  * random: the stand-in's protocol (refill on the interrupt after a random
//    delay) and random register traffic, rates, formats, restarts;
//  * with --wav (the model's recording, model/.out/au-*/audio.wav, local
//    data): a stretch of it played the stand-in's way (halves of 5600
//    samples), its frames must come out unchanged, and the 48 kHz output is
//    compared with the model's own resampler on the same frames (SNR, best
//    alignment); both are written to DIR as WAV files.
#include "Vupp_haudio.h"
#include "verilated.h"
#include "common.h"

#include <cmath>
#include <cstring>
#include <deque>
#include <functional>
#include <unordered_map>

namespace {

uint64_t CLK = 104000000;
constexpr uint64_t OUT_HZ = 48000;

// ---------------------------------------------------------------- memory
struct Mem {
	std::unordered_map<uint32_t, std::vector<uint8_t>> pages;   // 4 KB pages
	uint8_t &byte(uint32_t a) {
		auto &p = pages[a >> 12];
		if (p.empty()) {
			p.resize(4096);
			for (uint32_t i = 0; i < 4096; i++) {
				uint32_t x = ((a & ~0xFFFu) + i) * 2654435761u;
				p[i] = (uint8_t)(x >> 24);
			}
		}
		return p[a & 0xFFF];
	}
	uint16_t h(uint32_t a) { return (uint16_t)(byte(a) | byte(a + 1) << 8); }
	void set_h(uint32_t a, uint16_t v) { byte(a) = (uint8_t)v; byte(a + 1) = (uint8_t)(v >> 8); }
	uint32_t w(uint32_t a) { return h(a) | (uint32_t)h(a + 2) << 16; }
};

struct Frame {
	int16_t l, r;
	uint32_t adr = 0, vol = 0;       // where the model read it (0: silence), the volume
	uint64_t edge = 0;
	int ch = 0;
};

// ---------------------------------------------------------------- the model
struct Model {
	Mem *mem;
	std::deque<Frame> *out;
	uint32_t ctrl = 0, format = 0, rate = 16000, addr[2] = {0, 0}, len[2] = {0, 0}, volume = 0x100;
	bool full[2] = {false, false};
	uint32_t done = 0;
	int cur = 0;
	uint32_t pos = 0, played = 0;
	bool starved = false;
	uint64_t start = 0, due_base = 0;
	uint64_t now = 0;

	bool irq() const { return (ctrl & 2) && done; }

	void play(uint64_t todo) {
		int ch = (format & 1) ? 2 : 1;
		while (todo) {
			uint32_t n = (uint32_t)std::min<uint64_t>(todo, 4096);
			int b = cur;
			if (!full[b] && full[b ^ 1]) { cur = b ^= 1; pos = 0; }
			if (!full[b]) {
				starved = true;
				for (uint32_t i = 0; i < n; i++) out->push_back({0, 0});
				played += n;
				todo -= n;
				continue;
			}
			starved = false;
			n = std::min(n, len[b] - pos);
			for (uint32_t i = 0; i < n; i++) {
				uint32_t a = addr[b] + (pos + i) * 2 * ch;
				int32_t l = (int16_t)mem->h(a), r = (int16_t)mem->h(a + 2 * (ch - 1));
				out->push_back({(int16_t)((l * (int32_t)volume) >> 8), (int16_t)((r * (int32_t)volume) >> 8), a, volume, now, ch});
			}
			pos += n;
			played += n;
			todo -= n;
			if (pos >= len[b]) {
				full[b] = false;
				done |= 1u << b;
				cur = b ^ 1;
				pos = 0;
			}
		}
	}
	uint64_t due(uint64_t t) const { return due_base + (t - start) * rate / CLK; }
	void catch_up(uint64_t t) {
		now = t;
		if (!(ctrl & 1)) return;
		uint64_t d = due(t);
		if (d > played) play(d - played);
	}
	// the frame clock comes round at edge t (before what is written there)
	bool ticks(uint64_t t) const { return (ctrl & 1) && t > start && due(t) > due(t - 1); }
	uint64_t facc_after(uint64_t t) const { return (t - start) * rate % CLK; }

	uint32_t read(uint64_t t, uint32_t off) {
		catch_up(t);
		switch (off) {
		case 0x00: return 0x41554431;
		case 0x04: return ctrl;
		case 0x08: return format;
		case 0x0C: return rate;
		case 0x10: return addr[0];
		case 0x14: return addr[1];
		case 0x18: return len[0];
		case 0x1C: return len[1];
		case 0x20: return done | (full[0] ? 0x10 : 0) | (full[1] ? 0x20 : 0) | ((ctrl & 1) ? 0x100 : 0) |
		                  (cur ? 0x200 : 0) | (starved ? 0x400 : 0);
		case 0x24: return pos;
		case 0x28: return volume;
		case 0x2C: return played;
		}
		return 0;
	}
	void write(uint64_t t, uint32_t off, uint32_t v) {
		catch_up(t);
		switch (off) {
		case 0x04:
			if ((v ^ ctrl) & 1) {
				ctrl = v;
				if (v & 1) {
					cur = 0; pos = 0; played = 0; due_base = 0; starved = false; start = t;
				} else {
					full[0] = full[1] = false;
					done = 0;
				}
			}
			ctrl = v;
			break;
		case 0x08: format = v & 1; break;
		case 0x0C:
			v = std::max(4000u, std::min(48000u, v));
			if (v != rate && (ctrl & 1)) { due_base = played; start = t; }
			rate = v;
			break;
		case 0x10: addr[0] = v & ~1u; break;
		case 0x14: addr[1] = v & ~1u; break;
		case 0x18: case 0x1C: {
			int b = (off - 0x18) >> 2;
			len[b] = v;
			full[b] = v != 0;
			break;
		}
		case 0x20: done &= ~(v & 3); break;
		case 0x28: volume = std::min(v, 0x100u); break;
		}
	}
};

// the model's host resampler (out_put), for the WAV comparison
struct HostOut {
	uint32_t phase = 0;
	int16_t last[2] = {0, 0};
	std::vector<int16_t> pcm;        // interleaved L, R at 48 kHz
	void put(Frame f, uint32_t rate) {
		uint32_t step = (uint32_t)(((uint64_t)rate << 16) / 48000);
		while (phase < 0x10000) {
			int64_t a = phase;      // the product in 64 bits: the model's int can overflow
			pcm.push_back((int16_t)(last[0] + (((int64_t)(f.l - last[0]) * a) >> 16)));
			pcm.push_back((int16_t)(last[1] + (((int64_t)(f.r - last[1]) * a) >> 16)));
			phase += step;
		}
		phase -= 0x10000;
		last[0] = f.l;
		last[1] = f.r;
	}
};

bool write_wav(const std::string &path, const std::vector<int16_t> &pcm, int ch, uint32_t rate) {
	FILE *f = fopen(path.c_str(), "wb");
	if (!f) return false;
	uint32_t bytes = (uint32_t)(pcm.size() * 2);
	auto u32 = [&](uint32_t v) { fwrite(&v, 4, 1, f); };
	auto u16 = [&](uint16_t v) { fwrite(&v, 2, 1, f); };
	fwrite("RIFF", 1, 4, f); u32(36 + bytes); fwrite("WAVEfmt ", 1, 8, f);
	u32(16); u16(1); u16((uint16_t)ch); u32(rate); u32(rate * 2 * ch); u16((uint16_t)(2 * ch)); u16(16);
	fwrite("data", 1, 4, f); u32(bytes);
	fwrite(pcm.data(), 2, pcm.size(), f);
	fclose(f);
	return true;
}

// ---------------------------------------------------------------- bench
struct Bench {
	Vupp_haudio *t = new Vupp_haudio;
	sim::Rng rng;
	Mem mem;
	std::deque<Frame> want;           // frames the model played, not yet seen from the block
	Model m;
	uint64_t edge_n = 0;
	int max_lat = 12;                 // bus read latency, clocks
	int fixed_lat = -1;               // >= 0: every read takes this long
	int err_pct = 0;

	// the bus slave
	bool bus_busy = false;
	int bus_wait = 0;
	std::deque<uint32_t> err_words;   // words whose read ended with an error (the block takes 0)

	// the independent model of the output stage
	uint64_t oacc = 0;
	bool ot1 = false, ot2 = false, start_q = false;
	int16_t fr[2] = {0, 0}, o0[2] = {0, 0}, o1[2] = {0, 0}, b[2] = {0, 0}, out[2] = {0, 0};
	int32_t d[2] = {0, 0};
	int64_t x[2] = {0, 0};
	uint32_t frac = 0;
	uint64_t pk = 0;

	// statistics and recordings
	uint64_t frames_seen = 0, irq_rises = 0, reads = 0, bus_reads = 0, dropped = 0, out_samples = 0;
	bool prev_irq = false;
	std::vector<uint64_t> irq_edges;
	std::vector<int16_t> *rec48 = nullptr;    // the output, at each new sample
	std::vector<Frame> *recf = nullptr;      // the frames, as they come
	std::function<void()> on_irq;            // the guest's interrupt handler

	explicit Bench(uint32_t seed) : rng(seed) {
		m.mem = &mem;
		m.out = &want;
		pk = (1ull << 40) / CLK;
		t->reset = 1; t->acc = 0; t->wr = 0; t->off = 0; t->wdata = 0; t->m_ack = 0; t->m_err = 0; t->m_dat_i = 0;
		for (int i = 0; i < 3; i++) clock();
		t->reset = 0;
	}
	~Bench() { t->final(); delete t; }

	// one clock edge with the inputs as set; at_edge applies the model's side
	// of a register write at this edge
	void clock(const std::function<void(uint64_t)> &at_edge = nullptr) {
		uint64_t e = edge_n + 1;
		bool rst = t->reset;

		// the bus slave answers in this clock?
		t->m_ack = 0; t->m_err = 0;
		if (t->m_cyc && t->m_stb) {
			if (!bus_busy) { bus_busy = true; bus_wait = fixed_lat >= 0 ? fixed_lat : rng.range(0, max_lat); }
			if (bus_wait == 0) {
				bool err = rng.chance(err_pct);
				t->m_ack = !err; t->m_err = err;
				t->m_dat_i = err ? rng.u32() : mem.w(t->m_adr & ~3u);
				if (err) err_words.push_back(t->m_adr & ~3u);
				bus_busy = false;
				bus_reads++;
			} else {
				bus_wait--;
			}
		}

		// the output stage's inputs in this clock
		bool run_pre = m.ctrl & 1;
		bool tick = !rst && m.ticks(e);
		uint64_t facc_pre = (run_pre && e - 1 >= m.start) ? m.facc_after(e - 1) : 0;
		bool fwe = t->frame_we;
		int16_t fl = (int16_t)t->frame_l, frr = (int16_t)t->frame_r;
		bool otick = !rst && oacc + OUT_HZ >= CLK;
		bool run_set = false;
		if (t->wr && t->off == 0x04 && (t->wdata & 1) && !(m.ctrl & 1)) run_set = true;

		if (at_edge) at_edge(e);

		t->clk = 0; t->eval();
		t->clk = 1; t->eval();
		edge_n = e;

		if (rst) {
			oacc = 0; ot1 = ot2 = false; start_q = false;
			fr[0] = fr[1] = o0[0] = o0[1] = o1[0] = o1[1] = out[0] = out[1] = 0;
			return;
		}

		// the output stage after this edge (from the values before it)
		int16_t o0_p[2] = {o0[0], o0[1]}, o1_p[2] = {o1[0], o1[1]};
		int16_t fr_n[2] = {fr[0], fr[1]};
		if (fwe) { fr_n[0] = fl; fr_n[1] = frr; }
		if (start_q) { fr_n[0] = fr_n[1] = 0; }
		if (tick) {
			o0[0] = o1[0]; o0[1] = o1[1];
			o1[0] = fwe ? fl : fr[0];
			o1[1] = fwe ? frr : fr[1];
		}
		if (run_set) { o0[0] = o0[1] = o1[0] = o1[1] = 0; }
		fr[0] = fr_n[0]; fr[1] = fr_n[1];
		start_q = run_set;
		bool new_out = false;
		if (ot2) {
			for (int c = 0; c < 2; c++)
				out[c] = run_pre ? (int16_t)(b[c] + (int32_t)(x[c] >> 16)) : 0;
			new_out = true;
		}
		if (ot1) for (int c = 0; c < 2; c++) x[c] = (int64_t)d[c] * (int64_t)frac;
		if (otick) {
			frac = (uint32_t)((facc_pre * pk) >> 24) & 0xFFFF;
			for (int c = 0; c < 2; c++) {
				d[c] = run_pre ? (int32_t)o1_p[c] - (int32_t)o0_p[c] : 0;
				b[c] = run_pre ? o0_p[c] : 0;
			}
		}
		ot2 = ot1;
		ot1 = otick;
		oacc = otick ? oacc + OUT_HZ - CLK : oacc + OUT_HZ;

		// the model up to this edge
		m.catch_up(e);

		// checks
		if (t->frame_we) {
			frames_seen++;
			if (recf) recf->push_back({(int16_t)t->frame_l, (int16_t)t->frame_r});
			if (want.empty()) {
				sim::fail("edge %llu: a frame (%d, %d) the model did not play", (unsigned long long)e,
				          (int16_t)t->frame_l, (int16_t)t->frame_r);
			} else {
				Frame w = want.front();
				want.pop_front();
				// a sample whose read ended with a bus error is 0
				auto erred = [&](uint32_t a) {
					for (auto it = err_words.begin(); it != err_words.end(); ++it)
						if (*it == (a & ~3u)) { err_words.erase(it); return true; }
					return false;
				};
				if (w.ch) {
					bool el = erred(w.adr);
					bool er = w.ch == 2 && ((w.adr + 2) & ~3u) != (w.adr & ~3u) ? erred(w.adr + 2) : el;
					if (el) w.l = 0;
					if (er) w.r = 0;
				}
				if ((int16_t)t->frame_l != w.l || (int16_t)t->frame_r != w.r)
					sim::fail("edge %llu: frame %llu is (%d, %d), want (%d, %d) (read at 0x%08x, volume 0x%x, edge %llu)",
					          (unsigned long long)e, (unsigned long long)frames_seen, (int16_t)t->frame_l,
					          (int16_t)t->frame_r, w.l, w.r, w.adr, w.vol, (unsigned long long)w.edge);
			}
		}
		if (want.size() > 2) sim::fail("edge %llu: %zu frames behind the model", (unsigned long long)e, want.size());
		bool irq = t->irq;
		if (irq != m.irq()) sim::fail("edge %llu: interrupt %d, want %d", (unsigned long long)e, irq, m.irq());
		if (irq && !prev_irq) { irq_rises++; irq_edges.push_back(e); }
		prev_irq = irq;
		if ((int16_t)t->out_l != out[0] || (int16_t)t->out_r != out[1])
			sim::fail("edge %llu: output (%d, %d), want (%d, %d)", (unsigned long long)e, (int16_t)t->out_l,
			          (int16_t)t->out_r, out[0], out[1]);
		if (new_out) {
			out_samples++;
			if (rec48) { rec48->push_back(out[0]); rec48->push_back(out[1]); }
		}
		if (irq && on_irq) on_irq();
	}
	void idle(uint64_t n) {
		t->acc = 0; t->wr = 0;
		for (uint64_t i = 0; i < n; i++) clock();
	}
	void write(uint32_t off, uint32_t v) {
		t->acc = 1; t->wr = 1; t->off = off; t->wdata = v;
		t->eval();
		bool restart = off == 0x04 && (v & 1) && !(m.ctrl & 1);
		clock([&](uint64_t e) { m.write(e, off, v); });
		t->acc = 0; t->wr = 0;
		if (restart) {
			// frames of the run before still on their way are dropped
			dropped += want.size();
			want.clear();
		}
	}
	uint32_t read(uint32_t off) {
		t->acc = 1; t->wr = 0; t->off = off;
		t->eval();
		uint32_t w = m.read(edge_n, off);
		reads++;
		if (t->rmask != 0xFFFFFFFFu) sim::fail("+0x%02x: rmask 0x%08x", off, t->rmask);
		if (t->rdata != w)
			sim::fail("edge %llu: +0x%02x reads 0x%08x, want 0x%08x", (unsigned long long)edge_n, off, t->rdata, w);
		uint32_t v = t->rdata;
		clock();
		t->acc = 0;
		return v;
	}
	// run until the next interrupt rise or n clocks; the edge of the rise
	uint64_t until_irq(uint64_t n) {
		uint64_t r0 = irq_rises;
		t->acc = 0; t->wr = 0;
		for (uint64_t i = 0; i < n && irq_rises == r0; i++) clock();
		return irq_rises != r0 ? irq_edges.back() : 0;
	}
	void fill(uint32_t a, uint32_t frames, int ch, uint32_t seed) {
		for (uint32_t i = 0; i < frames * ch; i++) {
			uint32_t x = (seed + i) * 2246822519u;
			mem.set_h(a + 2 * i, (uint16_t)(x >> 16));
		}
	}
	uint64_t ceil_div(uint64_t a, uint64_t b) { return (a + b - 1) / b; }
};

// ---------------------------------------------------------------- tests
void test_registers(Bench &b) {
	printf("registers\n");
	CHECK_EQ(b.read(0x00), 0x41554431, "ID");
	CHECK_EQ(b.read(0x04), 0, "CTRL after reset");
	CHECK_EQ(b.read(0x0C), 16000, "RATE after reset");
	CHECK_EQ(b.read(0x28), 0x100, "VOLUME after reset");
	CHECK_EQ(b.read(0x20), 0, "STATUS after reset");
	b.write(0x0C, 0); CHECK_EQ(b.read(0x0C), 4000, "RATE clamps up");
	b.write(0x0C, 100000); CHECK_EQ(b.read(0x0C), 48000, "RATE clamps down");
	b.write(0x0C, 0x80001F40); CHECK_EQ(b.read(0x0C), 48000, "RATE: the whole word clamps");
	b.write(0x0C, 22050); CHECK_EQ(b.read(0x0C), 22050, "RATE");
	b.write(0x28, 0x200); CHECK_EQ(b.read(0x28), 0x100, "VOLUME clamps");
	b.write(0x28, 0x80); CHECK_EQ(b.read(0x28), 0x80, "VOLUME");
	b.write(0x10, 0x0A061001); CHECK_EQ(b.read(0x10), 0x0A061000, "ADDR0 bit 0");
	b.write(0x14, 0xFFFFFFFF); CHECK_EQ(b.read(0x14), 0xFFFFFFFE, "ADDR1 bit 0");
	b.write(0x08, 0xFFFFFFFF); CHECK_EQ(b.read(0x08), 1, "FORMAT");
	b.write(0x08, 2); CHECK_EQ(b.read(0x08), 0, "FORMAT bit 0 only");
	b.write(0x04, 0xFFFFFFFE); CHECK_EQ(b.read(0x04), 0xFFFFFFFE, "CTRL keeps the word");
	b.write(0x04, 0);
	b.write(0x18, 7); CHECK_EQ(b.read(0x20), 0x10, "LEN0 marks full");
	b.write(0x1C, 9); CHECK_EQ(b.read(0x20), 0x30, "LEN1 marks full");
	b.write(0x18, 0); CHECK_EQ(b.read(0x20), 0x20, "LEN0 = 0 empties");
	b.write(0x24, 5); b.write(0x2C, 5); b.write(0x00, 5);
	CHECK_EQ(b.read(0x24), 0, "POS is read-only");
	CHECK_EQ(b.read(0x2C), 0, "PLAYED is read-only");
	for (uint32_t o = 0x30; o < 0x100; o += 4) {
		b.write(o, 0xFFFFFFFF);
		CHECK_EQ(b.read(o), 0, "the rest of the window");
	}
	b.write(0x1C, 0);
	b.write(0x0C, 16000);
	b.write(0x28, 0x100);
}

// mono, aligned, two buffers: the DONE edges against their formula
void test_mono(Bench &b) {
	printf("mono play, DONE edges\n");
	const uint32_t A0 = 0x0A061000, A1 = 0x0A063BC0, L0 = 300, L1 = 170, R = 16000;
	b.fill(A0, L0, 1, 1);
	b.fill(A1, L1, 1, 2);
	b.write(0x08, 0);
	b.write(0x0C, R);
	b.write(0x10, A0);
	b.write(0x14, A1);
	b.write(0x18, L0);
	b.write(0x1C, L1);
	b.write(0x28, 0x100);
	b.write(0x04, 3);
	uint64_t run_edge = b.edge_n;
	uint64_t e0 = b.until_irq(CLK * 1);
	CHECK_EQ(e0, run_edge + b.ceil_div(L0 * CLK, R), "DONE0 edge");
	CHECK_EQ(b.read(0x20) & 0x7FF, 0x321, "STATUS after buffer 0: DONE0, FULL1, running, buffer 1");
	b.write(0x20, 1);
	uint64_t e1 = b.until_irq(CLK * 1);
	CHECK_EQ(e1, run_edge + b.ceil_div((L0 + L1) * CLK, R), "DONE1 edge");
	b.idle(CLK / R * 3);
	CHECK_EQ(b.read(0x20) & 0x7FF, 0x502, "STATUS starved: DONE1, running, buffer 0, starved");
	uint32_t played = b.read(0x2C);
	CHECK(played >= L0 + L1 + 2, "PLAYED counts silence (%u)", played);
	// resume with buffer 1 (the other one): play takes it at position 0
	b.write(0x20, 3);
	b.write(0x1C, 50);
	b.idle(CLK / R * 10);
	CHECK(b.read(0x24) >= 9, "POS after resuming");
	CHECK_EQ(b.read(0x20) & 0x7FF, 0x320, "STATUS resumed: FULL1, running, buffer 1");
	b.write(0x04, 0);
	CHECK_EQ(b.read(0x20), 0x200, "STATUS after stop: buffer 1 still");
	b.idle(1000);
}

void test_stereo(Bench &b, uint32_t a0, uint32_t a1, const char *what) {
	printf("stereo play, %s\n", what);
	const uint32_t L0 = 120, L1 = 77, R = 44100;
	b.fill(a0, L0, 2, 3);
	b.fill(a1, L1, 2, 4);
	b.write(0x08, 1);
	b.write(0x0C, R);
	b.write(0x10, a0);
	b.write(0x14, a1);
	b.write(0x18, L0);
	b.write(0x1C, L1);
	b.write(0x28, 0xC0);
	uint64_t r0 = b.bus_reads;
	b.write(0x04, 1);
	uint64_t run_edge = b.edge_n;
	b.idle(b.ceil_div((L0 + L1 + 1) * CLK, R) + 1);
	CHECK_EQ(b.read(0x20) & 0x403, 0x403, "both DONE, starved");
	uint64_t reads = b.bus_reads - r0;
	uint64_t want = (a0 & 2 ? 2 : 1) * L0 + (a1 & 2 ? 2 : 1) * L1;
	CHECK_EQ(reads, want, "bus reads for the frames");
	(void)run_edge;
	b.write(0x04, 0);
	b.write(0x08, 0);
	b.write(0x28, 0x100);
	b.idle(500);
}

// rate and volume changes while playing; stop and restart at once
void test_changes(Bench &b) {
	printf("rate and volume changes, restart\n");
	const uint32_t A0 = 0x0A100000, A1 = 0x0A110002;
	b.fill(A0, 4000, 1, 5);
	b.fill(A1, 4000, 1, 6);
	b.write(0x0C, 8000);
	b.write(0x10, A0);
	b.write(0x14, A1);
	b.write(0x18, 4000);
	b.write(0x1C, 4000);
	b.write(0x04, 3);
	for (int i = 0; i < 40; i++) {
		b.idle(b.rng.range(1, 40000));
		switch (b.rng.range(0, 4)) {
		case 0: b.write(0x0C, b.rng.range(3000, 50000)); break;
		case 1: b.write(0x0C, b.read(0x0C)); break;              // the same rate: no restart of the count
		case 2: b.write(0x28, b.rng.range(0, 0x120)); break;
		case 3: b.read(0x24); b.read(0x2C); break;
		case 4: b.write(0x04, 0); b.write(0x18, 4000); b.write(0x1C, 4000); b.write(0x04, 3); break;
		}
	}
	b.write(0x04, 0);
	b.idle(2000);
}

// stop and start again while a frame's reads are under way: they are dropped
void test_restart(Bench &b) {
	printf("restart with reads under way\n");
	const uint32_t A0 = 0x0A120002, A1 = 0x0A130002;
	b.fill(A0, 1000, 2, 7);
	b.fill(A1, 1000, 2, 8);
	b.write(0x08, 1);
	b.write(0x0C, 48000);
	b.write(0x10, A0);
	b.write(0x14, A1);
	b.max_lat = 20;
	uint64_t d0 = b.dropped;
	for (int i = 0; i < 60; i++) {
		b.write(0x18, 1000);
		b.write(0x1C, 1000);
		b.write(0x04, 1);
		for (int k = b.rng.range(1, 5); k > 0; k--) {
			size_t n = b.frames_seen + b.want.size();
			while (b.frames_seen + b.want.size() == n) b.idle(1);   // a frame played
		}
		b.idle((uint64_t)b.rng.range(0, 30));
		b.write(0x04, 0);
		if (b.rng.chance(50)) b.write(0x18, 1000);
		b.write(0x04, 1);
		b.idle((uint64_t)b.rng.range(0, 3) * (CLK / 48000));
		b.write(0x04, 0);
		for (int k = 0; k < 1000 && !b.want.empty(); k++) b.idle(1);
	}
	CHECK(b.dropped > d0, "no frame was dropped at a restart");
	printf("  %llu frames dropped\n", (unsigned long long)(b.dropped - d0));
	b.max_lat = 12;
	b.write(0x08, 0);
	b.idle(500);
}

// reads that take most of a frame period: a frame's samples arrive in the
// clock of the next frame (the interpolation takes them straight from the bus)
void test_slow_bus(Bench &b) {
	printf("reads taking a frame period\n");
	const uint32_t A0 = 0x0A140000, A1 = 0x0A150000, R = 48000;
	int fc = (int)(CLK / R);
	b.fill(A0, 4000, 1, 9);
	b.fill(A1, 4000, 1, 10);
	b.write(0x08, 0);
	b.write(0x0C, R);
	b.write(0x10, A0);
	b.write(0x14, A1);
	for (int lat = fc - 12; lat < fc - 1; lat++) {
		b.fixed_lat = lat;
		b.write(0x18, 4000);
		b.write(0x1C, 4000);
		b.write(0x04, 1);
		b.idle((uint64_t)fc * 120);
		b.write(0x04, 0);
		for (int k = 0; k < 4 * fc && !b.want.empty(); k++) b.idle(1);
	}
	b.fixed_lat = -1;
	b.idle(500);
}

void test_random(Bench &b, uint64_t cycles) {
	printf("random: the stand-in's protocol and register traffic, %llu clocks\n", (unsigned long long)cycles);
	uint64_t end = b.edge_n + cycles;
	int sessions = 0;
	while (b.edge_n < end) {
		// a session
		sessions++;
		int ch = b.rng.chance(30) ? 2 : 1;
		static const uint32_t rates[] = {8000, 16000, 11025, 22050, 32000, 44100, 48000, 4000};
		uint32_t rate = b.rng.chance(70) ? rates[b.rng.range(0, 7)] : (uint32_t)b.rng.range(4000, 48000);
		uint32_t half = (uint32_t)b.rng.range(1, 400);
		uint32_t a0 = 0x0A200000 + 2 * (uint32_t)b.rng.range(0, 64);
		// room for stereo frames: FORMAT may change during the session
		uint32_t a1 = a0 + half * 4 + 2 * (uint32_t)b.rng.range(0, 8);
		uint64_t frame_clks = CLK / rate;
		// the reads of a frame within a frame period, at any rate
		b.max_lat = std::min(b.rng.range(0, 40), (int)(CLK / 48000 / 4));
		b.err_pct = b.rng.chance(20) ? 5 : 0;
		uint32_t seed = b.rng.u32();
		b.write(0x08, ch == 2);
		b.write(0x0C, rate);
		b.write(0x10, a0);
		b.write(0x14, a1);
		b.write(0x28, b.rng.chance(50) ? 0x100 : (uint32_t)b.rng.range(0, 0x100));
		b.fill(a0, half, ch, seed++);
		b.fill(a1, half, ch, seed++);
		b.write(0x18, half);
		if (b.rng.chance(80)) b.write(0x1C, half);
		b.write(0x04, b.rng.chance(85) ? 3 : 1);
		uint64_t s_end = std::min(end, b.edge_n + (uint64_t)b.rng.range(20, 200) * frame_clks * 10);
		uint64_t refill_at = 0;
		int refill_buf = -1;
		while (b.edge_n < s_end) {
			// the interrupt handler: acknowledge, refill later
			if (b.t->irq && refill_buf < 0) {
				uint32_t st = b.read(0x20);
				int buf = (st & 1) ? 0 : (st & 2) ? 1 : -1;
				if (buf >= 0) {
					b.write(0x20, 1u << buf);
					refill_buf = buf;
					uint64_t delay = b.rng.chance(10) ? frame_clks * (uint64_t)b.rng.range(half, 3 * half)
					                                  : (uint64_t)b.rng.range(300, (int)std::max<uint64_t>(301, frame_clks * half / 2));
					refill_at = b.edge_n + delay;
				}
			}
			if (refill_buf >= 0 && b.edge_n >= refill_at) {
				uint32_t n = b.rng.chance(90) ? half : (uint32_t)b.rng.range(1, (int)half);
				b.fill(refill_buf ? a1 : a0, n, ch, seed++);
				b.write(refill_buf ? 0x1C : 0x18, n);
				refill_buf = -1;
			}
			// other traffic
			int r = b.rng.range(0, 999);
			if (r < 20) b.read((uint32_t)b.rng.range(0, 0x0F) * 4);
			else if (r < 22) b.write(0x28, (uint32_t)b.rng.range(0, 0x140));
			else if (r < 23) b.write(0x20, (uint32_t)b.rng.range(0, 3));      // a stray acknowledge
			else if (r < 24 && b.rng.chance(20)) b.write(0x04, b.read(0x04) ^ 2);
			else if (r < 25 && b.rng.chance(10)) b.write(0x0C, (uint32_t)b.rng.range(4000, 48000));
			else if (r < 26 && b.rng.chance(5)) b.write(0x08, (uint32_t)b.rng.range(0, 1));
			else b.idle((uint64_t)b.rng.range(1, (int)std::max<uint64_t>(2, frame_clks / 4)));
		}
		b.write(0x04, b.rng.chance(50) ? 0 : 2);
		b.idle((uint64_t)b.rng.range(0, 3000));
		// the last frame's read done before the buffers are written again
		for (int i = 0; i < 1000 && !b.want.empty(); i++) b.idle(1);
	}
	b.max_lat = 12;
	b.err_pct = 0;
	printf("  %d sessions\n", sessions);
}

// --------------------------------------------------------------- the model's WAV
struct Wav {
	int ch = 0;
	uint32_t rate = 0;
	std::vector<int16_t> pcm;
};

bool read_wav(const std::string &path, Wav &w, size_t max_frames, size_t skip_frames) {
	FILE *f = fopen(path.c_str(), "rb");
	if (!f) return false;
	uint8_t h[44];
	if (fread(h, 1, 44, f) != 44 || memcmp(h, "RIFF", 4) || memcmp(h + 8, "WAVEfmt ", 8)) { fclose(f); return false; }
	w.ch = h[22] | h[23] << 8;
	w.rate = h[24] | h[25] << 8 | h[26] << 16 | (uint32_t)h[27] << 24;
	if ((h[34] | h[35] << 8) != 16 || (w.ch != 1 && w.ch != 2)) { fclose(f); return false; }
	// find the first sound after skip_frames
	std::vector<int16_t> buf(4096 * w.ch);
	size_t frame = 0;
	bool found = false;
	while (!found) {
		size_t n = fread(buf.data(), 2 * w.ch, 4096, f);
		if (!n) break;
		for (size_t i = 0; i < n; i++, frame++) {
			if (frame >= skip_frames && buf[i * w.ch] != 0) {
				found = true;
				w.pcm.assign(buf.begin() + (long)(i * w.ch), buf.begin() + (long)(n * w.ch));
				break;
			}
		}
	}
	while (found && w.pcm.size() < max_frames * w.ch) {
		size_t n = fread(buf.data(), 2 * w.ch, 4096, f);
		if (!n) break;
		w.pcm.insert(w.pcm.end(), buf.begin(), buf.begin() + (long)(n * w.ch));
	}
	fclose(f);
	if (w.pcm.size() > max_frames * w.ch) w.pcm.resize(max_frames * w.ch);
	return found;
}

void test_wav(Bench &b, const std::string &path, const std::string &out_dir, size_t frames) {
	Wav w;
	if (!read_wav(path, w, frames, 0)) {
		printf("model recording: %s not there or not 16-bit PCM, skipped\n", path.c_str());
		return;
	}
	size_t nf = w.pcm.size() / w.ch;
	printf("model recording: %zu frames of %s (%u Hz, %s)\n", nf, path.c_str(), w.rate, w.ch == 2 ? "stereo" : "mono");
	const uint32_t A[2] = {0x0A061000, 0x0A063BC0}, HALF = 5600;
	size_t next = 0;
	auto fill = [&](int buf) -> uint32_t {
		uint32_t n = (uint32_t)std::min<size_t>(HALF, nf - next);
		for (uint32_t i = 0; i < n * w.ch; i++) b.mem.set_h(A[buf] + 2 * i, (uint16_t)w.pcm[next * w.ch + i]);
		next += n;
		return n;
	};
	std::vector<int16_t> rec;
	HostOut host;
	b.rec48 = &rec;
	b.max_lat = 30;
	b.write(0x08, w.ch == 2);
	b.write(0x0C, w.rate);
	b.write(0x10, A[0]);
	b.write(0x14, A[1]);
	b.write(0x28, 0x100);
	b.write(0x18, fill(0));
	b.write(0x1C, fill(1));
	uint64_t seen0 = b.frames_seen;
	std::vector<Frame> got;
	b.recf = &got;
	b.write(0x04, 3);
	int refill = -1;
	uint64_t refill_at = 0;
	uint64_t end_frames = nf;
	while (b.frames_seen - seen0 < end_frames + 4) {
		if (b.t->irq && refill < 0) {
			uint32_t st = b.read(0x20);
			int buf = (st & 1) ? 0 : 1;
			b.write(0x20, 1u << buf);
			refill = buf;
			refill_at = b.edge_n + CLK / 1000;         // 1 ms later
		}
		if (refill >= 0 && b.edge_n >= refill_at) {
			if (next < nf) b.write(refill ? 0x1C : 0x18, fill(refill));
			refill = -1;
		}
		b.idle(1);
	}
	b.write(0x04, 0);
	b.idle(100);
	b.rec48 = nullptr;
	b.recf = nullptr;
	b.max_lat = 12;
	// the frames, unchanged
	size_t bad = 0;
	for (size_t i = 0; i < nf && i < got.size(); i++) {
		int16_t l = w.pcm[i * w.ch], r = w.pcm[i * w.ch + w.ch - 1];
		if (got[i].l != l || got[i].r != r) {
			if (bad++ < 5) sim::fail("recording frame %zu: (%d, %d), want (%d, %d)", i, got[i].l, got[i].r, l, r);
		}
	}
	CHECK(got.size() >= nf, "recording: %zu frames played of %zu", got.size(), nf);
	// the model's resampler on the same frames (the block's output starts two
	// frames later: its interpolation is a frame behind the play, and the play
	// starts a frame period after RUN)
	for (size_t i = 0; i < nf; i++) host.put({w.pcm[i * w.ch], w.pcm[i * w.ch + w.ch - 1]}, w.rate);
	size_t n48 = std::min(host.pcm.size(), rec.size()) / 2;
	double best = -1e9;
	int best_k = 0;
	for (int k = 0; k < 400; k++) {
		double sig = 0, err = 0;
		for (size_t i = 0; i + (size_t)k < n48 && i < n48 - 400; i++) {
			double a = host.pcm[2 * i], g = rec[2 * (i + k)];
			sig += a * a;
			err += (a - g) * (a - g);
		}
		double snr = err > 0 ? 10 * log10(sig / err) : 200;
		if (snr > best) { best = snr; best_k = k; }
	}
	// the scale: the model's stream against itself half a sample later (the
	// two streams' phases differ by up to that: the block's is real time)
	double sig = 0, err = 0;
	for (size_t i = 0; i + 1 < n48; i++) {
		double a = host.pcm[2 * i], h = (host.pcm[2 * i] + host.pcm[2 * i + 2]) / 2.0;
		sig += a * a;
		err += (a - h) * (a - h);
	}
	double half = err > 0 ? 10 * log10(sig / err) : 200;
	printf("  48 kHz output against the model's resampler: SNR %.1f dB at an offset of %d samples "
	       "(the model's against itself half a sample later: %.1f dB)\n", best, best_k, half);
	CHECK(best > half - 6, "48 kHz output against the model's resampler: SNR %.1f dB", best);
	if (!out_dir.empty()) {
		write_wav(out_dir + "/haudio-48k.wav", rec, 2, 48000);
		write_wav(out_dir + "/haudio-model-48k.wav", host.pcm, 2, 48000);
		printf("  wrote %s/haudio-48k.wav and haudio-model-48k.wav\n", out_dir.c_str());
	}
}

}  // namespace

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	uint32_t seed = 1;
	uint64_t cycles = 30000000;
	std::string wav, out_dir;
	size_t wav_frames = 8000;
	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		if (a == "--seed" && i + 1 < argc) seed = (uint32_t)strtoul(argv[++i], nullptr, 0);
		else if (a == "--clk-hz" && i + 1 < argc) CLK = strtoull(argv[++i], nullptr, 0);
		else if (a == "--cycles" && i + 1 < argc) cycles = strtoull(argv[++i], nullptr, 0);
		else if (a == "--wav" && i + 1 < argc) wav = argv[++i];
		else if (a == "--wav-frames" && i + 1 < argc) wav_frames = strtoull(argv[++i], nullptr, 0);
		else if (a == "--out" && i + 1 < argc) out_dir = argv[++i];
	}
	Bench b(seed);
	test_registers(b);
	test_mono(b);
	test_stereo(b, 0x0A070000, 0x0A071000, "aligned");
	test_stereo(b, 0x0A070002, 0x0A07100E, "not aligned");
	test_changes(b);
	test_restart(b);
	test_slow_bus(b);
	test_random(b, cycles);
	if (!wav.empty()) test_wav(b, wav, out_dir, wav_frames);
	printf("%llu frames checked, %llu dropped at restarts, %llu interrupts, %llu register reads, %llu bus reads, "
	       "%llu output samples\n",
	       (unsigned long long)b.frames_seen, (unsigned long long)b.dropped, (unsigned long long)b.irq_rises,
	       (unsigned long long)b.reads, (unsigned long long)b.bus_reads, (unsigned long long)b.out_samples);
	return sim::finish("haudio");
}
