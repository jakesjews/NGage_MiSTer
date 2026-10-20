#!/usr/bin/env python3
"""Build the N-Gage QD MiSTer core's flash images (cs0.bin, cs1.bin) from a
user's own RH-29 firmware.

Input, either:
  phoenix  the Phoenix flash files: the MCU file (RH2946.0C1) and the language
           pack (RH2946.0S5, or another .S*), converted as tools/fls2bin.py
           does (CS0 at 0x00000000, 16 MB; CS1 at 0x02000000, 8 MB; unwritten
           bytes 0xFF)
  flat     flat CS0 (16 MB) and CS1 (8 MB) images, e.g. dumps

Then the model shortcuts in model/rom-patches.txt are applied exactly as the
reference model's model/hw/ngage_patch.c applies them at load:
  cs0|cs1 <offset> <hex bytes>        bytes as stored in flash
  cs0file|cs1file <offset> <path>     a file's contents: the NOS stand-in
                                      binaries, taken from --standin (by file
                                      name) unless --model-build is given
  md5 <CS0 offset of an entry>        after all byte patches: recompute the
                                      bootstrap's integrity digest of that
                                      table entry {start, end, digest[16]}
The md5 lines read ROM virtual address 0x50000000 + x as CS0 x below
0xF00000 and CS1 x - 0xF00000 above, as the patcher does. The integrity table
(CS0 0x8F00) is then checked the way the bootstrap does (routine 0x3238):
every entry that is not erased must hold the MD5 of its ROM virtual
addresses, mapped as the bootstrap's page table has them (CS0 to
0x50EFFFFF, CS1 0x000000-0x3FFFFF at 0x50F00000-0x512FFFFF, CS0 0xF00000
and up at 0x51300000: the language pack's ROM, entry 0x8F00, spans the end of
CS1 and the top of CS0).

The flash files leave out 56 per-phone bytes at CS0 0x12C (after the marker
"KaeP"); --phone-data copies them from a ROM dump that starts at flash 0
(SDumper's ROM-0x50000000-*.dmp), as the model's image has them. Whether the
firmware needs them is not known.

usage:
  mkimage.py phoenix MCU.C1 LANG.S5 [-o DIR] [options]
  mkimage.py flat CS0.bin CS1.bin [-o DIR] [options]
options:
  -o DIR             where cs0.bin and cs1.bin go (default .)
  --patches FILE     the patch list (default model/rom-patches.txt)
  --standin DIR      the stand-in binaries (default tools/standin)
  --model-build      take cs0file/cs1file paths as written (model/.build/...)
  --phone-data DUMP  restore the per-phone bytes from a ROM dump
  --no-patches       write the images unpatched (the table check then reports
                     the digests the firmware carries)

Load cs0.bin and cs1.bin with the OSD's "Load flash CS0" and "Load flash CS1".
Run with python3 -I. The firmware is read as data only; nothing from it is
executed.
"""
import argparse
import hashlib
import importlib.util
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CS0_SIZE = 16 << 20
CS1_SIZE = 8 << 20
CS1_BASE = 0x02000000
ROM_VA = 0x50000000
ROM_CS0_LEN = 0x00F00000
TABLE = (0x8F00, 0x8F18)          # the entries the bootstrap checks (0x359C, 0x35A0)
PHONE_DATA = (0x12C, 0x164)       # the 56 per-phone bytes: [start, end)


def fail(msg):
    sys.stderr.write("mkimage: %s\n" % msg)
    sys.exit(1)


# ---------------------------------------------------------------- input

def load_fls2bin():
    sys.dont_write_bytecode = True      # no __pycache__ next to the tools
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fls2bin.py")
    spec = importlib.util.spec_from_file_location("fls2bin", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def from_phoenix(files):
    fls = load_fls2bin()
    cs0 = bytearray(b"\xFF" * CS0_SIZE)
    cs1 = bytearray(b"\xFF" * CS1_SIZE)
    for path in files:
        _, records = fls.load(path)
        placed = 0
        for r in records:
            if "addr" not in r or r["type"] == 0x2E:
                continue
            a, d = r["addr"], r["data"]
            if 0 <= a and a + len(d) <= CS0_SIZE:
                cs0[a:a + len(d)] = d
            elif CS1_BASE <= a and a + len(d) <= CS1_BASE + CS1_SIZE:
                cs1[a - CS1_BASE:a - CS1_BASE + len(d)] = d
            else:
                fail("%s: a block at 0x%08X (%d bytes) is outside CS0 and CS1" % (path, a, len(d)))
            placed += len(d)
            if r.get("h_ok") is False:
                fail("%s: block at 0x%08X: header checksum mismatch" % (path, a))
        print("%s: %d bytes of flash data" % (path, placed))
    return cs0, cs1


def from_flat(cs0_path, cs1_path):
    cs0 = bytearray(open(cs0_path, "rb").read())
    cs1 = bytearray(open(cs1_path, "rb").read())
    if len(cs0) != CS0_SIZE:
        fail("%s: %d bytes, CS0 is %d" % (cs0_path, len(cs0), CS0_SIZE))
    if len(cs1) != CS1_SIZE:
        fail("%s: %d bytes, CS1 is %d" % (cs1_path, len(cs1), CS1_SIZE))
    return cs0, cs1


# ---------------------------------------------------------------- patches
# ngage_patch.c reads each line with sscanf(line, "%7s %li %511s") after
# cutting it at the first '#'; these helpers do the same.

def c_strtol(s):
    """strtol(s, &end, 0): returns (value, characters used) or (None, 0)."""
    i = 0
    neg = False
    if i < len(s) and s[i] in "+-":
        neg = s[i] == "-"
        i += 1
    base = 10
    if s[i:i + 2].lower() == "0x" and i + 2 < len(s) and s[i + 2] in "0123456789abcdefABCDEF":
        base = 16
        i += 2
    elif s[i:i + 1] == "0":
        base = 8
    j = i
    digits = "0123456789abcdef"[:base]
    while j < len(s) and s[j].lower() in digits:
        j += 1
    if j == i:
        return None, 0
    v = int(s[i:j], base)
    return (-v if neg else v), j


def scan_line(line):
    """The fields sscanf("%7s %li %511s") converts: (kind, off, word), None for missing."""
    line = line.split("#", 1)[0]
    pos = 0
    n = len(line)

    def skip_ws(p):
        while p < n and line[p] in " \t\r\n\v\f":
            p += 1
        return p

    pos = skip_ws(pos)
    if pos >= n:
        return None, None, None
    end = pos
    while end < n and end - pos < 7 and line[end] not in " \t\r\n\v\f":
        end += 1
    kind = line[pos:end]
    pos = skip_ws(end)
    off, used = c_strtol(line[pos:])
    if off is None:
        return kind, None, None
    pos = skip_ws(pos + used)
    end = pos
    while end < n and end - pos < 511 and line[end] not in " \t\r\n\v\f":
        end += 1
    word = line[pos:end] if end > pos else None
    return kind, off, word


def md5_entry(entry, cs0, cs1):
    start = int.from_bytes(cs0[entry:entry + 4], "little")
    end = int.from_bytes(cs0[entry + 4:entry + 8], "little")
    length = (end - start + 1) & 0xFFFFFFFF
    off = (start - ROM_VA) & 0xFFFFFFFF
    if off + length > ROM_CS0_LEN + CS1_SIZE:
        fail("md5 entry 0x%X: 0x%08X-0x%08X is outside the ROM" % (entry, start, end))
    return start, end, rom_md5(cs0, cs1, off, length)


def rom_md5(cs0, cs1, off, length):
    h = hashlib.md5()
    a, b = off, off + length
    if a < ROM_CS0_LEN:
        h.update(cs0[a:min(b, ROM_CS0_LEN)])
    if b > ROM_CS0_LEN:
        h.update(cs1[max(a, ROM_CS0_LEN) - ROM_CS0_LEN:b - ROM_CS0_LEN])
    return h.digest()


def apply_patches(path, cs0, cs1, standin, model_build):
    md5s = []
    for lineno, line in enumerate(open(path, encoding="latin-1"), 1):
        kind, off, word = scan_line(line)
        if kind is None or off is None:
            continue
        if kind == "md5":
            if len(md5s) < 16:
                md5s.append(off)
            continue
        if word is None:
            continue
        if kind in ("cs0file", "cs1file"):
            img = cs0 if kind == "cs0file" else cs1
            src = os.path.join(ROOT, word) if model_build else os.path.join(standin, os.path.basename(word))
            if not os.path.exists(src):
                fail("%s:%d: %s not found%s" % (path, lineno, src, "" if model_build else
                     " (make standin builds the stand-ins; --model-build takes model/.build's)"))
            data = open(src, "rb").read()
            if off < 0 or off + len(data) > len(img):
                fail("%s:%d: rom patch out of range" % (path, lineno))
            img[off:off + len(data)] = data
            print("rom-patch: %s 0x%x <- %s (%d bytes)" % (kind, off, os.path.relpath(src, ROOT), len(data)))
            continue
        if kind not in ("cs0", "cs1"):
            continue
        img = cs0 if kind == "cs0" else cs1
        nb = len(word) // 2
        if off < 0 or off + nb > len(img):
            fail("%s:%d: rom patch out of range" % (path, lineno))
        for i in range(nb):
            pair = word[2 * i:2 * i + 2]
            v, used = c_strtol("0x" + pair)
            img[off + i] = v & 0xFF if v is not None else img[off + i]
        print("rom-patch: %s 0x%x <- %s" % (kind, off, word))
    for entry in md5s:
        start, end, digest = md5_entry(entry, cs0, cs1)
        cs0[entry + 8:entry + 24] = digest
        print("rom-patch: digest at CS0 0x%x for 0x%08x-0x%08x recomputed (%s)" % (entry, start, end, digest.hex()))


# ---------------------------------------------------------------- checks

def rom_read(cs0, cs1, va, length):
    """ROM virtual addresses as the bootstrap's page table maps them."""
    out = bytearray()
    x = va - ROM_VA
    end = x + length
    for lo, hi, img, base in ((0, 0xF00000, cs0, 0), (0xF00000, 0x1300000, cs1, 0xF00000),
                              (0x1300000, 0x1400000, cs0, 0x1300000 - 0xF00000)):
        a, b = max(x, lo), min(end, hi)
        if a < b:
            out += img[a - base:b - base]
    if len(out) != length:
        fail("ROM 0x%08X+0x%X is outside the mapped ROM" % (va, length))
    return bytes(out)


def check_table(cs0, cs1):
    ok = True
    for entry in TABLE:
        start = int.from_bytes(cs0[entry:entry + 4], "little")
        end = int.from_bytes(cs0[entry + 4:entry + 8], "little")
        if start == 0xFFFFFFFF and end == 0xFFFFFFFF:
            print("integrity entry 0x%X: erased, skipped (as the bootstrap does)" % entry)
            continue
        if end < start:
            fail("integrity entry 0x%X: end 0x%08X before start 0x%08X" % (entry, end, start))
        digest = hashlib.md5(rom_read(cs0, cs1, start, end - start + 1)).digest()
        stored = bytes(cs0[entry + 8:entry + 24])
        good = digest == stored
        ok &= good
        print("integrity entry 0x%X: 0x%08X-0x%08X %s (%s)" % (entry, start, end, "matches" if good else
              "DOES NOT MATCH: the bootstrap would stop", stored.hex()))
    return ok


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("mode", choices=("phoenix", "flat"))
    p.add_argument("inputs", nargs="+")
    p.add_argument("-o", "--outdir", default=".")
    p.add_argument("--patches", default=os.path.join(ROOT, "model", "rom-patches.txt"))
    p.add_argument("--standin", default=os.path.join(ROOT, "tools", "standin"))
    p.add_argument("--model-build", action="store_true")
    p.add_argument("--phone-data")
    p.add_argument("--no-patches", action="store_true")
    a = p.parse_args()

    if a.mode == "phoenix":
        cs0, cs1 = from_phoenix(a.inputs)
    else:
        if len(a.inputs) != 2:
            fail("flat takes CS0.bin and CS1.bin")
        cs0, cs1 = from_flat(*a.inputs)

    if a.phone_data:
        dump = open(a.phone_data, "rb").read(PHONE_DATA[1])
        if len(dump) < PHONE_DATA[1] or dump[0x128:0x12C] != b"KaeP":
            fail("%s: not a ROM dump from flash 0 (no \"KaeP\" at 0x128)" % a.phone_data)
        cs0[PHONE_DATA[0]:PHONE_DATA[1]] = dump[PHONE_DATA[0]:PHONE_DATA[1]]
        print("per-phone bytes 0x%X-0x%X from %s" % (PHONE_DATA[0], PHONE_DATA[1] - 1, a.phone_data))
    elif all(b == 0xFF for b in cs0[PHONE_DATA[0]:PHONE_DATA[1]]):
        print("note: the per-phone bytes at CS0 0x%X are erased (as in the flash files); --phone-data restores them"
              % PHONE_DATA[0])

    if not a.no_patches:
        apply_patches(a.patches, cs0, cs1, a.standin, a.model_build)
    ok = check_table(cs0, cs1)

    os.makedirs(a.outdir, exist_ok=True)
    for name, img in (("cs0.bin", cs0), ("cs1.bin", cs1)):
        out = os.path.join(a.outdir, name)
        open(out, "wb").write(img)
        print("wrote %s (%d bytes, md5 %s)" % (out, len(img), hashlib.md5(img).hexdigest()))
    if not ok and not a.no_patches:
        fail("an integrity digest does not match; the images would not boot")
    return 0


if __name__ == "__main__":
    sys.exit(main())
