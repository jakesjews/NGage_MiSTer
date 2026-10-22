#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""What the CPU was doing in a trace dump: histograms over the rings.

    tools/trace_hist.py DUMP.bin [--dump N] [--pc 3000] [--data 1500] [--bus 800]
                        [--romfiles build/dis/romfiles.txt]

Runs tools/mister_trace.py show on the dump and aggregates:
  * retired instructions by ROM file (romfiles.txt: address, size, name per
    line) and by 256-byte region of the busiest file, with the clocks
    between retirements as a cycles-per-instruction distribution;
  * data-port accesses by read/write and by address region;
  * bus beats by target (flash, SDRAM, on-chip RAM, peripherals), by
    read/write, single beats against bursts, and the number of distinct
    16-byte lines touched (how much of the traffic is to the same places).
"""
import argparse, collections, re, subprocess, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def region(adr):
    a = adr & 0x0FFFFFFF
    if a < 0x04000000:
        return "flash CS0" if a < 0x02000000 else "flash CS1"
    if 0x08000000 <= a < 0x0A000000:
        return "EMIF regs"
    if 0x0A000000 <= a < 0x0C000000:
        return "SDRAM"
    if 0x0C000000 <= a < 0x0C100000:
        return "on-chip RAM"
    if 0x0C100000 <= a < 0x0E000000:
        return "peripherals"
    return "other"


def va_region(va):
    if 0x50000000 <= va < 0x52000000:
        return "ROM (XIP)"
    if 0x00000000 <= va < 0x00001000:
        return "vectors"
    if 0x58000000 <= va < 0x5A000000:
        return "peripherals (mapped)"
    if 0x0C000000 <= va < 0x0C100000:
        return "on-chip RAM (phys)"
    if 0x80000000 <= va < 0xC0000000:
        return "user data/stack"
    if 0x40000000 <= va < 0x50000000:
        return "kernel/super data"
    if 0x60000000 <= va < 0x80000000:
        return "heaps/chunks"
    return "other %08x" % (va & 0xF0000000)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dump")
    ap.add_argument("--dump", dest="n", type=int)
    ap.add_argument("--pc", type=int, default=3000)
    ap.add_argument("--data", type=int, default=1500)
    ap.add_argument("--bus", type=int, default=800)
    ap.add_argument("--romfiles", default="build/dis/romfiles.txt")
    a = ap.parse_args()
    cmd = [sys.executable, "-I", str(HERE / "mister_trace.py"), "show", a.dump, "--pc", str(a.pc), "--data", str(a.data), "--bus", str(a.bus)]
    if a.n is not None:
        cmd += ["--dump", str(a.n)]
    text = subprocess.run(cmd, capture_output=True, text=True).stdout
    files = []
    try:
        for ln in open(a.romfiles):
            s, size, name = ln.split()
            files.append((int(s, 16), int(size), name))
    except OSError:
        pass

    def romfile(pc):
        for s, size, name in files:
            if s <= pc < s + size:
                return name.split("\\")[-1]
        return "(RAM/other)"

    section = None
    pcs, data, bus = [], [], []
    for ln in text.splitlines():
        if ln.startswith("dump ") or ln.startswith("retired "):
            print(ln)
        if ln.startswith("== retired"):
            section = "pc"; continue
        if ln.startswith("== data"):
            section = "data"; continue
        if ln.startswith("== bus"):
            section = "bus"; continue
        m = re.match(r"\s+-\d+\s+([0-9a-f]{4})\s+(\w+)\s+(\S+)\s+([0-9a-f]{8})", ln)
        if section == "pc" and m:
            pcs.append((int(m[1], 16), m[2], int(m[4], 16)))
            continue
        m = re.match(r"\s+-\d+\s+([0-9a-f]{8})\s+([RW])\s+([0-9a-f]{8})\s+sel\s+(\w)\s+([0-9a-f]{8})", ln)
        if section == "data" and m:
            data.append((int(m[1], 16), m[2], int(m[3], 16)))
            continue
        m = re.match(r"\s+-\d+\s+([0-9a-f]{8})\s+([RW])\s+([0-9a-f]{8})\s+sel\s+(\w)\s+cti\s+(\d)", ln)
        if section == "bus" and m:
            bus.append((int(m[1], 16), m[2], int(m[3], 16), int(m[5])))

    print(f"\n== {len(pcs)} retired instructions ==")
    if pcs:
        byfile = collections.Counter(romfile(pc) for _, _, pc in pcs)
        for name, n in byfile.most_common(8):
            print(f"  {n:5d} {100.0 * n / len(pcs):5.1f}%  {name}")
        modes = collections.Counter(mode for _, mode, _ in pcs)
        print("  modes:", ", ".join(f"{m} {n}" for m, n in modes.most_common()))
        top = byfile.most_common(1)[0][0]
        regions = collections.Counter(pc & ~0xFF for _, _, pc in pcs if romfile(pc) == top)
        print(f"  busiest 256-byte regions of {top}:")
        for r, n in regions.most_common(6):
            print(f"    {n:5d}  {r:08x}")
        deltas = []
        for (c0, _, _), (c1, _, _) in zip(pcs, pcs[1:]):
            d = (c1 - c0) & 0xFFFF
            if d < 4096:
                deltas.append(d)
        if deltas:
            hist = collections.Counter(min(d, 64) for d in deltas)
            total = sum(deltas)
            print(f"  clocks between retirements: mean {total / len(deltas):.2f};", ", ".join(f"{d}:{n}" for d, n in sorted(hist.items())[:14]), "...")
            span = (pcs[-1][0] - pcs[0][0]) & 0xFFFF
            print(f"  (ring span {span} clocks of the low 16 bits for {len(pcs)} instructions)")

    print(f"\n== {len(data)} data-port accesses ==")
    if data:
        rw = collections.Counter(w for _, w, _ in data)
        print("  reads", rw.get("R", 0), "writes", rw.get("W", 0))
        for r, n in collections.Counter(va_region(va) for _, _, va in data).most_common(8):
            print(f"  {n:5d} {100.0 * n / len(data):5.1f}%  {r}")
        pages = collections.Counter(va & ~0xFFF for _, _, va in data)
        print("  busiest 4 KB pages:", ", ".join(f"{p:08x}:{n}" for p, n in pages.most_common(6)))

    print(f"\n== {len(bus)} bus beats ==")
    if bus:
        tgt = collections.Counter((region(adr), w) for _, w, adr, _ in bus)
        for (r, w), n in tgt.most_common(10):
            print(f"  {n:5d} {100.0 * n / len(bus):5.1f}%  {r} {w}")
        bursts = sum(1 for _, _, _, cti in bus if cti == 2)
        print(f"  beats in incrementing bursts (line fills/write-backs): {bursts}, single/last: {len(bus) - bursts}")
        lines = collections.Counter(adr & ~0xF for _, _, adr, _ in bus)
        print(f"  distinct 16-byte lines: {len(lines)} of {len(bus)} beats; most repeated:",
              ", ".join(f"{l:08x}:{n}" for l, n in lines.most_common(6)))
        span = (bus[-1][0] - bus[0][0]) & 0xFFFFFFFF
        if span:
            print(f"  ring span {span} clocks: {len(bus) / span * 104e6 / 1e6:.2f} M beats/s")


if __name__ == "__main__":
    main()
