// Bench for the UPP peripherals in the memory system (sim/harness/periph_tb.sv:
// ngage_mem + upp_periph + lcd_panel + mmc_card + keypad_matrix). A scripted
// CPU on the Wishbone port plays each block the way the firmware does, against
// the reference model's semantics (model/hw/ngage*.c), with the SDRAM chip
// model, the DDRAM port model and hps_io's SD interface around it.
//
//   Vperiph_tb [--seed N] [--out DIR] [--model-out DIR]
//
//  * storage: every register the model keeps as storage reads back what was
//    written (bytes, halfwords, words) in the known pages and elsewhere in
//    0x0C1xxxxx, also inside the blocks' windows; 0x0Dxxxxxx and 0x0C2xxxxx
//    read 0; the DPLL read quirks; accesses of a size the model's region
//    refuses read 0 and change nothing; the register file is cleared at reset;
//  * the model's first-access log (model/.out/regs.log) replayed: every read
//    gives the value the model logged;
//  * timers and interrupt controller together: an underflow raises irq
//    3 * C + 1 clocks after the write that started the timer; the number
//    register; FIQ routing; acknowledge;
//  * DMA: memory to memory in SDRAM and on-chip RAM, every width pair, odd
//    lengths, fixed and incrementing sides; more transfers than engines at
//    once; stop in the middle; the interrupt and +0x08; while the CPU does
//    random SDRAM traffic through the arbiter, checked word for word;
//  * LCD: the boot's command sequence (control words, packing modes 1-3, the
//    RGBSET table) and a 12-bpp picture written by the CPU, then a 16-bpp
//    picture moved by DMA from SDRAM, both read back from the panel's frame
//    memory as the viewer sees it; RDDID through the read phase; the ready
//    bits;
//  * MMC: no card (response time-out), then a retail card with its CID/CSD
//    sidecar: CMD0/1/2/3/9/7/16 as epbus.dll issues them, the CID and CSD
//    words against the sidecar (CRC7 included), blocks read with CMD17 and
//    CMD18 through DMA channel 5 into SDRAM against the image; a writable
//    card: CMD24 and CMD25 + CMD12 with the data from SDRAM by DMA, against
//    what the HPS receives; status bits and the four MMC interrupt sources;
//  * keypad: ekeyb's idle state, a key press raising CTSI bit 2 and
//    CTSI_IRQ, the column scan finding every key, the acknowledge;
//  * CBUS: UEMK 0x15, the power-on status and the power key, the A/D
//    converter's battery-size channel, device 4's ID, storage and read-back,
//    the transfer length masking; the model's CBUS log (model/.out/cbus.log)
//    replayed;
//  * the STI trace window takes bytes and reads 0.
#include "Vperiph_tb.h"
#include "verilated.h"
#include "common.h"
#include "ddram_model.h"
#include "sdram_model.h"

#include <cstring>
#include <fstream>
#include <map>
#include <sstream>
#include <string>

namespace {

constexpr int W = 176, H = 208;
constexpr uint32_t SD = 0x0A000000u;           // SDRAM
constexpr uint32_t OC = 0x0C000000u;           // on-chip RAM

// register addresses
constexpr uint32_t INTC = 0x0C120100u, FINTC = 0x0C1201C0u;
constexpr uint32_t TMR = 0x0C120A00u, DMA = 0x0C120300u, MMC = 0x0C120600u, LCD = 0x0C121200u;
constexpr uint32_t CTSI = 0x0C150100u, KP = 0x0C150400u, CBUS = 0x0C150420u;

uint8_t crc7(const uint8_t *d, int n) {
	uint8_t c = 0;
	for (int i = 0; i < n; i++)
		for (int k = 7; k >= 0; k--) {
			int fb = ((c >> 6) & 1) ^ (d[i] >> k & 1);
			c = (uint8_t)((c << 1) & 0x7F);
			if (fb) c ^= 0x09;
		}
	return c;
}

// hps_io's SD block interface (as in mmc_main.cpp)
struct Hps {
	std::vector<uint8_t> img;
	enum { IDLE, DELAY, XFER, END } st = IDLE;
	bool wr = false;
	uint32_t lba = 0;
	int delay = 0, word = 0, gap = 0;
	uint64_t reads = 0, writes = 0;
};

struct Bench {
	Vperiph_tb *t = new Vperiph_tb;
	SdramChip chip;
	DdramModel ddr;
	Hps hps;
	sim::Rng rng;
	uint64_t cyc = 0;
	std::string out = ".";

	// what the bench watched
	uint64_t p_edge = 0;         // the edge of the last completed register access
	uint32_t p_last = 0;
	std::string sti;
	uint64_t lcd_bytes = 0;
	bool wrx_prev = true;
	uint32_t keys = 0;
	bool power = false;

	explicit Bench(uint32_t seed) : chip(seed * 5 + 3), ddr(48u << 20, seed * 11 + 7), rng(seed) {
		ddr.prof.busy_pct = 10;
		t->clk = 0; t->reset = 1; t->sdram_init = 1;
		t->wb_cyc = 0; t->wb_stb = 0; t->wb_we = 0; t->wb_adr = 0; t->wb_dat_i = 0; t->wb_sel = 0; t->wb_cti = 7; t->wb_bte = 0;
		t->ddram_busy = 0; t->ddram_dout = 0; t->ddram_dout_ready = 0; t->sdram_dq_i = 0;
		t->img_mounted = 0; t->img_readonly = 0; t->img_size = 0; t->sd_ack = 0; t->sd_buff_addr = 0;
		t->sd_buff_dout = 0; t->sd_buff_wr = 0; t->keys = 0; t->power = 0;
		t->scan_en = 0; t->scan_x = 0; t->scan_y = 0;
		t->eval();
		for (int i = 0; i < 4; i++) tick();
		t->sdram_init = 0;
		for (int i = 0; i < 4; i++) tick();
		t->reset = 0;
		// SDRAM power-up (200 us), then the register store clears (8192 clocks)
		for (int i = 0; i < 40000 && !t->sdram_ready; i++) tick();
		CHECK(t->sdram_ready, "SDRAM not ready");
		rd(0x0C120000);
	}
	~Bench() { t->final(); delete t; }

	// ---------------- the clock ----------------
	void hps_step() {
		Hps &h = hps;
		t->sd_buff_wr = 0;
		switch (h.st) {
		case Hps::IDLE:
			if (t->sd_rd || t->sd_wr) {
				h.wr = t->sd_wr;
				h.lba = t->sd_lba;
				if ((uint64_t)(h.lba + 1) * 512 > h.img.size()) sim::fail("HPS asked for block %u past the image", h.lba);
				h.delay = rng.chance(10) ? rng.range(500, 3000) : rng.range(20, 200);
				h.st = Hps::DELAY;
			}
			break;
		case Hps::DELAY:
			if (--h.delay <= 0) {
				t->sd_ack = 1;
				h.word = 0; h.gap = 4;
				t->sd_buff_addr = 0;
				h.st = Hps::XFER;
			}
			break;
		case Hps::XFER:
			if (--h.gap > 0) break;
			h.gap = rng.range(3, 8);
			if (h.word < 256) {
				size_t off = (size_t)h.lba * 512 + h.word * 2;
				if (!h.wr) {
					t->sd_buff_addr = h.word;
					t->sd_buff_dout = (uint16_t)(h.img[off] | h.img[off + 1] << 8);
					t->sd_buff_wr = 1;
				} else {
					uint16_t w = t->sd_buff_din;
					h.img[off] = (uint8_t)w; h.img[off + 1] = (uint8_t)(w >> 8);
					t->sd_buff_addr = h.word + 1;
				}
				h.word++;
			} else {
				t->sd_ack = 0;
				if (h.wr) h.writes++; else h.reads++;
				h.st = Hps::END;
				h.delay = 3;
			}
			break;
		case Hps::END:
			if (--h.delay <= 0) h.st = Hps::IDLE;
			break;
		}
	}

	void tick() {
		t->keys = keys;
		t->power = power;
		t->ddram_busy = ddr.busy;
		t->ddram_dout = ddr.dout;
		t->ddram_dout_ready = ddr.dout_ready;
		t->sdram_dq_i = chip.sample(cyc + 1);
		t->eval();
		bool pdone = t->p_sel && !t->p_wait;
		uint32_t pa = t->p_addr;
		bool sti_we = t->sti_we;
		ddr.step(t->ddram_rd, t->ddram_we, t->ddram_addr, t->ddram_burstcnt, t->ddram_din, t->ddram_be);
		t->clk = 1;
		t->eval();
		cyc++;
		SdramPins sp;
		sp.cs_n = t->sdram_cs_n; sp.ras_n = t->sdram_ras_n; sp.cas_n = t->sdram_cas_n; sp.we_n = t->sdram_we_n;
		sp.ba = t->sdram_ba; sp.a = t->sdram_a; sp.dqm = t->sdram_dqml | t->sdram_dqmh << 1;
		sp.dq_oe = t->sdram_dq_oe != 0; sp.dq_o = t->sdram_dq_o;
		chip.edge(cyc, sp);
		if (pdone) { p_edge = cyc; p_last = pa; }
		if (sti_we)
			for (int i = 0; i < 4; i++)
				if (t->sti_be >> i & 1) sti += (char)(t->sti_data >> (8 * i));
		hps_step();
		t->clk = 0;
		t->eval();
		if (!t->lcd_wrx && wrx_prev) lcd_bytes++;
		wrx_prev = t->lcd_wrx;
	}
	void run(uint64_t n) { while (n--) tick(); }

	// ---------------- the CPU: classic single beats ----------------
	uint32_t access(bool we, uint32_t a, uint32_t d, uint8_t sel) {
		t->wb_cyc = 1; t->wb_stb = 1; t->wb_we = we; t->wb_adr = a & ~3u; t->wb_dat_i = d; t->wb_sel = sel; t->wb_cti = 7;
		uint64_t limit = cyc + 2000000;
		uint32_t v = 0;
		for (;;) {
			bool ack = false;
			// sample ack after the edge: the bus answers in the clock with ack high
			t->eval();
			if (t->wb_ack || t->wb_err) { ack = true; v = t->wb_dat_o; }
			tick();
			if (ack) break;
			if (cyc > limit) { sim::fail("no answer at %08x", a); break; }
		}
		t->wb_cyc = 0; t->wb_stb = 0;
		tick();
		return v;
	}
	// a 4-beat incrementing burst, as ZAP's line fills and write-backs
	void burst(bool we, uint32_t a, uint32_t *d) {
		uint64_t limit = cyc + 2000000;
		for (int i = 0; i < 4; i++) {
			t->wb_cyc = 1; t->wb_stb = 1; t->wb_we = we; t->wb_adr = (a & ~15u) + 4 * i;
			t->wb_dat_i = we ? d[i] : 0; t->wb_sel = 0xF; t->wb_cti = i == 3 ? 7 : 2; t->wb_bte = 0;
			for (;;) {
				t->eval();
				bool ack = t->wb_ack || t->wb_err;
				if (ack && !we) d[i] = t->wb_dat_o;
				tick();
				if (ack) break;
				if (cyc > limit) { sim::fail("no answer to a burst at %08x", a); return; }
			}
		}
		t->wb_cyc = 0; t->wb_stb = 0; t->wb_cti = 7;
		tick();
	}
	uint32_t rd(uint32_t a, uint8_t sel = 0xF) { return access(false, a, 0, sel); }
	void wr(uint32_t a, uint32_t v, uint8_t sel = 0xF) { access(true, a, v, sel); }
	uint32_t rd16(uint32_t a) { uint32_t v = rd(a, (a & 2) ? 0xC : 0x3); return (a & 2) ? v >> 16 : v & 0xFFFF; }
	void wr16(uint32_t a, uint32_t v) { wr(a, (a & 2) ? v << 16 : v & 0xFFFF, (a & 2) ? 0xC : 0x3); }
	uint32_t rd8(uint32_t a) { return (rd(a, (uint8_t)(1 << (a & 3))) >> (8 * (a & 3))) & 0xFF; }
	void wr8(uint32_t a, uint32_t v) { wr(a, (v & 0xFF) << (8 * (a & 3)), (uint8_t)(1 << (a & 3))); }
	uint32_t rdn(uint32_t a, int size) { return size == 1 ? rd8(a) : size == 2 ? rd16(a) : rd(a); }
	void wrn(uint32_t a, uint32_t v, int size) { if (size == 1) wr8(a, v); else if (size == 2) wr16(a, v); else wr(a, v); }

	// SDRAM through the chip model
	uint8_t sd_byte(uint32_t a) { uint16_t h = chip.lin(((a - SD) & 0xFFFFFF) >> 1); return (uint8_t)(h >> (8 * (a & 1))); }
	void sd_poke(uint32_t a, uint8_t v) {
		uint16_t &h = chip.lin(((a - SD) & 0xFFFFFF) >> 1);
		h = (a & 1) ? (uint16_t)((h & 0x00FF) | v << 8) : (uint16_t)((h & 0xFF00) | v);
	}

	uint32_t pending(int bank = 0) { return rd(INTC + 0x40 * bank + 0x10); }
	struct CpuTraffic *traffic = nullptr;

	// a core reset: the registers start again as at power-on
	void reset_core() {
		t->reset = 1;
		run(5);
		t->reset = 0;
		rd(0x0C120000);           // waits for the register store to clear
	}

	// a DMA transfer as ekern programs one
	void dma_setup(int ch, uint32_t src, uint32_t smode, uint32_t sw, uint32_t dst, uint32_t dmode, uint32_t dw, uint32_t units) {
		uint32_t b = DMA + 0x40 * ch;
		wr(b + 0x04, 1);
		wr(b + 0x14, src); wr(b + 0x18, smode); wr(b + 0x1C, sw);
		wr(b + 0x20, dst); wr(b + 0x24, dmode); wr(b + 0x28, dw);
		wr(b + 0x2C, units - 1);
	}
	void dma_start(int ch, uint32_t how = 1) { wr(DMA + 0x40 * ch + 0x08, how); }
	// done; then a few clocks for the last posted SDRAM write to reach the chip
	// model, which the checks read directly
	bool dma_done(int ch) {
		if (!((pending() >> (6 + ch)) & 1)) return false;
		run(64);
		return true;
	}
	void dma_finish(int ch) {
		CHECK_EQ(rd(DMA + 0x40 * ch + 0x08), 0, "DMA +0x08 reads 0 when done");
		wr(DMA + 0x40 * ch + 0x08, 0);
		wr(DMA + 0x40 * ch + 0x04, 0);
		CHECK(!dma_done(ch), "DMA interrupt acknowledged");
	}
};

// -------------------------------------------------------------------------
// storage and decoding
// -------------------------------------------------------------------------
void test_storage(Bench &b) {
	printf("storage\n");
	std::map<uint32_t, uint8_t> ref;    // byte address -> value
	// registers the model keeps as storage, in pages and windows
	std::vector<uint32_t> words = {
		0x0C120004, 0x0C120008, 0x0C120014, 0x0C120018, 0x0C120034, 0x0C120038, 0x0C120064, 0x0C120068,
		0x0C120074, 0x0C120C04, 0x0C120C10, 0x0C120C14, 0x0C120C18, 0x0C121000, 0x0C121034, 0x0C12103C,
		0x0C14D000, 0x0C14D004, 0x0C14F000, 0x0C14F008, 0x0C150000, 0x0C150010, 0x0C150024, 0x0C150200,
		0x0C150210, 0x0C150538, 0x0C15053C, 0x0C1F0010, 0x0C100100, 0x0C180800,
		// inside the blocks' windows
		INTC + 0x00, INTC + 0x18, FINTC + 0x3C, TMR + 0x18, TMR + 0x24, TMR + 0x5C, DMA + 0x14, DMA + 0x20 + 0x40 * 3,
		DMA + 0x30, MMC + 0x00, MMC + 0x0C, MMC + 0x10, MMC + 0x14, MMC + 0x28, MMC + 0x3C, LCD + 0x0C,
		0x0C150104, 0x0C150428, 0x0C150540};
	// blocks whose region takes only 32-bit accesses
	auto only32 = [](uint32_t a) {
		return (a >= 0x0C120040 && a < 0x0C120080) || (a >= 0x0C120100 && a < 0x0C120280) ||
		       (a >= 0x0C120300 && a < 0x0C120500) || (a >= 0x0C120A00 && a < 0x0C120AC0) ||
		       (a >= 0x0C121200 && a < 0x0C121210);
	};
	for (int round = 0; round < 600; round++) {
		uint32_t w = words[b.rng.range(0, (int)words.size() - 1)];
		int size = only32(w) ? 4 : (1 << b.rng.range(0, 2));
		uint32_t a = w + (size == 4 ? 0 : size == 2 ? 2 * b.rng.range(0, 1) : b.rng.range(0, 3));
		if (b.rng.chance(50)) {
			uint32_t v = b.rng.u32();
			b.wrn(a, v, size);
			for (int i = 0; i < size; i++) ref[a + i] = (uint8_t)(v >> (8 * i));
		} else {
			uint32_t want = 0;
			for (int i = 0; i < size; i++) want |= (uint32_t)ref[a + i] << (8 * i);   // 0 if never written
			uint32_t got = b.rdn(a, size);
			if (got != want) sim::fail("storage %08x (%d bytes): 0x%x, want 0x%x", a, size, got, want);
		}
	}
	// outside 0x0C1xxxxx: nothing
	for (uint32_t a : {0x0D000000u, 0x0D123450u, 0x0C200000u, 0x0CF00010u, 0x0DE00000u}) {
		b.wr(a, 0x12345678);
		CHECK_EQ(b.rd(a), 0, "read outside the register page");
	}
	// the read quirks
	b.wr(0x0C120020, 0x00000005);
	CHECK_EQ(b.rd(0x0C120020), 0x1C000005, "0x0C120020 DPLL lock bits");
	b.wr(0x0C149000, 0x2210);
	CHECK_EQ(b.rd(0x0C149000), 0x2211, "0x0C149000 DPLL ready");
	// sizes the model's regions refuse: dropped, read 0
	b.wr(TMR + 0x18, 0x11223344);
	b.wr8(TMR + 0x18, 0x99);
	CHECK_EQ(b.rd(TMR + 0x18), 0x11223344, "a byte write to a 32-bit block is dropped");
	CHECK_EQ(b.rd16(TMR + 0x18), 0, "a halfword read of a 32-bit block reads 0");
	b.wr16(KP + 0x18, 0x1234);
	b.wr(KP + 0x18, 0x0000FFFF);
	CHECK_EQ(b.rd16(KP + 0x18), 0x1234, "a word write to a 16-bit block is dropped");
	CHECK_EQ(b.rd(KP + 0x18), 0, "a word read of a 16-bit block reads 0");
}

// model/.out/regs.log: "W|R <block> <address> size=<n> val=<v> pc=<pc>"
void test_regs_log(Bench &b, const std::string &dir) {
	std::ifstream f(dir + "/regs.log");
	if (!f) { printf("regs.log replay: %s/regs.log not found, skipped\n", dir.c_str()); return; }
	b.reset_core();                 // the log starts at power-on
	std::string line;
	int writes = 0, reads = 0;
	while (std::getline(f, line)) {
		char rw, blk[32];
		unsigned a, size, v;
		if (sscanf(line.c_str(), "%c %31s %x size=%u val=%x", &rw, blk, &a, &size, &v) != 5) continue;
		if (strcmp(blk, "upp")) continue;             // the EMIF block is upp_bus's
		if (rw == 'W') { b.wrn(a, v, (int)size); writes++; }
		else if (rw == 'R') {
			uint32_t got = b.rdn(a, (int)size);
			reads++;
			if (got != v) sim::fail("regs.log: read %08x (%u bytes) gave 0x%x, the model logged 0x%x", a, size, got, v);
		}
	}
	printf("regs.log replay: %d writes, %d reads checked\n", writes, reads);
}

// -------------------------------------------------------------------------
// timers with the interrupt controller
// -------------------------------------------------------------------------
void test_timers(Bench &b) {
	printf("timers and interrupt controller\n");
	// the boot's timer 0 with IRQ bit 0 enabled
	const uint32_t C = 200;
	b.wr(TMR + 0x10, C);
	b.wr(TMR + 0x18, C);
	b.wr(TMR + 0x08, 0);
	b.wr(INTC + 0x08, 1);
	CHECK(!b.t->irq, "no irq before the timer runs");
	b.wr(TMR + 0x04, 2);
	uint64_t start = b.p_edge;
	while (!b.t->irq && b.cyc < start + 3 * C + 100) b.tick();
	// the timer's latch at start + 3C, the controller's irq register an edge later
	CHECK_EQ(b.cyc, start + 3 * C + 1, "the edge after which irq is high");
	CHECK_EQ(b.rd(INTC + 0x14), 1, "IRQ number: timer 0 is source 0, number 1");
	CHECK_EQ(b.pending() & 1, 1, "pending bit 0");
	b.wr(TMR + 0x08, 1);
	b.run(2);
	CHECK(!b.t->irq, "irq after the acknowledge");
	// the second underflow, 3C after the first
	uint64_t first = start + 3 * C;
	while (!b.t->irq && b.cyc < first + 3 * C + 100) b.tick();
	CHECK_EQ(b.cyc, first + 3 * C + 1, "the second underflow (reload)");
	b.wr(TMR + 0x04, 0);
	b.wr(TMR + 0x08, 0);
	b.wr(INTC + 0x0C, 1);
	// timer 4 one-shot on FIQ: number register of the FIQ plane, fiq line
	b.wr(FINTC + 0x08, 1u << 4);
	b.wr(TMR + 0x80 + 0x10, 50);
	b.wr(TMR + 0x80 + 0x04, 1);
	start = b.p_edge;
	while (!b.t->fiq && b.cyc < start + 400) b.tick();
	CHECK_EQ(b.cyc, start + 3 * 50 + 1, "timer 4 FIQ edge");
	CHECK_EQ(b.rd(FINTC + 0x14), 5, "FIQ number: timer 4");
	CHECK(!b.t->irq, "a FIQ source does not raise irq");
	CHECK_EQ(b.rd(TMR + 0x80 + 0x10), 0, "a one-shot that ran out reads 0");
	b.wr(TMR + 0x80 + 0x08, 1);
	b.run(2);
	CHECK(!b.t->fiq, "fiq after the acknowledge");
	b.wr(FINTC + 0x0C, ~0u);
	// the lowest pending enabled source wins: timers 2 and 3 together
	b.wr(TMR + 0x40 + 0x10, 30); b.wr(TMR + 0x60 + 0x10, 20);
	b.wr(TMR + 0x40 + 0x04, 1); b.wr(TMR + 0x60 + 0x04, 1);
	b.run(200);
	CHECK_EQ(b.pending() & 0x3F, 0x0C, "timers 2 and 3 pending");
	CHECK_EQ(b.rd(INTC + 0x14), 0, "nothing enabled: number 0");
	b.wr(INTC + 0x08, 0x0C);
	CHECK_EQ(b.rd(INTC + 0x14), 3, "timers 2 and 3: number 3");
	b.wr(TMR + 0x40 + 0x08, 0);
	CHECK_EQ(b.rd(INTC + 0x14), 4, "timer 3 alone: number 4");
	b.wr(TMR + 0x60 + 0x08, 0);
	CHECK_EQ(b.rd(INTC + 0x14), 0, "none: number 0");
	b.wr(INTC + 0x0C, ~0u);
	// at rest the MMC idle sources 21 and 23 are high (the model's levels)
	CHECK_EQ(b.pending() & 0x01E00000, 0x00A00000, "MMC DataIdle and CmdIdle pending at rest");
}

// -------------------------------------------------------------------------
// DMA
// -------------------------------------------------------------------------
void fill_sdram(Bench &b, uint32_t a, uint32_t n, uint32_t seed) {
	uint32_t x = seed;
	for (uint32_t i = 0; i < n; i++) { x = x * 1664525u + 1013904223u; b.sd_poke(a + i, (uint8_t)(x >> 24)); }
}

// random CPU traffic in SDRAM 0x0A800000-0x0A80FFFF, checked against a copy
// (one for the whole run: it snapshots the region from the chip model once,
// while the bus is quiet)
struct CpuTraffic {
	std::vector<uint8_t> mem = std::vector<uint8_t>(0x10000);
	bool init = false;
	uint64_t ops = 0, max_clocks = 0;
	void step(Bench &b) {
		if (!init) { for (uint32_t i = 0; i < mem.size(); i++) mem[i] = b.sd_byte(0x0A800000 + i); init = true; }
		uint32_t a = 0x0A800000 + (b.rng.u32() & 0xFFFC);
		uint64_t c0 = b.cyc;
		if (b.rng.chance(30)) {
			// a line fill or write-back
			uint32_t d[4], l = a & 0xFFF0;
			bool we = b.rng.chance(50);
			for (int k = 0; k < 4; k++) d[k] = b.rng.u32();
			b.burst(we, a, d);
			for (int k = 0; k < 4; k++) {
				uint32_t want = 0;
				for (int i = 0; i < 4; i++) {
					if (we) mem[l + 4 * k + i] = (uint8_t)(d[k] >> (8 * i));
					want |= (uint32_t)mem[l + 4 * k + i] << (8 * i);
				}
				if (!we && d[k] != want) sim::fail("CPU line fill during DMA: %08x = %08x, want %08x", 0x0A800000 + l + 4 * k, d[k], want);
			}
		} else if (b.rng.chance(50)) {
			uint32_t v = b.rng.u32();
			b.wr(a, v);
			for (int i = 0; i < 4; i++) mem[(a & 0xFFFF) + i] = (uint8_t)(v >> (8 * i));
		} else {
			uint32_t want = 0;
			for (int i = 0; i < 4; i++) want |= (uint32_t)mem[(a & 0xFFFF) + i] << (8 * i);
			uint32_t got = b.rd(a);
			if (got != want) sim::fail("CPU traffic during DMA: %08x = %08x, want %08x", a, got, want);
		}
		max_clocks = std::max(max_clocks, b.cyc - c0);
		ops++;
	}
};

uint32_t wcode(int bytes) { return bytes == 4 ? 0x20 : bytes == 2 ? 0x10 : 0x08; }

void test_dma(Bench &b) {
	printf("DMA\n");
	CpuTraffic &cpu = *b.traffic;
	// every width pair, incrementing both sides, odd lengths
	int n = 0;
	for (int sw : {1, 2, 4}) {
		for (int dw : {1, 2, 4}) {
			uint32_t units = (uint32_t)b.rng.range(1, 70);
			uint32_t bytes = units * sw;
			uint32_t src = SD + 0x100000 + 0x1000 * n, dst = SD + 0x200000 + 0x1000 * n;
			fill_sdram(b, src, bytes, 77 + n);
			fill_sdram(b, dst, bytes + 8, 99 + n);
			std::vector<uint8_t> before(bytes + 8);
			for (uint32_t i = 0; i < bytes + 8; i++) before[i] = b.sd_byte(dst + i);
			int ch = n % 7;
			b.dma_setup(ch, src, 4, wcode(sw), dst, 4, wcode(dw), units);
			b.dma_start(ch, 1);
			while (!b.dma_done(ch)) cpu.step(b);
			for (uint32_t i = 0; i < bytes + 8; i++) {
				uint8_t want = i < bytes ? b.sd_byte(src + i) : before[i];
				if (b.sd_byte(dst + i) != want) { sim::fail("DMA %d->%d bytes, %u units: byte %u is %02x, want %02x", sw, dw, units, i, b.sd_byte(dst + i), want); break; }
			}
			b.dma_finish(ch);
			n++;
		}
	}
	// a fixed source fills; on-chip RAM to SDRAM with mode 2
	{
		b.wr(OC + 0x100, 0xA5C3E1F0);
		b.dma_setup(2, OC + 0x100, 0, 0x20, SD + 0x300000, 4, 0x20, 64);
		b.dma_start(2);
		while (!b.dma_done(2)) cpu.step(b);
		for (int i = 0; i < 64; i++) CHECK_EQ(b.rd(SD + 0x300000 + 4 * i), 0xA5C3E1F0, "fixed-source fill");
		b.dma_finish(2);
		for (int i = 0; i < 32; i++) b.wr(OC + 0x200 + 4 * i, 0x01010101u * i);
		b.dma_setup(3, OC + 0x200, 2, 0x20, SD + 0x310000, 4, 0x10, 32);
		b.dma_start(3);
		while (!b.dma_done(3)) cpu.step(b);
		for (int i = 0; i < 32; i++) CHECK_EQ(b.rd(SD + 0x310000 + 4 * i), 0x01010101u * i, "on-chip RAM to SDRAM");
		b.dma_finish(3);
	}
	// five transfers at once (three engines), long ones, with CPU traffic
	{
		const uint32_t units = 600;
		for (int ch = 0; ch < 5; ch++) {
			fill_sdram(b, SD + 0x400000 + 0x10000 * ch, units * 4, 300 + ch);
			b.dma_setup(ch, SD + 0x400000 + 0x10000 * ch, 4, 0x20, SD + 0x480000 + 0x10000 * ch, 4, ch & 1 ? 0x08 : 0x20, units);
		}
		for (int ch = 0; ch < 5; ch++) b.dma_start(ch);
		uint32_t done = 0;
		uint64_t limit = b.cyc + 3000000;
		while (done != 0x1F && b.cyc < limit) {
			cpu.step(b);
			done = (b.pending() >> 6) & 0x1F;
		}
		b.run(64);
		CHECK_EQ(done, 0x1F, "five concurrent transfers done");
		for (int ch = 0; ch < 5; ch++) {
			for (uint32_t i = 0; i < units * 4; i++) {
				if (b.sd_byte(SD + 0x480000 + 0x10000 * ch + i) != b.sd_byte(SD + 0x400000 + 0x10000 * ch + i)) {
					sim::fail("concurrent DMA channel %d: byte %u differs", ch, i);
					break;
				}
			}
			b.dma_finish(ch);
		}
	}
	// a stop in the middle
	{
		const uint32_t units = 20000;
		b.wr(SD + 0x600000, 0xA5A5A5A5);
		for (uint32_t i = 0; i < units * 4; i++) b.sd_poke(SD + 0x700000 + i, 0);
		b.dma_setup(6, SD + 0x600000, 0, 0x20, SD + 0x700000, 4, 0x20, units);
		b.dma_start(6);
		b.run(3000);
		b.wr(DMA + 0x40 * 6 + 0x08, 0);
		b.run(200);
		uint32_t moved = 0;
		while (moved < units && b.sd_byte(SD + 0x700000 + 4 * moved) != 0) moved++;
		b.run(2000);
		uint32_t moved2 = 0;
		while (moved2 < units && b.sd_byte(SD + 0x700000 + 4 * moved2) != 0) moved2++;
		CHECK(moved > 0 && moved < units, "a stopped transfer moved part of its data");
		CHECK_EQ(moved2, moved, "nothing moves after the stop");
		CHECK(!b.dma_done(6), "a stopped transfer raises no interrupt");
		CHECK_EQ(b.rd(DMA + 0x40 * 6 + 0x08), 0, "+0x08 reads 0 after a stop");
		CHECK_EQ(b.rd(DMA + 0x40 * 6 + 0x0C), 0, "+0x0C reads 0");
		CHECK_EQ(b.rd(DMA + 0x40 * 6 + 0x14), SD + 0x600000, "+0x14 keeps the source address");
		b.wr(DMA + 0x40 * 6 + 0x04, 0);
	}
	printf("  %llu CPU accesses alongside\n", (unsigned long long)cpu.ops);
}

// -------------------------------------------------------------------------
// LCD
// -------------------------------------------------------------------------
struct Lcd {
	Bench &b;
	explicit Lcd(Bench &b_) : b(b_) {}
	void sync() {
		// lcd.ldd 0x504068A0: 0x49200000 and wait for bit 30, then 0x09200000
		b.wr(LCD, 0x49200000);
		int tries = 0;
		while (!(b.rd(LCD) & 0x40000000) && ++tries < 1000) {}
		CHECK(tries < 1000, "LCD ready bit");
		b.wr(LCD, 0x09200000);
	}
	void cmd(uint8_t c) { b.wr(LCD, 0x09280000); b.wr(LCD + 8, c); }
	// parameters as the bootstrap packs them (0x694C), LSB first in 12-bit units
	void params(const std::vector<uint8_t> &p) {
		b.wr(LCD, 0x09240000 | (uint32_t)(p.size() - 1));
		for (size_t i = 0; i < p.size(); i += 3) {
			uint32_t v = p[i] | (i + 1 < p.size() ? p[i + 1] << 8 : 0) | (i + 2 < p.size() ? p[i + 2] << 16 : 0);
			b.wr(LCD + 8, (v & 0xFFF) | ((v >> 12) & 0xFFF) << 16);
		}
	}
	void lut(const uint8_t *t48) {
		cmd(0x2D);
		b.wr(LCD, 0x092C002F);
		for (int i = 0; i < 48; i += 4) b.wr(LCD + 8, t48[i] | t48[i + 1] << 8 | t48[i + 2] << 16 | (uint32_t)t48[i + 3] << 24);
	}
	void window() {
		cmd(0x2A); params({0, 0, 0, 175});
		cmd(0x2B); params({0, 0, 0, 207});
	}
	// the viewer's picture from the panel's scan port
	sim::Image grab() {
		sim::Image im(W, H);
		for (int y = 0; y < H; y++) {
			for (int x = 0; x < W; x++) {
				b.t->scan_en = 1; b.t->scan_x = x; b.t->scan_y = y;
				b.tick();
				b.t->scan_en = 0;
				b.run(4);
				sim::set565(im, x, y, b.t->scan_rgb);
			}
		}
		return im;
	}
};

uint16_t pix12(int x, int y) { return (uint16_t)(((x * 15 / 175) << 8) | ((y * 15 / 207) << 4) | ((x + y) & 15)); }
uint16_t pix16(int x, int y) { return (uint16_t)((((x ^ y) & 31) << 11) | ((y * 63 / 207) << 5) | (x * 31 / 175)); }

void test_lcd(Bench &b) {
	printf("LCD\n");
	Lcd l(b);
	CHECK_EQ(b.rd(LCD + 4) & 4, 4, "aux bit 2: the FIFO can take a word");
	CHECK_EQ(b.rd(LCD) & 0x40000000, 0x40000000, "ready at rest");
	// RDDID through the read phase (bootstrap 0x6C44): a dummy byte, then ID1-3
	l.sync();
	l.cmd(0x04);
	b.wr(LCD, 0x07840003);
	uint32_t id[4];
	for (int i = 0; i < 4; i++) id[i] = b.rd(LCD + 8);
	CHECK_EQ(id[1], 0x29, "RDDID ID1 (module 0x10)");
	CHECK_EQ(id[2], 0x00, "RDDID ID2");
	CHECK_EQ(id[3], 0x00, "RDDID ID3");
	b.wr(LCD + 8, 0xDEADBEEF);
	b.wr(LCD, 0x09200000);
	CHECK_EQ(b.rd(LCD + 8), 0xDEADBEEF, "+0x08 outside a read phase reads the last word written");

	// the boot's set-up: SLPOUT, MADCTL 0xD4, COLMOD 3 (12 bpp), RGBSET, DISPON
	uint8_t t48[48];
	for (int i = 0; i < 16; i++) { t48[i] = (uint8_t)(i * 2 + (i >> 3)); t48[16 + i] = (uint8_t)(i * 4 + (i >> 2)); t48[32 + i] = (uint8_t)(31 - i * 2); }
	l.sync();
	l.cmd(0x11);
	l.cmd(0x36); l.params({0xD4});
	l.cmd(0x3A); l.params({0x03});
	l.lut(t48);
	l.window();
	l.cmd(0x2C);
	b.wr(LCD, 0x8314D67F);                  // 54912 bytes, DCS 12-bit pixel order
	uint64_t t0 = b.cyc;
	for (int y = 0; y < H; y++)
		for (int x = 0; x < W; x += 2) {
			if (b.rng.chance(10)) while (!(b.rd(LCD + 4) & 4)) {}   // polled now and then
			b.wr(LCD + 8, pix12(x, y) | (uint32_t)pix12(x + 1, y) << 16);
		}
	// a few words past the phase length are dropped
	b.wr(LCD + 8, 0x0FFF0FFF);
	l.sync();
	printf("  12-bpp frame by the CPU: %llu clocks, %llu bus bytes so far\n", (unsigned long long)(b.cyc - t0), (unsigned long long)b.lcd_bytes);
	l.cmd(0x29);
	l.sync();
	sim::Image got = l.grab(), want(W, H);
	for (int y = 0; y < H; y++)
		for (int x = 0; x < W; x++) {
			uint16_t p = pix12(x, y);
			uint16_t r = t48[p >> 8] & 31, g = t48[16 + ((p >> 4) & 15)] & 63, bl = t48[32 + (p & 15)] & 31;
			sim::set565(want, x, y, (uint16_t)(r << 11 | g << 5 | bl));
		}
	got.write_ppm(b.out + "/periph-lcd12.ppm");
	int bad = 0;
	for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) if (got.get(x, y) != want.get(x, y) && bad++ < 5)
		sim::fail("12-bpp picture (%d,%d): %06x, want %06x", x, y, got.get(x, y), want.get(x, y));
	CHECK_EQ(bad, 0, "12-bpp picture pixels wrong");

	// lcd.ldd's update (0x504042B4): a 12-bpp frame in SDRAM at 0x0A000020, two
	// pixels a word (u0 = bits 11:0, u1 = bits 27:16), moved by DMA channel 1
	// (0x0A000020 inc 32 -> 0x10121208 fixed 32, 73216 bytes, as the model logs it)
	const uint32_t fb = SD + 0x20;
	auto pix12b = [](int x, int y) { return (uint16_t)((((y * 15) / 207) << 8) | (((x ^ y) & 15) << 4) | ((x * 15) / 175)); };
	for (int y = 0; y < H; y++)
		for (int x = 0; x < W; x += 2) {
			uint32_t w = pix12b(x, y) | (uint32_t)pix12b(x + 1, y) << 16 | 0xF000F000u;   // the top bits are not used
			uint32_t a = fb + (uint32_t)(y * W + x) * 2;
			for (int i = 0; i < 4; i++) b.sd_poke(a + i, (uint8_t)(w >> (8 * i)));
		}
	l.sync();
	l.window();
	l.cmd(0x2C);
	b.wr(LCD, 0x8314D67F);
	b.dma_setup(1, fb, 4, 0x20, 0x10121208, 0, 0x20, W * H / 2);
	t0 = b.cyc;
	b.dma_start(1, 2);
	CpuTraffic &cpu = *b.traffic;
	while (!b.dma_done(1)) cpu.step(b);
	b.dma_finish(1);
	l.sync();
	printf("  12-bpp frame by DMA: %llu clocks, %llu CPU accesses alongside\n", (unsigned long long)(b.cyc - t0), (unsigned long long)cpu.ops);
	got = l.grab();
	got.write_ppm(b.out + "/periph-lcd12dma.ppm");
	bad = 0;
	for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
		uint16_t p = pix12b(x, y);
		uint16_t r = t48[p >> 8] & 31, g = t48[16 + ((p >> 4) & 15)] & 63, bl = t48[32 + (p & 15)] & 31;
		sim::set565(want, x, y, (uint16_t)(r << 11 | g << 5 | bl));
		if (got.get(x, y) != want.get(x, y) && bad++ < 5)
			sim::fail("12-bpp DMA picture (%d,%d): %06x, want %06x", x, y, got.get(x, y), want.get(x, y));
	}
	CHECK_EQ(bad, 0, "12-bpp DMA picture pixels wrong");

	// 16 bpp (COLMOD 5), packing 3 (control 0x082Cxxxx), by DMA: rows 0-159
	// (the phase length is 16 bits, 56320 bytes fit)
	const int H16 = 160;
	for (int y = 0; y < H16; y++)
		for (int x = 0; x < W; x += 2) {
			uint16_t p0 = pix16(x, y), p1 = pix16(x + 1, y);
			uint32_t a = fb + (uint32_t)(y * W + x) * 2;
			b.sd_poke(a, (uint8_t)(p0 >> 8)); b.sd_poke(a + 1, (uint8_t)p0);
			b.sd_poke(a + 2, (uint8_t)(p1 >> 8)); b.sd_poke(a + 3, (uint8_t)p1);
		}
	l.sync();
	l.cmd(0x3A); l.params({0x05});
	l.cmd(0x2A); l.params({0, 0, 0, 175});
	l.cmd(0x2B); l.params({0, 0, 0, H16 - 1});
	l.cmd(0x2C);
	b.wr(LCD, 0x082C0000 | (W * H16 * 2 - 1));
	b.dma_setup(1, fb, 4, 0x20, 0x10121208, 0, 0x20, W * H16 / 2);
	t0 = b.cyc;
	b.dma_start(1, 2);
	while (!b.dma_done(1)) cpu.step(b);
	b.dma_finish(1);
	l.sync();
	printf("  16-bpp rows by DMA: %llu clocks\n", (unsigned long long)(b.cyc - t0));
	got = l.grab();
	got.write_ppm(b.out + "/periph-lcd16.ppm");
	bad = 0;
	for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
		if (y >= H16) continue;      // the 12-bpp frame stays below
		sim::set565(want, x, y, pix16(x, y));
		if (got.get(x, y) != want.get(x, y) && bad++ < 5)
			sim::fail("16-bpp picture (%d,%d): %06x, want %06x", x, y, got.get(x, y), want.get(x, y));
	}
	CHECK_EQ(bad, 0, "16-bpp picture pixels wrong");
	printf("  %llu bytes on the LCD bus\n", (unsigned long long)b.lcd_bytes);
}

// -------------------------------------------------------------------------
// MMC
// -------------------------------------------------------------------------
struct Mmc {
	Bench &b;
	explicit Mmc(Bench &b_) : b(b_) {}
	uint32_t status() { return b.rd(MMC + 0x18); }
	// one command as epbus.dll issues it (0x503F5DA4-0x503F5490); waits for
	// command idle and returns the status
	uint32_t cmd(int idx, uint32_t arg, uint32_t ctrl, uint32_t len = 0) {
		b.wr(MMC + 0x14, 0x280); b.wr(MMC + 0x10, 0x1DC130); b.wr(MMC + 0x0C, 0x1DC130);
		b.wr(MMC + 0x1C, idx); b.wr(MMC + 0x20, arg); b.wr(MMC + 0x08, len);
		b.wr(MMC + 0x04, ctrl);
		int n = 120;
		while ((b.rd(MMC + 0x04) & 1) && --n > 0) {}
		CHECK(n > 0, "control bit 0 cleared");
		uint32_t s;
		uint64_t limit = b.cyc + 400000;
		while (((s = status()) & 8) && b.cyc < limit) {}
		CHECK(!(s & 8), "command idle");
		return s;
	}
	uint32_t resp() { return b.rd(MMC + 0x20); }
	// a data phase's end: DMA done, then data idle
	void wait_data(int ch) {
		uint64_t limit = b.cyc + 4000000;
		while (!b.dma_done(ch) && b.cyc < limit) {}
		CHECK(b.dma_done(ch), "MMC DMA done");
		b.dma_finish(ch);
		while ((status() & 4) && b.cyc < limit) {}
		CHECK(!(status() & 4), "data idle");
	}
};

void mount(Bench &b, std::vector<uint8_t> img, bool ro) {
	b.hps.img = std::move(img);
	b.t->img_size = b.hps.img.size();
	b.t->img_readonly = ro;
	b.t->img_mounted = 1;
	b.tick();
	b.t->img_mounted = 0;
	for (int i = 0; i < 40000 && !b.t->card_present; i++) b.tick();
	CHECK(b.t->card_present, "card present after mounting");
}

std::vector<uint8_t> pattern_image(uint32_t blocks, uint32_t seed) {
	std::vector<uint8_t> v((size_t)blocks * 512);
	uint32_t x = seed;
	for (auto &c : v) { x = x * 1664525u + 1013904223u; c = (uint8_t)(x >> 24); }
	return v;
}

void test_mmc(Bench &b) {
	printf("MMC\n");
	Mmc m(b);
	// no card: CMD0 goes out, CMD1 times out
	CHECK_EQ(m.cmd(0, 0, 0x01), 0, "CMD0 status");
	uint32_t s = m.cmd(1, 0x80008000, 0x49);
	CHECK_EQ(s, 0x40, "CMD1 with no card: response time-out");
	CHECK_EQ(b.pending() & 0x01E00000, 0x00A00000, "after a time-out: command and data idle, no response");

	// a retail card: SonicN's CID/CSD from research/peripherals/MMC.md
	static const uint8_t CID[16] = {0x07, 0x00, 0x04, 0x00, 0x0B, 0x3B, 0x18, 0x29, 0x4D, 0x01, 0x00, 0xC4, 0x00, 0x20, 0x96, 0x00};
	static const uint8_t CSD[16] = {0x8C, 0x08, 0x03, 0x2A, 0x00, 0x79, 0xA3, 0xFF, 0xB6, 0xC0, 0x81, 0xE1, 0x80, 0x00, 0x20, 0x00};
	std::vector<uint8_t> img = pattern_image(512, 11), side(512, 0);
	memcpy(side.data(), "NGAGEMMC", 8);
	side[8] = 1;
	memcpy(side.data() + 16, CID, 16);
	memcpy(side.data() + 32, CSD, 16);
	side[48] = 0x00; side[49] = 0xFF; side[50] = 0x80; side[51] = 0x00;
	std::vector<uint8_t> data = img;
	img.insert(img.end(), side.begin(), side.end());
	mount(b, img, true);

	CHECK_EQ(m.cmd(0, 0, 0x01), 0, "CMD0");
	int tries = 0;
	uint32_t ocr = 0;
	do {
		s = m.cmd(1, 0x80008000, 0x49);
		CHECK_EQ(s, 0x100, "CMD1 status: response");
		CHECK_EQ(b.pending() >> 24 & 1, 1, "MMCCmdRdy pending with a response");
		ocr = m.resp();
		CHECK_EQ(m.status() & 0x100, 0, "response bit clears when read");
	} while (!(ocr >> 31) && ++tries < 10);
	CHECK_EQ(ocr, 0x80FF8000, "OCR, ready");
	auto r2 = [&](const uint8_t *want, const char *what) {
		uint8_t w[16];
		memcpy(w, want, 15);
		w[15] = (uint8_t)(crc7(want, 15) << 1 | 1);
		for (int i = 0; i < 4; i++) {
			uint32_t v = m.resp();
			uint32_t e = (uint32_t)w[4 * i] << 24 | w[4 * i + 1] << 16 | w[4 * i + 2] << 8 | w[4 * i + 3];
			if (v != e) sim::fail("%s word %d: %08x, want %08x", what, i, v, e);
		}
		CHECK_EQ(m.resp(), 0, "nothing after the fourth word");
	};
	s = m.cmd(2, 0, 0x0D);
	CHECK_EQ(s, 0x100, "CMD2 status");
	r2(CID, "CID");
	s = m.cmd(3, 0x00010000, 0x05);
	CHECK_EQ(s, 0x100, "CMD3 status");
	CHECK_EQ((m.resp() >> 9) & 15, 2, "CMD3 R1: state ident");
	s = m.cmd(9, 0x00010000, 0x0D);
	CHECK_EQ(s, 0x100, "CMD9 status");
	r2(CSD, "CSD");
	s = m.cmd(7, 0x00010000, 0x05);
	CHECK_EQ(s, 0x100, "CMD7 status");
	CHECK_EQ((m.resp() >> 9) & 15, 3, "CMD7 R1: state stby");
	s = m.cmd(16, 512, 0x05);
	CHECK_EQ((m.resp() >> 9) & 15, 4, "CMD16 R1: state tran");

	// CMD17 into SDRAM through DMA channel 5 (8-bit FIFO side), as epbus does
	auto read_check = [&](uint32_t sdaddr, uint32_t lba, int nblocks, const char *what) {
		for (int k = 0; k < nblocks; k++)
			for (int i = 0; i < 512; i++)
				if (b.sd_byte(sdaddr + 512 * k + i) != data[(size_t)(lba + k) * 512 + i]) {
					sim::fail("%s: block %d byte %d is %02x, want %02x", what, k, i, b.sd_byte(sdaddr + 512 * k + i), data[(size_t)(lba + k) * 512 + i]);
					return;
				}
	};
	s = m.cmd(17, 7 * 512, 0x21, 0x200);
	CHECK_EQ(s & ~4u, 0x100, "CMD17 status");
	CHECK_EQ((m.resp() >> 9) & 15, 4, "CMD17 R1");
	b.dma_setup(5, 0x10120624, 0, 0x08, SD + 0xC00000, 4, 0x20, 512);
	b.dma_start(5, 2);
	{
		// the DMA waits for the card off the bus (paced by the FIFO): the CPU
		// keeps going meanwhile, every access quick
		CpuTraffic &cpu = *b.traffic;
		cpu.ops = 0;
		cpu.max_clocks = 0;
		uint64_t limit = b.cyc + 4000000;
		while (!b.dma_done(5) && b.cyc < limit) cpu.step(b);
		printf("  CMD17 block: %llu CPU accesses alongside, the slowest %llu clocks\n",
		       (unsigned long long)cpu.ops, (unsigned long long)cpu.max_clocks);
		CHECK(cpu.ops > 100, "the CPU runs while the MMC DMA waits for data");
		CHECK(cpu.max_clocks < 200, "no CPU access waits on the card");
	}
	m.wait_data(5);
	CHECK_EQ(m.status() & 0x7FF, 0, "status after the block");
	read_check(SD + 0xC00000, 7, 1, "CMD17");
	// CMD18: three blocks, type 9 for each after the first, then CMD12 (type 10);
	// an 8-bit destination this time
	s = m.cmd(18, 100 * 512, 0x21, 0x200);
	m.resp();
	for (int k = 0; k < 3; k++) {
		if (k) { b.wr(MMC + 0x08, 0x200); b.wr(MMC + 0x04, 0x25); }
		b.dma_setup(5, 0x10120624, 0, 0x08, SD + 0xC10000 + 512 * k, 4, k == 1 ? 0x08 : 0x20, 512);
		b.dma_start(5, 2);
		m.wait_data(5);
		CHECK(!(m.status() & 0x481), "no data error");
	}
	s = m.cmd(12, 0, 0x29);
	CHECK_EQ(s, 0x100, "CMD12 status");
	read_check(SD + 0xC10000, 100, 3, "CMD18");
	s = m.cmd(13, 0x00010000, 0x05);
	CHECK_EQ((m.resp() >> 9) & 15, 4, "CMD13: back in tran");
	// a retail card refuses writes: CMD24 gets no response (illegal for class 0/1/2)
	s = m.cmd(24, 0, 0x15, 0x200);
	CHECK_EQ(s & 0x40, 0x40, "CMD24 to a retail card: no response");
	CHECK_EQ(s & 4, 0, "no data phase without a response");

	// a writable card (no sidecar): CMD24, CMD25 + CMD12 with data from SDRAM
	printf("  writable card\n");
	data = pattern_image(256, 23);
	mount(b, data, false);
	CHECK_EQ(m.cmd(0, 0, 0x01), 0, "CMD0");
	do { m.cmd(1, 0x80008000, 0x49); ocr = m.resp(); } while (!(ocr >> 31));
	m.cmd(2, 0, 0x0D); for (int i = 0; i < 4; i++) m.resp();
	m.cmd(3, 0x00020000, 0x05); m.resp();
	m.cmd(7, 0x00020000, 0x05); m.resp();
	m.cmd(16, 512, 0x05); m.resp();
	fill_sdram(b, SD + 0xD00000, 4 * 512, 1234);
	s = m.cmd(24, 9 * 512, 0x15, 0x200);
	CHECK_EQ(s & ~4u, 0x100, "CMD24 status");
	m.resp();
	b.dma_setup(5, SD + 0xD00000, 4, 0x20, 0x10120624, 0, 0x08, 512);
	b.dma_start(5, 2);
	m.wait_data(5);
	CHECK_EQ(m.status() & 0x7FF, 0, "status after a written block");
	for (int i = 0; i < 512; i++)
		if (b.hps.img[9 * 512 + i] != b.sd_byte(SD + 0xD00000 + i)) { sim::fail("CMD24: byte %d not written", i); break; }
	s = m.cmd(25, 20 * 512, 0x15, 0x200);
	m.resp();
	for (int k = 0; k < 3; k++) {
		if (k) { b.wr(MMC + 0x08, 0x200); b.wr(MMC + 0x04, 0x19); }
		b.dma_setup(5, SD + 0xD00000 + 512 * (k + 1), 4, k == 2 ? 0x08 : 0x20, 0x10120624, 0, 0x08, k == 2 ? 512 : 128);
		b.dma_start(5, 2);
		m.wait_data(5);
		CHECK(!(m.status() & 0x4A1), "no data error");
	}
	s = m.cmd(12, 0, 0x1D);
	CHECK_EQ(s & 0x60, 0, "CMD12 after writing");
	m.resp();
	for (int k = 0; k < 3; k++)
		for (int i = 0; i < 512; i++)
			if (b.hps.img[(20 + k) * 512 + i] != b.sd_byte(SD + 0xD00000 + 512 * (k + 1) + i)) { sim::fail("CMD25 block %d byte %d not written", k, i); k = 3; break; }
	// read one back through the host
	s = m.cmd(17, 21 * 512, 0x21, 0x200);
	m.resp();
	b.dma_setup(5, 0x10120624, 0, 0x08, SD + 0xD20000, 4, 0x20, 512);
	b.dma_start(5, 2);
	m.wait_data(5);
	for (int i = 0; i < 512; i++)
		if (b.sd_byte(SD + 0xD20000 + i) != b.sd_byte(SD + 0xD00000 + 1024 + i)) { sim::fail("read-back byte %d", i); break; }
	printf("  HPS: %llu block reads, %llu block writes\n", (unsigned long long)b.hps.reads, (unsigned long long)b.hps.writes);
}

// -------------------------------------------------------------------------
// keypad and CTSI
// -------------------------------------------------------------------------
void test_keypad(Bench &b) {
	printf("keypad\n");
	// ekeyb's idle state (0x5041CCE0): columns outputs at 0, rows pulled-up
	// inputs with interrupts on
	b.wr16(KP + 0x00, 0x00);
	b.wr16(KP + 0x02, 0x001F);
	b.wr16(KP + 0x0E, 0x3F00);
	b.wr16(KP + 0x16, 0x003F);
	b.wr16(KP + 0x10, 0x003F);
	b.wr16(KP + 0x18, 0);
	CHECK_EQ(b.rd16(KP + 0x02), 0x1F, "port D direction");
	CHECK_EQ(b.rd16(KP + 0x0C), 0x3F, "rows idle high");
	CHECK_EQ(b.rd16(CTSI) & 0xC, 0, "no key interrupt yet");
	b.wr(INTC + 0x08, 1u << 25);
	static const int fitted[] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 13, 14, 15, 17, 18, 19, 22, 23, 24, 27, 28, 29};
	for (int k : fitted) {
		int row = k / 5, col = k % 5;
		b.keys = 1u << k;
		b.run(30);
		CHECK_EQ(b.rd16(CTSI) & 4, 4, "a key press latches CTSI bit 2");
		CHECK(b.t->irq, "CTSI_IRQ raises irq");
		CHECK_EQ(b.rd(INTC + 0x14), 26, "IRQ number 26: CTSI_IRQ");
		// the handler masks the row interrupts and acknowledges (0x5041CD6C)
		b.wr16(KP + 0x10, 0x3F00);
		b.wr16(CTSI, 0xC);
		CHECK_EQ(b.rd16(CTSI) & 0xC, 0, "acknowledged");
		// the scan (0x5041C490): everything input, one column driven at a time
		b.wr16(KP + 0x02, 0x1F00);
		int found = -1, hits = 0;
		for (int c = 0; c < 5; c++) {
			b.wr16(KP + 0x00, 0x1F & ~(1 << c));
			b.wr16(KP + 0x02, (uint32_t)(1 << c));
			uint32_t rows = ~b.rd16(KP + 0x0C) & 0x3F;
			for (int r = 0; r < 6; r++) if (rows >> r & 1) { found = r * 5 + c; hits++; }
			b.wr16(KP + 0x02, (uint32_t)(1 << c) << 8);
		}
		CHECK_EQ(hits, 1, "one key found");
		CHECK_EQ(b.rd16(CTSI) & 0xC, 0, "the masked rows latch nothing during the scan");
		CHECK_EQ(found, row * 5 + col, "the scan finds the key");
		// back to idle, release
		b.wr16(KP + 0x00, 0x00);
		b.wr16(KP + 0x02, 0x001F);
		b.keys = 0;
		b.run(30);
		b.wr16(CTSI, 0xC);
		b.wr16(KP + 0x10, 0x003F);
	}
	CHECK_EQ(b.rd16(CTSI) & 0xC, 0, "no stray interrupt");
	b.wr16(CTSI, 0x8000);
	CHECK_EQ(b.rd16(CTSI), 0x8000, "CTSI's other bits are stored (bootstrap 0x2EE4)");
	b.wr(INTC + 0x0C, 1u << 25);
}

// -------------------------------------------------------------------------
// CBUS
// -------------------------------------------------------------------------
struct Cbus {
	Bench &b;
	explicit Cbus(Bench &b_) : b(b_) {}
	void wait_done() {
		int n = 0;
		while (!(b.rd16(CBUS + 2) & 0x400) && ++n < 100) {}
		CHECK(n < 100, "CBUS done");
	}
	uint32_t read(int dev, int reg, int bits) {
		b.wr16(CBUS + 0, (uint32_t)(bits - 1));
		b.wr16(CBUS + 2, (uint32_t)(reg | dev << 5 | 0x100));
		wait_done();
		return b.rd16(CBUS + 6) | (bits > 16 ? b.rd16(CBUS + 4) << 16 : 0);
	}
	void write(int dev, int reg, int bits, uint32_t v) {
		b.wr16(CBUS + 0, (uint32_t)(bits - 1));
		b.wr16(CBUS + 2, (uint32_t)(reg | dev << 5));
		if (bits > 16) b.wr16(CBUS + 4, v >> 16);
		b.wr16(CBUS + 6, v & 0xFFFF);
		wait_done();
	}
};

void test_cbus(Bench &b, const std::string &dir) {
	printf("CBUS\n");
	Cbus c(b);
	// the power key counts as held for POWER_ON_HOLD_CLKS (20000 here) after reset
	b.run(30000);
	CHECK_EQ(c.read(1, 0x15, 16), 0x0008, "UEMK 0x15");
	CHECK_EQ(c.read(1, 0x1F, 16), 0x0000, "UEMK 0x1F, power key up");
	b.power = true;
	b.run(20);
	CHECK_EQ(c.read(1, 0x1F, 16), 0x0002, "UEMK 0x1F bit 1: power key held");
	b.power = false;
	b.run(20);
	CHECK_EQ(c.read(1, 0x1F, 16), 0x0000, "UEMK 0x1F after the power key");
	// the A/D converter (bootstrap 0x3604/0x3644, cbus.dll 0x5037E1E8)
	c.write(1, 0x19, 16, 0x6880);
	CHECK_EQ(c.read(1, 0x1A, 16) & 0x3FF, 485, "ADC channel 6 (BSI)");
	c.write(1, 0x19, 16, 0xC800);
	CHECK_EQ(c.read(1, 0x1A, 16), 0, "ADC channel 12");
	CHECK_EQ(c.read(1, 0x19, 16), 0xC800, "0x19 reads back");
	// device 4: the ID cbus.dll's self-test needs, a register that holds a value
	CHECK_EQ(c.read(4, 0x00, 16) & 0xFF00, 0x0400, "device 4 register 0");
	c.write(4, 0x0D, 20, 0xABCDE);
	CHECK_EQ(c.read(4, 0x0D, 20), 0xABCDE, "device 4 register 0x0D, 20 bits");
	CHECK_EQ(c.read(4, 0x0D, 8), 0xDE, "masked to 8 bits");
	// ro registers keep their value
	c.write(1, 0x15, 16, 0x0200);
	CHECK_EQ(c.read(1, 0x15, 16), 0x0008, "UEMK 0x15 is read-only");
	// device 5: storage
	for (int r = 0; r < 8; r++) c.write(5, r, 16, 0x1111u * r + 5);
	for (int r = 0; r < 8; r++) CHECK_EQ(c.read(5, r, 16), 0x1111u * r + 5, "device 5 storage");
	// 32-bit accesses: length and control together, data high and low together
	b.wr(CBUS + 0, 0x0F | (0x16 | 1 << 5) << 16);       // write UEMK 0x16 (no start bit)
	b.wr(CBUS + 4, 0x0000 | 0x5A5Au << 16);              // data_hi 0, data_lo 0x5A5A: starts the write
	c.wait_done();
	b.wr(CBUS + 0, 0x0F | (0x16 | 1 << 5 | 0x100) << 16);
	c.wait_done();
	CHECK_EQ(b.rd(CBUS + 4) >> 16, 0x5A5A, "32-bit CBUS write and read");
	CHECK_EQ(b.rd(CBUS + 0) & 0xFFFF, 0x0F, "length register");
	CHECK_EQ(b.rd(CBUS + 0) >> 16, (0x16 | 1 << 5 | 0x100 | 0x400), "control reads with done");

	// model/.out/cbus.log: "R|W dev=D reg=RR bits=N val=V len=L ctrl=C pc=P"
	std::ifstream f(dir + "/cbus.log");
	if (!f) { printf("cbus.log replay: %s/cbus.log not found, skipped\n", dir.c_str()); return; }
	b.reset_core();                 // the log starts at power-on
	b.run(25000);                   // past the power-on hold: the key is what the log says
	std::string line;
	int nw = 0, nr = 0;
	while (std::getline(f, line)) {
		char rw;
		unsigned dev, reg, bits, val, len, ctrl;
		if (sscanf(line.c_str(), "%c dev=%u reg=%x bits=%u val=%x len=%x ctrl=%x", &rw, &dev, &reg, &bits, &val, &len, &ctrl) != 7) continue;
		if (rw == 'W') {
			b.wr16(CBUS + 0, len);
			if (bits > 16) b.wr16(CBUS + 4, val >> 16);
			b.wr16(CBUS + 2, ctrl);
			b.wr16(CBUS + 6, val & 0xFFFF);
			c.wait_done();
			nw++;
		} else if (rw == 'R') {
			// the power key as the model had it then (UEMK 0x1F bit 1); the
			// directed checks above test the key itself
			if (dev == 1 && reg == 0x1F) { b.power = val >> 1 & 1; b.run(20); }
			b.wr16(CBUS + 0, len);
			b.wr16(CBUS + 2, ctrl);
			c.wait_done();
			uint32_t got = b.rd16(CBUS + 6) | (bits > 16 ? b.rd16(CBUS + 4) << 16 : 0);
			nr++;
			if (got != val) sim::fail("cbus.log: dev %u reg %02x read 0x%x, the model logged 0x%x", dev, reg, got, val);
		}
	}
	b.power = false;
	printf("cbus.log replay: %d writes, %d reads checked\n", nw, nr);
}

void test_sti(Bench &b) {
	printf("STI window\n");
	const char *msg = "TRtcQueue::Add: 2\n";
	b.sti.clear();
	for (int i = 0; msg[i]; i++) b.wr8(0x0DE00000 + i, (uint8_t)msg[i]);
	b.run(4);
	CHECK(b.sti == msg, "STI window bytes");
	CHECK_EQ(b.rd(0x0DE00000), 0, "the STI window reads 0");
}

void test_reset(Bench &b) {
	printf("reset\n");
	b.wr(0x0C150000, 0x0000000E);
	b.wr(0x0C120004, 0x12345678);
	b.reset_core();
	CHECK_EQ(b.rd(0x0C150000), 0, "storage cleared by reset (CTSI reset reason reads 0)");
	CHECK_EQ(b.rd(0x0C120004), 0, "storage cleared by reset");
	CHECK_EQ(b.rd(INTC + 0x08), 0, "enables cleared by reset");
}

}  // namespace

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	uint32_t seed = 1;
	std::string out = ".", model_out = "../model/.out";
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = (uint32_t)strtoul(argv[++i], nullptr, 0);
		else if (!strcmp(argv[i], "--out") && i + 1 < argc) out = argv[++i];
		else if (!strcmp(argv[i], "--model-out") && i + 1 < argc) model_out = argv[++i];
	}
	Bench b(seed);
	b.out = out;
	CpuTraffic traffic;
	b.traffic = &traffic;
	test_storage(b);
	test_regs_log(b, model_out);
	test_timers(b);
	test_keypad(b);
	test_cbus(b, model_out);
	test_sti(b);
	test_dma(b);
	test_lcd(b);
	test_mmc(b);
	test_reset(b);
	CHECK_EQ(b.chip.errors, 0, "SDRAM chip model errors");
	CHECK_EQ(b.ddr.protocol_errors, 0, "DDRAM port protocol errors");
	printf("periph: %llu clocks\n", (unsigned long long)b.cyc);
	return sim::finish("periph");
}
