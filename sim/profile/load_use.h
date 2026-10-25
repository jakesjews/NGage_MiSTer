// SPDX-License-Identifier: GPL-3.0-or-later
// Load-to-consumer mix and the cycle cost of V2's candidate 104 MHz pipeline
// cuts (docs/consults/2026-10-25-v2-104mhz-plan.md), measured on the retired
// instruction stream. Observation only: it reads the profile probe's retired
// (expanded ARM) word, condition-pass and Thumb bits; nothing feeds back.
//
// Every scenario runs the same in-order issue model over the stream: an
// instruction issues at max(previous issue + occupancy, producer issue +
// spacing(producer, consumer role)) over its source registers. Only the
// scenarios' spacing rules differ, so the difference of two scenarios' clocks
// is the added dependency time of a cut, with the stream's real distances and
// chaining. Memory, fetch and other stalls are not modelled; an added hold
// that the real pipeline would overlap with them is still counted, so the
// costs are upper bounds. Completion costs (+1 per non-short completion) are
// counted separately from the D-cache event taps.
//
// Baseline spacing (docs/ARM9V2.md windows 3/4/5): a load reaches a late
// (A-picked) operand 2 clocks after it issues and an early (S-needed) operand
// 3 clocks after; an ALU result 1 and 2. Late operands: unshifted DP Rn/Rm,
// LDR/STR base and unshifted register offset, store data, BX/SWP Rm, MLA
// accumulator. Early: shifted Rm, Rs, multiply factors, LDM/STM base.
#pragma once
#include <array>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <string>

namespace load_use {

enum Prod : uint8_t { PNone, PLoadWord, PLoadSub, PAlu, PWriteback, PMult };
enum Role : uint8_t { RLate, RLateFlag, REarly, RBase, ROffset };

// Scenarios: 0 baseline; 1 A1 S-AGU; 2 A2 L stage; 3 B2 flag consumers early;
// 4 B3 no load-word late pickup; 5 C2 sub-word format in W; 6 preferred
// (A1+B2); 7 fallback (A2+B3+C2).
constexpr int NS = 8;
inline constexpr const char *scenario_names[NS] = {"baseline", "A1_sagu", "A2_lstage", "B2_flag_early",
                                                    "B3_no_load_late", "C2_subword_w", "preferred_A1_B2",
                                                    "fallback_A2_B3_C2"};

inline int spacing(int s, Prod p, Role r) {
	const bool A1 = s == 1 || s == 6, A2 = s == 2 || s == 7, B2 = s == 3 || s == 6, B3 = s == 4 || s == 7,
	           C2 = s == 5 || s == 7;
	const bool load = p == PLoadWord || p == PLoadSub;
	if (load) {
		bool early = r == REarly;
		// A1: the AGU in S needs base and register offset at S.
		if (A1 && (r == RBase || r == ROffset)) early = true;
		// B2: a flag-setting late consumer of a load takes the early path.
		if (B2 && r == RLateFlag) early = true;
		// B3: no load word in A's late bypass: every load consumer is early.
		if (B3) early = true;
		int sp = early ? 3 : 2;
		if (A2) sp += 1;                       // L stage: 3/5/6
		if (C2 && p == PLoadSub) sp += 1;      // sub-word format in W
		return sp;
	}
	if (p == PMult) return r == REarly ? 4 : 3;
	if (p == PWriteback) {
		// A1: the AGU forwards its own registered result to the next base.
		if (A1 && (r == RBase || r == ROffset)) return 1;
		return r == REarly ? 2 : 1;
	}
	if (p == PAlu) {
		if (A1 && (r == RBase || r == ROffset)) return 2;
		return r == REarly ? 2 : 1;
	}
	return 0;
}

struct Counts {
	uint64_t instructions = 0, slots = 0, clocks = 0;
	uint64_t loads = 0, loads_sub = 0, ldm = 0, ldm_words = 0, stores = 0, mem_ops = 0, pc_loads = 0;
	uint64_t scaled_offset = 0;
	// first consumer of a scalar/LDM load's destination: [distance 1..4, 5=none within 4][role]
	std::array<std::array<uint64_t, 5>, 6> first{};
	std::array<std::array<uint64_t, 5>, 6> first_sub{};
	// memory ops whose base or register offset comes from a producer at distance 1/2/3:
	// [producer kind][distance-1]
	std::array<std::array<uint64_t, 3>, 6> base_from{};
	std::array<uint64_t, 4> dcache{};  // load fills, store fills, write-backs, uncached completions
	uint64_t cp15 = 0;
	std::array<uint64_t, NS> model{};
};

class Observer {
public:
	bool enabled = false;
	FILE *out = nullptr;
	Counts total, seg;
	uint64_t seg_start = 0;

	void open(const std::string &path) {
		out = fopen(path.c_str(), "w");
		enabled = out != nullptr;
		if (out) {
			fprintf(out, "# load_use: per segment; costs are added clocks of each scenario over the baseline model\n");
			fflush(out);
		}
	}

	// every clock: the D-cache event taps (one bit each)
	void clock(uint8_t dcache) {
		if (!enabled) return;
		total.clocks++;
		for (unsigned b = dcache & 15; b; b &= b - 1) total.dcache[__builtin_ctz(b)]++;
	}

	// a pipeline flush (exception entry, mode change): no producer survives
	void barrier() {
		for (auto &r : regs_) r.prod = PNone;
	}

	// a retired instruction: the expanded ARM word, condition passed, Thumb
	void retire(uint32_t ins, bool passed, bool thumb) {
		if (!enabled) return;
		total.instructions++;
		Decoded d = decode(ins, thumb);
		// first-consumer bookkeeping for loads and the base-producer mix
		for (int k = 0; k < d.nreads; k++) {
			auto &rd = d.reads[k];
			auto &r = regs_[rd.reg];
			if (r.prod == PNone) continue;
			const uint64_t dist = slot_ - r.slot;
			if ((rd.role == RBase || rd.role == ROffset) && dist >= 1 && dist <= 3)
				total.base_from[r.prod][dist - 1]++;
			if ((r.prod == PLoadWord || r.prod == PLoadSub) && !r.consumed) {
				r.consumed = true;
				const int di = dist >= 1 && dist <= 4 ? int(dist - 1) : 4;
				(r.prod == PLoadSub ? total.first_sub : total.first)[di][rd.role]++;
			}
		}
		if (d.mem && d.scaled) total.scaled_offset++;
		// the issue model, per scenario
		for (int s = 0; s < NS; s++) {
			uint64_t t = time_[s];
			for (int k = 0; k < d.nreads; k++) {
				auto &r = regs_[d.reads[k].reg];
				if (r.prod == PNone) continue;
				const uint64_t ready = r.time[s] + spacing(s, r.prod, d.reads[k].role);
				if (ready > t) t = ready;
			}
			issue_[s] = t;
			uint64_t occ = d.occupancy;
			if ((s == 1 || s == 6) && d.mem && d.scaled) occ += 1;  // A1: rotator then adder
			time_[s] = t + occ;
		}
		// writes (only when the condition passed)
		if (passed) {
			for (int k = 0; k < d.nwrites; k++) {
				auto &w = d.writes[k];
				auto &r = regs_[w.reg];
				r.prod = w.prod;
				r.slot = slot_ + w.offset;
				r.consumed = false;
				for (int s = 0; s < NS; s++) r.time[s] = issue_[s] + w.offset;
			}
			if (d.load) {
				if (d.ldm) {
					total.ldm++;
					total.ldm_words += d.nwrites - (d.writeback ? 1 : 0);
				} else {
					total.loads++;
					total.loads_sub += d.sub;
				}
				total.pc_loads += d.pc_load;
			}
			total.stores += d.store;
			total.mem_ops += d.mem;
			total.cp15 += d.cp15;
		}
		slot_ += d.occupancy;
		total.slots += d.occupancy;
		if (d.mode_change && passed) barrier();
	}

	void mark(const char *label, uint64_t clock) {
		if (!enabled) return;
		for (int s = 0; s < NS; s++) total.model[s] = time_[s];
		Counts c = sub(total, seg);
		write(label, seg_start, clock, c);
		seg = total;
		seg_start = clock;
	}
	void finish(uint64_t clock) {
		if (!enabled) return;
		mark("end", clock);
		for (int s = 0; s < NS; s++) total.model[s] = time_[s];
		write("whole", 0, clock, total);
		fclose(out);
		out = nullptr;
		enabled = false;
	}

private:
	struct Reg {
		Prod prod = PNone;
		bool consumed = true;
		uint64_t slot = 0;
		std::array<uint64_t, NS> time{};
	};
	struct Read { uint8_t reg; Role role; };
	struct Write { uint8_t reg; Prod prod; uint8_t offset; };
	struct Decoded {
		int nreads = 0, nwrites = 0;
		Read reads[20];
		Write writes[17];
		uint8_t occupancy = 1;
		bool load = false, store = false, mem = false, ldm = false, sub = false, scaled = false, writeback = false;
		bool pc_load = false, pc_write = false, mode_change = false, cp15 = false;
		void rd(unsigned r, Role role) { if (r < 15 && nreads < 20) reads[nreads++] = {uint8_t(r), role}; }
		void wr(unsigned r, Prod p, unsigned off = 0) { if (r < 15 && nwrites < 17) writes[nwrites++] = {uint8_t(r), p, uint8_t(off)}; }
	};
	std::array<Reg, 16> regs_{};
	std::array<uint64_t, NS> time_{}, issue_{};
	uint64_t slot_ = 0;

	static Decoded decode(uint32_t i, bool thumb) {
		Decoded d;
		const unsigned rn = (i >> 16) & 15, rd = (i >> 12) & 15, rs = (i >> 8) & 15, rm = i & 15;
		// Thumb BL halves are NV-coded markers in the shared expander
		if (thumb && ((i & 0xfffff800) == 0xf0000000 || (i & 0xfffff800) == 0xf0001000)) {
			if (i & 0x00001000) { d.rd(14, RLate); d.pc_write = true; }
			d.wr(14, PAlu);
			return d;
		}
		if ((i >> 28) == 15) return d;
		if ((i & 0x0f000000) == 0x0f000000) { d.mode_change = true; return d; }       // SWI
		if ((i & 0x0ffffff0) == 0x012fff10) { d.rd(rm, RLate); d.pc_write = true; return d; }  // BX
		if ((i & 0x0e000000) == 0x0a000000) {                                            // B/BL
			if (i & (1u << 24)) d.wr(14, PAlu);
			d.pc_write = true;
			return d;
		}
		if ((i & 0x0e000000) == 0x08000000) {                                            // LDM/STM
			const bool L = i & (1u << 20), W = i & (1u << 21), S = i & (1u << 22);
			const unsigned list = i & 0xffff;
			unsigned n = __builtin_popcount(list);
			d.rd(rn, REarly);
			d.mem = true;
			d.occupancy = uint8_t(n ? n : 1);
			unsigned k = 0;
			for (unsigned r = 0; r < 16; r++)
				if (list & (1u << r)) {
					if (L) d.wr(r, PLoadWord, k);
					else d.rd(r, RLate);
					k++;
				}
			if (W && !(L && (list & (1u << rn)))) { d.wr(rn, PWriteback); d.writeback = true; }
			if (L) { d.load = true; d.ldm = true; d.pc_load = list & 0x8000; d.pc_write = list & 0x8000;
			         if (S && (list & 0x8000)) d.mode_change = true; }
			else d.store = true;
			return d;
		}
		if ((i & 0x0fc000f0) == 0x00000090) {                                            // MUL/MLA
			d.rd(rm, REarly); d.rd(rs, REarly);
			if (i & (1u << 21)) { d.rd(rd, RLate); d.occupancy = 3; } else d.occupancy = 2;
			d.wr(rn, PMult);
			return d;
		}
		if ((i & 0x0f8000f0) == 0x00800090) {                                            // long multiply
			d.rd(rm, REarly); d.rd(rs, REarly);
			if (i & (1u << 21)) { d.rd(rn, RLate); d.rd(rd, RLate); d.occupancy = 3; } else d.occupancy = 2;
			d.wr(rd, PMult); d.wr(rn, PMult);
			return d;
		}
		if ((i & 0x0fb00ff0) == 0x01000090) {                                            // SWP
			d.rd(rn, RBase); d.rd(rm, RLate);
			d.wr(rd, (i & (1u << 22)) ? PLoadSub : PLoadWord);
			d.load = d.store = d.mem = true;
			d.sub = i & (1u << 22);
			d.occupancy = 2;
			return d;
		}
		if ((i & 0x0fbf0fff) == 0x010f0000) { d.wr(rd, PAlu); return d; }                // MRS
		if ((i & 0x0db0f000) == 0x0120f000) {                                            // MSR
			if (!(i & (1u << 25))) d.rd(rm, RLate);
			if ((i & (1u << 16)) && !(i & (1u << 22))) d.mode_change = true;
			return d;
		}
		if ((i & 0x0f000010) == 0x0e000010) {                                            // MRC/MCR
			d.cp15 = true;
			if (i & (1u << 20)) d.wr(rd, PAlu); else d.rd(rd, RLate);
			return d;
		}
		if ((i & 0x0e000090) == 0x00000090 && (i & 0x60)) {                             // LDRH/STRH/LDRSB/LDRSH
			const bool P = i & (1u << 24), I = i & (1u << 22), W = i & (1u << 21), L = i & (1u << 20);
			d.rd(rn, RBase);
			if (!I) d.rd(rm, ROffset);
			d.mem = true;
			if (L) { d.wr(rd, PLoadSub); d.load = true; d.sub = true; }
			else { d.rd(rd, RLate); d.store = true; }
			if (!P || W) { d.wr(rn, PWriteback); d.writeback = true; }
			return d;
		}
		if ((i & 0x0c000000) == 0x04000000) {                                            // LDR/STR
			const bool I = i & (1u << 25), P = i & (1u << 24), B = i & (1u << 22), W = i & (1u << 21),
			           L = i & (1u << 20);
			d.rd(rn, RBase);
			if (I) {
				const bool scaled = ((i >> 7) & 31) != 0 || ((i >> 5) & 3) != 0;
				d.scaled = scaled;
				d.rd(rm, scaled ? REarly : ROffset);
			}
			d.mem = true;
			if (L) {
				d.load = true;
				d.sub = B;
				if (rd == 15) { d.pc_load = true; d.pc_write = true; }
				else d.wr(rd, B ? PLoadSub : PLoadWord);
			} else { d.rd(rd, RLate); d.store = true; }
			if (!P || W) { d.wr(rn, PWriteback); d.writeback = true; }
			return d;
		}
		if ((i & 0x0c000000) == 0x00000000) {                                            // data processing
			const unsigned op = (i >> 21) & 15;
			const bool S = i & (1u << 20), I = i & (1u << 25);
			const bool cmp = op >= 8 && op <= 11, mov = op == 13 || op == 15;
			const Role late = (S || cmp) ? RLateFlag : RLate;
			if (!mov) d.rd(rn, late);
			if (!I) {
				if (i & 0x10) { d.rd(rs, REarly); d.rd(rm, REarly); d.occupancy = 2; }
				else {
					const bool shifted = ((i >> 7) & 31) != 0 || ((i >> 5) & 3) != 0;
					d.rd(rm, shifted ? REarly : late);
				}
			}
			if (!cmp) {
				if (rd == 15) { d.pc_write = true; if (S) d.mode_change = true; }
				else d.wr(rd, PAlu);
			}
			return d;
		}
		return d;
	}

	static Counts sub(const Counts &a, const Counts &b) {
		Counts c = a;
		c.instructions -= b.instructions; c.slots -= b.slots; c.clocks -= b.clocks;
		c.loads -= b.loads; c.loads_sub -= b.loads_sub; c.ldm -= b.ldm; c.ldm_words -= b.ldm_words;
		c.stores -= b.stores; c.mem_ops -= b.mem_ops; c.pc_loads -= b.pc_loads; c.scaled_offset -= b.scaled_offset;
		c.cp15 -= b.cp15;
		for (int x = 0; x < 6; x++)
			for (int y = 0; y < 5; y++) { c.first[x][y] -= b.first[x][y]; c.first_sub[x][y] -= b.first_sub[x][y]; }
		for (int x = 0; x < 6; x++)
			for (int y = 0; y < 3; y++) c.base_from[x][y] -= b.base_from[x][y];
		for (int x = 0; x < 4; x++) c.dcache[x] -= b.dcache[x];
		for (int s = 0; s < NS; s++) c.model[s] -= b.model[s];
		return c;
	}

	void write(const char *label, uint64_t from, uint64_t to, const Counts &c) {
		if (!out) return;
		fprintf(out, "segment %s clocks %" PRIu64 "-%" PRIu64 " (%" PRIu64 ") instructions %" PRIu64 " slots %" PRIu64 "\n",
		        label, from, to, to - from, c.instructions, c.slots);
		fprintf(out, "  loads %" PRIu64 " (sub-word %" PRIu64 ") ldm %" PRIu64 " (words %" PRIu64 ") stores %" PRIu64
		             " mem_ops %" PRIu64 " pc_loads %" PRIu64 " scaled_offset %" PRIu64 " cp15 %" PRIu64 "\n",
		        c.loads, c.loads_sub, c.ldm, c.ldm_words, c.stores, c.mem_ops, c.pc_loads, c.scaled_offset, c.cp15);
		fprintf(out, "  dcache load_fills %" PRIu64 " store_fills %" PRIu64 " writebacks %" PRIu64 " uncached %" PRIu64 "\n",
		        c.dcache[0], c.dcache[1], c.dcache[2], c.dcache[3]);
		static const char *roles[5] = {"late", "late_flag", "early", "base", "offset"};
		for (int sub = 0; sub < 2; sub++) {
			const auto &f = sub ? c.first_sub : c.first;
			fprintf(out, "  first consumer of %s loads (distance 1/2/3/4, then none<=4 per role):", sub ? "sub-word" : "word/LDM");
			for (int r = 0; r < 5; r++) {
				fprintf(out, " %s", roles[r]);
				for (int x = 0; x < 5; x++) fprintf(out, "%c%" PRIu64, x ? '/' : '=', f[x][r]);
			}
			fprintf(out, "\n");
		}
		static const char *prods[6] = {"none", "load_word", "load_sub", "alu", "writeback", "mult"};
		fprintf(out, "  base/offset producer at distance 1/2/3:");
		for (int p = 1; p < 6; p++) fprintf(out, " %s=%" PRIu64 "/%" PRIu64 "/%" PRIu64, prods[p], c.base_from[p][0], c.base_from[p][1], c.base_from[p][2]);
		fprintf(out, "\n  model clocks:");
		for (int s = 0; s < NS; s++) fprintf(out, " %s=%" PRIu64, scenario_names[s], c.model[s]);
		fprintf(out, "\n  added over baseline:");
		for (int s = 1; s < NS; s++) fprintf(out, " %s=%" PRId64, scenario_names[s], int64_t(c.model[s] - c.model[0]));
		fprintf(out, "\n");
		fflush(out);
	}
};

}  // namespace load_use
