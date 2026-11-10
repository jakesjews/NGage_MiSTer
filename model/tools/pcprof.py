#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Where the model's PC samples fall between two guest times: by processor
mode, and by ROM file or RAM region.

usage: pcprof.py ROM PC.TXT T0 T1
  ROM     linear ROM image (research/firmware/images/nor/rh29-4.60-symrom-from-fls.bin)
  PC.TXT  the model's NGAGE_PCSAMPLE file: "<guest seconds> <pc> <mode>", one a guest millisecond
This kernel reschedules and switches processes in Undefined mode, and the
system idles in it (the NOS side), so that mode's samples are both.
Run with python3 -I. Files are read as data only.
"""
import bisect
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import romdis  # noqa: E402

MODES = {0x10: "usr", 0x11: "fiq", 0x12: "irq", 0x13: "svc", 0x17: "abt", 0x1B: "und", 0x1F: "sys"}


def main():
    rom = open(sys.argv[1], "rb").read()
    files = sorted((addr, addr + size, name) for name, addr, size in romdis.files(rom))
    starts = [f[0] for f in files]

    def where(pc):
        if 0x50000000 <= pc < 0x52000000:
            i = bisect.bisect_right(starts, pc) - 1
            if i >= 0 and pc < files[i][1]:
                return files[i][2].replace("\\", "/").rsplit("/", 1)[-1].lower()
            return "rom, outside the files"
        return "ram %02xxxxxxx" % (pc >> 24)

    t0, t1 = float(sys.argv[3]), float(sys.argv[4])
    count, n = collections.Counter(), 0
    for line in open(sys.argv[2]):
        a = line.split()
        if len(a) != 3:
            continue
        t = float(a[0])
        if t < t0:
            continue
        if t >= t1:
            break
        n += 1
        count[(MODES.get(int(a[2], 16) & 0x1F, a[2]), where(int(a[1], 16)))] += 1
    print("%d samples, guest %.0f-%.0f s" % (n, t0, t1))
    by_mode = collections.Counter()
    for (m, _), v in count.items():
        by_mode[m] += v
    print("  modes: " + "  ".join("%s %.2f%%" % (m, 100.0 * v / n) for m, v in by_mode.most_common()))
    for (m, w), v in count.most_common(20):
        print("  %6.2f%%  %-4s %s" % (100.0 * v / n, m, w))


if __name__ == "__main__":
    main()
