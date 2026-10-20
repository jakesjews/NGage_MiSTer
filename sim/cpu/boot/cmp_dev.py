#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare every device access of a boot bench run with the model's.

    python3 -I cmp_dev.py RTL_DEV_LOG MODEL_TRACE [--loose ADDR ...]

RTL_DEV_LOG: tb/main.cpp --devlog (dev.log). MODEL_TRACE: the
model/trace_plugin.c log (insns=0 is enough). Both have lines
"M n R|W size pa value pc"; only physical addresses the plugin records are
compared (0x08000000-0x0DFFFFFF without SDRAM and on-chip RAM). The two
sequences are walked in order, comparing direction, size, address and
value; n (instructions executed) and the PC are printed but not compared:
interrupts arrive a few instructions apart on the two sides, and the
plugin reports the PC a QEMU translation block was first translated at,
which can be another virtual alias of the same code. --loose names
addresses whose values are not compared (free-running counters such as
the timers' current-count registers). The last line of the RTL log is
skipped (the run may still be writing it).
"""
import argparse
import sys

TIMERS = ["0c120a10", "0c120a30", "0c120a50", "0c120a70", "0c120a90", "0c120ab0",
          "0c120048", "0c12004c"]


def device(a):
    return (0x08000000 <= a < 0x0E000000 and not 0x0A000000 <= a < 0x0B000000
            and not 0x0C000000 <= a < 0x0C040000)


def load(path, skip_last):
    with open(path) as f:
        lines = f.readlines()
    if skip_last:
        lines = lines[:-1]
    out = []
    for line in lines:
        p = line.split()
        if len(p) == 7 and p[0] == "M" and device(int(p[4], 16)):
            out.append((p[2], p[3], int(p[4], 16), int(p[5], 16), int(p[6], 16), int(p[1])))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rtl")
    ap.add_argument("model")
    ap.add_argument("--loose", nargs="*", default=TIMERS,
                    help="addresses whose values differ by timing (default: the timer counters)")
    ap.add_argument("--context", type=int, default=6)
    opt = ap.parse_args()
    loose = {int(x, 16) for x in opt.loose}
    r, m = load(opt.rtl, True), load(opt.model, False)
    for i, (x, y) in enumerate(zip(r, m)):
        if x[:3] != y[:3] or (x[2] not in loose and x[3] != y[3]):
            print(f"device accesses: RTL {len(r)}, model {len(m)}; first difference at #{i}")
            for k in range(max(0, i - opt.context), min(i + opt.context + 2, len(r), len(m))):
                a, b = r[k], m[k]
                print(f"{'>' if k == i else ' '} RTL {a[0]} {a[1]} {a[2]:08x} {a[3]:08x} pc {a[4]:08x} "
                      f"n {a[5]:<11d}| model {b[0]} {b[1]} {b[2]:08x} {b[3]:08x} pc {b[4]:08x} n {b[5]}")
            return 1
    print(f"device accesses: RTL {len(r)}, model {len(m)}; the first {min(len(r), len(m))} agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
