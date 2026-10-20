// A single-data-rate SDRAM chip as a MiSTer SDRAM module carries it, for the
// Verilator benches: 4 banks x 8192 rows x 512 columns x 16 bits (32 MB),
// with the checks a real chip would impose on a controller:
//   * power-up: 200 us of NOPs, then PRECHARGE ALL, INIT_REFRESHES refreshes
//     and the mode register before the first ACTIVE;
//   * tRCD, tRP, tRAS (min and max), tRC, tRRD, tRFC, tWR (and two clocks),
//     tMRD; commands to banks in the wrong state;
//   * the refresh interval: every gap between two AUTO REFRESH commands
//     must be at most tREFI (7.8125 us);
//   * reads: CAS latency and burst length from the mode register, sequential
//     wrap, a burst cut by PRECHARGE (x = CL - 1) or another READ, DQM read
//     masking two clocks ahead; writes: single-location or burst mode, DQM
//     masking; DQ contention between the chip and the controller;
//   * the read capture: the chip clock is the inverted FPGA clock, so the
//     chip samples a command half a clock after the FPGA's edge, and a read
//     halfword reaches the FPGA's DQ register in the window
//     [edge(CL-1) + tAC + D, edge(CL) + tOH + D] after the READ, where D is
//     the clock-out, board and input delay (D_MIN..D_MAX). The halfword the
//     DQ register takes at an FPGA edge is the one whose window holds the
//     edge (with setup and hold) for every D; an edge on the border of a
//     window is an error, and an edge in no window reads junk.
// Timings are the slowest of the AS4C16M16SA, AS4C32M16SB and W9825G6KH
// data sheets (as in Apple-III-MiSTer's sim/sdram/sdram_model.sv).
//
// Timebase: FPGA edge e is at e * tck; the chip's edge for the outputs the
// controller registered at FPGA edge e is at e * tck + tck / 2.
//   edge(e, pins)  once per clock, after FPGA edge e, with the outputs it set
//   sample(e)      before FPGA edge e: the halfword the DQ register takes
#pragma once
#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <random>
#include <string>
#include <vector>

struct SdramTiming {
	double tck = 1000.0 / 104.0;   // ns
	double rcd = 20, rp = 20, ras = 45, ras_max = 100000, rc = 70, rfc = 70, wr = 15, rrd = 15;
	int    mrd_clk = 2, wr_min_clk = 2;
	double refi = 7812.5;
	double powerup = 200000;
	int    init_refreshes = 8;
	double tac_cl2 = 6.0, tac_cl3 = 5.4, toh = 2.5;
	double d_min = 4.5, d_max = 7.0;   // clock out + board + DQ input delay
	double su = 0.5, hold = 0.5;       // FPGA DQ register
};

struct SdramPins {
	bool     cs_n = true, ras_n = true, cas_n = true, we_n = true;
	int      ba = 0, a = 0;
	int      dqm = 0;                   // bit 0 DQML, bit 1 DQMH
	bool     dq_oe = false;
	uint16_t dq_o = 0;
};

class SdramChip {
public:
	static constexpr int BANKS = 4, ROWS = 8192, COLS = 512;
	SdramTiming tm;
	std::vector<uint16_t> mem;
	int errors = 0;
	uint64_t refreshes = 0, reads = 0, writes = 0, activates = 0;
	double max_refresh_gap = 0;
	bool quiet = false;

	explicit SdramChip(uint32_t seed = 1, SdramTiming t = SdramTiming()) : tm(t), mem((size_t)BANKS * ROWS * COLS), rng(seed) {
		for (auto &w : mem) w = (uint16_t)rng();
		for (auto &b : bank) b = Bank();
	}

	uint16_t &at(int b, int r, int c) { return mem[((size_t)b * ROWS + r) * COLS + c]; }
	// the halfword at a linear halfword address: column 8:0, row 21:9, bank 23:22
	uint16_t &lin(uint32_t h) { return at((h >> 22) & 3, (h >> 9) & 8191, h & 511); }

	void edge(uint64_t e, const SdramPins &p) {
		double now = e * tm.tck + tm.tck / 2;
		cur_edge = e;
		dqm_hist.push_back(p.dqm);
		if (dqm_hist.size() > 8) dqm_hist.pop_front();

		// precharges that finish
		for (int b = 0; b < BANKS; b++)
			if (bank[b].state == PRE && now + EPS >= bank[b].ready) bank[b].state = IDLE;
		// active too long
		for (int b = 0; b < BANKS; b++)
			if (bank[b].state == ACT && now - bank[b].t_act > tm.ras_max) { err("bank %d open longer than tRAS max", b); bank[b].t_act = now; }
		// refresh interval
		if (mode_set && refreshes > (uint64_t)tm.init_refreshes && now - last_refresh > tm.refi + EPS) {
			err("%.0f ns without a refresh", now - last_refresh);
			last_refresh = now;
		}
		// contention: the controller drives DQ while a read halfword is on the bus
		if (p.dq_oe) {
			for (auto &r : rd)
				if (!r.dropped && win_lo(r, tm.d_min) - tm.su < (e + 1) * tm.tck && win_hi(r, tm.d_max) + tm.hold > e * tm.tck) {
					err("DQ driven by the controller while the chip drives it");
					break;
				}
		}

		if (p.cs_n) return;
		int cmd = (p.ras_n << 2) | (p.cas_n << 1) | (int)p.we_n;
		if (cmd == 7) return;   // NOP

		if (!started) {
			if (now < tm.powerup) err("command at %.0f ns, before %.0f ns of power-up NOPs", now, tm.powerup);
			started = true;
		}
		if (now + EPS < rfc_until) err("command inside tRFC");
		if (e < mrd_until) err("command inside tMRD");

		int b = p.ba & 3;
		Bank &k = bank[b];
		switch (cmd) {
		case 3: {   // ACTIVE
			if (!precharged_all || refreshes < (uint64_t)tm.init_refreshes || !mode_set)
				err("ACTIVE before the power-up sequence (precharge %d, refreshes %llu, mode %d)",
					precharged_all, (unsigned long long)refreshes, mode_set);
			if (k.state == ACT) err("ACTIVE to bank %d, which is open", b);
			else if (k.state == PRE) err("ACTIVE to bank %d inside tRP", b);
			if (now - k.t_act + EPS < tm.rc) err("ACTIVE to bank %d %.1f ns after the last: tRC", b, now - k.t_act);
			for (int o = 0; o < BANKS; o++)
				if (o != b && now - bank[o].t_act + EPS < tm.rrd) err("ACTIVE %.1f ns after bank %d's: tRRD", now - bank[o].t_act, o);
			k.state = ACT;
			k.row = p.a & 8191;
			k.t_act = now;
			k.last_write = -1e18;
			activates++;
			break;
		}
		case 5:     // READ
		case 4: {   // WRITE
			bool wr = cmd == 4;
			if (k.state != ACT) { err("%s to bank %d, which is not open", wr ? "WRITE" : "READ", b); break; }
			if (now - k.t_act + EPS < tm.rcd) err("%s %.1f ns after ACTIVE: tRCD", wr ? "WRITE" : "READ", now - k.t_act);
			if (p.a & (1 << 10)) err("auto precharge used (not modelled)");
			if (p.a & (1 << 9)) err("column bit A9 set: a 512-column chip has none");
			int col = p.a & 511;
			// a READ or WRITE ends a read burst in progress: its halfwords from
			// CL clocks on are not driven
			for (auto &r : rd)
				if (!r.dropped && r.valid_edge >= e + (uint64_t)cl) r.dropped = true;
			if (wr) {
				if (!p.dq_oe) err("WRITE without the controller driving DQ");
				for (auto &r : rd)
					if (!r.dropped && r.valid_edge + 1 >= e) { err("WRITE while read data is on DQ"); break; }
				int n = wburst_single ? 1 : bl;
				// burst writes would take the following clocks' data; this
				// model only checks single-location writes
				if (n != 1) err("burst writes are not modelled");
				uint16_t &m = at(b, k.row, col);
				uint16_t v = p.dq_o;
				if (!(p.dqm & 1)) m = (uint16_t)((m & 0xFF00) | (v & 0x00FF));
				if (!(p.dqm & 2)) m = (uint16_t)((m & 0x00FF) | (v & 0xFF00));
				k.last_write = now;
				writes++;
			} else {
				int base = col & ~(bl - 1);
				for (int i = 0; i < bl; i++) {
					int c = base | ((col + i) & (bl - 1));
					rd.push_back({e + (uint64_t)cl + (uint64_t)i, b, at(b, k.row, c), false});
				}
				reads++;
			}
			break;
		}
		case 2: {   // PRECHARGE
			bool all = p.a & (1 << 10);
			for (int o = 0; o < BANKS; o++) {
				if (!all && o != b) continue;
				Bank &q = bank[o];
				if (q.state == ACT) {
					if (now - q.t_act + EPS < tm.ras) err("PRECHARGE %.1f ns after ACTIVE: tRAS", now - q.t_act);
					double wr_need = std::max(tm.wr, tm.wr_min_clk * tm.tck);
					if (now - q.last_write + EPS < wr_need) err("PRECHARGE %.1f ns after a WRITE: tWR", now - q.last_write);
					q.state = PRE;
					q.ready = now + tm.rp;
					// the burst stops after the halfword valid at e + CL - 1
					for (auto &r : rd)
						if (!r.dropped && r.bank == o && r.valid_edge > e + (uint64_t)cl - 1) r.dropped = true;
				}
			}
			if (all) precharged_all = true;
			break;
		}
		case 1: {   // AUTO REFRESH
			for (int o = 0; o < BANKS; o++)
				if (bank[o].state != IDLE) { err("REFRESH with bank %d %s", o, bank[o].state == ACT ? "open" : "inside tRP"); break; }
			if (!precharged_all) err("REFRESH before PRECHARGE ALL");
			if (refreshes > (uint64_t)tm.init_refreshes && mode_set) max_refresh_gap = std::max(max_refresh_gap, now - last_refresh);
			last_refresh = now;
			rfc_until = now + tm.rfc;
			refreshes++;
			break;
		}
		case 0: {   // LOAD MODE REGISTER
			for (int o = 0; o < BANKS; o++)
				if (bank[o].state != IDLE) { err("MODE with bank %d not idle", o); break; }
			int m = p.a;
			int blc = m & 7;
			if (blc > 3) err("burst length code %d not modelled", blc);
			bl = 1 << (blc & 3);
			if (m & 8) err("interleaved bursts not modelled");
			cl = (m >> 4) & 7;
			if (cl != 2 && cl != 3) err("CAS latency %d", cl);
			if ((m >> 7) & 3) err("mode register operating mode %d", (m >> 7) & 3);
			wburst_single = (m >> 9) & 1;
			mrd_until = e + (uint64_t)tm.mrd_clk;
			mode_set = true;
			break;
		}
		default:
			err("command %d (burst terminate or reserved) not modelled", cmd);
		}
	}

	// what the FPGA's DQ register takes at FPGA edge e
	uint16_t sample(uint64_t e) {
		double s = e * tm.tck;
		uint16_t v = (uint16_t)rng();
		bool found = false;
		for (auto &r : rd) {
			if (r.dropped) continue;
			double lo_min = win_lo(r, tm.d_min), lo_max = win_lo(r, tm.d_max);
			double hi_min = win_hi(r, tm.d_min), hi_max = win_hi(r, tm.d_max);
			if (s < lo_min - tm.su || s > hi_max + tm.hold) continue;
			if (s >= lo_max + tm.su && s + tm.hold <= hi_min) {
				if (found) err("two read halfwords on DQ at once");
				found = true;
				v = r.data;
				// DQM two clocks before the halfword's edge masks it
				int dqm = dqm_at(r.valid_edge - 2);
				if (dqm & 1) v = (uint16_t)((v & 0xFF00) | (rng() & 0xFF));
				if (dqm & 2) v = (uint16_t)((v & 0x00FF) | (rng() & 0xFF00));
			} else {
				err("read capture at %.2f ns on the border of a data window [%.2f..%.2f, %.2f..%.2f]",
					s, lo_min, lo_max, hi_min, hi_max);
			}
		}
		while (!rd.empty() && (rd.front().dropped || win_hi(rd.front(), tm.d_max) + tm.hold < s)) rd.pop_front();
		return v;
	}

	int cas_latency() const { return cl; }
	bool initialised() const { return mode_set; }

private:
	enum State { IDLE, ACT, PRE };
	struct Bank {
		State  state = IDLE;
		int    row = 0;
		double t_act = -1e18, ready = 0, last_write = -1e18;
	};
	struct Rd {
		uint64_t valid_edge;   // the chip edge at which the halfword is valid
		int      bank;
		uint16_t data;
		bool     dropped;
	};
	static constexpr double EPS = 0.001;
	Bank bank[BANKS];
	std::deque<Rd> rd;
	std::deque<int> dqm_hist;
	std::mt19937 rng;
	uint64_t cur_edge = 0, mrd_until = 0;
	double last_refresh = 0, rfc_until = -1e18;
	bool started = false, precharged_all = false, mode_set = false, wburst_single = false;
	int bl = 1, cl = 2;

	double tac() const { return cl == 3 ? tm.tac_cl3 : tm.tac_cl2; }
	// the data window at the FPGA's register for a halfword valid at chip edge v
	double win_lo(const Rd &r, double d) const { return (double)(r.valid_edge - 1) * tm.tck + tm.tck / 2 + tac() + d; }
	double win_hi(const Rd &r, double d) const { return (double)r.valid_edge * tm.tck + tm.tck / 2 + tm.toh + d; }
	int dqm_at(uint64_t edge) const {
		// dqm_hist ends with the value at cur_edge
		uint64_t back = cur_edge - edge;
		if (edge > cur_edge || back >= dqm_hist.size()) return 0;
		return dqm_hist[dqm_hist.size() - 1 - back];
	}
	void err(const char *fmt, ...) __attribute__((format(printf, 2, 3))) {
		errors++;
		if (quiet || errors > 20) return;
		va_list ap;
		va_start(ap, fmt);
		fprintf(stderr, "SDRAM chip: edge %llu: ", (unsigned long long)cur_edge);
		vfprintf(stderr, fmt, ap);
		fprintf(stderr, "\n");
		va_end(ap);
	}
};
