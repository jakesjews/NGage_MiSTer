#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare a window of the RTL boot trace with the model's.

    python3 -I cmp_window.py RTL_TRACE MODEL_TRACE [--sync PC] [--context N]

RTL_TRACE: tb/main.cpp --trace (one line per retired instruction or
exception, registers after it). MODEL_TRACE: model/trace_plugin.c output
("I n pc r0..r14 cpsr", registers before; "X n kind from to"). Both become
lists of (pc, registers before). The comparison starts at the first
instruction at PC --sync (default: the RTL trace's first PC) where the two
agree in r0-r14, then walks both: the first difference in PC or a register
is printed with the lines around it. Interrupts arrive a few instructions
apart on the two sides, so the walk resynchronises after an IRQ or FIQ
entry by skipping each side's handler until both are back at the same PC
with the same registers. --pc-only compares the PCs alone: the plugin's
register values are not always current (QEMU translation blocks shared
between virtual aliases of a page also report the PC of the alias they
were translated at, so --alias MASK compares PCs under a mask).
"""
import argparse
import sys

IRQ_VEC = (0x18, 0x1C, 0xFFFF0018, 0xFFFF001C)


def rtl_list(path):
    out, prev, last = [], None, None
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) != 18:
                continue
            kind, pc = p[0], int(p[1], 16)
            regs = [None if v.startswith("-") else int(v, 16) for v in p[2:17]] + [int(p[17], 16)]
            # The second half of a Thumb BL pair right after the first: QEMU
            # runs the pair as one instruction unless the first half ends a
            # 1 KB page (as tb/main.cpp counts it).
            bl_second = (kind == "R" and last is not None and last[0] == "R" and pc == last[1] + 2
                         and pc & 0x3FF and regs[15] & 0x20 and regs[14] == (pc + 2) | 1)
            # An SWI or undefined instruction is an exception event in the
            # RTL trace but an executed instruction in the model's.
            if kind in ("R", "S", "U") and prev is not None and not bl_second:
                out.append((pc, prev))
            prev, last = regs, (kind, pc)
    return out


def model_list(path):
    out = []
    with open(path) as f:
        for line in f:
            p = line.split()
            if p and p[0] == "I" and len(p) == 19:
                out.append((int(p[2], 16), [int(v, 16) for v in p[3:19]]))
    return out


PC_ONLY = False
ALIAS = 0xFFFFFFFF


def same(a, b):
    if PC_ONLY:
        return True
    return all(x is None or y is None or x == y for x, y in zip(a[:15], b[:15]))


def pc_eq(x, y):
    return (x & ALIAS) == (y & ALIAS)


def show(tag, lst, i, n):
    for j in range(max(0, i - n), min(len(lst), i + 3)):
        pc, r = lst[j]
        mark = ">" if j == i else " "
        regs = " ".join("--------" if v is None else f"{v:08x}" for v in r)
        print(f" {mark} {tag} {j:8d} {pc:08x} {regs}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rtl")
    ap.add_argument("model")
    ap.add_argument("--sync", type=lambda s: int(s, 0))
    ap.add_argument("--context", type=int, default=8)
    ap.add_argument("--pc-only", action="store_true")
    ap.add_argument("--alias", type=lambda s: int(s, 0), default=0xFFFFFFFF)
    opt = ap.parse_args()
    global PC_ONLY, ALIAS
    PC_ONLY, ALIAS = opt.pc_only, opt.alias
    a, b = rtl_list(opt.rtl), model_list(opt.model)
    if not a or not b:
        sys.exit("empty trace")
    sync = opt.sync if opt.sync is not None else a[0][0]
    ia = next((i for i, e in enumerate(a) if e[0] == sync), None)
    ib = next((i for i, e in enumerate(b) if ia is not None and pc_eq(e[0], sync) and same(e[1], a[ia][1])), None)
    if ia is None or ib is None:
        sys.exit(f"no common start at {sync:08x}")
    print(f"start: RTL #{ia}, model #{ib}, pc {sync:08x}")
    matched = resyncs = 0
    while ia < len(a) and ib < len(b):
        (pa, ra), (pb, rb) = a[ia], b[ib]
        if pc_eq(pa, pb) and same(ra, rb):
            ia += 1
            ib += 1
            matched += 1
            continue
        # an interrupt taken on one side only: skip that side's handler
        if pa in IRQ_VEC or pb in IRQ_VEC:
            side, lst, i, other = ("RTL", a, ia, b[ib]) if pa in IRQ_VEC else ("model", b, ib, a[ia])
            j = i + 1
            while j < len(lst) and not (pc_eq(lst[j][0], other[0]) and same(lst[j][1], other[1])):
                j += 1
            if j < len(lst):
                resyncs += 1
                if side == "RTL":
                    ia = j
                else:
                    ib = j
                continue
        print(f"differ after {matched} instructions ({resyncs} interrupt resyncs):")
        show("RTL  ", a, ia, opt.context)
        show("model", b, ib, opt.context)
        return 1
    print(f"agree for {matched} instructions ({resyncs} interrupt resyncs); "
          f"RTL {len(a) - ia} and model {len(b) - ib} left")
    return 0


if __name__ == "__main__":
    sys.exit(main())
