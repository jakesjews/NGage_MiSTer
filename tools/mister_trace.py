#!/usr/bin/env python3
"""Fetch and decode the core's hardware trace dumps (rtl/mister/dbg_trace.sv).

The core writes a dump to DDR3 at 0x33000000 + n * 0x40000 on the first
aborts; the MiSTer's Linux side reads DDR3 through /dev/mem.

usage:
  tools/mister_trace.py fetch OUT.bin [--dumps N]      read N dumps (default 4) over ssh
  tools/mister_trace.py show DUMP.bin [options]        decode
    --dump N        which dump of the file (default: the last one written)
    --pc N          PC entries to show, newest last (default 400)
    --data N        data-port entries (default 200)
    --bus N         bus beats (default 100)
    --rom CS0 CS1   disassemble ROM addresses with arm-none-eabi-objdump
                    (virtual 0x50000000: CS0, then CS1 at 0x51000000)

Run with python3 -I; the dump is data only.
"""
import os
import struct
import subprocess
import sys

DUMP_BYTES = 0x40000
PC_OFF, PC_N = 0x10000, 8192
D_OFF, D_N = 0x20000, 4096
B_OFF, B_N = 0x30000, 2048
MAGIC = b"NGAGETRC"
EV = {0: "-", 1: "", 2: "SWI", 3: "UND", 4: "PABT", 5: "DABT", 6: "IRQ", 7: "FIQ"}
MODES = {0x10: "usr", 0x11: "fiq", 0x12: "irq", 0x13: "svc", 0x17: "abt", 0x1B: "und", 0x1F: "sys"}


def fetch(out, dumps, host):
    cmd = "dd if=/dev/mem bs=65536 skip=%d count=%d 2>/dev/null" % (0x33000000 // 65536, dumps * DUMP_BYTES // 65536)
    data = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "LogLevel=ERROR", "root@" + host, cmd],
                          capture_output=True).stdout
    if len(data) != dumps * DUMP_BYTES:
        sys.exit("read %d bytes, wanted %d" % (len(data), dumps * DUMP_BYTES))
    open(out, "wb").write(data)
    for n in range(dumps):
        d = data[n * DUMP_BYTES:(n + 1) * DUMP_BYTES]
        print("dump %d: %s" % (n, "present" if d[:8] == MAGIC else "empty"))


class Dis:
    """ARM disassembly of ROM words through objdump, by virtual address."""

    def __init__(self, cs0, cs1):
        self.cs0 = open(cs0, "rb").read()
        self.cs1 = open(cs1, "rb").read()
        self.cache = {}

    def word(self, va):
        if 0x50000000 <= va < 0x50000000 + len(self.cs0):
            o = va - 0x50000000
            return self.cs0[o:o + 4]
        if 0x51000000 <= va < 0x51000000 + len(self.cs1):
            o = va - 0x51000000
            return self.cs1[o:o + 4]
        return None

    def line(self, va, thumb):
        key = (va, thumb)
        if key in self.cache:
            return self.cache[key]
        w = self.word(va & ~1)
        if w is None or len(w) < 4:
            return ""
        tmp = "/tmp/mister_trace_%d.bin" % os.getpid()
        open(tmp, "wb").write(w)
        args = ["arm-none-eabi-objdump", "-D", "-b", "binary", "-m", "arm", "--adjust-vma=0x%x" % (va & ~1), tmp]
        if thumb:
            args.insert(4, "-Mforce-thumb")
        try:
            out = subprocess.run(args, capture_output=True, text=True).stdout
        except OSError:
            return ""
        os.unlink(tmp)
        text = ""
        for ln in out.splitlines():
            parts = ln.split("\t")
            if len(parts) >= 3 and parts[0].strip().endswith(":"):
                text = " ".join(p.strip() for p in parts[1:])
                break
        self.cache[key] = text
        return text


def u64(buf, off):
    return struct.unpack_from("<Q", buf, off)[0]


def show(path, which, npc, nd, nb, rom):
    data = open(path, "rb").read()
    dumps = [data[i:i + DUMP_BYTES] for i in range(0, len(data) - DUMP_BYTES + 1, DUMP_BYTES)]
    present = [i for i, d in enumerate(dumps) if d[:8] == MAGIC]
    if not present:
        sys.exit("no dump in %s" % path)
    if which is None:
        which = present[-1]
    d = dumps[which]
    if d[:8] != MAGIC:
        sys.exit("dump %d is empty" % which)
    clk = u64(d, 8)
    w2 = u64(d, 16)
    w3 = u64(d, 24)
    w4 = u64(d, 32)
    w5 = u64(d, 40)
    pc_w, d_w, b_w = (w2 >> 32) & 0xFFFF, (w2 >> 16) & 0xFFFF, w2 & 0xFFFF
    reason = (w2 >> 48) & 0xFF
    print("dump %d of %s: trigger at clock %d (%.6f s), reason %s, trigger pc %08x" % (
        w2 >> 56, present, clk, clk / 104e6,
        "+".join(n for b, n in ((1, "exception"), (2, "fault-record")) if reason & b) or "?", w5 & 0xFFFFFFFF))
    print("retired %d, triggers %d, data accesses %d, bus beats %d" % (w3 >> 32, (w3 >> 8) & 0xFFFFFF, w4 >> 32, w4 & 0xFFFFFFFF))
    dis = Dis(*rom) if rom else None

    print("\n== retired instructions (newest last; clock low 16 bits, mode, flags after) ==")
    n = min(npc, PC_N, w3 >> 32)
    for k in range(n, 0, -1):
        idx = (pc_w - k) % PC_N
        v = u64(d, PC_OFF + 8 * idx)
        pc8 = v & 0xFFFFFFFF
        cpsr = (v >> 32) & 0xFF
        clk16 = (v >> 40) & 0xFFFF
        ev = (v >> 56) & 0xF
        flags = v >> 60
        thumb = (cpsr >> 5) & 1
        pc = (pc8 - (4 if thumb else 8)) & 0xFFFFFFFF
        text = dis.line(pc, thumb) if dis and ev in (1, 2, 3, 4, 5) else ""
        print("%5d  %04x %s%s %s %08x %-5s %s" % (-k, clk16, MODES.get(cpsr & 0x1F, "%02x" % (cpsr & 0x1F)),
                                                 "T" if thumb else " ",
                                                 "".join(f if (flags >> i) & 1 else "." for i, f in ((3, "N"), (2, "Z"), (1, "C"), (0, "V"))),
                                                 pc, EV.get(ev, "?"), text))

    print("\n== data port (newest last) ==")
    n = min(nd, D_N, w4 >> 32)
    for k in range(n, 0, -1):
        idx = (d_w - k) % D_N
        w0 = u64(d, D_OFF + 16 * idx)
        w1 = u64(d, D_OFF + 16 * idx + 8)
        print("%5d  %08x  %s %08x sel %x  %08x" % (-k, w0 >> 32, "W" if (w1 >> 16) & 1 else "R", w0 & 0xFFFFFFFF,
                                                   (w1 >> 8) & 0xF, w1 >> 32))

    print("\n== bus (newest last) ==")
    n = min(nb, B_N, w4 & 0xFFFFFFFF)
    for k in range(n, 0, -1):
        idx = (b_w - k) % B_N
        w0 = u64(d, B_OFF + 16 * idx)
        w1 = u64(d, B_OFF + 16 * idx + 8)
        print("%5d  %08x  %s%s %08x sel %x cti %d  %08x" % (-k, w0 >> 32, "W" if (w1 >> 18) & 1 else "R",
                                                            "!" if (w1 >> 19) & 1 else " ", w0 & 0xFFFFFFFF,
                                                            (w1 >> 8) & 0xF, (w1 >> 13) & 7, w1 >> 32))


def main():
    a = sys.argv[1:]
    if not a:
        sys.exit(__doc__)
    if a[0] == "fetch":
        dumps = 4
        host = os.environ.get("MISTER_HOST", "mister")
        if "--dumps" in a:
            dumps = int(a[a.index("--dumps") + 1])
        fetch(a[1], dumps, host)
        return
    if a[0] == "show":
        which, npc, nd, nb, rom = None, 400, 200, 100, None
        i = 2
        while i < len(a):
            if a[i] == "--dump":
                which = int(a[i + 1]); i += 2
            elif a[i] == "--pc":
                npc = int(a[i + 1]); i += 2
            elif a[i] == "--data":
                nd = int(a[i + 1]); i += 2
            elif a[i] == "--bus":
                nb = int(a[i + 1]); i += 2
            elif a[i] == "--rom":
                rom = (a[i + 1], a[i + 2]); i += 3
            else:
                sys.exit("unknown option %s" % a[i])
        show(a[1], which, npc, nd, nb, rom)
        return
    sys.exit(__doc__)


if __name__ == "__main__":
    main()
