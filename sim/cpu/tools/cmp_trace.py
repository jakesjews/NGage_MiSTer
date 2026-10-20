#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare the RTL bench's retirement trace with a QEMU instruction log.

    python3 -I cmp_trace.py RTL.trace QEMU.qlog [--halt 0x40] [--name TEST]

RTL.trace (sim/cpu/tb/main.cpp): one line per retired instruction or taken
exception, "K PC r0 ... r14 CPSR", with the registers *after* it; K is R
(retired), S/U/P/D (SWI, undefined, prefetch abort, data abort taken at
PC) or I/F (interrupt taken before PC). A register still waiting for a
background load prints as "--------" and is not compared.

QEMU.qlog (qemu/run.sh: -d exec,cpu,nochain with one instruction per TB):
"Trace" lines with the PC, each followed by the registers *before* that
instruction.

Both become a list of (PC, registers before): the RTL list shifted by one,
starting from the reset state, with interrupt events folded into the
following instruction, and so are prefetch aborts (QEMU never logs the
instruction it could not fetch). They must agree up to (not including) the first visit to the
halt loop. PSR bit 8 is ignored (QEMU sets the ARMv6 A bit on an ARMv4 CPU), and
so are the flags until the two first agree (they are unknown after reset;
QEMU starts with Z set, ZAP with none).
"""
import argparse
import re
import sys

PSR_MASK = 0xFFFFFEFF
RESET_CPSR = 0xD3


def merge_thumb_bl(events, image):
    """QEMU runs a Thumb BL pair (prefix 11110, suffix 11111) as one
    instruction; ZAP retires the halves separately. Keep the prefix's line
    (its registers are those before the pair) and drop the suffix's."""
    if image is None:
        return events

    def half(pc):
        return int.from_bytes(image[pc:pc + 2], "little") if pc + 2 <= len(image) else 0

    out = []
    i = 0
    while i < len(events):
        pc, kind, state = events[i]
        out.append(events[i])
        thumb = state[15] is not None and (state[15] >> 5) & 1
        if (kind == "R" and thumb and i + 1 < len(events) and
                (half(pc) & 0xF800) == 0xF000 and events[i + 1][0] == pc + 2 and
                events[i + 1][1] == "R" and (half(pc + 2) & 0xF800) == 0xF800):
            i += 2
            continue
        i += 1
    return out


def rtl_stream(path, halt):
    out = []
    state = [0] * 15 + [RESET_CPSR]
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) != 18:
                continue
            kind, pc = p[0], int(p[1], 16)
            regs = [None if v.startswith("-") else int(v, 16) for v in p[2:17]]
            after = regs + [int(p[17], 16)]
            if kind == "R" and pc == halt:
                break
            if kind not in ("I", "F", "P"):
                out.append((pc, kind, state))
            state = after
    return out


TRACE_RE = re.compile(r"^Trace \d+: \S+ \[[0-9a-f]+/([0-9a-f]+)/")
REG_RE = re.compile(r"R(\d\d)=([0-9a-f]{8})")
PSR_RE = re.compile(r"^PSR=([0-9a-f]{8})")


def qemu_stream(path, halt):
    out = []
    pc = None
    regs = {}
    with open(path) as f:
        for line in f:
            m = TRACE_RE.match(line)
            if m:
                pc = int(m.group(1), 16) & 0xFFFFFFFF
                regs = {}
                continue
            if pc is None:
                continue
            for r, v in REG_RE.findall(line):
                regs[int(r)] = int(v, 16)
            m = PSR_RE.match(line)
            if m:
                if pc == halt:
                    break
                state = [regs.get(i, 0) for i in range(15)] + [int(m.group(1), 16)]
                out.append((pc, state))
                pc = None
    return out


def fmt(state):
    return " ".join("--------" if v is None else f"{v:08x}" for v in state)


def main():
    ap = argparse.ArgumentParser(description="compare RTL and QEMU traces")
    ap.add_argument("rtl")
    ap.add_argument("qemu")
    ap.add_argument("--halt", default="0x40")
    ap.add_argument("--name", default="")
    ap.add_argument("--max", type=int, default=5, help="mismatches to show")
    ap.add_argument("--bin", help="the test image at 0 (to pair Thumb BL halves)")
    opt = ap.parse_args()
    halt = int(opt.halt, 0)
    name = opt.name + ": " if opt.name else ""
    image = None
    if opt.bin:
        with open(opt.bin, "rb") as f:
            image = f.read()

    r = merge_thumb_bl(rtl_stream(opt.rtl, halt), image)
    q = qemu_stream(opt.qemu, halt)
    shown = 0
    flags_known = False
    for i in range(min(len(r), len(q))):
        rpc, kind, rs = r[i]
        qpc, qs = q[i]
        if not flags_known and not ((rs[15] ^ qs[15]) & PSR_MASK):
            flags_known = True
        psr_mask = PSR_MASK if flags_known else PSR_MASK & 0x0FFFFFFF
        bad = [j for j in range(16)
               if rs[j] is not None and
               ((rs[j] ^ qs[j]) & (psr_mask if j == 15 else 0xFFFFFFFF))]
        if rpc != qpc or bad:
            if shown == 0:
                print(f"{name}traces diverge at instruction {i}:")
            what = "pc" if rpc != qpc else ", ".join(
                "cpsr" if j == 15 else f"r{j}" for j in bad)
            print(f"  #{i} RTL {kind} pc {rpc:08x} | QEMU pc {qpc:08x}  ({what}, registers before)")
            print(f"     RTL  {fmt(rs)}")
            print(f"     QEMU {fmt(qs)}")
            if i > 0:
                print(f"     previous: RTL pc {r[i-1][0]:08x} {r[i-1][1]}, QEMU pc {q[i-1][0]:08x}")
            shown += 1
            if shown >= opt.max or rpc != qpc:
                return 1
    if shown:
        return 1
    if len(r) != len(q):
        print(f"{name}trace lengths differ: RTL {len(r)}, QEMU {len(q)} instructions")
        tail = r[len(q):len(q) + 3] if len(r) > len(q) else q[len(r):len(r) + 3]
        for t in tail:
            print(f"  next: pc {t[0]:08x}")
        return 1
    print(f"{name}traces match ({len(r)} instructions)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
