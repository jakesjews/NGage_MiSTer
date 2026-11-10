#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Kernel calls, process switches and cache/TLB flushes per second from an
exception log of the model (NGAGE_EXCLOG, model/plugins/excprof.c).

usage: excstat.py EXC.BIN [T0 T1]      guest seconds; without them, a table
                                       of 20-second windows over the run
Guest seconds are instructions / 62.5 million (the model's -icount shift=4;
the firmware never halts the CPU). Needs numpy. The log is read as data.

The names of the executive calls are those of EKA2L1's Symbian 6 table
(src/emu/kernel/src/svc.cpp, svc_register_funcs_v6); the phone's EUSER
makes each call from a one-instruction stub, so the SWI's number is the
call. The kernel's process switch shows as its CP15 writes: c3 (domain
access), c7,c10,4 (drain write buffer), then, as the switch needs them,
c8,c6,0 and c8,c5,0 (invalidate the D and I TLBs), c7,c5,0 (invalidate the
I-cache) and a loop of c7,c14,2 over every D-cache index (clean and
invalidate the D-cache; 512 operations for the phone's 8 KB).

A log made with footprint=on also holds, for each D-TLB invalidation, what
ran since the one before: the distinct 16-byte code lines, 4 KB code pages
and 4 KB data pages. The pages' sums per second are the walks TLBs of any
size must repeat because of the kernel's invalidations.
"""
import collections
import sys

import numpy as np

DT = np.dtype([("n", "<u8"), ("pc", "<u4"), ("to", "<u4"), ("word", "<u4"), ("value", "<u4")])
IPS = 62.5e6
VEC = {0x04: "undefined", 0x08: "SWI", 0x0C: "prefetch abort", 0x10: "data abort", 0x18: "IRQ", 0x1C: "FIQ"}
CALLS = {
    0x01: "ChunkBase", 0x02: "ChunkSize", 0x03: "ChunkMaxSize", 0x18: "MutexCount", 0x19: "MutexWait",
    0x1A: "MutexSignal", 0x1B: "ProcessId", 0x29: "SemaphoreCount", 0x2A: "SemaphoreWait", 0x32: "ThreadId",
    0x36: "ThreadPriority", 0x3C: "ThreadRequestCount", 0x4D: "WaitForAnyRequest", 0x6C: "Heap", 0x70: "TickCount",
    0x72: "PushTrapFrame", 0x73: "PopTrapFrame", 0x74: "ActiveScheduler", 0x75: "SetActiveScheduler", 0x80: "DllTls",
    0x81: "TrapHandler", 0x82: "SetTrapHandler", 0x8D: "LockedInc", 0x8E: "LockedDec", 0xBC: "RomHeaderAddress",
    0xBE: "MathRand",
    0x80002C: "SemaphoreSignalN", 0x800040: "ThreadGetDesLength", 0x800041: "ThreadGetDesMaxLength",
    0x800042: "ThreadReadIpcToDes8", 0x800043: "ThreadReadIpcToDes16", 0x800044: "ThreadWriteIpcToDes8",
    0x800045: "ThreadWriteIpcToDes16", 0x80006E: "TimeNow", 0x800083: "HalGet", 0x8000A9: "LibraryType",
    0x8000AA: "ProcessType", 0x8000B7: "BusDevOpenSocket", 0x8000BB: "DllFileName", 0x8000C9: "ClearInactivityTime",
    0xC0000C: "LogicalChannelDoRequest", 0xC0000E: "LogicalChannelDoControl", 0xC0002B: "SemaphoreSignal",
    0xC0002E: "ServerReceive", 0xC0002F: "ServerCancel", 0xC00031: "SessionSend", 0xC00046: "ThreadRequestComplete",
    0xC00047: "TimerCancel", 0xC00048: "TimerAfter", 0xC00049: "TimerAt", 0xC0004A: "TimerLock",
    0xC0004E: "RequestSignal", 0xC0005E: "After", 0xC0006B: "MessageComplete", 0xC0006D: "HeapSwitch",
    0xC00076: "TheExecutor", 0xC0007B: "AddEvent", 0xC000BF: "SessionSendSync",
}


def call(word):
    if (word & 0xFFFFFF00) == 0xDF00:
        return "Thumb swi %02x" % (word & 0xFF)
    n = word & 0xFFFFFF
    return "%s (%x)" % (CALLS.get(n, "?"), n)


def cp15(word):
    return "c%d,%d,c%d,%d" % ((word >> 16) & 15, (word >> 21) & 7, word & 15, (word >> 5) & 7)


def window(ev, t0, t1, detail):
    secs = t1 - t0
    sel = ev[(ev["n"] >= t0 * IPS) & (ev["n"] < t1 * IPS)]
    calls, ops, others = collections.Counter(), collections.Counter(), collections.Counter()
    before_i, before_d = collections.Counter(), collections.Counter()
    last = None
    foot = []
    for n, pc, to, word, value in sel.tolist():
        if to == 0xFFFFFFFD:
            foot.append((pc, word, value))
            continue
        if to == 0xFFFFFFFE:
            k = cp15(word)
            ops[k] += 1
            if k == "c8,0,c6,0":
                before_i[last] += 1
            elif k == "c7,0,c14,2" and value == 0:
                before_d[last] += 1
            continue
        name = VEC.get(to & 0x1C, "vector %02x" % (to & 0x1C))
        if name == "SWI":
            last = call(word)
            calls[last] += 1
        else:
            last = name
            others[name] += 1
    rate = lambda v: v / secs
    if not detail:
        print("%5.0f-%-5.0f SWI %7.0f  IRQ %6.1f  FIQ %6.1f  aborts %5.1f  undefined %5.1f  invalidations: D-TLB %6.1f I-TLB %6.1f I-cache %6.1f  D-cache loops %5.2f" % (
            t0, t1, rate(sum(calls.values())), rate(others["IRQ"]), rate(others["FIQ"]),
            rate(others["data abort"] + others["prefetch abort"]), rate(others["undefined"]),
            rate(ops["c8,0,c6,0"]), rate(ops["c8,0,c5,0"]), rate(ops["c7,0,c5,0"]), rate(sum(before_d.values()))))
        return
    print("guest %.0f-%.0f s, per second:" % (t0, t1))
    print("  exceptions: SWI %.0f" % rate(sum(calls.values())) + "".join("  %s %.1f" % (k, rate(v)) for k, v in others.most_common()))
    print("  kernel calls:")
    for k, v in calls.most_common(20):
        print("    %8.1f  %s" % (rate(v), k))
    print("  CP15 writes: " + "  ".join("%s %.1f" % (k, rate(v)) for k, v in ops.most_common()))
    print("  D-TLB invalidations %.1f (I-TLB %.1f, I-cache %.1f), after: " % (rate(ops["c8,0,c6,0"]), rate(ops["c8,0,c5,0"]), rate(ops["c7,0,c5,0"]))
          + "  ".join("%s %.1f" % (k, rate(v)) for k, v in before_i.most_common(6)))
    print("  D-cache clean-and-invalidate loops %.2f, after: " % rate(sum(before_d.values()))
          + "  ".join("%s %.2f" % (k, rate(v)) for k, v in before_d.most_common(4)))
    if foot:
        f = np.array(foot, dtype=np.float64)
        for i, what in enumerate(("code lines", "code pages", "data pages")):
            col = f[:, i]
            print("  between D-TLB invalidations, distinct %s: %.0f a second; an interval: mean %.0f, median %.0f, 90%% %.0f" % (
                what, rate(col.sum()), col.mean(), np.median(col), np.percentile(col, 90)))


def main():
    ev = np.fromfile(sys.argv[1], dtype=DT)
    total, ev = ev[-1]["n"], ev[:-1]
    if len(sys.argv) >= 4:
        window(ev, float(sys.argv[2]), float(sys.argv[3]), True)
    else:
        print("%d events, %.1f guest seconds" % (len(ev), total / IPS))
        for t0 in range(0, int(total / IPS), 20):
            window(ev, t0, t0 + 20, False)


if __name__ == "__main__":
    main()
