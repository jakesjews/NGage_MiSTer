#!/usr/bin/env python3
"""Name the exports of every ROM DLL that has an SDK import library.

usage: romsyms.py ROM LIBDIR [-o OUT]
Writes "address name dll ordinal" lines for each export, both the function
address and the export-table slot (so import thunks, which load the slot,
can be named too). LIBDIR is the SDK's Epoc32/Release/armi/urel.
Run with python3 -I. Files are read as data only.
"""
import argparse, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import romdis, implib


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('rom'); ap.add_argument('libdir'); ap.add_argument('-o')
    a = ap.parse_args()
    rom = open(a.rom, 'rb').read()
    libs = {f.lower()[:-4]: os.path.join(a.libdir, f) for f in os.listdir(a.libdir) if f.lower().endswith('.lib')}
    out = []
    for name, addr, size in romdis.files(rom):
        base = name.lower().rsplit('.', 1)[0]
        if base not in libs or size < 0x64:
            continue
        h = addr - romdis.BASE
        if struct.unpack_from('<I', rom, h)[0] not in (0x10000079, 0x1000007A):
            continue
        count, edir = struct.unpack_from('<II', rom, h + 0x3C)
        if not count or not (romdis.BASE <= edir and edir + 4 * count <= romdis.BASE + len(rom)):
            continue
        table = {}
        for mname, obj in implib.members(open(libs[base], 'rb').read()):
            if mname in ('/', '//'):
                continue
            try:
                r = implib.coff_import(obj)
            except (struct.error, ValueError):
                continue
            if r:
                table[r[0]] = r[1]
        for k in range(count):
            slot = edir + 4 * k
            fn = struct.unpack_from('<I', rom, slot - romdis.BASE)[0]
            sym = table.get(k + 1, '?')
            out.append('%08X %s %s %d' % (fn & ~1, sym, name, k + 1))
            out.append('%08X slot:%s %s %d' % (slot, sym, name, k + 1))
    out.sort()
    text = '\n'.join(out) + '\n'
    if a.o:
        open(a.o, 'w').write(text)
    else:
        sys.stdout.write(text)


if __name__ == '__main__':
    main()
