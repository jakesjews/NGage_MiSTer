// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise the actual whole-core host adapter without clocking the RTL.
// Build against either bench's generated model; see sim/harness/hps_read_test.sh.
#define main firmware_bench_main
#ifdef HPS_TEST_TOP
#include "top_main.cpp"
#else
#include "coreboot_main.cpp"
#endif
#undef main
// The model's $fatal checks (rtl/upp) read the simulation time.
double sc_time_stamp() { return 0; }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Bench b;
    auto &h = *b.r;
    b.img.resize(40 * 512);
    for (size_t i = 0; i < b.img.size(); ++i)
        b.img[i] = uint8_t((i * 37) ^ (i >> 8));
    // Includes single-sector metadata, a clamped tail, and full CMD18 chunks.
    for (unsigned blocks : {1u, 2u, 5u, 8u, 32u}) {
        constexpr unsigned lba = 9;
        h.emu__DOT__hps_io__DOT__sim_sd_rd = 1;
        h.emu__DOT__hps_io__DOT__sim_sd_wr = 0;
        h.emu__DOT__hps_io__DOT__sim_sd_rd1 = 0;
        h.emu__DOT__hps_io__DOT__sim_sd_wr1 = 0;
        h.emu__DOT__hps_io__DOT__sim_sd_lba = lba;
        h.emu__DOT__hps_io__DOT__sim_sd_blk_cnt = blocks - 1;
        b.sd_step();
        // Descriptors may change after acceptance; the adapter must latch them.
        h.emu__DOT__hps_io__DOT__sim_sd_rd = 0;
        h.emu__DOT__hps_io__DOT__sim_sd_lba = 123;
        h.emu__DOT__hps_io__DOT__sim_sd_blk_cnt = 0;
        unsigned words = 0, clocks = 0;
        while (b.sd_state && clocks++ < 40000) {
            b.sd_step();
            if (!h.emu__DOT__hps_io__DOT__sim_sd_wr_buf) continue;
            CHECK_EQ(h.emu__DOT__hps_io__DOT__sim_sd_ack, 1, "ACK while delivering data");
            CHECK_EQ(h.emu__DOT__hps_io__DOT__sim_sd_addr, words, "buffer word address");
            size_t off = lba * 512 + words * 2;
            unsigned want = off + 1 < b.img.size() ? b.img[off] | (b.img[off + 1] << 8) : 0;
            CHECK_EQ(h.emu__DOT__hps_io__DOT__sim_sd_dout, want, "image word (or beyond-image zero)");
            ++words;
        }
        CHECK_EQ(b.sd_state, 0, "transfer completed");
        CHECK_EQ(h.emu__DOT__hps_io__DOT__sim_sd_ack, 0, "ACK released");
        CHECK_EQ(words, blocks * 256, "complete requested burst");
    }
    return sim::finish("whole-core HPS reads");
}
