// Bench for rtl/board/mmc_card.sv: a C++ MMC host on CLK/CMD/DAT0 and a
// model of hps_io's SD block interface serving a disk image.
//
//   Vmmc_card [--seed N]
//
// Cards:
//  1. a retail game card: 32760 blocks plus a sidecar with the SonicN CID and
//     CSD from research/peripherals/MMC.md (CCC 0x007, permanent write
//     protection). The CRC7 bytes the card sends must be the ones computed
//     there (0x5D, 0xDB).
//  2. a writable card from a plain image (no sidecar): the default CID/CSD,
//     the capacity from the file size, writes.
//  3. the same image mounted read-only, and a small odd-sized image.
// For each: the card answers nothing before it is mounted; the
// identification sequence (CMD0, CMD1 until ready, CMD2, CMD3) with the
// response timing (NID, NCR) and every CRC checked; CSD/CID/status; block
// reads (single, multiple with CMD12, partial and across blocks) with
// CRC16 against the image; out-of-range and misaligned addresses; illegal
// commands and bad command CRCs reported in the next status; deselect,
// inactive; writes with the CRC status token, busy, CMD25 + CMD12, a bad
// data CRC, write protection. The bus is checked for both sides driving.
#include "Vmmc_card.h"
#include "verilated.h"
#include "common.h"

#include <cstring>
#include <string>

namespace {

// -------------------------------------------------------------------------
// CRCs, written from the MMC specification
// -------------------------------------------------------------------------
uint8_t crc7_bits(const std::vector<int> &bits) {
	uint8_t c = 0;
	for (int b : bits) {
		int fb = ((c >> 6) & 1) ^ b;
		c = (uint8_t)((c << 1) & 0x7F);
		if (fb) c ^= 0x09;
	}
	return c;
}
uint8_t crc7_bytes(const uint8_t *p, int n) {
	std::vector<int> bits;
	for (int i = 0; i < n; i++) for (int k = 7; k >= 0; k--) bits.push_back(p[i] >> k & 1);
	return crc7_bits(bits);
}
uint16_t crc16_bytes(const uint8_t *p, int n) {
	uint16_t c = 0;
	for (int i = 0; i < n; i++)
		for (int k = 7; k >= 0; k--) {
			int fb = ((c >> 15) & 1) ^ (p[i] >> k & 1);
			c = (uint16_t)(c << 1);
			if (fb) c ^= 0x1021;
		}
	return c;
}

const uint8_t SONIC_CID[16] = {0x07, 0x00, 0x04, 0x00, 0x0B, 0x3B, 0x18, 0x29, 0x4D, 0x01, 0x00, 0xC4, 0x00, 0x20, 0x96, 0x00};
const uint8_t SONIC_CSD[16] = {0x8C, 0x08, 0x03, 0x2A, 0x00, 0x79, 0xA3, 0xFF, 0xB6, 0xC0, 0x81, 0xE1, 0x80, 0x00, 0x20, 0x00};

// R1 status bits
constexpr uint32_t OUT_OF_RANGE = 1u << 31, MISALIGN = 1u << 30, BLOCK_LEN = 1u << 29, WP_VIOL = 1u << 26,
	COM_CRC = 1u << 23, ILLEGAL = 1u << 22, READY_FOR_DATA = 1u << 8;
int state_of(uint32_t s) { return (s >> 9) & 15; }

// -------------------------------------------------------------------------
// hps_io's SD block interface
// -------------------------------------------------------------------------
struct Hps {
	std::vector<uint8_t> img;
	enum { IDLE, DELAY, XFER, END } st = IDLE;
	bool wr = false;
	uint32_t lba = 0;
	int delay = 0, word = 0, gap = 0;
	uint64_t reads = 0, writes = 0;
	sim::Rng *rng;
};

// -------------------------------------------------------------------------
// Bench: the card, the host's bus, the HPS
// -------------------------------------------------------------------------
struct Bench {
	Vmmc_card *t = new Vmmc_card;
	sim::Rng rng;
	Hps hps;
	uint64_t clocks = 0;
	size_t data_bytes = 0;       // the image without its sidecar
	int hi = 3, lo = 3;          // CLK phases in clocks
	bool h_cmd_oe = false, h_cmd = true, h_dat_oe = false, h_dat = true;

	Bench(uint32_t seed) : rng(seed) {
		hps.rng = &rng;
		t->clk = 0; t->reset = 1; t->mmc_clk = 0; t->cmd_i = 1; t->dat_i = 1;
		t->img_mounted = 0; t->img_readonly = 0; t->img_size = 0;
		t->sd_ack = 0; t->sd_buff_addr = 0; t->sd_buff_dout = 0; t->sd_buff_wr = 0;
		t->eval();
		for (int i = 0; i < 4; i++) tick();
		t->reset = 0;
		tick();
	}
	~Bench() { t->final(); delete t; }

	int cmd_line() const { return (h_cmd_oe ? h_cmd : 1) & (t->cmd_oe ? t->cmd_o : 1); }
	int dat_line() const { return (h_dat_oe ? h_dat : 1) & (t->dat_oe ? t->dat_o : 1); }

	void hps_step() {
		Hps &h = hps;
		t->sd_buff_wr = 0;
		switch (h.st) {
		case Hps::IDLE:
			if ((t->sd_rd || t->sd_wr) && !t->reset) {
				if (t->sd_rd && t->sd_wr) sim::fail("sd_rd and sd_wr together");
				h.wr = t->sd_wr;
				h.lba = t->sd_lba;
				if ((uint64_t)(h.lba + 1) * 512 > h.img.size()) sim::fail("HPS asked for block %u past the image", h.lba);
				h.delay = rng.chance(20) ? rng.range(500, 3000) : rng.range(20, 200);
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
			if (h.gap == 2 && (t->sd_rd || t->sd_wr)) sim::fail("sd_rd/sd_wr still high during the transfer");
			if (--h.gap > 0) break;
			h.gap = rng.range(3, 8);
			if (h.word < 256) {
				size_t off = (size_t)h.lba * 512 + h.word * 2;
				if (!h.wr) {
					t->sd_buff_addr = h.word;
					t->sd_buff_dout = (uint16_t)(h.img[off] | h.img[off + 1] << 8);
					t->sd_buff_wr = 1;
				} else {
					// the word at the current address, then the address moves on
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
		t->cmd_i = cmd_line();
		t->dat_i = dat_line();
		if (h_cmd_oe && t->cmd_oe) sim::fail("host and card both drive CMD");
		if (h_dat_oe && t->dat_oe) sim::fail("host and card both drive DAT0");
		t->clk = 1; t->eval();
		hps_step();
		t->clk = 0; t->eval();
		clocks++;
	}

	// one CLK period: the host's outputs change as CLK falls; the lines are
	// sampled as it rises
	void mclk(int &cmd_s, int &dat_s) {
		t->mmc_clk = 0;
		for (int i = 0; i < lo; i++) tick();
		cmd_s = cmd_line();
		dat_s = dat_line();
		t->mmc_clk = 1;
		for (int i = 0; i < hi; i++) tick();
	}
	void mclk() { int a, b; mclk(a, b); }
	void idle_clocks(int n) { h_cmd_oe = false; h_dat_oe = false; while (n-- > 0) mclk(); }

	void mount(std::vector<uint8_t> img, bool ro) {
		hps.img = std::move(img);
		t->img_size = hps.img.size();
		t->img_readonly = ro;
		t->img_mounted = 1;
		tick();
		t->img_mounted = 0;
		for (int i = 0; i < 20000 && !t->present; i++) tick();
		CHECK(t->present, "card not present after mounting");
	}

	// ---- commands and responses ----
	struct Resp {
		bool got = false;
		int ncr = -1;
		std::vector<int> bits;
		uint32_t field(int hi_bit, int lo_bit) const {  // bit numbers as in the specification
			uint32_t v = 0;
			int n = (int)bits.size();
			for (int b = hi_bit; b >= lo_bit; b--) v = v << 1 | (uint32_t)bits[n - 1 - b];
			return v;
		}
	};
	void send_cmd(int idx, uint32_t arg, bool bad_crc = false) {
		std::vector<int> bits = {0, 1};
		for (int k = 5; k >= 0; k--) bits.push_back(idx >> k & 1);
		for (int k = 31; k >= 0; k--) bits.push_back(arg >> k & 1);
		uint8_t c = crc7_bits(bits);
		if (bad_crc) c ^= 0x11;
		for (int k = 6; k >= 0; k--) bits.push_back(c >> k & 1);
		bits.push_back(1);
		h_cmd_oe = true;
		for (int b : bits) { h_cmd = b; mclk(); }
		h_cmd_oe = false;
		h_cmd = true;
	}
	// read a response of `len` bits; nothing within 80 clocks is no response
	Resp get_resp(int len) {
		Resp r;
		int c, d;
		for (int i = 0; i < 80; i++) {
			mclk(c, d);
			if (!c) { r.got = true; r.ncr = i; break; }
		}
		if (!r.got) return r;
		r.bits.push_back(0);
		for (int i = 1; i < len; i++) { mclk(c, d); r.bits.push_back(c); }
		return r;
	}
	// R1: checks the frame and returns the status
	bool r1(int idx, uint32_t arg, uint32_t &status, int want_ncr = 2, bool bad_crc = false) {
		send_cmd(idx, arg, bad_crc);
		Resp r = get_resp(48);
		if (!r.got) { idle_clocks(8); return false; }
		std::vector<int> head(r.bits.begin(), r.bits.begin() + 40);
		if (r.bits[1] != 0) sim::fail("CMD%d response: transmission bit 1", idx);
		if ((int)r.field(45, 40) != idx) sim::fail("CMD%d response: index %d", idx, r.field(45, 40));
		if (r.field(7, 1) != crc7_bits(head)) sim::fail("CMD%d response: CRC7 %02x, want %02x", idx, r.field(7, 1), crc7_bits(head));
		if (r.bits[47] != 1) sim::fail("CMD%d response: end bit 0", idx);
		if (want_ncr >= 0 && r.ncr != want_ncr) sim::fail("CMD%d response after %d clocks, want %d", idx, r.ncr, want_ncr);
		status = r.field(39, 8);
		// NRC; a read block may start NAC clocks after the response, so the
		// host listens on DAT0 at once after CMD17/18
		if (idx != 17 && idx != 18) idle_clocks(8);
		return true;
	}
	uint32_t status(uint16_t rca, const char *what) {
		uint32_t s = 0;
		if (!r1(13, (uint32_t)rca << 16, s)) sim::fail("%s: no answer to CMD13", what);
		return s;
	}
	// R2: CID or CSD; checks the frame and the register's own CRC7
	bool r2(int idx, uint32_t arg, uint8_t reg[16], int want_ncr) {
		send_cmd(idx, arg);
		Resp r = get_resp(136);
		if (!r.got) { idle_clocks(8); return false; }
		if (r.bits[1] != 0 || r.field(133, 128) != 0x3F) sim::fail("CMD%d R2 header", idx);
		if (r.bits[135] != 1) sim::fail("CMD%d R2 end bit", idx);
		if (want_ncr >= 0 && r.ncr != want_ncr) sim::fail("CMD%d R2 after %d clocks, want %d", idx, r.ncr, want_ncr);
		for (int i = 0; i < 16; i++) reg[i] = (uint8_t)r.field(127 - 8 * i, 120 - 8 * i);
		reg[15] |= 0;  // bit 0 of the register is the frame's end bit
		uint8_t want = (uint8_t)(crc7_bytes(reg, 15) << 1 | 1);
		if ((reg[15] | 1) != want) sim::fail("CMD%d: register CRC %02x, want %02x", idx, reg[15] | 1, want);
		reg[15] |= 1;
		idle_clocks(8);
		return true;
	}

	// ---- data ----
	// a block from the card: false when no start bit came
	bool read_data(std::vector<uint8_t> &out, int len, int *nac = nullptr, int timeout = 400000) {
		int c, d;
		int i = 0;
		for (; i < timeout; i++) { mclk(c, d); if (!d) break; }
		if (i == timeout) return false;
		if (nac) *nac = i;
		out.assign(len, 0);
		for (int b = 0; b < len * 8; b++) { mclk(c, d); out[b / 8] = (uint8_t)(out[b / 8] << 1 | d); }
		uint16_t crc = 0;
		for (int b = 0; b < 16; b++) { mclk(c, d); crc = (uint16_t)(crc << 1 | d); }
		mclk(c, d);
		if (d != 1) sim::fail("read data: end bit 0");
		uint16_t want = crc16_bytes(out.data(), len);
		if (crc != want) sim::fail("read data: CRC16 %04x, want %04x", crc, want);
		return true;
	}
	// a block to the card; returns the CRC status (2 = accepted, 5 = CRC
	// error, -1 = none) and waits for the end of busy
	int write_data(const uint8_t *p, int len, bool bad_crc = false, uint64_t *busy_clocks = nullptr) {
		idle_clocks(2);
		uint16_t crc = crc16_bytes(p, len);
		if (bad_crc) crc ^= 0x0100;
		h_dat_oe = true;
		h_dat = 0; mclk();
		for (int b = 0; b < len * 8; b++) { h_dat = p[b / 8] >> (7 - b % 8) & 1; mclk(); }
		for (int b = 15; b >= 0; b--) { h_dat = crc >> b & 1; mclk(); }
		h_dat = 1; mclk();
		h_dat_oe = false;
		int c, d, i;
		for (i = 0; i < 10; i++) { mclk(c, d); if (!d) break; }
		if (i == 10) return -1;
		int s = 0;
		for (int k = 0; k < 3; k++) { mclk(c, d); s = s << 1 | d; }
		mclk(c, d);
		if (d != 1) sim::fail("CRC status token: end bit 0");
		uint64_t c0 = clocks;
		for (i = 0; i < 400000; i++) { mclk(c, d); if (d) break; }
		if (i == 400000) sim::fail("busy never ended");
		if (busy_clocks) *busy_clocks = clocks - c0;
		return s;
	}
};

// -------------------------------------------------------------------------
// Images
// -------------------------------------------------------------------------
std::vector<uint8_t> pattern_image(uint32_t blocks, uint32_t seed) {
	std::vector<uint8_t> v((size_t)blocks * 512);
	uint32_t x = seed;
	for (size_t i = 0; i < v.size(); i++) { x = x * 1664525u + 1013904223u; v[i] = (uint8_t)(x >> 24); }
	return v;
}
void add_sidecar(std::vector<uint8_t> &img, const uint8_t cid[16], const uint8_t csd[16], uint32_t ocr) {
	std::vector<uint8_t> s(512, 0);
	memcpy(s.data(), "NGAGEMMC", 8);
	s[8] = 1;
	memcpy(s.data() + 16, cid, 16);
	memcpy(s.data() + 32, csd, 16);
	s[48] = (uint8_t)(ocr >> 24); s[49] = (uint8_t)(ocr >> 16); s[50] = (uint8_t)(ocr >> 8); s[51] = (uint8_t)ocr;
	s[15] = 0xA5;  // junk the card must not care about
	img.insert(img.end(), s.begin(), s.end());
}

// identification up to the selected card; returns the RCA used
uint16_t identify(Bench &b, const uint8_t want_cid[16], uint32_t want_ocr) {
	uint32_t s;
	b.send_cmd(0, 0);
	b.idle_clocks(8);
	// CMD1 until ready: the first answer is busy
	int tries = 0;
	uint32_t ocr = 0;
	for (;;) {
		b.send_cmd(1, 0x00FF8000);
		Bench::Resp r = b.get_resp(48);
		if (!r.got) { sim::fail("no answer to CMD1"); return 0; }
		if (r.ncr != 5) sim::fail("CMD1 answer after %d clocks, want NID = 5", r.ncr);
		if (r.field(45, 40) != 0x3F || r.field(7, 1) != 0x7F || r.bits[47] != 1) sim::fail("R3 frame");
		ocr = r.field(39, 8);
		b.idle_clocks(8);
		tries++;
		if (ocr >> 31) break;
		if (tries > 10) { sim::fail("card stays busy"); return 0; }
	}
	CHECK_EQ(tries, 2, "CMD1 tries until ready");
	CHECK_EQ(ocr, want_ocr | 0x80000000u, "OCR");
	uint8_t cid[16];
	if (!b.r2(2, 0, cid, 5)) sim::fail("no answer to CMD2");
	for (int i = 0; i < 15; i++) if (cid[i] != want_cid[i]) { sim::fail("CID byte %d = %02x, want %02x", i, cid[i], want_cid[i]); break; }
	CHECK_EQ(cid[15], crc7_bytes(want_cid, 15) << 1 | 1, "CID CRC byte");
	// CMD2 again: the card is no longer in ready
	uint8_t junk[16];
	CHECK(!b.r2(2, 0, junk, -1), "card answers CMD2 in the ident state");
	uint16_t rca = 0x4A11;
	if (!b.r1(3, (uint32_t)rca << 16, s)) sim::fail("no answer to CMD3");
	CHECK_EQ(state_of(s), 2, "state in the CMD3 answer (ident)");
	CHECK(s & ILLEGAL, "the CMD2 in ident is not reported as illegal");
	s = b.status(rca, "after CMD3");
	CHECK_EQ(state_of(s), 3, "state after CMD3 (stby)");
	CHECK_EQ(s & ILLEGAL, 0, "ILLEGAL_COMMAND not cleared");
	return rca;
}

void select(Bench &b, uint16_t rca) {
	uint32_t s;
	if (!b.r1(7, (uint32_t)rca << 16, s)) sim::fail("no answer to CMD7");
	CHECK_EQ(state_of(s), 3, "state in the CMD7 answer");
	CHECK_EQ(state_of(b.status(rca, "after CMD7")), 4, "state after CMD7 (tran)");
}

void check_block(Bench &b, uint32_t addr, int len, const char *what) {
	std::vector<uint8_t> got;
	if (!b.read_data(got, len)) { sim::fail("%s: no data at %08x", what, addr); return; }
	for (int i = 0; i < len; i++) {
		uint8_t want = (size_t)addr + i < b.data_bytes ? b.hps.img[addr + i] : 0;
		if (got[i] != want) { sim::fail("%s: byte %d at %08x = %02x, want %02x", what, i, addr, got[i], want); return; }
	}
}

// reads shared by every card
void test_reads(Bench &b, uint16_t rca, uint32_t blocks) {
	uint32_t s;
	// single blocks
	for (uint32_t blk : {0u, 1u, 77u, blocks / 2, blocks - 1}) {
		if (!b.r1(17, blk * 512, s)) { sim::fail("no answer to CMD17"); continue; }
		CHECK_EQ(s & 0xFFFF0000u, 0, "CMD17 error bits");
		CHECK_EQ(state_of(s), 4, "state in the CMD17 answer");
		check_block(b, blk * 512, 512, "CMD17");
		b.idle_clocks(4);
		CHECK_EQ(state_of(b.status(rca, "after CMD17")), 4, "state after a block (tran)");
	}
	// past the end
	if (b.r1(17, blocks * 512, s)) {
		CHECK(s & OUT_OF_RANGE, "CMD17 past the end: no OUT_OF_RANGE (%08x)", s);
		std::vector<uint8_t> junk;
		CHECK(!b.read_data(junk, 512, nullptr, 3000), "data sent for an out-of-range read");
	} else sim::fail("no answer to CMD17 past the end");
	// several blocks, then CMD12 while the next one is on its way
	{
		uint32_t first = 300;
		if (!b.r1(18, first * 512, s)) sim::fail("no answer to CMD18");
		for (int k = 0; k < 5; k++) check_block(b, (first + k) * 512, 512, "CMD18");
		if (!b.r1(12, 0, s, -1)) sim::fail("no answer to CMD12");
		CHECK_EQ(state_of(s), 5, "state in the CMD12 answer (data)");
		b.idle_clocks(4);
		int c, d, low = 0;
		for (int i = 0; i < 2000; i++) { b.mclk(c, d); if (!d) low++; }
		CHECK_EQ(low, 0, "DAT0 driven after CMD12");
		CHECK_EQ(state_of(b.status(rca, "after CMD12")), 4, "state after CMD12 (tran)");
	}
	// CMD18 running into the end: OUT_OF_RANGE comes with CMD12
	{
		if (!b.r1(18, (blocks - 2) * 512, s)) sim::fail("no answer to CMD18 at the end");
		check_block(b, (blocks - 2) * 512, 512, "CMD18 at the end");
		check_block(b, (blocks - 1) * 512, 512, "CMD18 last block");
		std::vector<uint8_t> junk;
		CHECK(!b.read_data(junk, 512, nullptr, 3000), "data past the end");
		if (!b.r1(12, 0, s, -1)) sim::fail("no answer to CMD12 at the end");
		CHECK(s & OUT_OF_RANGE, "no OUT_OF_RANGE after reading past the end (%08x)", s);
		CHECK_EQ(b.status(rca, "after OUT_OF_RANGE") & OUT_OF_RANGE, 0, "OUT_OF_RANGE not cleared");
	}
	// partial blocks across block boundaries
	{
		if (!b.r1(16, 100, s)) sim::fail("no answer to CMD16");
		CHECK_EQ(s & BLOCK_LEN, 0, "CMD16 100");
		if (!b.r1(17, 5 * 512 + 450, s)) sim::fail("no answer to a partial CMD17");
		check_block(b, 5 * 512 + 450, 100, "partial read across two blocks");
		uint32_t a = 9 * 512 + 333;
		if (!b.r1(18, a, s)) sim::fail("no answer to a partial CMD18");
		for (int k = 0; k < 12; k++) check_block(b, a + 100 * k, 100, "partial multiple read");
		b.r1(12, 0, s, -1);
		b.idle_clocks(20);
		if (!b.r1(16, 1, s)) sim::fail("no answer to CMD16 1");
		if (!b.r1(18, 1023, s)) sim::fail("no answer to CMD18 of single bytes");
		for (int k = 0; k < 4; k++) check_block(b, 1023 + k, 1, "one-byte blocks");
		b.r1(12, 0, s, -1);
		b.idle_clocks(20);
		if (!b.r1(16, 513, s)) sim::fail("no answer to CMD16 513");
		CHECK(s & BLOCK_LEN, "CMD16 513 accepted");
		if (!b.r1(16, 512, s)) sim::fail("no answer to CMD16 512");
		CHECK_EQ(s & BLOCK_LEN, 0, "CMD16 512");
	}
}

// errors, addressing, inactive: shared by every card
void test_protocol(Bench &b, uint16_t rca) {
	uint32_t s;
	// an unknown command (CMD8, SD's SEND_IF_COND) gets nothing, and is reported
	b.send_cmd(8, 0x1AA);
	CHECK(!b.get_resp(48).got, "answer to CMD8");
	b.idle_clocks(8);
	s = b.status(rca, "after CMD8");
	CHECK(s & ILLEGAL, "CMD8 not reported as illegal (%08x)", s);
	CHECK_EQ(b.status(rca, "after reporting") & ILLEGAL, 0, "ILLEGAL_COMMAND not cleared");
	// a bad CRC
	uint32_t dummy;
	CHECK(!b.r1(13, (uint32_t)rca << 16, dummy, 2, true), "answer to a command with a bad CRC");
	s = b.status(rca, "after a bad CRC");
	CHECK(s & COM_CRC, "COM_CRC_ERROR not set (%08x)", s);
	// another card's address
	CHECK(!b.r1(13, (uint32_t)(rca + 1) << 16, dummy), "answer to CMD13 for another RCA");
	// CMD9/CMD10 only in stby
	uint8_t reg[16];
	CHECK(!b.r2(9, (uint32_t)rca << 16, reg, -1), "CSD in tran");
	CHECK(b.status(rca, "after CMD9 in tran") & ILLEGAL, "CMD9 in tran not illegal");
	// deselect (RCA 0): no answer, back to stby
	CHECK(!b.r1(7, 0, dummy), "answer to CMD7 deselect");
	CHECK_EQ(state_of(b.status(rca, "after deselect")), 3, "state after deselect (stby)");
	CHECK(b.r2(10, (uint32_t)rca << 16, reg, 2), "no CID in stby");
	select(b, rca);
}

void test_inactive(Bench &b, uint16_t rca) {
	uint32_t s;
	b.r1(7, 0, s);
	CHECK(!b.r1(15, (uint32_t)rca << 16, s), "answer to CMD15");
	CHECK(!b.r1(13, (uint32_t)rca << 16, s), "inactive card answers CMD13");
	b.send_cmd(0, 0);
	b.idle_clocks(8);
	b.send_cmd(1, 0x00FF8000);
	CHECK(!b.get_resp(48).got, "inactive card answers CMD1 after CMD0");
	b.idle_clocks(8);
}

void test_writes(Bench &b, uint16_t rca, uint32_t blocks) {
	uint32_t s;
	std::vector<uint8_t> data(512);
	for (int i = 0; i < 512; i++) data[i] = (uint8_t)(i * 7 + 3);
	uint64_t writes0 = b.hps.writes;
	// one block
	if (!b.r1(24, 10 * 512, s)) sim::fail("no answer to CMD24");
	CHECK_EQ(s & 0xFFFF0000u, 0, "CMD24 error bits");
	uint64_t busy = 0;
	int tok = b.write_data(data.data(), 512, false, &busy);
	CHECK_EQ(tok, 2, "CRC status of a good block");
	CHECK(busy > 0, "no busy after a write");
	CHECK(memcmp(&b.hps.img[10 * 512], data.data(), 512) == 0, "block 10 not written to the image");
	CHECK_EQ(b.hps.writes - writes0, 1, "HPS writes for one block");
	CHECK_EQ(state_of(b.status(rca, "after CMD24")), 4, "state after a write (tran)");
	if (!b.r1(17, 10 * 512, s)) sim::fail("no answer to CMD17 after a write");
	{
		// the block is still in the buffer: the data comes NAC = 2 clocks
		// after the response
		std::vector<uint8_t> got;
		int nac = -1;
		if (!b.read_data(got, 512, &nac)) sim::fail("no data reading back a written block");
		CHECK_EQ(nac, 2, "NAC for a block already in the buffer");
		CHECK(memcmp(got.data(), data.data(), 512) == 0, "read back a written block");
	}
	// CMD13 while busy shows prg and not ready for data
	{
		if (!b.r1(24, 11 * 512, s)) sim::fail("no answer to CMD24 (2)");
		b.idle_clocks(2);
		uint16_t crc = crc16_bytes(data.data(), 512);
		b.h_dat_oe = true;
		b.h_dat = 0; b.mclk();
		for (int k = 0; k < 4096; k++) { b.h_dat = data[k / 8] >> (7 - k % 8) & 1; b.mclk(); }
		for (int k = 15; k >= 0; k--) { b.h_dat = crc >> k & 1; b.mclk(); }
		b.h_dat = 1; b.mclk();
		b.h_dat_oe = false;
		b.idle_clocks(8);
		s = b.status(rca, "while programming");
		CHECK_EQ(state_of(s), 7, "state while programming (prg)");
		CHECK_EQ(s & READY_FOR_DATA, 0, "READY_FOR_DATA while programming");
		int c, d;
		for (int i = 0; i < 400000; i++) { b.mclk(c, d); if (d) break; }
		CHECK_EQ(state_of(b.status(rca, "after programming")), 4, "state after programming");
		CHECK(memcmp(&b.hps.img[11 * 512], data.data(), 512) == 0, "block 11 not written");
	}
	// several blocks, then CMD12
	{
		std::vector<uint8_t> old = b.hps.img;
		if (!b.r1(25, 40 * 512, s)) sim::fail("no answer to CMD25");
		for (int k = 0; k < 3; k++) {
			for (int i = 0; i < 512; i++) data[i] = (uint8_t)(i ^ (k * 37));
			CHECK_EQ(b.write_data(data.data(), 512), 2, "CRC status in CMD25");
			CHECK(memcmp(&b.hps.img[(40 + k) * 512], data.data(), 512) == 0, "CMD25 block not written");
		}
		if (!b.r1(12, 0, s, -1)) sim::fail("no answer to CMD12 after CMD25");
		CHECK_EQ(state_of(s), 6, "state in the CMD12 answer (rcv)");
		CHECK(memcmp(&b.hps.img[43 * 512], &old[43 * 512], 512) == 0, "a fourth block written");
		CHECK_EQ(state_of(b.status(rca, "after CMD25")), 4, "state after CMD25");
	}
	// a bad data CRC: the block is refused and not written
	{
		std::vector<uint8_t> old(b.hps.img.begin() + 50 * 512, b.hps.img.begin() + 51 * 512);
		if (!b.r1(24, 50 * 512, s)) sim::fail("no answer to CMD24 (bad CRC)");
		CHECK_EQ(b.write_data(data.data(), 512, true), 5, "CRC status of a bad block");
		CHECK(memcmp(&b.hps.img[50 * 512], old.data(), 512) == 0, "a bad block was written");
		CHECK_EQ(state_of(b.status(rca, "after a bad block")), 4, "state after a bad block");
		if (!b.r1(17, 50 * 512, s)) sim::fail("no answer to CMD17 after a bad block");
		check_block(b, 50 * 512, 512, "read after a refused block");
	}
	// addressing and length errors
	if (b.r1(24, 50 * 512 + 4, s)) CHECK(s & MISALIGN, "misaligned CMD24 accepted (%08x)", s);
	else sim::fail("no answer to a misaligned CMD24");
	if (b.r1(24, blocks * 512, s)) CHECK(s & OUT_OF_RANGE, "CMD24 past the end accepted (%08x)", s);
	else sim::fail("no answer to CMD24 past the end");
	b.r1(16, 256, s);
	if (b.r1(24, 0, s)) CHECK(s & BLOCK_LEN, "CMD24 with a 256-byte block length accepted (%08x)", s);
	else sim::fail("no answer to CMD24 with a short block length");
	b.r1(16, 512, s);
	CHECK_EQ(state_of(b.status(rca, "after write errors")), 4, "state after write errors");
}

void retail_card(Bench &b) {
	printf("retail card (SonicN registers)\n");
	// nothing mounted: nothing answers
	b.send_cmd(0, 0);
	b.idle_clocks(8);
	b.send_cmd(1, 0x00FF8000);
	CHECK(!b.get_resp(48).got, "answer to CMD1 with no image");
	b.idle_clocks(8);

	// the CSD says 32760 blocks; the file holds 32700 of data, so the last 60
	// read as zeros (and never as the sidecar)
	const uint32_t blocks = 32760;
	std::vector<uint8_t> img = pattern_image(32700, 7);
	b.data_bytes = img.size();
	add_sidecar(img, SONIC_CID, SONIC_CSD, 0x00FF8000);
	b.mount(img, true);
	CHECK(b.t->write_protected, "retail card not write protected");

	// the CRC bytes MMC.md computed for these registers
	CHECK_EQ(crc7_bytes(SONIC_CID, 15) << 1 | 1, 0x5D, "bench CRC7 of the SonicN CID");
	CHECK_EQ(crc7_bytes(SONIC_CSD, 15) << 1 | 1, 0xDB, "bench CRC7 of the SonicN CSD");

	uint16_t rca = identify(b, SONIC_CID, 0x00FF8000);
	uint8_t csd[16], cid[16];
	if (!b.r2(9, (uint32_t)rca << 16, csd, 2)) sim::fail("no answer to CMD9");
	for (int i = 0; i < 15; i++) CHECK_EQ(csd[i], SONIC_CSD[i], "CSD byte");
	CHECK_EQ(csd[15], 0xDB, "CSD CRC byte");
	if (!b.r2(10, (uint32_t)rca << 16, cid, 2)) sim::fail("no answer to CMD10");
	CHECK_EQ(cid[15], 0x5D, "CID CRC byte (CMD10)");
	select(b, rca);
	test_reads(b, rca, blocks);
	{
		uint32_t s;
		if (!b.r1(18, 32699 * 512, s)) sim::fail("no answer to CMD18 at the end of the data");
		for (int k = 0; k < 3; k++) check_block(b, (32699 + k) * 512, 512, "blocks past the end of the file");
		b.r1(12, 0, s, -1);
	}
	// no write class: CMD24 is illegal
	uint32_t s;
	CHECK(!b.r1(24, 0, s), "retail card answers CMD24");
	CHECK(b.status(rca, "after CMD24") & ILLEGAL, "CMD24 on a ROM card not illegal");
	CHECK(!b.r1(25, 0, s), "retail card answers CMD25");
	b.status(rca, "after CMD25");
	CHECK_EQ(b.hps.writes, 0, "HPS writes on a ROM card");
	test_protocol(b, rca);
	test_inactive(b, rca);
}

void homebrew_card(Bench &b) {
	printf("writable card (no sidecar)\n");
	const uint32_t blocks = 16384;
	b.data_bytes = (size_t)blocks * 512;
	b.mount(pattern_image(blocks, 99), false);
	CHECK(!b.t->write_protected, "plain image write protected");
	uint8_t want_cid[16] = {0x00, 0x00, 0x00, 'M', 'i', 'S', 'T', 'e', 'r', 0x10, 0x00, 0x00, 0x00, 0x01, 0x17, 0x00};
	uint16_t rca = identify(b, want_cid, 0x00FF8000);
	uint8_t csd[16];
	if (!b.r2(9, (uint32_t)rca << 16, csd, 2)) sim::fail("no answer to CMD9");
	uint32_t ccc = (uint32_t)csd[4] << 4 | csd[5] >> 4;
	uint32_t c_size = (uint32_t)(csd[6] & 3) << 10 | (uint32_t)csd[7] << 2 | csd[8] >> 6;
	uint32_t mult = (uint32_t)(csd[9] & 3) << 1 | csd[10] >> 7;
	uint32_t rbl = csd[5] & 15;
	CHECK_EQ(ccc, 0x015, "default CCC");
	CHECK_EQ(rbl, 9, "default READ_BL_LEN");
	CHECK_EQ((uint64_t)(c_size + 1) << (mult + 2), blocks, "default capacity in blocks");
	CHECK_EQ((csd[12] & 3) << 2 | csd[13] >> 6, 9, "default WRITE_BL_LEN");
	CHECK_EQ(csd[14] & 0x30, 0, "write protection in the default CSD");
	select(b, rca);
	test_reads(b, rca, blocks);
	test_writes(b, rca, blocks);
	test_protocol(b, rca);
}

void readonly_card(Bench &b) {
	printf("plain image mounted read-only, odd size\n");
	b.hps.writes = 0;
	const uint32_t blocks = 40001;  // capacity rounds down to 40000
	b.data_bytes = (size_t)blocks * 512;
	b.mount(pattern_image(blocks, 5), true);
	CHECK(b.t->write_protected, "read-only image not write protected");
	uint8_t want_cid[16] = {0x00, 0x00, 0x00, 'M', 'i', 'S', 'T', 'e', 'r', 0x10, 0x00, 0x00, 0x00, 0x01, 0x17, 0x00};
	uint16_t rca = identify(b, want_cid, 0x00FF8000);
	uint8_t csd[16];
	b.r2(9, (uint32_t)rca << 16, csd, 2);
	uint32_t c_size = (uint32_t)(csd[6] & 3) << 10 | (uint32_t)csd[7] << 2 | csd[8] >> 6;
	uint32_t mult = (uint32_t)(csd[9] & 3) << 1 | csd[10] >> 7;
	CHECK_EQ((uint64_t)(c_size + 1) << (mult + 2), 40000, "capacity of a 40001-block image");
	CHECK(csd[14] & 0x10, "TMP_WRITE_PROTECT not set");
	select(b, rca);
	uint32_t s;
	if (b.r1(24, 0, s)) CHECK(s & WP_VIOL, "write to a protected card: no WP_VIOLATION (%08x)", s);
	else sim::fail("no answer to CMD24 on a protected card");
	CHECK_EQ(b.hps.writes, 0, "HPS writes on a protected card");
	if (!b.r1(17, 39999 * 512, s)) sim::fail("no answer to CMD17 at the last block");
	check_block(b, 39999 * 512, 512, "last block");
	if (b.r1(17, 40000 * 512, s)) CHECK(s & OUT_OF_RANGE, "block 40000 is past the capacity");
}

}  // namespace

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	uint32_t seed = 1;
	for (int i = 1; i < argc; i++)
		if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = (uint32_t)atoi(argv[++i]);
	Bench b(seed);
	b.hi = b.rng.range(2, 4);
	b.lo = b.rng.range(2, 4);
	printf("CLK high %d, low %d clocks\n", b.hi, b.lo);
	retail_card(b);
	homebrew_card(b);
	readonly_card(b);
	printf("HPS: %llu block reads, %llu block writes; %llu clocks\n",
		(unsigned long long)b.hps.reads, (unsigned long long)b.hps.writes, (unsigned long long)b.clocks);
	return sim::finish("mmc_card");
}
