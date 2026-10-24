// SPDX-License-Identifier: GPL-3.0-or-later
// NXT-source handshake model: update each source for its accepted beat before
// the rising edge, just as zap_cache/zap_dcache do. The external bus monitor
// independently checks stability, burst ownership and saved victim bytes.
#include "Vzap_wb_merger.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <vector>

static void check(bool ok, const char *why) {
    if (!ok) { std::fprintf(stderr, "FAIL merger: %s\n", why); std::exit(1); }
}
struct Request { uint32_t addr; unsigned words = 4, beat = 0; bool write = false; };
struct Bench {
    Vzap_wb_merger t;
    std::deque<Request> c, d;
    std::vector<char> accepted;
    unsigned latency, wait = 0, cycles = 0, victim_beats = 0, completions = 0;
    bool waiting = false, burst = false, inject_error = false;
    uint64_t held = 0;
    unsigned held_control = 0;
    uint32_t prior_addr = 0;
    char prior_owner = 0;
    static constexpr uint32_t pa = 0x00412000;
    static constexpr std::array<uint32_t,4> line = {0x12345678, 0x89abcdef, 0xfedcba98, 0x76543210};
    explicit Bench(unsigned lat): latency(lat) {
        t.i_clk = 0; t.i_reset = 1;
        t.i_victim_valid = t.i_victim_drain = 0;
        t.i_wb_ack = t.i_wb_err = 0;
        drive(); edge(); edge(); t.i_reset = 0;
    }
    void edge() { t.i_clk = 1; t.eval(); t.i_clk = 0; t.eval(); }
    void drive() {
        auto addr = [](const Request &r) { return (r.addr & ~15u) | ((r.addr + r.beat*4) & 15u); };
        t.i_c_wb_cyc = t.i_c_wb_stb = !c.empty();
        t.i_c_wb_wen = 0; t.i_c_wb_sel = 15; t.i_c_wb_dat = 0;
        t.i_c_wb_adr = c.empty() ? 0 : addr(c.front());
        t.i_c_wb_cti = c.empty() || c.front().beat+1 == c.front().words ? 7 : 2;
        t.i_c_wb_bte = c.empty() || c.front().words == 1 ? 0 : 1;
        t.i_d_wb_cyc = t.i_d_wb_stb = !d.empty();
        t.i_d_wb_wen = !d.empty() && d.front().write;
        t.i_d_wb_sel = 15; t.i_d_wb_dat = 0xaabbccdd;
        t.i_d_wb_adr = d.empty() ? 0 : addr(d.front());
        t.i_d_wb_cti = d.empty() || d.front().beat+1 == d.front().words ? 7 : 2;
        t.i_d_wb_bte = d.empty() || d.front().words == 1 ? 0 : 1;
    }
    void enqueue() {
        check(!t.o_victim_busy, "producer reused a full buffer");
        t.i_victim_addr = pa;
        for (unsigned n=0;n<4;n++) t.i_victim_line[n] = line[n];
        t.i_victim_valid = 1;
        step(); t.i_victim_valid = 0;
        // Deliberately change the producer's saved context after the handoff.
        t.i_victim_addr = 0;
        for (unsigned n=0;n<4;n++) t.i_victim_line[n] = 0;
        check(t.o_victim_busy, "handoff did not capture ownership");
    }
    void step() {
        check(++cycles < 20000, "deadlock / required drain starved");
        drive(); t.eval();
        bool req = t.o_wb_cyc && t.o_wb_stb;
        uint64_t payload = (uint64_t(t.o_wb_adr)<<32) | t.o_wb_dat;
        unsigned control = (unsigned(t.o_wb_wen)<<8) | (unsigned(t.o_wb_sel)<<4) |
                           (unsigned(t.o_wb_bte)<<2) | (t.o_wb_cti == 7);
        if (waiting) check(req && payload == held && control == held_control,
                           "request changed before ACK");
        bool ack = req && wait >= latency;
        bool err = ack && inject_error && t.o_wb_wen && t.o_wb_adr == pa+4;
        t.i_wb_ack = ack && !err; t.i_wb_err = err; t.eval();
        if (ack) {
            char owner = t.o_c_wb_ack ? 'I' : t.o_d_wb_ack ? 'D' : 'W';
            if (burst) check(owner == prior_owner && t.o_wb_adr ==
                ((prior_addr & ~15u) | ((prior_addr+4)&15u)), "burst preempted / wrong wrap order");
            if (owner == 'W') {
                check(t.o_victim_busy && t.o_wb_wen && t.o_wb_sel == 15 && t.o_wb_bte == 1,
                      "victim control or ownership lost");
                check(t.o_wb_adr == pa + 4*(victim_beats%4) &&
                      t.o_wb_dat == line[victim_beats%4], "victim data/address changed after handoff");
                check(t.o_wb_cti == (victim_beats%4 == 3 ? 7 : 2), "victim EOB incorrect");
                ++victim_beats;
            } else {
                auto &q = owner == 'I' ? c : d;
                check(!q.empty(), "ACK went to an idle source");
                const auto &r = q.front();
                check(t.o_wb_adr == ((r.addr & ~15u) | ((r.addr+r.beat*4)&15u)), "source address lost");
                if ((t.o_wb_adr & ~15u) == pa)
                    check(!t.o_victim_busy, "physical alias overtook buffered write");
                if (++q.front().beat == q.front().words) q.pop_front();
            }
            accepted.push_back(owner);
            burst = t.o_wb_cti != 7; prior_addr = t.o_wb_adr; prior_owner = owner;
        }
        waiting = req && !ack; held = payload; held_control = control;
        wait = req && !ack ? wait+1 : 0;
        drive(); t.eval(); edge();
        if (t.o_victim_done) ++completions;
        t.i_wb_ack = t.i_wb_err = 0; t.eval();
    }
    void finish() {
        while (!c.empty() || !d.empty() || t.o_victim_busy || t.o_wb_stb) step();
        check(victim_beats == 4 && completions == 1, "missing/duplicate victim completion");
    }
};
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    for (unsigned lat : {0u, 3u, 9u, 31u}) {
        { // Both read sources beat the lowest-priority write, no burst split.
            Bench b(lat); b.c.push_back({0x1008}); b.d.push_back({0x2004});
            b.enqueue(); b.finish();
            check(b.accepted.size() == 12, "unexpected beat count");
            for (unsigned n=0;n<8;n++) check(b.accepted[n] != 'W', "write overtook pending read");
        }
        for (bool code : {false,true}) { // PA aliases drain first, for either owner.
            Bench b(lat); (code ? b.c : b.d).push_back({Bench::pa+8});
            // Keep the old transaction idle on the handoff edge; then submit alias.
            auto q = code ? b.c : b.d; b.c.clear(); b.d.clear(); b.enqueue();
            (code ? b.c : b.d) = q; b.finish();
            check(b.accepted.front() == 'W', "alias read was not fenced");
        }
        for (bool code : {false,true}) { // Back-to-back burst changes cannot reuse an old PA check.
            Bench b(lat);
            auto &q = code ? b.c : b.d;
            q.push_back({0x1004}); q.push_back({Bench::pa+12}); q.push_back({0x3008});
            auto &other = code ? b.d : b.c;
            for (unsigned n=0;n<4;n++) other.push_back({0x4000+16*n});
            b.enqueue(); b.finish();
        }
        { // Continuous reads cannot starve an explicit maintenance/drain fence.
            Bench b(lat);
            for (unsigned n=0;n<32;n++) b.c.push_back({0x1000+16*n});
            b.enqueue(); b.t.i_victim_drain = 1; b.step();
            b.d.push_back({Bench::pa, 1, 0, true});
            b.finish();
            unsigned first=0; while (b.accepted[first] != 'W') ++first;
            check(first <= 4, "forced drain did not follow the accepted burst");
        }
        { // A bus ERR consumes one beat, matching existing cacheable WB semantics.
            Bench b(lat); b.inject_error = true; b.enqueue(); b.finish();
        }
    }
    std::puts("PASS merger: read priority, aliases, full-buffer ownership, forced drain, bursts and ERR (4 latencies)");
}
