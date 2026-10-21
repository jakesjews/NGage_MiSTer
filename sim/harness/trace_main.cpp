// Bench for rtl/mister/dbg_trace.sv: the trace rings and their dump.
//
//   Vdbg_trace [--seed N]
//
//  * random retired instructions and exceptions, data-port accesses and bus
//    beats go in; an abort (or trig_in) starts a dump through the loader
//    port, modelled here with random busy clocks;
//  * the dump's header names the trigger, the clock and the write pointers;
//    the rings hold the newest entries in order, each with the clock it was
//    taken at, and the triggering event is the last entry;
//  * while a dump runs nothing is recorded; afterwards recording resumes
//    and a second dump, at the next region, shows the newer entries;
//  * a write left waiting by the port is held unchanged (Avalon); only
//    MAX_DUMPS dumps are written, later triggers are only counted.
#include "Vdbg_trace.h"
#include "Vdbg_trace___024root.h"
#include "verilated.h"
#include "common.h"

#include <cstring>
#include <map>
#include <vector>

namespace {

constexpr uint64_t BASE = 0x33000000ull;
constexpr uint64_t DUMP_BYTES = 0x40000;
constexpr int PC_N = 8192, D_N = 4096, B_N = 2048;

struct PcEv { uint64_t cyc; uint32_t pc, cpsr, cpsr_nxt; int ev; };
struct DEv  { uint64_t cyc; uint32_t va, data; int sel, we; };
struct BEv  { uint64_t cyc; uint32_t adr, data; int sel, we, err, cti; };

struct Bench {
	Vdbg_trace *t = new Vdbg_trace;
	sim::Rng rng;
	uint64_t cyc = 0;
	// the DDR3 words the loader port took: byte address -> word
	std::map<uint64_t, uint64_t> ddr;
	bool busy = false, waiting = false;
	uint32_t w_addr = 0;
	uint64_t w_din = 0;
	// what went in: an event driven in a clock is in the rings two edges
	// later, if the trace was recording at that edge (not during a dump)
	std::vector<PcEv> pcs;
	std::vector<DEv> ds;
	std::vector<BEv> bs;
	struct Pending { bool pc = false, d = false, b = false; PcEv pe; DEv de; BEv be; } cur, prev;

	explicit Bench(uint32_t seed) : rng(seed) {}

	void clear_inputs() {
		t->wb_valid = t->wb_dvalid = t->wb_uop_last = 0;
		t->wb_dabt = 0;
		t->wb_pabt = t->wb_und = t->wb_swi = t->wb_irq = t->wb_fiq = 0;
		t->d_done = 0;
		t->b_ack = 0;
		t->trig_in = 0;
	}

	// one clock: the inputs are already driven; the port model answers
	void tick() {
		t->ld_busy = busy;
		t->eval();
		if (t->rootp->dbg_trace__DOT__tracing) {
			if (prev.pc) pcs.push_back(prev.pe);
			if (prev.d) ds.push_back(prev.de);
			if (prev.b) bs.push_back(prev.be);
		}
		prev = cur;
		cur = Pending();
		if (t->ld_we) {
			if (t->ld_be != 0xFF) sim::fail("ld_be 0x%x", (unsigned)t->ld_be);
			if (waiting && (t->ld_addr != w_addr || t->ld_din != w_din))
				sim::fail("a write left waiting changed (cycle %llu)", (unsigned long long)cyc);
			w_addr = t->ld_addr;
			w_din = t->ld_din;
			if (!busy) {
				ddr[(uint64_t)t->ld_addr << 3] = t->ld_din;
				waiting = false;
			} else {
				waiting = true;
			}
		} else if (waiting) {
			sim::fail("a write left waiting was withdrawn (cycle %llu)", (unsigned long long)cyc);
			waiting = false;
		}
		t->clk = 1;
		t->eval();
		t->clk = 0;
		t->eval();
		cyc++;
		busy = rng.chance(30);
	}

	// a clock of random traffic
	void traffic() {
		clear_inputs();
		if (rng.chance(60)) {
			PcEv e;
			e.cyc = cyc;
			e.pc = rng.u32() & ~3u;
			e.cpsr = rng.u32();
			e.cpsr_nxt = rng.u32();
			int k = rng.range(0, 99);
			e.ev = k < 90 ? 1 : k < 95 ? 2 : k < 98 ? 6 : 7;   // retired, SWI, IRQ, FIQ
			t->wb_pc = e.pc;
			t->wb_cpsr = e.cpsr;
			t->wb_cpsr_nxt = e.cpsr_nxt;
			if (e.ev == 1) { t->wb_valid = rng.chance(50); t->wb_dvalid = !t->wb_valid; t->wb_uop_last = 1; }
			else if (e.ev == 2) t->wb_swi = 1;
			else if (e.ev == 6) t->wb_irq = 1;
			else t->wb_fiq = 1;
			cur.pc = true; cur.pe = e;
		} else if (rng.chance(20)) {
			// a uop that is not the last, or a data abort's second flag: no entry
			t->wb_valid = 1;
			t->wb_uop_last = 0;
			t->wb_pc = rng.u32();
			if (rng.chance(50)) t->wb_dabt = 2;
		}
		if (rng.chance(40)) {
			DEv e;
			e.cyc = cyc;
			e.va = rng.u32();
			e.data = rng.u32();
			e.sel = rng.range(1, 15);
			e.we = rng.chance(40);
			t->d_done = 1;
			t->d_we = e.we;
			t->d_va = e.va;
			t->d_sel = e.sel;
			t->d_wdata = e.we ? e.data : rng.u32();
			t->d_rdata = e.we ? rng.u32() : e.data;
			cur.d = true; cur.de = e;
		}
		if (rng.chance(25)) {
			BEv e;
			e.cyc = cyc;
			e.adr = rng.u32() & ~3u;
			e.data = rng.u32();
			e.sel = rng.range(0, 15);
			e.we = rng.chance(40);
			e.err = rng.chance(5);
			e.cti = rng.chance(50) ? 2 : 7;
			t->b_ack = 1;
			t->b_err = e.err;
			t->b_we = e.we;
			t->b_adr = e.adr;
			t->b_sel = e.sel;
			t->b_cti = e.cti;
			t->b_wdata = e.we ? e.data : rng.u32();
			t->b_rdata = e.we ? rng.u32() : e.data;
			cur.b = true; cur.be = e;
		}
	}

	uint64_t word(int dump, uint64_t off) {
		uint64_t a = BASE + dump * DUMP_BYTES + off * 8;
		auto it = ddr.find(a);
		if (it == ddr.end()) { sim::fail("dump %d: word 0x%llx not written", dump, (unsigned long long)off); return 0; }
		return it->second;
	}

	// the dump holds the newest entries, newest last, the trigger last of all
	void check_dump(int dump, int reason, uint32_t trig_pc, uint64_t trig_cyc) {
		uint64_t magic = word(dump, 0);
		CHECK(magic == 0x4352544547414741ull + 0xDull, "dump %d: magic %016llx", dump, (unsigned long long)magic);
		uint64_t clk = word(dump, 1);
		uint64_t w2 = word(dump, 2);
		CHECK_EQ(w2 >> 56, dump, "dump number");
		CHECK_EQ((w2 >> 48) & 0xFF, reason, "reason");
		int pc_w = (int)((w2 >> 32) & 0xFFFF), d_w = (int)((w2 >> 16) & 0xFFFF), b_w = (int)(w2 & 0xFFFF);
		CHECK_EQ(pc_w, pcs.size() % PC_N, "pc write pointer");
		CHECK_EQ(d_w, ds.size() % D_N, "data write pointer");
		CHECK_EQ(b_w, bs.size() % B_N, "bus write pointer");
		uint64_t w3 = word(dump, 3), w4 = word(dump, 4), w5 = word(dump, 5);
		size_t retired = 0;
		for (auto &e : pcs) if (e.ev == 1) retired++;
		CHECK_EQ(w3 >> 32, retired, "retired count");
		CHECK_EQ(w4 >> 32, ds.size(), "data count");
		CHECK_EQ(w4 & 0xFFFFFFFFu, bs.size(), "bus count");
		if (trig_pc != 0xFFFFFFFFu) CHECK_EQ(w5 & 0xFFFFFFFFu, trig_pc, "trigger pc");
		// the rings, newest first; the clock fields run with the bench's cycles
		size_t npc = std::min(pcs.size(), (size_t)PC_N);
		int64_t base_delta = 0;
		bool have_base = false;
		for (size_t k = 0; k < npc; k++) {
			const PcEv &e = pcs[pcs.size() - 1 - k];
			int idx = ((pc_w - 1 - (int)k) % PC_N + PC_N) % PC_N;
			uint64_t v = word(dump, 0x2000 + idx);
			char what[64];
			snprintf(what, sizeof what, "pc entry -%zu", k);
			CHECK_EQ(v & 0xFFFFFFFFu, e.pc, what);
			CHECK_EQ((v >> 32) & 0xFF, e.cpsr & 0xFF, what);
			CHECK_EQ((v >> 56) & 0xF, e.ev, what);
			CHECK_EQ(v >> 60, e.cpsr_nxt >> 28, what);
			int64_t delta = (int64_t)((v >> 40) & 0xFFFF) - (int64_t)(e.cyc & 0xFFFF);
			delta = ((delta % 65536) + 65536) % 65536;
			if (!have_base) { base_delta = delta; have_base = true; }
			else CHECK(delta == base_delta, "%s: clock skew %lld vs %lld", what, (long long)delta, (long long)base_delta);
			// an exception trigger is the last entry, taken at the trigger's clock
			if (k == 0 && (reason & 1)) CHECK_EQ(clk & 0xFFFF, (v >> 40) & 0xFFFF, "trigger clock vs last entry");
		}
		CHECK(((int64_t)((clk - trig_cyc) & 0xFFFF)) == base_delta, "trigger clock");
		size_t nd = std::min(ds.size(), (size_t)D_N);
		for (size_t k = 0; k < nd; k++) {
			const DEv &e = ds[ds.size() - 1 - k];
			int idx = ((d_w - 1 - (int)k) % D_N + D_N) % D_N;
			uint64_t w0 = word(dump, 0x4000 + 2 * idx), w1 = word(dump, 0x4000 + 2 * idx + 1);
			char what[64];
			snprintf(what, sizeof what, "data entry -%zu", k);
			CHECK_EQ(w0 & 0xFFFFFFFFu, e.va, what);
			CHECK_EQ(w1 >> 32, e.data, what);
			CHECK_EQ((w1 >> 16) & 1, e.we, what);
			CHECK_EQ((w1 >> 8) & 0xF, e.sel, what);
			int64_t delta = (int64_t)(w0 >> 32) - (int64_t)(e.cyc & 0xFFFFFFFFu);
			delta = ((delta % 65536) + 65536) % 65536;
			CHECK(delta == base_delta, "%s: clock skew %lld", what, (long long)delta);
		}
		size_t nb = std::min(bs.size(), (size_t)B_N);
		for (size_t k = 0; k < nb; k++) {
			const BEv &e = bs[bs.size() - 1 - k];
			int idx = ((b_w - 1 - (int)k) % B_N + B_N) % B_N;
			uint64_t w0 = word(dump, 0x6000 + 2 * idx), w1 = word(dump, 0x6000 + 2 * idx + 1);
			char what[64];
			snprintf(what, sizeof what, "bus entry -%zu", k);
			CHECK_EQ(w0 & 0xFFFFFFFFu, e.adr, what);
			CHECK_EQ(w1 >> 32, e.data, what);
			CHECK_EQ((w1 >> 19) & 1, e.err, what);
			CHECK_EQ((w1 >> 18) & 1, e.we, what);
			CHECK_EQ((w1 >> 13) & 7, e.cti, what);
			CHECK_EQ((w1 >> 8) & 0xF, e.sel, what);
			int64_t delta = (int64_t)(w0 >> 32) - (int64_t)(e.cyc & 0xFFFFFFFFu);
			delta = ((delta % 65536) + 65536) % 65536;
			CHECK(delta == base_delta, "%s: clock skew %lld", what, (long long)delta);
		}
	}

	// an exception (ev 3, 4, 5) or trig_in; returns its cycle
	uint64_t trigger(int ev, uint32_t pc) {
		clear_inputs();
		uint64_t c = cyc;
		if (ev == 0) {
			t->trig_in = 1;
		} else {
			PcEv e;
			e.cyc = cyc;
			e.pc = pc;
			e.cpsr = rng.u32();
			e.cpsr_nxt = rng.u32();
			e.ev = ev;
			t->wb_pc = e.pc;
			t->wb_cpsr = e.cpsr;
			t->wb_cpsr_nxt = e.cpsr_nxt;
			if (ev == 3) t->wb_und = 1;
			else if (ev == 4) t->wb_pabt = 1;
			else t->wb_dabt = 1;
			cur.pc = true; cur.pe = e;
		}
		tick();
		clear_inputs();
		return c;
	}

	// wait for a dump to finish (it starts two clocks after the trigger)
	bool wait_dump(uint64_t max) {
		uint64_t start = cyc;
		while (cyc - start < max) {
			traffic();               // traffic during a dump is dropped
			tick();
			if (cyc - start > 4 && !t->dumping) return true;
		}
		return false;
	}
};

}  // namespace

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	uint32_t seed = 1;
	for (int i = 1; i < argc; i++)
		if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = (uint32_t)strtoul(argv[++i], nullptr, 0);
	Bench b(seed);
	Vdbg_trace *t = b.t;
	b.clear_inputs();
	t->clk = 0;
	t->reset = 1;
	t->cpu_reset = 1;
	for (int i = 0; i < 4; i++) b.tick();
	t->reset = 0;
	for (int i = 0; i < 4; i++) b.tick();
	t->cpu_reset = 0;
	for (int i = 0; i < 4; i++) b.tick();

	// enough traffic to wrap every ring
	for (int i = 0; i < 20000; i++) { b.traffic(); b.tick(); }
	CHECK_EQ(t->dumping, 0, "dumping before a trigger");
	CHECK_EQ(t->dumps, 0, "dumps before a trigger");

	// dump 0: a data abort
	uint64_t c0 = b.trigger(5, 0x503A879Cu);
	CHECK(b.wait_dump(200000), "dump 0 did not finish");
	CHECK_EQ(t->dumps, 1, "dumps after dump 0");
	CHECK_EQ(t->triggers, 1, "triggers after dump 0");
	CHECK_EQ(t->trig_pc, 0x503A879Cu, "first trigger pc");
	b.check_dump(0, 1, 0x503A879Cu, c0);

	// dump 1: after more traffic, trig_in
	for (int i = 0; i < 3000; i++) { b.traffic(); b.tick(); }
	uint64_t c1 = b.trigger(0, 0);
	CHECK(b.wait_dump(200000), "dump 1 did not finish");
	CHECK_EQ(t->dumps, 2, "dumps after dump 1");
	b.check_dump(1, 2, 0xFFFFFFFFu, c1);   // word 5 is the stage's PC then, whatever it holds

	// dumps 2 and 3, then no more
	for (int k = 2; k < 6; k++) {
		for (int i = 0; i < 500; i++) { b.traffic(); b.tick(); }
		uint64_t c = b.trigger(k & 1 ? 4 : 3, 0x1000u * k);
		if (k < 4) {
			CHECK(b.wait_dump(200000), "dump %d did not finish", k);
			CHECK_EQ(t->dumps, k + 1, "dumps");
			b.check_dump(k, 1, 0x1000u * k, c);
		} else {
			for (int i = 0; i < 50; i++) { b.traffic(); b.tick(); }
			CHECK_EQ(t->dumping, 0, "dumping past MAX_DUMPS");
			CHECK_EQ(t->dumps, 4, "dumps past MAX_DUMPS");
		}
		CHECK_EQ(t->triggers, k + 1, "triggers");
	}
	CHECK_EQ(t->trig_pc, 0x503A879Cu, "first trigger pc kept");
	printf("dbg_trace: %zu pc entries, %zu data, %zu bus, %zu DDR3 words in %llu clocks\n",
	       b.pcs.size(), b.ds.size(), b.bs.size(), b.ddr.size(), (unsigned long long)b.cyc);
	delete t;
	return sim::finish("dbg_trace");
}
