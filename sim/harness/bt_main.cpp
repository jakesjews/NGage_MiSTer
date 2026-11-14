// Bench for rtl/board/bt_module.sv: the Bluetooth module (CBUS device 5)
// against the reference model's (model/hw/ngage_bt_chip.h), which keeps the
// same state. Every read's value and every clock's interrupt pulse are
// compared; the model's timers are the bench's clock count.
//
//   Vbt_module [--seed N] [--ops N] [--session FILE]
//
//  * the phone's own traffic (sim/harness/bt_session.txt, from the model's
//    bt.log): each packet goes in the way btldd.ldd writes it (room asked
//    for and granted, the words, "written" and its acknowledge), each answer
//    comes out the way it reads one (status, length, words) and must be the
//    logged bytes; the driver's reset first; a device search that ends by
//    itself after its 12.8 s;
//  * random traffic: commands of every kind the module knows and of kinds
//    it does not, with random parameters and lengths, read out fully, partly
//    or not at all before the next; packets cut short, with a wrong type
//    byte or written without asking for room; reads and writes of every
//    register in between, also while the module makes its next word (writes
//    only: the bus side holds a read while `busy`); inquiries that end,
//    that are cancelled, that end in the clock of the next access; resets by
//    the phone and at power-on.
// RESET_CLKS and INQ_UNIT_CLKS are small here (the Makefile's -G).
#include "Vbt_module.h"
#include "verilated.h"
#include "common.h"

#include <cstring>
#include <deque>
#include <fstream>
#include <sstream>

#include "../../model/hw/ngage_bt_chip.h"

namespace {

const long RESET_CLKS = 50, INQ_UNIT_CLKS = 200;

struct Op {
	enum Kind { IDLE, RD, WR } kind;
	unsigned reg, val;
	int want;                           // RD: the value the session file asks for, or -1
};

struct Bench {
	Vbt_module *t = nullptr;
	BtChip c;
	long now = 0, reset_dl = -1, inq_dl = -1;
	bool want_irq = false;
	uint64_t reads = 0, writes = 0, irqs = 0, data_reads = 0, held = 0;
	uint64_t n_cc = 0, n_cs = 0, n_inq = 0, n_name = 0, n_par = 0, n_fix = 0, n_resets = 0, n_dropped = 0;

	void edge() {
		t->clk = 0; t->eval();
		t->clk = 1; t->eval();
	}

	// one clock: the access (if any), then the model's timers
	unsigned step(Op op) {
		unsigned got = 0;

		t->rd = op.kind == Op::RD;
		t->wr = op.kind == Op::WR;
		t->rn = op.reg;
		t->wdata = op.val;
		t->eval();
		if (t->irq != want_irq) sim::fail("clock %ld: irq %d, want %d", now, t->irq, want_irq);
		irqs += t->irq;

		if (op.kind == Op::RD) {
			if (t->busy) sim::fail("clock %ld: bench read while busy", now);
			uint8_t kind = c.rx_kind, src = c.rep_src, cs = c.rep_cs;
			unsigned want = bt_chip_read(&c, op.reg);
			got = t->rdata;
			reads++;
			if (got != want) sim::fail("clock %ld: read of register 0x%02x: 0x%04x, want 0x%04x", now, op.reg, got, want);
			if (op.want >= 0 && (int)got != op.want)
				sim::fail("clock %ld: read of register 0x%02x: 0x%04x, the session has 0x%04x", now, op.reg, got, op.want);
			if (op.reg == BT_REG_DATA && kind != BT_RX_NONE) {
				data_reads++;
				if (c.rx_kind == BT_RX_NONE || c.rx_idx == 0) {   // the packet's last word
					if (kind == BT_RX_INQ) n_inq++;
					else if (cs) n_cs++;
					else {
						n_cc++;
						n_name += src == BT_SRC_NAME;
						n_par += src == BT_SRC_PAR;
						n_fix += src == BT_SRC_FIX;
					}
				}
			}
		} else if (op.kind == Op::WR) {
			bool had = c.rx_kind == BT_RX_REPLY;
			bt_chip_write(&c, op.reg, op.val);
			writes++;
			n_dropped += had && c.rx_new;
		}
		if (c.inq_stop) { c.inq_stop = false; inq_dl = -1; }
		if (c.inq_start) { inq_dl = now + c.inq_start * INQ_UNIT_CLKS; c.inq_start = 0; }
		if (c.reset_req) { c.reset_req = false; reset_dl = now + RESET_CLKS; n_resets++; }
		if (reset_dl == now) { reset_dl = -1; bt_chip_reset_done(&c); }
		if (inq_dl == now) { inq_dl = -1; bt_chip_inquiry_done(&c); }
		want_irq = c.irq;
		c.irq = false;
		c.rx_new = false;
		c.tx_done = 0;

		edge();
		now++;
		return got;
	}

	void idle(int n) { for (int i = 0; i < n; i++) step({Op::IDLE, 0, 0, -1}); }
	void write(unsigned reg, unsigned val) { step({Op::WR, reg, val, -1}); }
	// the bus side holds a read while the module is busy
	unsigned read(unsigned reg, int want = -1) {
		t->rd = 0; t->wr = 0; t->eval();
		while (t->busy) { held++; step({Op::IDLE, 0, 0, -1}); t->eval(); }
		return step({Op::RD, reg, 0, want});
	}

	void power_on() {
		t->reset = 1; t->rd = 0; t->wr = 0;
		edge(); edge();
		t->reset = 0;
		bt_chip_init(&c);
		reset_dl = inq_dl = -1;
		want_irq = false;
		now += 2;
	}
};

// ---- the driver's ways (btldd.ldd) ----

void drv_reset(Bench &b, bool check) {
	b.write(BT_REG_STATUS, 0);
	b.write(BT_REG_STATUS, 1);
	b.idle(RESET_CLKS + 2);
	b.read(BT_REG_STATUS, check ? 0x0084 : -1);
	b.read(BT_REG_REASON, check ? 0x0008 : -1);
	b.write(BT_REG_START, 0x8000);
	b.read(BT_REG_STATUS, check ? 0x0044 : -1);
	b.read(BT_REG_REG0, check ? 0x0208 : -1);
}

void drv_send(Bench &b, const std::vector<uint8_t> &p, bool check) {
	unsigned n = (unsigned)p.size();

	b.write(BT_REG_REG0, 0x8000 | n);
	b.read(BT_REG_STATUS, check ? 0x0044 : -1);
	b.read(BT_REG_REG0, check ? (int)n : -1);
	for (unsigned i = 0; i < n; i += 2) {
		b.write(BT_REG_DATA, p[i] << 8 | (i + 1 < n ? p[i + 1] : 0));
	}
	b.write(BT_REG_REG0, 0xC000 | n);
}

// read one packet the way the driver does; false if none is held
bool drv_recv(Bench &b, std::vector<uint8_t> &p, int want_status) {
	unsigned st = b.read(BT_REG_STATUS, want_status);

	p.clear();
	if (!(st & BT_ST_RX)) return false;
	unsigned n = b.read(BT_REG_RXLEN);
	for (unsigned i = 0; i < n; i += 2) {
		unsigned w = b.read(BT_REG_DATA);
		p.push_back(w >> 8);
		if (i + 1 < n) p.push_back(w & 0xFF);
	}
	return true;
}

std::vector<uint8_t> hex_bytes(const std::string &s) {
	std::vector<uint8_t> v;
	std::istringstream in(s);
	std::string tok;
	while (in >> tok) v.push_back((uint8_t)strtoul(tok.c_str(), nullptr, 16));
	return v;
}

void expect_packet(Bench &b, const std::vector<uint8_t> &got, const std::vector<uint8_t> &want, int line) {
	if (got != want) {
		sim::fail("session line %d: packet of %zu bytes, want %zu%s", line, got.size(), want.size(),
		          got.size() == want.size() ? " (bytes differ)" : "");
	}
}

int run_session(Bench &b, const char *path) {
	std::ifstream f(path);
	std::string line;
	int ln = 0, packets = 0;
	bool sent = false;                  // a command's acknowledge is still in the status

	if (!f) {
		sim::fail("cannot open %s", path);
		return 0;
	}
	while (std::getline(f, line)) {
		ln++;
		if (line.rfind("reset requested", 0) == 0) {
			drv_reset(b, true);
			sent = false;
		} else if (line.rfind("HCI< ", 0) == 0) {
			drv_send(b, hex_bytes(line.substr(5)), true);
			sent = true;
		} else if (line.rfind("HCI> ", 0) == 0) {
			std::vector<uint8_t> want = hex_bytes(line.substr(5)), got;
			if (sent) {
				// the acknowledge and the answer are there together
				if (!drv_recv(b, got, 0x0054)) sim::fail("session line %d: no answer", ln);
				// and the acknowledge names the packet
				sent = false;
			} else {
				// an event of its own: wait for the interrupt
				long limit = b.now + 0x30 * INQ_UNIT_CLKS + 100;
				b.t->eval();
				while (!b.t->irq && b.now < limit) b.idle(1), b.t->eval();
				if (!drv_recv(b, got, 0x0014)) sim::fail("session line %d: no event", ln);
			}
			expect_packet(b, got, want, ln);
			packets++;
		}
	}
	return packets;
}

// ---- random traffic ----

const uint16_t known_ops[] = {
	0x0401, 0x0402, 0x0C01, 0x0C03, 0x0C05, 0x0C0B, 0x0C0D, 0x0C11, 0x0C12, 0x0C13, 0x0C14,
	0x0C31, 0x0C33, 0x0C35, 0x0C38, 0x1001, 0x1003, 0x1005, 0x1007, 0x1009,
	0x0405, 0x0406, 0x0419, 0x0803, 0x080D, 0x1405, 0x1801, 0xFC00, 0x0C08, 0x0C40,
};

std::vector<uint8_t> random_command(sim::Rng &r) {
	unsigned op;
	int pick = r.range(0, 9);

	if (pick < 4) {
		const BtPar &p = bt_par[r.range(0, BT_NPAR - 1)];
		op = 0x0C00 | (p.ocf + (r.chance(60) ? 1 : 0));
	} else if (pick < 9) {
		op = known_ops[r.range(0, (int)(sizeof(known_ops) / sizeof(known_ops[0])) - 1)];
	} else {
		op = r.u32() & 0xFFFF;
	}
	unsigned plen = r.chance(70) ? (unsigned)r.range(0, 8) : (unsigned)r.range(0, 255);
	if (op == 0x0C13 && r.chance(80)) plen = r.chance(50) ? 248 : (unsigned)r.range(0, 255);
	if (op == 0x0401 && r.chance(85)) plen = 5;
	std::vector<uint8_t> p = { 0x01, 0x00, (uint8_t)op, (uint8_t)(op >> 8), (uint8_t)plen };
	for (unsigned i = 0; i < plen; i++) p.push_back((uint8_t)r.u32());
	if (op == 0x0401 && plen >= 4 && r.chance(85)) p[8] = (uint8_t)r.range(1, 3);   // a short inquiry
	if (op == 0x0C3A && plen >= 1 && r.chance(70)) p[5] = 1;
	if (r.chance(4)) p[0] = (uint8_t)r.u32();                    // not a command
	if (r.chance(5)) p[4] = (uint8_t)r.u32();                    // a length that is not the packet's
	return p;
}

unsigned random_reg(sim::Rng &r) {
	static const unsigned regs[] = { 0x00, 0x01, 0x06, 0x08, 0x09, 0x0A };
	return r.chance(85) ? regs[r.range(0, 5)] : (unsigned)r.range(0, 31);
}

void noise(Bench &b, sim::Rng &r) {
	int n = r.range(0, 3);

	for (int i = 0; i < n; i++) {
		if (r.chance(55)) {
			b.read(random_reg(r));
		} else {
			unsigned reg = random_reg(r), v = r.u32() & 0xFFFF;
			if (reg == BT_REG_STATUS && !r.chance(3)) v &= ~1u;  // a reset only now and then
			b.write(reg, v);
		}
		if (r.chance(30)) b.idle(r.range(1, 6));
	}
}

void random_traffic(Bench &b, sim::Rng &r, uint64_t ops) {
	std::vector<uint8_t> got;

	while (b.reads + b.writes < ops) {
		if (r.chance(2)) {
			drv_reset(b, false);
		} else if (r.chance(1)) {
			b.power_on();
		}
		if (r.chance(15)) noise(b, r);

		std::vector<uint8_t> p = random_command(r);
		unsigned n = (unsigned)p.size();
		unsigned said = r.chance(92) ? n : (unsigned)r.range(0, 600);   // the length it claims
		if (!r.chance(3)) {
			b.write(BT_REG_REG0, 0x8000 | said);
			if (r.chance(60)) { b.read(BT_REG_STATUS); b.read(BT_REG_REG0); }
		}
		unsigned words = (n + 1) / 2;
		if (r.chance(5)) words = (unsigned)r.range(0, (int)words);       // cut short
		for (unsigned i = 0; i < words; i++) {
			b.write(BT_REG_DATA, p[2 * i] << 8 | (2 * i + 1 < n ? p[2 * i + 1] : 0));
			if (r.chance(3)) noise(b, r);
		}
		b.write(BT_REG_REG0, 0xC000 | said);
		if (r.chance(10)) b.idle(r.range(0, 5));

		// the answer: all of it, some of it, none of it
		int how = r.range(0, 99);
		if (how < 80) {
			while (drv_recv(b, got, -1)) {
				if (r.chance(50)) break;
			}
		} else if (how < 90) {
			b.read(BT_REG_STATUS);
			b.read(BT_REG_RXLEN);
			for (int i = r.range(0, 6); i > 0; i--) b.read(BT_REG_DATA);
		}
		if (r.chance(8)) b.idle(r.range(1, 3 * (int)INQ_UNIT_CLKS));
		else if (r.chance(30)) b.idle(r.range(1, 12));
	}
}

} // namespace

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	uint32_t seed = 1;
	uint64_t ops = 400000;
	const char *session = nullptr;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = (uint32_t)strtoul(argv[++i], nullptr, 0);
		else if (!strcmp(argv[i], "--ops") && i + 1 < argc) ops = strtoull(argv[++i], nullptr, 0);
		else if (!strcmp(argv[i], "--session") && i + 1 < argc) session = argv[++i];
	}

	Bench b;
	sim::Rng rng(seed);
	b.t = new Vbt_module;
	b.power_on();

	int packets = 0;
	if (session) {
		packets = run_session(b, session);
		if (packets < 20) sim::fail("the session gave %d packets", packets);
		// and nothing more comes after it
		b.idle(2 * (int)INQ_UNIT_CLKS);
		b.read(BT_REG_STATUS, 0x0004);
		b.read(BT_REG_RXLEN, 0);
	}
	uint64_t s_reads = b.reads, s_writes = b.writes;

	random_traffic(b, rng, s_reads + s_writes + ops);

	printf("bt: session %d packets (%llu reads, %llu writes); random %llu reads (%llu of data, %llu held), "
	       "%llu writes, %llu interrupts\n", packets, (unsigned long long)s_reads, (unsigned long long)s_writes,
	       (unsigned long long)(b.reads - s_reads), (unsigned long long)b.data_reads, (unsigned long long)b.held,
	       (unsigned long long)(b.writes - s_writes), (unsigned long long)b.irqs);
	printf("bt: packets read out: %llu Command Complete (%llu a name, %llu a written value or its default, "
	       "%llu fixed), %llu Command Status, %llu Inquiry Complete; %llu answers replaced unread, %llu resets\n",
	       (unsigned long long)b.n_cc, (unsigned long long)b.n_name, (unsigned long long)b.n_par,
	       (unsigned long long)b.n_fix, (unsigned long long)b.n_cs, (unsigned long long)b.n_inq,
	       (unsigned long long)b.n_dropped, (unsigned long long)b.n_resets);
	if (!b.n_name || !b.n_par || !b.n_fix || !b.n_cs || !b.n_inq || !b.n_dropped || !b.n_resets) {
		sim::fail("the random traffic missed a kind of packet");
	}

	b.t->final();
	delete b.t;
	return sim::finish("bt_module");
}
