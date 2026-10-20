#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare a full-core boot run with the model's where real time allows.

    python3 -I cmp_flow.py RTL_DEV_LOG MODEL_TRACE [--context N]

RTL_DEV_LOG: sim/harness/coreboot_main.cpp --devlog. MODEL_TRACE: the
model/trace_plugin.c log. On the whole core the peripherals run in real
time while the model's time follows its instruction count, so interrupts
arrive at other instructions and the interleaving of interrupt-driven work
differs; cmp_dev.py's lockstep comparison then stops at the first timer
interrupt that lands elsewhere. This compares what does not depend on it:

  1. program flow: the synchronous exceptions (SWI, undefined instruction,
     prefetch and data abort; "X n exc from vector" lines) in order, by
     vector and by the PC they came from (the plugin reports the next
     instruction's PC for an SWI, so PCs within 4 bytes agree);
  2. device accesses outside the interrupt controller and timers
     (0x0C120000-0x0C120FFF) and the CBUS (0x0C150000-0x0C150FFF), in
     order, with values;
  3. per 4 KB device block, the number of writes on each side.

Each part reports how far the two agree. An unfinished last line of the
RTL log is skipped.
"""
import argparse
import collections
import sys

SKIP = [(0x0C120000, 0x0C121000), (0x0C150000, 0x0C151000)]


def device(a):
    return (0x08000000 <= a < 0x0E000000 and not 0x0A000000 <= a < 0x0B000000
            and not 0x0C000000 <= a < 0x0C040000)


def load(path, skip_last):
    with open(path) as f:
        lines = f.readlines()
    if skip_last and lines and not lines[-1].endswith("\n"):
        lines = lines[:-1]
    exc, acc, blocks = [], [], collections.Counter()
    for line in lines:
        p = line.split()
        if len(p) == 5 and p[0] == "X" and p[2] == "exc" and p[4] not in ("00000018", "0000001c"):
            exc.append((int(p[3], 16), p[4], int(p[1])))
        elif len(p) == 7 and p[0] == "M" and device(int(p[4], 16)):
            a = int(p[4], 16)
            if p[2] == "W":
                blocks[a >> 12] += 1
            if not any(lo <= a < hi for lo, hi in SKIP):
                acc.append((p[2], p[3], a, int(p[5], 16), int(p[1])))
    return exc, acc, blocks


def first_diff(r, m, same):
    n = min(len(r), len(m))
    return next((i for i in range(n) if not same(r[i], m[i])), n)


def show(r, m, i, ctx, fmt):
    for k in range(max(0, i - ctx), min(max(len(r), len(m)), i + ctx + 2)):
        a = fmt(r[k]) if k < len(r) else "-"
        b = fmt(m[k]) if k < len(m) else "-"
        print(f"{'>' if k == i else ' '} RTL {a:44s}| model {b}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rtl")
    ap.add_argument("model")
    ap.add_argument("--context", type=int, default=4)
    opt = ap.parse_args()
    re_, ra, rb = load(opt.rtl, True)
    me, ma, mb = load(opt.model, False)
    bad = 0

    i = first_diff(re_, me, lambda x, y: x[1] == y[1] and abs(x[0] - y[0]) <= 4)
    print(f"synchronous exceptions: RTL {len(re_)}, model {len(me)}; the first {i} agree")
    if i < min(len(re_), len(me)):
        bad = 1
        show(re_, me, i, opt.context, lambda x: f"{x[1]} from {x[0]:08x} n {x[2]}")

    i = first_diff(ra, ma, lambda x, y: x[:4] == y[:4])
    print(f"device accesses without INTC/timers/CBUS: RTL {len(ra)}, model {len(ma)}; the first {i} agree")
    if i < min(len(ra), len(ma)):
        bad = 1
        show(ra, ma, i, opt.context, lambda x: f"{x[0]} {x[1]} {x[2]:08x} {x[3]:08x} n {x[4]}")

    print("writes per device block (RTL / model):")
    for blk in sorted(set(rb) | set(mb)):
        print(f"  {blk << 12:08x}  {rb[blk]:7d} / {mb[blk]}")
    return bad


if __name__ == "__main__":
    sys.exit(main())
