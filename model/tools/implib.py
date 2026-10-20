#!/usr/bin/env python3
"""Ordinal -> symbol table from a Symbian 6.1 ARMI import library (.lib).

usage: implib.py LIB [--rom ROM --image NAME]
The .lib is an ar archive of PE-COFF members made by dlltool; each member
holds one import: its .idata$5 word is 0x80000000 | ordinal and its symbols
name the function. With --rom/--image the export directory of that ROM file
is read too and the ROM address of each ordinal is printed.
Run with python3 -I. Files are read as data only.
"""
import argparse, struct, sys


def members(data):
    if data[:8] != b'!<arch>\n':
        sys.exit('not an ar archive')
    p = 8
    while p + 60 <= len(data):
        hdr = data[p:p + 60]
        size = int(hdr[48:58].decode().strip())
        yield hdr[:16].decode(errors='replace').strip(), data[p + 60:p + 60 + size]
        p += 60 + size + (size & 1)


def coff_import(obj):
    if len(obj) < 20:
        return None
    nsec, symptr, nsym = struct.unpack_from('<HxxxxII', obj, 2)
    opt = struct.unpack_from('<H', obj, 16)[0]
    secs = []
    for i in range(nsec):
        o = 20 + opt + 40 * i
        name = obj[o:o + 8].rstrip(b'\0').decode(errors='replace')
        size, rawptr = struct.unpack_from('<II', obj, o + 16)
        secs.append((name, obj[rawptr:rawptr + size] if rawptr else b''))
    ordinal = None
    for name, raw in secs:
        if name == '.idata$5' and len(raw) >= 4:
            v = struct.unpack_from('<I', raw)[0]
            if v & 0x80000000:
                ordinal = v & 0xFFFF
    if ordinal is None:
        return None
    strtab = symptr + 18 * nsym
    names = []
    for i in range(nsym):
        o = symptr + 18 * i
        raw = obj[o:o + 8]
        if raw[:4] == b'\0\0\0\0':
            off = struct.unpack_from('<I', raw, 4)[0]
            n = obj[strtab + off:obj.index(b'\0', strtab + off)].decode(errors='replace')
        else:
            n = raw.rstrip(b'\0').decode(errors='replace')
        names.append(n)
    best = [n for n in names if not n.startswith(('__imp_', '_imp__', '.', '__head', '_head'))]
    return ordinal, (best[0] if best else names[0] if names else '?')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('lib')
    ap.add_argument('--rom')
    ap.add_argument('--image')
    a = ap.parse_args()
    table = {}
    for name, obj in members(open(a.lib, 'rb').read()):
        if name in ('/', '//'):
            continue
        try:
            r = coff_import(obj)
        except (struct.error, ValueError):
            continue
        if r:
            table[r[0]] = r[1]
    addrs = {}
    if a.rom and a.image:
        sys.path.insert(0, __file__.rsplit('/', 1)[0])
        import romdis
        rom = open(a.rom, 'rb').read()
        hits = [f for f in romdis.files(rom) if f[0].lower() == a.image.lower()]
        hdr = hits[0][1] - romdis.BASE
        count, edir = struct.unpack_from('<II', rom, hdr + 0x3C)
        for k in range(count):
            addrs[k + 1] = struct.unpack_from('<I', rom, edir - romdis.BASE + 4 * k)[0]
    for o in sorted(table):
        print('%4d %s %s' % (o, ('%08X' % addrs[o]) if o in addrs else '', table[o]))


if __name__ == '__main__':
    main()
