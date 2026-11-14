// Bench for the UPP peripherals in the memory system (sim/harness/periph_tb.sv:
// ngage_mem + upp_periph + lcd_panel + mmc_card + keypad_matrix). A scripted
// CPU on the Wishbone port plays each block the way the firmware does, against
// the reference model's semantics (model/hw/ngage*.c), with the SDRAM chip
// model, the DDRAM port model and hps_io's SD interface around it.
//
//   Vperiph_tb [--seed N] [--out DIR] [--model-out DIR] [--card FILE.mmc]
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
//    multi-block transfers as epbus runs them, the last block in the phase
//    that sends CMD12 (types 10 and 7), every block checked;
//  * a real game card's image (--card, tools/mkcard.py's .mmc, local data):
//    CID, CSD and its first sectors; skipped when the file is absent;
//  * keypad: ekeyb's idle state, a key press raising CTSI bit 2 and
//    CTSI_IRQ, the column scan finding every key, the acknowledge;
//  * the Bluetooth module behind CBUS device 5 and its interrupt: the
//    driver's reset, the line's bit in CTSI's second group (latched, read
//    and raised only while enabled, cleared by writing 1), a command and
//    its answer; the module itself has its own bench (bt);
//  * CBUS: UEMK 0x15, the power-on status and the power key, the A/D
//    converter's battery-size channel, device 4's ID, storage and read-back,
//    the transfer length masking; the model's CBUS log (model/.out/cbus.log)
//    replayed;
//  * the HLE audio device (0x0C1F0000) through the register bus: 32-bit
//    only, two buffers from SDRAM read through the DMA port while a DMA
//    transfer runs, DONE0 on interrupt source 5 at the model's time, the
//    48 kHz output with the volume (rtl/upp/upp_haudio.sv has its own bench);
//  * the UEMK RTC and the HLE RTC date register (0x0C1F0100) with the wall
//    clock (a second is 20000 clocks here): 0 / counting from 00:00:00
//    before the HPS sends a time, then set from it, midnight, month, year and
//    leap-day ends, the day counter written and stepping with the date, a
//    core reset taking the date again, UEMK 0x04 = 0xC0;
//  * the STI trace window takes bytes and reads 0.
#include "Vperiph_tb.h"
#include "verilated.h"
#include "common.h"
#include "ddram_model.h"
#include "sdram_model.h"
#include "sdram_address.h"

#include <cstring>
#include <fstream>
#include <functional>
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
	int delay = 0, word = 0, nwords = 256, gap = 0;
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
		t->rtc[0] = 0; t->rtc[1] = 0; t->rtc[2] = 0;
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
				h.nwords = ((int)t->sd_blk_cnt + 1) * 256;
				if ((uint64_t)h.lba * 512 + (uint64_t)h.nwords * 2 > h.img.size()) sim::fail("HPS asked for block %u (cnt %u) past the image", h.lba, (unsigned)t->sd_blk_cnt);
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
			if (h.word < h.nwords) {
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
	uint8_t sd_byte(uint32_t a) { uint16_t h = chip.lin(sdram_physical_halfword((a - SD) & 0xFFFFFF)); return (uint8_t)(h >> (8 * (a & 1))); }
	void sd_poke(uint32_t a, uint8_t v) {
		uint16_t &h = chip.lin(sdram_physical_halfword((a - SD) & 0xFFFFFF));
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
		0x0C150210, 0x0C150538, 0x0C15053C, 0x0C1F0200, 0x0C1E0010, 0x0C100100, 0x0C180800,
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
	// A multi-block transfer as epbus runs it (0x503F5688-0x503F57A8): the
	// first phase with the command (type 8 CMD18 / 5 CMD25), one phase a block
	// after it (9 / 6), and the last block's phase (10 / 7) with CMD12 and the
	// block length loaded into +0x1C/+0x20/+0x08 first. Each phase: control
	// written, its DMA (channel 5) started at once, then command idle, data
	// idle and the DMA awaited in any order (0x503F5888-0x503F5A94). The SDRAM
	// side's width changes from block to block. Returns the last status.
	uint32_t multi(bool write, uint32_t lba, int nblk, uint32_t sdaddr, const char *what) {
		uint32_t st = 0;
		for (int k = 0; k < nblk; k++) {
			bool first = k == 0, last = k == nblk - 1;
			if (first) {
				b.wr(MMC + 0x14, 0x280); b.wr(MMC + 0x10, 0x1DC130); b.wr(MMC + 0x0C, 0x1DC130);
				b.wr(MMC + 0x1C, write ? 25 : 18); b.wr(MMC + 0x20, lba * 512);
			} else if (last) {
				b.wr(MMC + 0x1C, 12); b.wr(MMC + 0x20, 0);
			}
			b.wr(MMC + 0x08, 0x200);
			uint32_t ty = first ? (write ? 5 : 8) : last ? (write ? 7 : 10) : (write ? 6 : 9);
			b.wr(MMC + 0x04, ty << 2 | 1);
			int n = 120;
			while ((b.rd(MMC + 0x04) & 1) && --n > 0) {}
			static const uint32_t widths[3] = {0x20, 0x08, 0x10};
			// the count is in source units: FIFO bytes for a read, the SDRAM width for a write
			uint32_t w = widths[k % 3], units = write ? 512 / (w == 0x20 ? 4 : w == 0x10 ? 2 : 1) : 512;
			if (write) b.dma_setup(5, sdaddr + 512 * k, 4, w, 0x10120624, 0, 0x08, units);
			else       b.dma_setup(5, 0x10120624, 0, 0x08, sdaddr + 512 * k, 4, w, units);
			b.dma_start(5, 2);
			uint64_t limit = b.cyc + 4000000;
			while (b.cyc < limit && !(b.dma_done(5) && !((st = status()) & 0xC))) {}
			if (b.cyc >= limit) { sim::fail("%s: phase %d (type %u) did not finish", what, k, ty); return st; }
			b.dma_finish(5);
			if (st & 0x6E3) sim::fail("%s: phase %d (type %u): status %03x", what, k, ty, st);
			if (first || last) {
				// the command's R1: CMD18/25 in tran; CMD12 while sending (data) or receiving (rcv)
				if (!(st & 0x100)) sim::fail("%s: phase %d (type %u): no response (status %03x)", what, k, ty, st);
				uint32_t r1 = resp();
				int want = first ? 4 : (write ? 6 : 5);
				if ((int)((r1 >> 9) & 15) != want) sim::fail("%s: phase %d (type %u): R1 state %u, want %d", what, k, ty, (r1 >> 9) & 15, want);
			} else if (st & 0x100) {
				sim::fail("%s: phase %d (type %u): a response without a command", what, k, ty);
			}
		}
		return st;
	}
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
	// CMD18 as epbus reads: three blocks (8, 9, 10), then 4 KB (8, six 9s,
	// 10); every block checked, the last one (type 10) included
	m.multi(false, 100, 3, SD + 0xC10000, "CMD18 3 blocks");
	read_check(SD + 0xC10000, 100, 3, "CMD18 3 blocks");
	s = m.cmd(13, 0x00010000, 0x05);
	CHECK_EQ((m.resp() >> 9) & 15, 4, "CMD13: back in tran after type 10");
	m.multi(false, 40, 8, SD + 0xC30000, "CMD18 4 KB");
	read_check(SD + 0xC30000, 40, 8, "CMD18 4 KB");
	s = m.cmd(13, 0x00010000, 0x05);
	CHECK_EQ((m.resp() >> 9) & 15, 4, "CMD13: back in tran after 4 KB");
	// past the capacity: OUT_OF_RANGE and no block; the host times out (2^16
	// clocks here), the paced DMA then reads zeros and finishes
	{
		uint64_t t0 = b.cyc;
		s = m.cmd(17, 0x7FFFFE00, 0x21, 0x200);
		CHECK_EQ(s & ~4u, 0x100, "CMD17 out of range: answered");
		uint32_t r1 = m.resp();
		for (int i = 0; i < 64; i++) b.sd_poke(SD + 0xC20000 + i, 0x55);
		b.dma_setup(5, 0x10120624, 0, 0x08, SD + 0xC20000, 4, 0x20, 512);
		b.dma_start(5, 2);
		m.wait_data(5);
		CHECK_EQ(m.status() & 0x80, 0x80, "data time-out");
		CHECK_EQ(b.sd_byte(SD + 0xC20000), 0, "the DMA read zeros");
		printf("  CMD17 out of range (R1 %08x): data time-out after %llu clocks\n", r1, (unsigned long long)(b.cyc - t0));
		CHECK_EQ(r1 >> 31, 1, "OUT_OF_RANGE in the R1");
	}
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
	// CMD25 as epbus writes: three blocks (5, 6, 7), then 4 KB (5, six 6s, 7);
	// every block reaches the image, the last one (type 7) included
	auto write_check = [&](uint32_t sdaddr, uint32_t lba, int nblk, const char *what) {
		for (int k = 0; k < nblk; k++)
			for (int i = 0; i < 512; i++)
				if (b.hps.img[(size_t)(lba + k) * 512 + i] != b.sd_byte(sdaddr + 512 * k + i)) {
					sim::fail("%s: block %d byte %d not written", what, k, i);
					return;
				}
	};
	m.multi(true, 20, 3, SD + 0xD00000 + 512, "CMD25 3 blocks");
	write_check(SD + 0xD00000 + 512, 20, 3, "CMD25 3 blocks");
	s = m.cmd(13, 0x00020000, 0x05);
	CHECK_EQ((m.resp() >> 9) & 15, 4, "CMD13: back in tran after type 7");
	fill_sdram(b, SD + 0xD10000, 8 * 512, 4321);
	m.multi(true, 64, 8, SD + 0xD10000, "CMD25 4 KB");
	write_check(SD + 0xD10000, 64, 8, "CMD25 4 KB");
	s = m.cmd(13, 0x00020000, 0x05);
	CHECK_EQ((m.resp() >> 9) & 15, 4, "CMD13: back in tran after 4 KB");
	// and read back through the host
	m.multi(false, 64, 8, SD + 0xD30000, "CMD18 read-back");
	for (int i = 0; i < 8 * 512; i++)
		if (b.sd_byte(SD + 0xD30000 + i) != b.sd_byte(SD + 0xD10000 + i)) { sim::fail("4 KB read-back byte %d", i); break; }
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

// A real game card's image (tools/mkcard.py's OUT.mmc: the sectors, then the
// NGAGEMMC trailer with the card's CID/CSD): identification, its CID and CSD,
// and the first 16 sectors read as two 4 KB transfers, against the file.
// Local test data, not in the repository: skipped when the file is absent.
void test_card(Bench &b, const std::string &path) {
	std::ifstream f(path, std::ios::binary);
	if (!f) { printf("game card: %s not found, skipped\n", path.c_str()); return; }
	std::vector<uint8_t> img((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
	if (img.size() < 32 * 512 || memcmp(img.data() + img.size() - 512, "NGAGEMMC", 8)) {
		sim::fail("game card: %s has no NGAGEMMC trailer", path.c_str());
		return;
	}
	printf("game card %s\n", path.c_str());
	const uint8_t *tr = img.data() + img.size() - 512;
	Mmc m(b);
	mount(b, img, true);
	m.cmd(0, 0, 0x01);
	uint32_t ocr = 0;
	int tries = 0;
	do { m.cmd(1, 0x80008000, 0x49); ocr = m.resp(); } while (!(ocr >> 31) && ++tries < 10);
	auto r2 = [&](const uint8_t *want, const char *what) {
		uint8_t w[16];
		memcpy(w, want, 15);
		w[15] = (uint8_t)(crc7(want, 15) << 1 | 1);
		for (int i = 0; i < 4; i++) {
			uint32_t v = m.resp(), e = (uint32_t)w[4 * i] << 24 | w[4 * i + 1] << 16 | w[4 * i + 2] << 8 | w[4 * i + 3];
			if (v != e) sim::fail("game card %s word %d: %08x, want %08x", what, i, v, e);
		}
	};
	CHECK_EQ(m.cmd(2, 0, 0x0D), 0x100, "game card CMD2");
	r2(tr + 16, "CID");
	m.cmd(3, 0x00010000, 0x05); m.resp();
	CHECK_EQ(m.cmd(9, 0x00010000, 0x0D), 0x100, "game card CMD9");
	r2(tr + 32, "CSD");
	m.cmd(7, 0x00010000, 0x05); m.resp();
	m.cmd(16, 512, 0x05); m.resp();
	m.multi(false, 0, 8, SD + 0xE00000, "game card sectors 0-7");
	m.multi(false, 8, 8, SD + 0xE00000 + 4096, "game card sectors 8-15");
	int bad = 0;
	for (int i = 0; i < 16 * 512; i++)
		if (b.sd_byte(SD + 0xE00000 + i) != img[i] && bad++ < 3) sim::fail("game card: byte %d is %02x, want %02x", i, b.sd_byte(SD + 0xE00000 + i), img[i]);
	CHECK_EQ(bad, 0, "game card sector bytes wrong");
	printf("  CID %02x%02x... read, sectors 0-15 match (sector 0 ends %02x%02x)\n", tr[16], tr[17], img[510], img[511]);
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
	// the power key counts as held for POWER_ON_HOLD_CLKS (20000 here) after
	// reset, and until 0x1F has been read once
	b.reset_core();
	b.run(5000);
	CHECK_EQ(c.read(1, 0x1F, 16), 0x0002, "UEMK 0x1F: power key held at power-on");
	CHECK_EQ(c.read(1, 0x1F, 16), 0x0002, "UEMK 0x1F: still held within the hold time");
	b.run(30000);
	CHECK_EQ(c.read(1, 0x15, 16), 0x0008, "UEMK 0x15");
	CHECK_EQ(c.read(1, 0x1F, 16), 0x0000, "UEMK 0x1F, power key up");
	b.reset_core();
	b.run(30000);
	CHECK_EQ(c.read(1, 0x1F, 16), 0x0002, "UEMK 0x1F: the first read after the hold time still sees the key");
	CHECK_EQ(c.read(1, 0x1F, 16), 0x0000, "UEMK 0x1F: released after the first read");
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
	// a device nothing is known of: storage (device 5 is the Bluetooth module, test_bt)
	for (int r = 0; r < 8; r++) c.write(3, r, 16, 0x1111u * r + 5);
	for (int r = 0; r < 8; r++) CHECK_EQ(c.read(3, r, 16), 0x1111u * r + 5, "device 3 storage");
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
			// the power key as the model had it then (UEMK 0x1F bit 1); its
			// timing is guest time against clocks, so bit 1 is not compared
			// here (the directed checks above test the key itself)
			if (dev == 1 && reg == 0x1F) { b.power = val >> 1 & 1; b.run(20); }
			b.wr16(CBUS + 0, len);
			b.wr16(CBUS + 2, ctrl);
			c.wait_done();
			uint32_t got = b.rd16(CBUS + 6) | (bits > 16 ? b.rd16(CBUS + 4) << 16 : 0);
			if (dev == 1 && reg == 0x1F) { got &= ~2u; val &= ~2u; }
			// the RTC's time and day counter are the wall clock's (test_rtc); the
			// calibration register's 0xC0 (cbus-regs.txt) is newer than some logs
			if (dev == 1 && (reg == 0x11 || reg == 0x12 || reg == 0x13 || reg == 0x01 || reg == 0x04)) { nr++; continue; }
			// the Bluetooth module answers in its own time (the bt bench)
			if (dev == 5) { nr++; continue; }
			nr++;
			if (got != val) sim::fail("cbus.log: dev %u reg %02x read 0x%x, the model logged 0x%x", dev, reg, got, val);
		}
	}
	b.power = false;
	printf("cbus.log replay: %d writes, %d reads checked\n", nw, nr);
}

// -------------------------------------------------------------------------
// the Bluetooth module behind CBUS and its interrupt line
// -------------------------------------------------------------------------
void test_bt(Bench &b) {
	printf("Bluetooth\n");
	Cbus c(b);
	const uint32_t EN_CLR = 0x0C150014u, EN_SET = 0x0C150016u, ST2 = 0x0C150102u;
	const int DEV = 5, DATA = 0x00, RXLEN = 0x01, STATUS = 0x06, REG0 = 0x08, REASON = 0x09, START = 0x0A;
	auto pending = [&]() { b.run(4); return b.t->irq != 0; };

	b.reset_core();
	b.wr(INTC + 0x08, 1u << 25);
	CHECK_EQ(c.read(DEV, STATUS, 16), 0x0004, "the module is awake and has nothing to say");
	CHECK_EQ(b.rd16(ST2), 0, "its interrupt bit is clear");
	CHECK_EQ(b.rd16(EN_SET), 0, "and disabled after reset");

	// the driver's open (btldd 0x503F0B14): the reset, then the enable
	c.write(DEV, STATUS, 16, 0);
	c.write(DEV, STATUS, 16, 1);
	CHECK_EQ(c.read(DEV, STATUS, 16), 0, "the module is deaf while it resets");
	b.run(2100);                    // BT_RESET_CLKS
	CHECK_EQ(b.rd16(ST2), 0, "the bit does not read as set while it is disabled");
	CHECK(!pending(), "nor raise CTSI_IRQ");
	b.wr16(EN_SET, 0x0010);
	CHECK_EQ(b.rd16(EN_SET), 0x0010, "the enables read back");
	CHECK_EQ(b.rd16(EN_CLR), 0x0010, "at both addresses");
	CHECK_EQ(b.rd16(ST2), 0x0010, "enabled, the latched bit shows");
	CHECK(pending(), "and raises CTSI_IRQ");
	CHECK_EQ(b.rd(INTC + 0x14), 26, "IRQ number 26: CTSI_IRQ");
	CHECK_EQ(b.rd16(CTSI) & 0xC, 0, "the key matrix's bits are not touched");
	b.wr16(ST2, 0x0010);            // the driver's acknowledge (btldd 0x503F0B68)
	CHECK_EQ(b.rd16(ST2), 0, "writing 1 clears it");
	CHECK(!pending(), "and the interrupt");
	CHECK_EQ(c.read(DEV, STATUS, 16), 0x0084, "status: the module has reset");
	CHECK_EQ(c.read(DEV, STATUS, 16), 0x0004, "the event clears when read");
	CHECK_EQ(c.read(DEV, REASON, 16), 0x0008, "reset reason: the phone asked");
	c.write(DEV, START, 16, 0x8000);
	CHECK(pending(), "the answer raises the interrupt");
	b.wr16(ST2, 0x0010);
	CHECK_EQ(c.read(DEV, STATUS, 16), 0x0044, "status: register 8 has an answer");
	CHECK_EQ(c.read(DEV, REG0, 16), 0x0208, "the buffer size");

	// Read_BD_ADDR the way the driver writes a packet, and its answer
	static const uint16_t cmd[3] = { 0x0100, 0x0910, 0x0000 };
	static const uint16_t ans[7] = { 0x0400, 0x0E0A, 0x0109, 0x1000, 0x0000, 0x0057, 0x6000 };
	c.write(DEV, REG0, 16, 0x8005);
	CHECK_EQ(c.read(DEV, STATUS, 16), 0x0044, "room granted");
	CHECK_EQ(c.read(DEV, REG0, 16), 0x0005, "for the five bytes");
	for (uint16_t w : cmd) c.write(DEV, DATA, 16, w);
	c.write(DEV, REG0, 16, 0xC005);
	CHECK(pending(), "the packet's acknowledge and the answer raise the interrupt");
	b.wr16(ST2, 0x0010);
	CHECK_EQ(c.read(DEV, STATUS, 16), 0x0054, "status: acknowledge and a packet");
	CHECK_EQ(c.read(DEV, REG0, 16), 0x4005, "the packet acknowledged");
	CHECK_EQ(c.read(DEV, RXLEN, 16), 14, "the answer's length");
	for (uint16_t w : ans) CHECK_EQ(c.read(DEV, DATA, 16), w, "the answer's words (00:60:57:00:00:00)");
	CHECK_EQ(c.read(DEV, RXLEN, 16), 0, "the phone has all of it");
	CHECK_EQ(c.read(DEV, 0x1F, 16), 0, "a register the module does not have reads 0");

	// disabled (the driver's close, btldd 0x503F084C), the line is held back
	b.wr16(EN_CLR, 0x0010);
	c.write(DEV, START, 16, 0x8000);
	CHECK_EQ(b.rd16(ST2), 0, "disabled: the bit does not read");
	CHECK(!pending(), "and does not interrupt");
	b.wr16(EN_SET, 0x0010);
	CHECK(pending(), "it was latched all the same");
	b.wr16(ST2, 0x0010);
	b.wr16(EN_CLR, 0x0010);
	(void)c.read(DEV, STATUS, 16);
	CHECK(!pending(), "quiet again");
}

// -------------------------------------------------------------------------
// the emulator devices: HLE audio, the RTC and its date register
// -------------------------------------------------------------------------
constexpr uint32_t AU = 0x0C1F0000u, RTC_DATE = 0x0C1F0100u;
constexpr uint64_t CLK = 104000000, RTC_SEC = 20000;

void test_audio(Bench &b) {
	printf("HLE audio device\n");
	CHECK_EQ(b.rd(AU), 0x41554431, "ID");
	CHECK_EQ(b.rd16(AU), 0, "a 16-bit read is dropped");
	b.wr16(AU + 0x0C, 8000);
	CHECK_EQ(b.rd(AU + 0x0C), 16000, "a 16-bit write is dropped");
	b.wr(AU + 0xFC, 0x12345678);
	CHECK_EQ(b.rd(AU + 0xFC), 0, "the rest of the window reads 0, not storage");
	// 40 frames of 0x2000 and 30 of -0x1000 at an odd halfword, mono, half volume
	const uint32_t A0 = SD + 0xD00000, A1 = SD + 0xD01002, L0 = 40, L1 = 30, R = 48000;
	for (uint32_t i = 0; i < L0; i++) { b.sd_poke(A0 + 2 * i, 0x00); b.sd_poke(A0 + 2 * i + 1, 0x20); }
	for (uint32_t i = 0; i < L1; i++) { b.sd_poke(A1 + 2 * i, 0x00); b.sd_poke(A1 + 2 * i + 1, 0xF0); }
	b.wr(AU + 0x0C, R);
	b.wr(AU + 0x10, A0);
	b.wr(AU + 0x14, A1);
	b.wr(AU + 0x18, L0);
	b.wr(AU + 0x1C, L1);
	b.wr(AU + 0x28, 0x80);
	b.wr(INTC + 0x08, 1u << 5);
	// a DMA transfer at the same time: the two take the master port in turns
	const uint32_t units = 3000, src = SD + 0xD10000, dst = SD + 0xD20000;
	fill_sdram(b, src, units * 4, 555);
	b.dma_setup(1, src, 4, 0x20, dst, 4, 0x20, units);
	b.wr(AU + 0x04, 3);
	uint64_t run_edge = b.p_edge;
	b.dma_start(1);
	auto frame_edge = [&](uint64_t n) { return run_edge + (n * CLK + R - 1) / R; };
	b.run(frame_edge(10) - b.cyc);
	CHECK_EQ((int16_t)b.t->audio_l, 0x1000, "output in buffer 0, left");
	CHECK_EQ((int16_t)b.t->audio_r, 0x1000, "output in buffer 0, right");
	while (!b.t->irq && b.cyc < frame_edge(L0) + 1000) b.run(1);
	CHECK(b.cyc >= frame_edge(L0) && b.cyc <= frame_edge(L0) + 4, "DONE0 interrupt %lld clocks from its frame",
	      (long long)(b.cyc - frame_edge(L0)));
	CHECK_EQ(b.rd(INTC + 0x14), 6, "IRQ number 6: source 5");
	CHECK_EQ(b.rd(AU + 0x20), 0x321, "STATUS: DONE0, FULL1, running, buffer 1");
	b.wr(AU + 0x20, 1);
	b.run(4);
	CHECK(!b.t->irq, "DONE0 acknowledged");
	b.run(frame_edge(L0 + 10) - b.cyc);
	CHECK_EQ((int16_t)b.t->audio_l, -0x800, "output in buffer 1");
	while (!b.dma_done(1) && b.cyc < run_edge + 3000000) b.run(16);
	for (uint32_t i = 0; i < units * 4; i++) {
		if (b.sd_byte(dst + i) != b.sd_byte(src + i)) { sim::fail("DMA with the audio device: byte %u differs", i); break; }
	}
	b.dma_finish(1);
	while (!b.t->irq && b.cyc < frame_edge(L0 + L1) + 1000) b.run(1);
	CHECK(b.cyc >= frame_edge(L0 + L1) && b.cyc <= frame_edge(L0 + L1) + 4, "DONE1 interrupt");
	CHECK_EQ(b.rd(AU + 0x2C) >= L0 + L1, 1, "PLAYED");
	b.wr(AU + 0x04, 0);
	b.run(CLK / 48000 * 3);
	CHECK_EQ(b.t->audio_l, 0, "output 0 when stopped");
	CHECK(!b.t->irq, "stop clears DONE");
	b.wr(INTC + 0x0C, 1u << 5);
}

struct Clock { int y, mo, d, h, mi, s; };

int days_since_2000(int y, int mo, int d) {
	static const int cum[] = {0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334};
	int n = 0;
	for (int i = 2000; i < y; i++) n += (i % 4 == 0) ? 366 : 365;
	return n + cum[mo - 1] + (mo > 2 && y % 4 == 0) + d - 1;
}

void set_rtc(Bench &b, const Clock &c) {
	auto bcd = [](int v) { return (uint32_t)((v / 10) << 4 | v % 10); };
	b.t->rtc[0] = bcd(c.s) | bcd(c.mi) << 8 | bcd(c.h) << 16 | bcd(c.d) << 24;
	b.t->rtc[1] = bcd(c.mo) | bcd(c.y % 100) << 8 | 2u << 16 | 0x40u << 24;   // weekday, the last byte
	b.t->rtc[2] ^= 1;
	b.run(4);
}

void test_rtc(Bench &b) {
	printf("UEMK RTC and the HLE RTC date register\n");
	Cbus c(b);
	b.reset_core();                 // after the CBUS log's writes
	// before the HPS has sent a time: date unknown, the clock runs from 00:00:00
	CHECK_EQ(b.rd(RTC_DATE), 0, "date register before the HPS sends a time");
	CHECK_EQ(c.read(1, 0x04, 8), 0xC0, "UEMK 0x04 (calibration) after reset");
	CHECK_EQ(c.read(1, 0x01, 8), 0, "day counter after reset");
	uint32_t s0 = c.read(1, 0x11, 8);
	b.run(RTC_SEC);
	CHECK_EQ(c.read(1, 0x11, 8), (s0 + 1) % 60, "the clock counts seconds");
	// the HPS's time
	set_rtc(b, {2026, 10, 20, 23, 59, 58});
	CHECK_EQ(b.rd(RTC_DATE), 2026u << 16 | 10 << 8 | 20, "date register: the HPS's date");
	CHECK_EQ(c.read(1, 0x13, 8), 23, "hours");
	CHECK_EQ(c.read(1, 0x12, 8), 59, "minutes");
	CHECK_EQ(c.read(1, 0x11, 8), 58, "seconds");
	CHECK_EQ(c.read(1, 0x01, 8), 0, "day counter 0 at the first time");
	CHECK_EQ(b.rd16(RTC_DATE), 0, "date register: a 16-bit read is dropped");
	CHECK_EQ(b.rd(RTC_DATE + 4), 0, "date register +4");
	b.wr(RTC_DATE, 0x12345678);
	CHECK_EQ(b.rd(RTC_DATE), 2026u << 16 | 10 << 8 | 20, "date register: writes are dropped");
	// midnight
	b.run(RTC_SEC * 5 / 2);
	CHECK_EQ(c.read(1, 0x11, 8), 0, "seconds after midnight");
	CHECK_EQ(c.read(1, 0x12, 8), 0, "minutes after midnight");
	CHECK_EQ(c.read(1, 0x13, 8), 0, "hours after midnight");
	CHECK_EQ(c.read(1, 0x01, 8), 1, "day counter after midnight");
	CHECK_EQ(b.rd(RTC_DATE), 2026u << 16 | 10 << 8 | 20, "the date register keeps the base date");
	// a written counter steps with the date from there
	c.write(1, 0x01, 8, 0x37);
	CHECK_EQ(c.read(1, 0x01, 8), 0x37, "day counter written");
	int base = days_since_2000(2026, 10, 21);
	struct { Clock t; const char *what; } steps[] = {
		{{2026, 10, 23, 10, 0, 0}, "two days on (an HPS time)"},
		{{2026, 12, 31, 23, 59, 59}, "the last day of the year"},
		{{2028, 2, 28, 23, 59, 59}, "the day before a leap day"},
		{{2027, 6, 30, 23, 59, 59}, "a time set back"},
	};
	for (auto &st : steps) {
		set_rtc(b, st.t);
		int want = (0x37 + days_since_2000(st.t.y, st.t.mo, st.t.d) - base) & 0xFF;
		CHECK_EQ(c.read(1, 0x01, 8), want, st.what);
		b.run(RTC_SEC * 3 / 2);
		CHECK_EQ(c.read(1, 0x01, 8), st.t.h == 23 ? (want + 1) & 0xFF : want, "the next day");
	}
	// a core reset: the date register takes the date, the counter starts at 0
	set_rtc(b, {2028, 2, 28, 23, 59, 59});
	b.run(RTC_SEC * 3 / 2);
	b.reset_core();
	CHECK_EQ(b.rd(RTC_DATE), 2028u << 16 | 2 << 8 | 29, "date register after a core reset: the leap day");
	CHECK_EQ(c.read(1, 0x01, 8), 0, "day counter after a core reset");
	CHECK_EQ(c.read(1, 0x13, 8), 0, "the wall clock runs through a core reset");
	// the 8-bit counter wraps
	c.write(1, 0x01, 8, 0xFF);
	set_rtc(b, {2028, 3, 1, 12, 0, 0});
	CHECK_EQ(c.read(1, 0x01, 8), 0x00, "day counter wraps");
	CHECK_EQ(c.read(1, 0x01, 4), 0x0, "masked to the transfer length");
	set_rtc(b, {2028, 3, 3, 12, 0, 0});
	CHECK_EQ(c.read(1, 0x01, 4), 0x2, "masked to the transfer length");
	// the calendar's ends, seen through the date register after a core reset
	struct { Clock t; uint32_t next; } ends[] = {
		{{2026, 12, 31, 23, 59, 59}, 2027u << 16 | 1 << 8 | 1},
		{{2026, 4, 30, 23, 59, 59}, 2026u << 16 | 5 << 8 | 1},
		{{2026, 2, 28, 23, 59, 59}, 2026u << 16 | 3 << 8 | 1},
		{{2028, 2, 29, 23, 59, 59}, 2028u << 16 | 3 << 8 | 1},
		{{2026, 7, 31, 23, 59, 59}, 2026u << 16 | 8 << 8 | 1},
		{{2026, 9, 29, 23, 59, 59}, 2026u << 16 | 9 << 8 | 30},
	};
	for (auto &e : ends) {
		set_rtc(b, e.t);
		b.run(RTC_SEC * 3 / 2);
		b.reset_core();
		CHECK_EQ(b.rd(RTC_DATE), e.next, "the date after a day's end");
	}
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
	std::string out = ".", model_out = "../model/.out", card;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = (uint32_t)strtoul(argv[++i], nullptr, 0);
		else if (!strcmp(argv[i], "--out") && i + 1 < argc) out = argv[++i];
		else if (!strcmp(argv[i], "--model-out") && i + 1 < argc) model_out = argv[++i];
		else if (!strcmp(argv[i], "--card") && i + 1 < argc) card = argv[++i];
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
	test_bt(b);
	test_rtc(b);
	test_audio(b);
	test_sti(b);
	test_dma(b);
	test_lcd(b);
	test_mmc(b);
	if (!card.empty()) test_card(b, card);
	test_reset(b);
	CHECK_EQ(b.chip.errors, 0, "SDRAM chip model errors");
	CHECK_EQ(b.ddr.protocol_errors, 0, "DDRAM port protocol errors");
	printf("periph: %llu clocks\n", (unsigned long long)b.cyc);
	return sim::finish("periph");
}
