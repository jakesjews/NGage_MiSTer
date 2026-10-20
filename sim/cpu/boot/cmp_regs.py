#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare a boot bench log with the reference model's.

    python3 -I cmp_regs.py [--name NAME] [--ignore LO-HI ...] RTL.log MODEL.log

regs.log lists the first read and the first write of every register in
the emif and upp blocks, in order, with the size, the value and the PC of
the instruction (model/hw/ngage_upp.c, sim/cpu/tb/ngage.h); cbus.log lists
every CBUS transfer (model/hw/ngage_cbus.c). Only lines starting with R or
W are compared (the model's "T" lines for traced ranges and the ADC notes
are not). The RTL run usually stops earlier than the model's, so the RTL
log must equal the start of the model's log. --ignore drops register-log
entries in an address range from both logs (devices that one side models
and the other logs as storage, such as the CTSI register at 0x0C150100,
which the model has logged either way).
"""
import argparse
import sys


def entries(path, ignore):
    out = []
    with open(path) as f:
        for line in f:
            w = line.split()
            if not w or w[0] not in ("R", "W"):
                continue
            if len(w) == 6:
                a = int(w[2], 16)
                if any(lo <= a < hi for lo, hi in ignore):
                    continue
            out.append(tuple(w))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--name", default="logs")
    ap.add_argument("--ignore", action="append", default=[])
    ap.add_argument("rtl")
    ap.add_argument("model")
    opt = ap.parse_args()
    ignore = [tuple(int(x, 0) for x in r.split("-")) for r in opt.ignore]
    a, b = entries(opt.rtl, ignore), entries(opt.model, ignore)
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            print(f"{opt.name} differ at entry {i + 1}:")
            for j in range(max(0, i - 2), min(n, i + 3)):
                mark = ">" if j == i else " "
                print(f" {mark} RTL   {' '.join(a[j])}")
                print(f" {mark} model {' '.join(b[j])}")
            return 1
    more = "" if len(a) <= len(b) else f" (and {len(a) - len(b)} more on the RTL)"
    print(f"{opt.name} agree: {n} entries; the model's log has {len(b)}{more}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
