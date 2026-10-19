#!/usr/bin/env python3
"""Find and describe Symbian EKA1 (OS 6.1) XIP ROM images inside a file.

Works on a flat NOR image, an EKA2L1 SYM.ROM or an SDumper ROM-0x50000000
dump. Layouts follow the Symbian 6.1 SDK e32rom.h (TRomHeader 0x100 bytes,
TRomImageHeader 0x64 bytes, TRomDir/TRomEntry directory tree, UTF-16 names).

usage:
  romhdr.py scan FILE                  list candidate TRomHeaders (iRomBase at +0x8C)
  romhdr.py info FILE [--offset N]     decode the header and the kernel image header
  romhdr.py ls   FILE [--offset N]     list the Z: directory tree
  romhdr.py cut  FILE --offset N -o OUT    extract iRomSize bytes (a SYM.ROM)

Run with python3 -I. Files are read as data only.
"""
import argparse
import struct
import sys

ROM_BASE_EKA1 = 0x50000000


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def candidates(buf):
    """Offsets where a TRomHeader with iRomBase == 0x50000000 and a sane size could start."""
    pos = 0x8C
    while True:
        i = buf.find(struct.pack("<I", ROM_BASE_EKA1), pos)
        if i < 0:
            return
        start = i - 0x8C
        if start >= 0 and start % 4 == 0:
            size = u32(buf, i + 4)
            root = u32(buf, i + 8)
            prim = u32(buf, start + 0xA0)
            if 0x100000 <= size <= 0x4000000 and ROM_BASE_EKA1 < root < ROM_BASE_EKA1 + size \
                    and ROM_BASE_EKA1 < prim < ROM_BASE_EKA1 + size:
                yield start
        pos = i + 4


def header(buf, off):
    h = {}
    h["jump0"] = u32(buf, off)
    maj, minr, build = struct.unpack_from("<bbh", buf, off + 0x80)
    h["version"] = "%d.%02d(%d)" % (maj, minr, build)
    t_lo, t_hi = struct.unpack_from("<II", buf, off + 0x84)
    h["time_us"] = (t_hi << 32) | t_lo
    names = ["iRomBase", "iRomSize", "iRomRootDirectoryList", "iKernDataAddress",
             "iKernStackAddress", "iPrimaryFile", "iSecondaryFile", "iCheckSum"]
    for k, n in enumerate(names):
        h[n] = u32(buf, off + 0x8C + 4 * k)
    lang_lo, lang_hi = struct.unpack_from("<II", buf, off + 0xAC)
    h["iLanguage"] = (lang_hi << 32) | lang_lo
    h["iHardware"] = u32(buf, off + 0xB4)
    h["iScreenSize"] = struct.unpack_from("<ii", buf, off + 0xB8)
    rest = ["iScreenBitsPerPixel", "iRomSectionHeader", "iTotalSvDataSize", "iVariantFile",
            "iExtensionFile", "iRelocInfo", "iTraceMask", "iUserDataAddress", "iTotalUserDataSize"]
    for k, n in enumerate(rest):
        h[n] = u32(buf, off + 0xC0 + 4 * k)
    return h


def lin(off, base, addr):
    """File offset of a linear ROM address."""
    return off + addr - base


IMG_FIELDS = ["iUid1", "iUid2", "iUid3", "iCheck", "iEntryPoint", "iCodeAddress", "iDataAddress",
              "iCodeSize", "iTextSize", "iDataSize", "iBssSize", "iHeapSizeMin", "iHeapSizeMax",
              "iStackSize", "iDllRefTable", "iExportDirCount", "iExportDir", "iCheckSumCode",
              "iCheckSumData", "iVersion", "iFlags", "iPriority", "iDataBssLinearBase",
              "iNextExtension", "iHardwareVariant"]


def image_header(buf, foff):
    return dict(zip(IMG_FIELDS, struct.unpack_from("<25I", buf, foff)))


def is_entry(buf, off, base, addr):
    """True when addr holds a TRomEntry (size, address, attributes, UTF-16 name)."""
    f = lin(off, base, addr)
    nlen = buf[f + 9]
    if not 1 <= nlen <= 64:
        return False
    name = buf[f + 10:f + 10 + 2 * nlen]
    return all(name[i + 1] == 0 and 0x20 <= name[i] < 0x7F for i in range(0, len(name), 2))


def entry_name(buf, off, base, addr):
    if not is_entry(buf, off, base, addr):
        return "(no entry)"
    f = lin(off, base, addr)
    return buf[f + 10:f + 10 + 2 * buf[f + 9]].decode("utf-16-le")


def image_addr(buf, off, base, addr):
    """EKA1 header fields point at the file's TRomEntry; follow it to the TRomImageHeader."""
    if is_entry(buf, off, base, addr):
        return u32(buf, lin(off, base, addr) + 4)
    return addr


def walk(buf, off, base, dir_addr, path, out, depth=0):
    if depth > 32:
        return
    d = lin(off, base, dir_addr)
    size = u32(buf, d)
    p = d + 4
    end = p + size
    while p < end:
        esize, eaddr = struct.unpack_from("<iI", buf, p)
        att, nlen = buf[p + 8], buf[p + 9]
        name = buf[p + 10:p + 10 + 2 * nlen].decode("utf-16-le", "replace")
        full = path + "\\" + name
        if att & 0x10:
            out.append((full + "\\", eaddr, esize, att))
            walk(buf, off, base, eaddr, full, out, depth + 1)
        else:
            out.append((full, eaddr, esize, att))
        p += (10 + 2 * nlen + 3) & ~3


def pick(buf, offset):
    if offset is not None:
        return int(offset, 0)
    found = list(candidates(buf))
    if not found:
        sys.exit("no EKA1 TRomHeader found")
    return found[0]


def cmd_scan(args):
    buf = open(args.file, "rb").read()
    for off in candidates(buf):
        h = header(buf, off)
        print("offset 0x%08X  size 0x%08X  version %s  kernel 0x%08X  root 0x%08X  screen %dx%d @%d bpp" % (
            off, h["iRomSize"], h["version"], h["iPrimaryFile"], h["iRomRootDirectoryList"],
            h["iScreenSize"][0], h["iScreenSize"][1], h["iScreenBitsPerPixel"]))


def cmd_info(args):
    buf = open(args.file, "rb").read()
    off = pick(buf, args.offset)
    h = header(buf, off)
    base = h["iRomBase"]
    print("TRomHeader at file offset 0x%X" % off)
    for k, v in h.items():
        print("  %-22s %s" % (k, ("0x%08X" % v) if isinstance(v, int) else v))
    end = min(len(buf), off + h["iRomSize"])
    s = sum(struct.unpack_from("<%dI" % ((end - off) // 4), buf, off)) & 0xFFFFFFFF
    print("  word sum of image      0x%08X" % s)
    for label, key in (("kernel (primary)", "iPrimaryFile"), ("file server (secondary)", "iSecondaryFile"),
                       ("variant", "iVariantFile"), ("first extension", "iExtensionFile")):
        if not h[key]:
            continue
        addr = image_addr(buf, off, base, h[key])
        ih = image_header(buf, lin(off, base, addr))
        print("%s %s, TRomImageHeader at 0x%08X" % (label, entry_name(buf, off, base, h[key]), addr))
        for k in ("iUid1", "iUid2", "iUid3", "iEntryPoint", "iCodeAddress", "iCodeSize", "iDataAddress",
                  "iDataSize", "iBssSize", "iDataBssLinearBase", "iFlags", "iHardwareVariant"):
            print("    %-20s 0x%08X" % (k, ih[k]))


def cmd_ls(args):
    buf = open(args.file, "rb").read()
    off = pick(buf, args.offset)
    h = header(buf, off)
    base = h["iRomBase"]
    rl = lin(off, base, h["iRomRootDirectoryList"])
    n = u32(buf, rl)
    for k in range(n):
        variant, root = struct.unpack_from("<II", buf, rl + 4 + 8 * k)
        print("root %d: hardware variant 0x%08X, Z:\\ at 0x%08X" % (k, variant, root))
        out = []
        walk(buf, off, base, root, "Z:", out)
        for name, addr, size, att in out:
            print("  0x%08X %9d %02X %s" % (addr, size, att, name))


def cmd_cut(args):
    buf = open(args.file, "rb").read()
    off = int(args.offset, 0)
    size = header(buf, off)["iRomSize"]
    open(args.output, "wb").write(buf[off:off + size])
    print("wrote %s (%d bytes)" % (args.output, size))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("scan", "info", "ls", "cut"):
        s = sub.add_parser(name)
        s.add_argument("file")
        s.add_argument("--offset")
        if name == "cut":
            s.add_argument("-o", "--output", required=True)
    args = p.parse_args()
    return {"scan": cmd_scan, "info": cmd_info, "ls": cmd_ls, "cut": cmd_cut}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
