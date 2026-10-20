// Bench for rtl/upp/upp_timers.sv: timers 0-5 against a C++ port of the
// reference model's timer (model/hw/ngage_intc.c), which runs in continuous
// time: a timer started at clock edge s with count C reads C - floor((t - s) /
// 3) after edge t and underflows at edge s + 3C (3 * 2^32 for C = 0).
//
//   Vupp_timers [--seed N] [--cycles N]
//
//  * directed: the boot's and the kernel's use (periodic with reload, the
//    one-shot high-resolution timer re-armed through +0x10, timer 4), each
//    underflow's clock against the model, the live count read back every
//    clock, stop keeping the count, start from +0x10, acknowledge;
//  * random: writes of control (0-3 and others), count, reload, acknowledge
//    and storage offsets, at random clocks on all six timers including the
//    clock edge of an underflow; every read of +0x10 and the interrupt lines
//    every clock against the model.
#include "Vupp_timers.h"
#include "verilated.h"
#include "common.h"

#include <cstring>

namespace {

constexpr uint64_t DIV = 3;

struct Timer {
	bool running = false, irq = false;
	uint64_t start = 0;        // the edge it was (re)started at
	uint32_t start_count = 0;
	uint32_t ctrl = 0, reload = 0, stored = 0;   // stored: +0x10 while stopped

	uint64_t expiry() const { return start + DIV * (start_count ? (uint64_t)start_count : (1ull << 32)); }
	uint32_t count(uint64_t t) const { return start_count - (uint32_t)((t - start) / DIV); }
	// the underflows up to and including edge t
	void advance(uint64_t t) {
		while (running && expiry() <= t) {
			uint64_t e = expiry();
			irq = true;
			if (ctrl & 2) {
				start = e;
				start_count = reload;
			} else {
				running = false;
				stored = 0;
			}
		}
	}
	uint32_t read(uint64_t t) {           // after edge t
		advance(t);
		return running ? count(t) : stored;
	}
	void write(uint64_t t, uint32_t r, uint32_t v) {   // at edge t, after its underflows
		advance(t);
		switch (r) {
		case 0x04:
			if ((v & 3) && !running) {
				running = true; start = t; start_count = stored;
			} else if (!(v & 3) && running) {
				stored = count(t); running = false;
			}
			ctrl = v;
			break;
		case 0x08: irq = false; break;
		case 0x10:
			if (running || (ctrl & 3)) { running = true; start = t; start_count = v; }
			stored = v;
			break;
		case 0x18: reload = v; break;
		default: break;
		}
	}
};

struct Bench {
	Vupp_timers *t = new Vupp_timers;
	sim::Rng rng;
	Timer m[6];
	uint64_t edge_n = 0;        // edges so far; the next is edge_n + 1
	uint64_t irqs_seen = 0, reads = 0;
	uint8_t prev_irq = 0;
	std::vector<uint64_t> irq_edges[6];

	explicit Bench(uint32_t seed) : rng(seed) {
		t->reset = 1; t->acc = 0; t->wr = 0; t->off = 0; t->wdata = 0;
		for (int i = 0; i < 3; i++) clock();
		t->reset = 0;
	}
	~Bench() { t->final(); delete t; }

	// one clock edge with the inputs as set; checks the lines after it
	void clock() {
		t->clk = 0; t->eval();
		t->clk = 1; t->eval();
		edge_n++;
		if (t->reset) return;
		for (int i = 0; i < 6; i++) {
			m[i].advance(edge_n);
			bool got = t->irq >> i & 1;
			if (got != m[i].irq)
				sim::fail("edge %llu: timer %d interrupt %d, want %d", (unsigned long long)edge_n, i, got, m[i].irq);
			if (got && !(prev_irq >> i & 1)) { irqs_seen++; irq_edges[i].push_back(edge_n); }
		}
		prev_irq = t->irq;
	}
	void idle(uint64_t n) {
		t->acc = 0; t->wr = 0;
		for (uint64_t i = 0; i < n; i++) clock();
	}
	void write(int n, uint32_t r, uint32_t v) {
		t->acc = 1; t->wr = 1; t->off = 0xA00 + 0x20 * n + r; t->wdata = v;
		t->eval();
		m[n].write(edge_n + 1, r, v);
		clock();
		t->acc = 0; t->wr = 0;
	}
	uint32_t read(int n) {
		t->acc = 1; t->wr = 0; t->off = 0xA00 + 0x20 * n + 0x10;
		t->eval();
		uint32_t want = m[n].read(edge_n);
		reads++;
		if (t->rmask != 0xFFFFFFFFu) sim::fail("timer %d count: rmask 0x%08x", n, t->rmask);
		if (t->rdata != want) sim::fail("edge %llu: timer %d count 0x%08x, want 0x%08x", (unsigned long long)edge_n, n, t->rdata, want);
		uint32_t v = t->rdata;
		clock();
		t->acc = 0;
		return v;
	}
	void check_storage_offsets(int n) {
		for (uint32_t r = 0; r < 0x20; r += 4) {
			t->acc = 1; t->wr = 0; t->off = 0xA00 + 0x20 * n + r;
			t->eval();
			uint32_t want = r == 0x10 ? ~0u : 0;
			if (t->rmask != want) sim::fail("timer %d +0x%02x: rmask 0x%08x, want 0x%08x", n, r, t->rmask, want);
		}
		t->acc = 0;
	}
};

}  // namespace

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	uint32_t seed = 1;
	uint64_t cycles = 300000;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = (uint32_t)strtoul(argv[++i], nullptr, 0);
		if (!strcmp(argv[i], "--cycles") && i + 1 < argc) cycles = strtoull(argv[++i], nullptr, 0);
	}
	Bench b(seed);
	for (int n = 0; n < 6; n++) b.check_storage_offsets(n);

	// the boot's timer 0: +0x04 = 2 (periodic), +0x10/+0x18 = count, +0x08 = 0
	// (0x31AC), with a short count; underflow every 3 * C clocks
	{
		const uint32_t C = 100;
		b.write(0, 0x10, C);
		b.write(0, 0x18, C);
		b.write(0, 0x08, 0);
		uint64_t s = b.edge_n + 1;
		b.write(0, 0x04, 2);
		for (int k = 0; k < 5; k++) {
			while (b.irq_edges[0].size() <= (size_t)k) b.idle(1);
			CHECK_EQ(b.irq_edges[0][k], s + 3 * C * (k + 1), "timer 0 underflow edge");
			b.write(0, 0x08, 1);
		}
		b.write(0, 0x04, 0);
	}
	// the kernel's tick reload 0x843E2 is 1/64 s at 104/3 MHz: the period in
	// clocks is 3 * 0x843E2 = 1624998 = 15.625 ms at 104 MHz, within a clock
	CHECK_EQ(3 * 0x843E2, 1624998, "tick period in clocks");

	// the high-resolution timer 1: control 1 (one-shot), re-armed by +0x10
	{
		b.write(1, 0x04, 1);                 // count 0: starts a 2^32 run
		b.write(1, 0x10, 40);                // restarts it with 40
		uint64_t s = b.edge_n;
		while (b.irq_edges[1].empty()) b.idle(1);
		CHECK_EQ(b.irq_edges[1][0], s + 3 * 40, "one-shot underflow edge");
		CHECK_EQ(b.read(1), 0, "a one-shot that ran out reads 0");
		b.idle(50);
		CHECK_EQ(b.read(1), 0, "and stays stopped");
		b.write(1, 0x08, 1);                 // the ISR acknowledges without disabling
		b.write(1, 0x10, 7);                 // and re-arms
		s = b.edge_n;
		while (b.irq_edges[1].size() < 2) b.idle(1);
		CHECK_EQ(b.irq_edges[1][1], s + 3 * 7, "re-armed one-shot underflow edge");
		b.write(1, 0x08, 1);
		b.write(1, 0x04, 0);
	}
	// timer 4: the live count steps every 3 clocks; stop keeps it, start goes on
	{
		b.write(4, 0x10, 1000);
		b.write(4, 0x04, 2);
		for (int i = 0; i < 40; i++) b.read(4);
		b.write(4, 0x04, 0);
		uint32_t held = b.read(4);
		b.idle(30);
		CHECK_EQ(b.read(4), held, "a stopped timer keeps its count");
		b.write(4, 0x04, 3);
		for (int i = 0; i < 10; i++) b.read(4);
		b.write(4, 0x04, 0);
	}

	// random operations, including writes at underflow edges
	for (uint64_t c = 0; c < cycles; c++) {
		int n = b.rng.range(0, 5);
		int what = b.rng.range(0, 99);
		if (what < 5) {
			static const uint32_t ctl[] = {0, 1, 2, 3, 0x40, 6};
			b.write(n, 0x04, ctl[b.rng.range(0, 5)]);
		} else if (what < 9) {
			b.write(n, 0x10, b.rng.chance(20) ? 0 : (uint32_t)b.rng.range(1, b.rng.chance(50) ? 20 : 400));
		} else if (what < 12) {
			b.write(n, 0x18, b.rng.chance(10) ? 0 : (uint32_t)b.rng.range(1, b.rng.chance(50) ? 10 : 300));
		} else if (what < 16) {
			b.write(n, 0x08, b.rng.u32());
		} else if (what < 17) {
			static const uint32_t other[] = {0x00, 0x0C, 0x14, 0x1C};
			b.write(n, other[b.rng.range(0, 3)], b.rng.u32());
		} else if (what < 30) {
			b.read(n);
		} else if (what < 33) {
			// land a write exactly on the next underflow edge of a running timer
			Timer &m = b.m[n];
			m.advance(b.edge_n);
			if (m.running && m.expiry() - b.edge_n < 2000 && m.expiry() > b.edge_n + 1) {
				b.idle(m.expiry() - b.edge_n - 1);
				static const uint32_t rr[] = {0x04, 0x08, 0x10};
				uint32_t r = rr[b.rng.range(0, 2)];
				b.write(n, r, r == 0x04 ? (uint32_t)b.rng.range(0, 3) : (uint32_t)b.rng.range(0, 50));
			}
		} else {
			b.idle(b.rng.range(1, 20));
		}
	}

	printf("timers: %llu underflows, %llu count reads\n", (unsigned long long)b.irqs_seen, (unsigned long long)b.reads);
	return sim::finish("upp_timers");
}
