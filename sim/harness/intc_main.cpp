// Bench for rtl/upp/upp_intc.sv: the interrupt controller and the OS-timer
// interrupt unit against a C++ port of the reference model's register
// semantics (model/hw/ngage_intc.c).
//
//   Vupp_intc [--seed N] [--cycles N]
//
//  * random source levels (sparse and dense patterns, single sources, all of a
//    bank), enable set/clear writes on both planes of all three banks, reads of
//    every register: enable, the 0 of +0x0C, pending, and the active-source
//    number (1 + the lowest pending enabled source, 0 for none) against the
//    model;
//  * offsets the model keeps as storage are left to upp_periph (rmask 0);
//  * irq and fiq follow the enabled pending sources of their plane (a clock
//    later, registered), fiq also the OS-timer status under its enable;
//  * the OS-timer status: set by ost_set, cleared by writing 1s to +0x10,
//    read back; its enable at +0x04;
//  * reset clears the enables.
#include "Vupp_intc.h"
#include "verilated.h"
#include "common.h"

#include <cstring>

namespace {

struct Model {
	uint32_t en[6] = {};               // IRQ banks 0-2, FIQ banks 3-5
	uint32_t ost_status = 0, ost_en = 0;
	uint32_t src[3] = {};

	static int lowest(uint32_t v) {
		for (int i = 0; i < 32; i++) if (v >> i & 1) return i + 1;
		return 0;
	}
	// rmask, rdata of a read at page offset off
	void read(uint32_t off, uint32_t &mask, uint32_t &data) const {
		mask = 0; data = 0;
		if (off >= 0x40 && off < 0x80) {
			if (off == 0x50) { mask = ~0u; data = ost_status; }
			return;
		}
		int idx = (off - 0x100) >> 6, bank = idx % 3;
		switch (off & 0x3F) {
		case 0x08: mask = ~0u; data = en[idx]; break;
		case 0x0C: mask = ~0u; data = 0; break;
		case 0x10: mask = ~0u; data = src[bank]; break;
		case 0x14: mask = ~0u; data = (uint32_t)lowest(src[bank] & en[idx]); break;
		default: break;
		}
	}
	void write(uint32_t off, uint32_t v) {
		if (off >= 0x40 && off < 0x80) {
			if (off == 0x44) ost_en = v & 7;
			if (off == 0x50) ost_status &= ~v & 7;
			return;
		}
		int idx = (off - 0x100) >> 6;
		if ((off & 0x3F) == 0x08) en[idx] |= v;
		if ((off & 0x3F) == 0x0C) en[idx] &= ~v;
	}
	bool irq() const { return (src[0] & en[0]) || (src[1] & en[1]) || (src[2] & en[2]); }
	bool fiq() const { return (src[0] & en[3]) || (src[1] & en[4]) || (src[2] & en[5]) || (ost_status & ost_en & 7); }
};

uint32_t random_offset(sim::Rng &rng) {
	if (rng.chance(15)) return 0x40 + 4 * rng.range(0, 15);
	uint32_t base = 0x100 + 0x40 * rng.range(0, 5);
	static const uint32_t regs[] = {0x08, 0x0C, 0x10, 0x14};
	return base + (rng.chance(85) ? regs[rng.range(0, 3)] : 4 * rng.range(0, 15));
}

uint32_t random_bits(sim::Rng &rng) {
	switch (rng.range(0, 5)) {
	case 0: return 0;
	case 1: return 1u << rng.range(0, 31);
	case 2: return ~0u;
	case 3: return rng.u32() & rng.u32() & rng.u32();
	default: return rng.u32();
	}
}

}  // namespace

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	uint32_t seed = 1;
	uint64_t cycles = 400000;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = (uint32_t)strtoul(argv[++i], nullptr, 0);
		if (!strcmp(argv[i], "--cycles") && i + 1 < argc) cycles = strtoull(argv[++i], nullptr, 0);
	}
	sim::Rng rng(seed);
	Vupp_intc *t = new Vupp_intc;
	Model m;

	auto set_src = [&]() {
		t->src[0] = m.src[0];
		t->src[1] = m.src[1];
		t->src[2] = m.src[2];
	};
	auto edge = [&]() {
		t->clk = 0; t->eval();
		t->clk = 1; t->eval();
	};

	t->reset = 1; t->acc = 0; t->wr = 0; t->off = 0; t->wdata = 0; t->ost_set = 0;
	set_src();
	for (int i = 0; i < 3; i++) edge();
	t->reset = 0;

	bool want_irq = false, want_fiq = false;
	uint64_t reads = 0, writes = 0, numbers = 0, nonzero_numbers = 0;
	for (uint64_t c = 0; c < cycles; c++) {
		// the sources change now and then
		if (rng.chance(3)) m.src[rng.range(0, 2)] = random_bits(rng);
		if (rng.chance(1)) m.src[rng.range(0, 2)] ^= 1u << rng.range(0, 31);
		set_src();
		uint32_t ost = rng.chance(2) ? (uint32_t)rng.range(1, 7) : 0;
		t->ost_set = ost;

		int what = rng.range(0, 9);
		t->acc = 0; t->wr = 0;
		uint32_t off = random_offset(rng), v = random_bits(rng);
		if (what < 4) {
			t->acc = 1; t->wr = 1; t->off = off; t->wdata = v;
		} else if (what < 8) {
			t->acc = 1; t->off = off;
		}
		t->eval();

		if (t->irq != want_irq) sim::fail("cycle %llu: irq %d, want %d", (unsigned long long)c, t->irq, want_irq);
		if (t->fiq != want_fiq) sim::fail("cycle %llu: fiq %d, want %d", (unsigned long long)c, t->fiq, want_fiq);
		if (t->acc && !t->wr) {
			uint32_t mask, data;
			m.read(off, mask, data);
			reads++;
			if (t->rmask != mask) sim::fail("read 0x%03x: rmask 0x%08x, want 0x%08x", off, t->rmask, mask);
			else if ((t->rdata & mask) != (data & mask)) sim::fail("read 0x%03x: 0x%08x, want 0x%08x", off, t->rdata & mask, data);
			if ((off & 0x3F) == 0x14 && off >= 0x100) { numbers++; nonzero_numbers += data != 0; }
		}

		// the edge: irq/fiq register what they see now; then the write and the
		// OS-timer sources
		want_irq = m.irq();
		want_fiq = m.fiq();
		if (t->wr) { m.write(off, v); writes++; }
		m.ost_status |= ost;
		edge();

		// a reset now and then
		if (rng.chance(0) || (c % 100000) == 99999) {
			t->reset = 1; t->acc = 0; t->wr = 0;
			edge();
			t->reset = 0;
			for (int i = 0; i < 6; i++) m.en[i] = 0;
			m.ost_status = 0; m.ost_en = 0;
			want_irq = want_fiq = false;
			t->eval();
		}
	}

	// directed: the number register picks the lowest pending enabled source
	for (int bank = 0; bank < 3; bank++) {
		for (int plane = 0; plane < 2; plane++) {
			uint32_t base = (plane ? 0x1C0 : 0x100) + 0x40 * bank;
			for (int b = 0; b < 32; b++) {
				m.src[bank] = ~0u << b;
				set_src();
				t->acc = 1; t->wr = 1; t->off = base + 0x0C; t->wdata = ~0u; t->eval(); edge(); m.write(base + 0x0C, ~0u);
				t->off = base + 0x08; t->wdata = 1u << b | 1u << 31; t->eval(); edge(); m.write(base + 0x08, 1u << b | 1u << 31);
				t->wr = 0; t->off = base + 0x14; t->eval();
				CHECK_EQ(t->rdata, (uint32_t)(b + 1), "active source number");
				t->acc = 0; t->eval(); edge();
			}
		}
	}

	printf("intc: %llu reads (%llu number reads, %llu nonzero), %llu writes\n", (unsigned long long)reads,
	       (unsigned long long)numbers, (unsigned long long)nonzero_numbers, (unsigned long long)writes);
	t->final();
	delete t;
	return sim::finish("upp_intc");
}
