#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Flash images for the boot bench, patched as the reference model loads them.

    python3 -I prep.py --cs0 CS0.bin --cs1 CS1.bin --patches model/rom-patches.txt \
        --root REPO --out DIR

Applies model/rom-patches.txt as model/hw/ngage_patch.c does: "cs0|cs1 OFF
HEX" bytes, "cs0file|cs1file OFF PATH" file contents (PATH relative to the
repository), then "md5 ENTRY": the integrity-table entry {start, end,
digest} at CS0 ENTRY gets the MD5 of ROM virtual addresses start..end
(0x50000000 + x is CS0 x below 0xF00000, CS1 above). Writes DIR/cs0.bin and
DIR/cs1.bin.
"""
import argparse
import hashlib
import os
import struct
import sys

ROM_VA = 0x50000000
ROM_CS0_LEN = 0x00F00000


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cs0", required=True)
    ap.add_argument("--cs1", required=True)
    ap.add_argument("--patches", required=True)
    ap.add_argument("--root", required=True)
    ap.add_argument("--out", required=True)
    opt = ap.parse_args()

    img = {"cs0": bytearray(16 << 20), "cs1": bytearray(8 << 20)}
    for k in img:
        img[k][:] = b"\xff" * len(img[k])
        with open(getattr(opt, k), "rb") as f:
            d = f.read(len(img[k]))
        img[k][:len(d)] = d

    md5s = []
    with open(opt.patches) as f:
        for line in f:
            line = line.split("#", 1)[0].split()
            if len(line) < 2:
                continue
            kind, off = line[0], int(line[1], 0)
            if kind == "md5":
                md5s.append(off)
            elif kind in ("cs0file", "cs1file") and len(line) == 3:
                with open(os.path.join(opt.root, line[2]), "rb") as g:
                    d = g.read()
                t = img[kind[:3]]
                if off + len(d) > len(t):
                    sys.exit(f"prep: patch out of range: {line}")
                t[off:off + len(d)] = d
                print(f"prep: {kind} 0x{off:x} <- {line[2]} ({len(d)} bytes)")
            elif kind in ("cs0", "cs1") and len(line) == 3:
                d = bytes.fromhex(line[2])
                img[kind][off:off + len(d)] = d
                print(f"prep: {kind} 0x{off:x} <- {line[2]}")
    for e in md5s:
        start, end = struct.unpack_from("<II", img["cs0"], e)
        rom = bytes(img["cs0"][:ROM_CS0_LEN]) + bytes(img["cs1"])
        digest = hashlib.md5(rom[start - ROM_VA:end - ROM_VA + 1]).digest()
        img["cs0"][e + 8:e + 24] = digest
        print(f"prep: md5 entry 0x{e:x} (0x{start:08x}-0x{end:08x}) = {digest.hex()}")

    os.makedirs(opt.out, exist_ok=True)
    for k, d in img.items():
        with open(os.path.join(opt.out, k + ".bin"), "wb") as f:
            f.write(d)


if __name__ == "__main__":
    main()
