#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare two CPU-test signature dumps (RTL bench and QEMU).

    python3 -I cmp_sig.py RTL.sig QEMU.sig [--name TEST]

The layout is described in sim/cpu/tests/test.inc: a result word, the
CHECKPOINT records (r0-r14 and the CPSR, 16 words each) and a free area.
Every word must match. Exit status 0 when they match, 1 otherwise.
"""
import argparse
import struct
import sys

REC_BASE = 0x100
REC_WORDS = 16
NAMES = [f"r{i}" for i in range(15)] + ["cpsr"]


def words(path):
    with open(path, "rb") as f:
        data = f.read()
    n = len(data) // 4
    return list(struct.unpack(f"<{n}I", data[: 4 * n]))


def describe(off, sig_ptr):
    if off == 0:
        return "result"
    if off == 4:
        return "record pointer"
    if 8 <= off < 0x14:
        return ["fail value", "fail expected", "fail address"][(off - 8) // 4]
    if REC_BASE <= off < 0x8000:
        rec, w = divmod((off - REC_BASE) // 4, REC_WORDS)
        return f"checkpoint {rec} {NAMES[w]}"
    return f"data +0x{off - 0x8000:x}"


def main():
    ap = argparse.ArgumentParser(description="compare CPU-test signatures")
    ap.add_argument("rtl")
    ap.add_argument("qemu")
    ap.add_argument("--name", default="")
    opt = ap.parse_args()
    name = opt.name + ": " if opt.name else ""
    a, b = words(opt.rtl), words(opt.qemu)
    if len(a) != len(b):
        print(f"{name}signature sizes differ ({len(a)} / {len(b)} words)")
        return 1
    diffs = [i for i in range(len(a)) if a[i] != b[i]]
    nrec = max(0, (a[1] - 0xF00100) // 64) if len(a) > 1 else 0
    if not diffs:
        print(f"{name}signatures match (result 0x{a[0]:08x}, {nrec} checkpoints)")
        return 0
    print(f"{name}{len(diffs)} word(s) differ (RTL / QEMU):")
    for i in diffs[:24]:
        print(f"  +0x{4 * i:04x} {describe(4 * i, a[1]):24s} 0x{a[i]:08x} / 0x{b[i]:08x}")
    if len(diffs) > 24:
        print("  ...")
    return 1


if __name__ == "__main__":
    sys.exit(main())
