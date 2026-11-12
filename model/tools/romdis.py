#!/usr/bin/env python3
"""Disassemble one file of the EKA1 XIP ROM at its ROM address.

usage: romdis.py ROM NAME [-t] [-o OUT]
  ROM   linear ROM image (research/firmware/images/nor/rh29-4.10-symrom-from-fls.bin)
  NAME  file name as in `tools/romhdr.py ls` (e.g. cbus.dll), case-insensitive
  -t    disassemble as Thumb (default ARM)
Prints the TRomImageHeader; writes the objdump listing to OUT (default stdout).
Run with python3 -I. The ROM is read as data only.
"""
import argparse, os, struct, subprocess, sys, tempfile

BASE = 0x50000000
F = ["iUid1", "iUid2", "iUid3", "iCheck", "iEntryPoint", "iCodeAddress", "iDataAddress",
     "iCodeSize", "iTextSize", "iDataSize", "iBssSize", "iHeapSizeMin", "iHeapSizeMax",
     "iStackSize", "iDllRefTable", "iExportDirCount", "iExportDir", "iCheckSumCode",
     "iCheckSumData", "iVersion", "iFlags", "iPriority", "iDataBssLinearBase",
     "iNextExtension", "iHardwareVariant"]


def files(buf):
    u = lambda o: struct.unpack_from("<I", buf, o)[0]
    root_list = u(0x8C + 8) - BASE
    out = []

    def walk(d, depth=0):
        size = u(d)
        p, end = d + 4, d + 4 + size
        while p < end:
            esize, eaddr = struct.unpack_from("<iI", buf, p)
            att, nlen = buf[p + 8], buf[p + 9]
            name = buf[p + 10:p + 10 + 2 * nlen].decode("utf-16-le", "replace")
            if att & 0x10:
                if depth < 32:
                    walk(eaddr - BASE, depth + 1)
            else:
                out.append((name, eaddr, esize))
            p += (10 + 2 * nlen + 3) & ~3
    walk(u(root_list + 8) - BASE)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rom"); ap.add_argument("name")
    ap.add_argument("-t", action="store_true"); ap.add_argument("-o")
    a = ap.parse_args()
    buf = open(a.rom, "rb").read()
    hits = [f for f in files(buf) if f[0].lower() == a.name.lower()]
    if not hits:
        sys.exit("not found")
    name, addr, size = hits[0]
    h = dict(zip(F, struct.unpack_from("<25I", buf, addr - BASE)))
    for k in F:
        print("  %-20s 0x%08X" % (k, h[k]), file=sys.stderr)
    code = h["iCodeAddress"]
    n = h["iCodeSize"]
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as t:
        t.write(buf[code - BASE:code - BASE + n])
    cmd = ["arm-none-eabi-objdump", "-D", "-b", "binary", "-m", "armv4t", "--adjust-vma=0x%X" % code]
    if a.t:
        cmd += ["-M", "force-thumb"]
    cmd.append(t.name)
    txt = subprocess.run(cmd, capture_output=True, text=True).stdout
    os.unlink(t.name)
    hdr = "; %s  TRomImageHeader 0x%08X  code 0x%08X size 0x%X  entry 0x%08X  data 0x%08X\n" % (
        name, addr, code, n, h["iEntryPoint"], h["iDataAddress"])
    if a.o:
        open(a.o, "w").write(hdr + txt)
    else:
        sys.stdout.write(hdr + txt)


if __name__ == "__main__":
    main()
