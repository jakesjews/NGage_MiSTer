#!/usr/bin/env python3
"""Build the N-Gage QD MiSTer core's flash images (cs0.bin, cs1.bin) from a
user's own RH-29 firmware.

Input, either:
  phoenix  the Phoenix flash files: the MCU file (RH2941.0C1) and a language
           pack (RH2941.021, or another of 4.10's), in that order, converted as
           tools/fls2bin.py does (CS0 at 0x00000000, 16 MB; CS1 at 0x02000000,
           8 MB; unwritten bytes 0xFF) and placed as the core's loader places
           them (rtl/mister/phoenix_load.sv): the pack's areas (PACK_AREAS)
           hold what the pack writes, everything else what the MCU file writes
  flat     flat CS0 (16 MB) and CS1 (8 MB) images as flash stores them

Part of CS0 is scrambled in flash (the cellular software; the image's header
at 0x174 names the area, 0xA000-0x2ACFFF in RH-29) and the phone decodes it on
every read (tools/nos_scramble.py). The patches and the integrity check below
work on the bytes the phone reads; the images are written as flash stores
them, which is what the core loads. --plain writes CS0 decoded instead, for
reading in a disassembler: the core does not run such an image.

Then the firmware patches in firmware-patches/rom-patches.txt are applied
exactly as the reference model's model/hw/ngage_patch.c applies them at load:
  cs0|cs1 <offset> <hex bytes>        bytes as the phone reads them
  cs0file|cs1file <offset> <path>     a file's contents: the NOS stand-in
                                      binaries, at the path the list gives
                                      (firmware-patches/bin) unless --standin
                                      or --model-build names another directory
  md5 <CS0 offset of an entry>        after all byte patches: recompute the
                                      bootstrap's integrity digest of that
                                      table entry {start, end, digest[16]}
The md5 lines and the integrity check read ROM virtual addresses as the
bootstrap's page table maps them (entries at CS0 0x744, as the model's
patcher and sim/cpu/boot/prep.py do): CS0 to 0x50EFFFFF, CS1 0x000000-0x3FFFFF
at 0x50F00000-0x512FFFFF, CS0 0xF00000-0xFEFFFF at 0x51300000-0x513EFFFF (the
language pack's ROM, entry 0x8F00, spans the end of CS1 and the top of CS0).
The integrity table (CS0 0x8F00) is checked the way the bootstrap does
(routine 0x3238): every entry that is not erased must hold the MD5 of its ROM
virtual addresses.

The flash files leave out 56 per-phone bytes at CS0 0x12C (after the marker
"KaeP"); --phone-data copies them from a ROM dump that starts at flash 0
(SDumper's ROM-0x50000000-*.dmp), as the model's image has them. Whether the
firmware needs them is not known.

usage:
  mkimage.py phoenix MCU.C1 LANG.S5 [-o DIR] [options]
  mkimage.py flat CS0.bin CS1.bin [-o DIR] [options]
options:
  -o DIR             where cs0.bin and cs1.bin go (default .)
  --patches FILE     the patch list (default firmware-patches/rom-patches.txt)
  --standin DIR      take the stand-in binaries from DIR, by file name
  --model-build      the same with the model's own build (model/.build)
  --phone-data DUMP  restore the per-phone bytes from a ROM dump
  --no-patches       write the images unpatched (the table check then reports
                     the digests the firmware carries)
  --plain            write CS0 with its scrambled area decoded (not for the core)
  --force            go on with Phoenix files that are not the RH-29 4.10 pair
                     (the inputs are checked by SHA-256; see KNOWN_INPUTS)

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
TABLE = (0x8F00, 0x8F18)          # the entries the bootstrap checks (0x359C, 0x35A0)
PHONE_DATA = (0x12C, 0x164)       # the 56 per-phone bytes: [start, end)


def fail(msg):
    sys.stderr.write("mkimage: %s\n" % msg)
    sys.exit(1)


# ---------------------------------------------------------------- input

def load_tool(name):
    sys.dont_write_bytecode = True      # no __pycache__ next to the tools
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# The language pack's areas, [start, end) in the files' addresses: the first
# 64 KB of CS0 (which every pack writes again, with its own entry in the
# integrity table), its ROM at the top of CS0 and the top of CS1's firmware
# half. The core's loader takes these bytes from the pack and all others from
# the MCU file, whichever arrives first (rtl/mister/phoenix_load.sv).
PACK_AREAS = ((0x00000000, 0x00010000), (0x00F00000, 0x01000000), (0x02330000, 0x02400000))


def pack_area(addr):
    return any(a <= addr < b for a, b in PACK_AREAS)


# The Phoenix flash files the core is built against (RH-29 software 4.10, the
# retail firmware): the SHA-256 of the whole file, and what it is. Anything
# else fails unless --force. Another of 4.10's language packs is fine with
# --force (the patches are all in the MCU file's range); another version's
# image loads but its patch offsets differ, and the phone does not boot.
KNOWN_INPUTS = {
    "3ce529d6fbcd6db1f4290fabe8b70c62242a23444c4fa74caec42657d12ab4a0": "RH2941.0C1 (RH-29 4.10, the MCU file)",
    "657c2d1bafbad6797732c86892999a9e201e10961ee8c1801b0b6cc73bb41fa5": "RH2941.021 (RH-29 4.10, the language pack of the Romania variant)",
}


def check_input(path, force):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    digest = h.hexdigest()
    if digest in KNOWN_INPUTS:
        print("%s: %s" % (path, KNOWN_INPUTS[digest]))
        return
    msg = ("%s is not one of the RH-29 4.10 Phoenix files (RH2941.0C1 and RH2941.021; sha256 %s). "
           "The core is built against 4.10: another of its language packs works, another version "
           "does not boot. --force goes on anyway." % (path, digest))
    if force:
        sys.stderr.write("mkimage: warning: %s\n" % msg)
    else:
        fail(msg)


def from_phoenix(files, force=False):
    fls = load_tool("fls2bin")
    cs0 = bytearray(b"\xFF" * CS0_SIZE)
    cs1 = bytearray(b"\xFF" * CS1_SIZE)
    if len(files) != 2:
        fail("phoenix takes the MCU file and a language pack, in that order")
    for pack, path in enumerate(files):
        check_input(path, force)
        _, records = fls.load(path)
        placed = left = 0
        for r in records:
            if "addr" not in r or r["type"] == 0x2E:
                continue
            a, d = r["addr"], r["data"]
            if 0 <= a and a + len(d) <= CS0_SIZE:
                img, base = cs0, 0
            elif CS1_BASE <= a and a + len(d) <= CS1_BASE + CS1_SIZE:
                img, base = cs1, CS1_BASE
            else:
                fail("%s: a block at 0x%08X (%d bytes) is outside CS0 and CS1" % (path, a, len(d)))
            if r.get("h_ok") is False:
                fail("%s: block at 0x%08X: header checksum mismatch" % (path, a))
            for i, b in enumerate(d):           # byte by byte, as the loader decides
                if pack_area(a + i) == bool(pack):
                    img[a + i - base] = b
                    placed += 1
                else:
                    left += 1
        print("%s: %d bytes of flash data%s" % (path, placed,
              " (%d more belong to the %s and are left to it)" % (left, "MCU file" if pack else "language pack")
              if left else ""))
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
    return start, end, hashlib.md5(rom_read(cs0, cs1, start, length)).digest()


def apply_patches(path, cs0, cs1, standin):
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
            src = os.path.join(standin, os.path.basename(word)) if standin else os.path.join(ROOT, word)
            if not os.path.exists(src):
                fail("%s:%d: %s not found (make standin builds the stand-ins, model/build.sh the model's)"
                     % (path, lineno, src))
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
    for va_off, img, off, n in ((0x0000000, cs0, 0x000000, 0xF00000),
                                (0x0F00000, cs1, 0x000000, 0x400000),
                                (0x1300000, cs0, 0xF00000, 0x0F0000)):
        a, b = max(x, va_off), min(end, va_off + n)
        if a < b:
            out += img[a - va_off + off:b - va_off + off]
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
    p.add_argument("--patches", default=os.path.join(ROOT, "firmware-patches", "rom-patches.txt"))
    p.add_argument("--standin")
    p.add_argument("--model-build", action="store_true")
    p.add_argument("--phone-data")
    p.add_argument("--no-patches", action="store_true")
    p.add_argument("--plain", action="store_true", help="write CS0 with its scrambled area decoded")
    p.add_argument("--force", action="store_true", help="go on with Phoenix files that are not the 4.10 pair")
    a = p.parse_args()

    if a.mode == "phoenix":
        cs0, cs1 = from_phoenix(a.inputs, a.force)
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

    # From here on CS0 is what the phone reads: the scrambled area decoded.
    scr = load_tool("nos_scramble")
    area = scr.decode_image(cs0)
    if area:
        print("CS0 0x%X-0x%X is scrambled in flash (header 0x%X): patched and checked as the phone reads it"
              % (area[0], area[1] - 1, scr.HEADER[0]))
        if area != scr.RH29_WINDOW and not a.no_patches:
            sys.stderr.write("mkimage: warning: the core's patch ROM is made for the area 0x%X-0x%X\n"
                             % (scr.RH29_WINDOW[0], scr.RH29_WINDOW[1] - 1))
    else:
        print("note: the image names no scrambled area at CS0 0x%X" % scr.HEADER[0])

    if not a.no_patches:
        standin = os.path.join(ROOT, "model", ".build") if a.model_build else a.standin
        apply_patches(a.patches, cs0, cs1, standin)
    ok = check_table(cs0, cs1)

    if a.plain:
        print("--plain: CS0 is written decoded; the core and the model expect it as flash stores it")
    else:
        scr.encode_image(cs0, area)
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
