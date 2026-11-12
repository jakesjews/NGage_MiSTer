#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The data-cache simulation's report (model/plugins/dcsim.c, NGAGE_DCSIM in
model/run.sh) per guest second: load misses, store misses and write-backs
of each simulated cache against the core's, the prefetches and how many
were used, and the core's load misses by 1 MB region, by ROM file or RAM
region of the instruction, and by instruction address.

usage: dcstat.py DCSIM.TXT [ROM]
  ROM  linear ROM image (research/firmware/images/nor/rh29-4.10-symrom-from-fls.bin):
       names the ROM files; without it instructions are "rom" or "ram xx"
Run with python3 -I. Files are read as data only.
"""
import bisect
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import romdis  # noqa: E402


def main():
    lines = open(sys.argv[1]).read().split("\n")
    files = []
    if len(sys.argv) > 2:
        rom = open(sys.argv[2], "rb").read()
        files = sorted((addr, addr + size, name) for name, addr, size in romdis.files(rom))
    starts = [f[0] for f in files]

    def where(pc):
        if 0x50000000 <= pc < 0x52000000:
            i = bisect.bisect_right(starts, pc) - 1
            if i >= 0 and pc < files[i][1]:
                return files[i][2].replace("\\", "/").rsplit("/", 1)[-1].lower()
            return "rom"
        return "ram %02xxxxxxx" % (pc >> 24)

    n0, n1, _ = (int(x) for x in lines[0].split()[1:])
    secs = (n1 - n0) / 62.5e6
    print("%.0f guest seconds, per second:" % secs)
    core = None
    for l in lines:
        if l.startswith("cache|"):
            name = l.split("|")[1]
            loads, stores, lm, sm, wb, pfi, pfu, pfx, _ = (int(x) for x in l.split("|")[2:])
            if core is None:
                core = lm
                print("  loads %.2f M, stores %.2f M; %.2f load misses per 1000 instructions in the first cache" % (
                    loads / secs / 1e6, stores / secs / 1e6, 1000.0 * lm / (n1 - n0)))
            extra = ""
            if pfi:
                extra = "  prefetches %7.0f (%.0f%% used, %.0f%% evicted unused), all fills %+.0f%%" % (
                    pfi / secs, 100.0 * pfu / pfi, 100.0 * pfx / pfi, 100.0 * (lm + pfi - core) / core)
            print("  %-30s load misses %8.0f (%+5.1f%%)  store misses %8.0f  write-backs %7.0f%s" % (
                name, lm / secs, 100.0 * (lm - core) / core, sm / secs, wb / secs, extra))
        elif l.startswith("seq "):
            up, dn, both = (int(x) for x in l.split()[1:])
            print("  first cache's load misses with the line before in the cache %.1f%%, the line after %.1f%%, both %.1f%%, neither %.1f%%" % (
                100.0 * up / core, 100.0 * dn / core, 100.0 * both / core, 100.0 * (core - up - dn - both) / core))
    miss, loads, stores = collections.Counter(), collections.Counter(), collections.Counter()
    for l in lines:
        if l.startswith("region "):
            _, r, ld, st, ms = l.split()
            key = "%sxxxxx" % r
            miss[key] += int(ms)
            loads[key] += int(ld)
            stores[key] += int(st)
    print("  load misses by 1 MB region (its loads and stores a second, the loads' miss rate):")
    for k, v in miss.most_common(12):
        print("    %s  %5.1f%%  loads %9.0f  stores %9.0f  miss rate %5.2f%%" % (
            k, 100.0 * v / core, loads[k] / secs, stores[k] / secs, 100.0 * v / max(loads[k], 1)))
    pcs = [(int(l.split()[1], 16), int(l.split()[2])) for l in lines if l.startswith("pc ")]
    by_file = collections.Counter()
    for pc, c in pcs:
        by_file[where(pc)] += c
    print("  load misses by code (%.1f%% of them are in the listed instructions):" % (100.0 * sum(c for _, c in pcs) / core))
    for k, v in by_file.most_common(10):
        print("    %-26s %5.1f%%" % (k, 100.0 * v / core))
    print("  instructions with the most:")
    for pc, c in pcs[:16]:
        print("    %08x  %5.2f%%  %s" % (pc, 100.0 * c / core, where(pc)))


if __name__ == "__main__":
    main()
