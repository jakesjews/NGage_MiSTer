#!/usr/bin/env python3
"""Convert Nokia DCT4 / UPP_WD2 Phoenix flash files into a flat NOR image.

A DCT4 flash file (MCU "*.C1", PPM, content) starts with type byte 0xA2,
a big-endian token-section length, the token section, then a list of
records. Record 0x14 is a flash block:

    0x14, address u32 BE, data checksum u8, length u24 BE, header checksum u8, data

Record 0x21 is the same with a 16-byte header (address at +7, data checksum
+11, length u24 at +12, header checksum +15). 0x20 is Bluetooth firmware
(not flash mapped), 0x25/0x26 are short raw records seen in N-Gage files,
0x2E is a mass-memory block (sector address << 9). Checksums are the 8-bit
sum of the covered bytes XOR 0xFF. Format as implemented by g3gg0's TriX
(src/fmt_phoenix.c) and Florin9doi's romdump (parse.c).

usage:
  fls2bin.py map  FILE [FILE ...]                 list tokens and block ranges
  fls2bin.py flat --base ADDR --size BYTES -o OUT FILE [FILE ...]
                                                  write a flat image of
                                                  [ADDR, ADDR+BYTES), unwritten
                                                  bytes 0xFF (erased NOR)

Run with python3 -I. Files are read as data only.
"""
import argparse
import sys

TOKEN_NAMES = {
    0xC2: "platform",
    0xC3: "algorithm",
    0xC8: "erase-areas",
    0xD3: "signature",
    0xD4: "supported-ids",
    0xE1: "tiku",
    0xF3: "nested",
    0xF7: "last",
}


def chk8(data):
    return (sum(data) & 0xFF) ^ 0xFF


def parse_tokens(buf, start, length):
    """Return a list of (id, bytes) from the token section at buf[start:start+length]."""
    out = []
    pos = start
    end = start + length
    count = int.from_bytes(buf[pos:pos + 4], "big")
    pos += 4
    while pos + 1 < end and len(out) < count:
        tid = buf[pos]
        pos += 1
        if tid == 0xF3:
            tlen = int.from_bytes(buf[pos:pos + 2], "big")
            pos += 2
        else:
            tlen = buf[pos]
            pos += 1
            if tlen == 0:
                tlen = buf[pos]
                pos += 1
        if pos + tlen > end:
            raise ValueError("token 0x%02X runs past the token section" % tid)
        out.append((tid, bytes(buf[pos:pos + tlen])))
        pos += tlen
    if len(out) != count:
        raise ValueError("token section holds %d tokens, header says %d" % (len(out), count))
    return out


def parse_records(buf, pos):
    """Yield dicts describing each record from pos to the end of the file."""
    n = len(buf)
    while pos < n:
        rtype = buf[pos]
        if rtype == 0x14:
            hdr = buf[pos:pos + 10]
            if len(hdr) < 10:
                raise ValueError("truncated 0x14 header at 0x%X" % pos)
            addr = int.from_bytes(hdr[1:5], "big")
            d_chk = hdr[5]
            length = int.from_bytes(hdr[6:9], "big")
            h_chk = hdr[9]
            data = bytes(buf[pos + 10:pos + 10 + length])
            if len(data) != length:
                raise ValueError("truncated 0x14 data at 0x%X" % pos)
            yield {
                "type": 0x14, "file_pos": pos, "addr": addr, "data": data,
                "h_ok": chk8(hdr[1:9]) == h_chk,
                "d_ok": chk8(data) == d_chk,
                "d_fix": (d_chk - chk8(data)) & 0xFF,
            }
            pos += 10 + length
        elif rtype == 0x21:
            hdr = buf[pos:pos + 16]
            addr = int.from_bytes(hdr[7:11], "big")
            d_chk = hdr[11]
            length = int.from_bytes(hdr[12:15], "big")
            data = bytes(buf[pos + 16:pos + 16 + length])
            yield {
                "type": 0x21, "file_pos": pos, "addr": addr, "data": data,
                "h_ok": None, "d_ok": chk8(data) == d_chk, "d_fix": 0,
            }
            pos += 16 + length
        elif rtype == 0x2E:
            hdr = buf[pos:pos + 10]
            dev = int.from_bytes(hdr[1:3], "big")
            addr = int.from_bytes(hdr[3:5], "big") << 9
            length = int.from_bytes(hdr[6:9], "big")
            data = bytes(buf[pos + 10:pos + 10 + length])
            yield {
                "type": 0x2E, "file_pos": pos, "addr": addr, "dev": dev, "data": data,
                "h_ok": chk8(hdr[1:9]) == hdr[9], "d_ok": chk8(data) == hdr[5], "d_fix": 0,
            }
            pos += 10 + length
        elif rtype == 0x20:
            length = int.from_bytes(buf[pos + 3:pos + 5], "big")
            yield {"type": 0x20, "file_pos": pos, "data": bytes(buf[pos + 6:pos + 6 + length])}
            pos += 6 + length
        elif rtype == 0x25:
            length = 2 + buf[pos + 1]
            yield {"type": 0x25, "file_pos": pos, "data": bytes(buf[pos:pos + length])}
            pos += length
        elif rtype == 0x26:
            yield {"type": 0x26, "file_pos": pos, "data": bytes(buf[pos:pos + 10])}
            pos += 10
        else:
            raise ValueError("unknown record type 0x%02X at file offset 0x%X" % (rtype, pos))


def load(path):
    buf = open(path, "rb").read()
    if not buf or buf[0] != 0xA2:
        raise ValueError("%s: not a DCT4 flash file (first byte 0x%02X, want 0xA2)" % (path, buf[0] if buf else 0))
    tlen = int.from_bytes(buf[1:5], "big")
    tokens = parse_tokens(buf, 5, tlen)
    records = list(parse_records(buf, 5 + tlen))
    return tokens, records


def merge_ranges(records):
    spans = sorted((r["addr"], r["addr"] + len(r["data"])) for r in records if "addr" in r)
    merged = []
    for a, b in spans:
        if merged and a <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    return merged


def cmd_map(args):
    for path in args.files:
        tokens, records = load(path)
        print("== %s" % path)
        for tid, data in tokens:
            name = TOKEN_NAMES.get(tid, "0x%02X" % tid)
            if tid == 0xC8:
                words = [int.from_bytes(data[i:i + 4], "big") for i in range(0, len(data) - 3, 4)]
                pairs = ", ".join("0x%08X-0x%08X" % (words[i], words[i + 1]) for i in range(0, len(words) - 1, 2))
                print("  token %-13s %s" % (name, pairs))
            elif tid in (0xC2, 0xC3):
                print("  token %-13s %r" % (name, data.rstrip(b"\0").decode("latin-1")))
            else:
                print("  token %-13s %s" % (name, data[:32].hex() + ("..." if len(data) > 32 else "")))
        kinds = {}
        bad = 0
        for r in records:
            kinds[r["type"]] = kinds.get(r["type"], 0) + 1
            if r.get("h_ok") is False or (r.get("d_ok") is False and r.get("d_fix") not in (0, 1)):
                bad += 1
        print("  records: " + ", ".join("0x%02X x%d" % (k, v) for k, v in sorted(kinds.items())))
        print("  checksum mismatches: %d" % bad)
        for a, b in merge_ranges(records):
            print("  flash 0x%08X-0x%08X  (%d bytes)" % (a, b - 1, b - a))


def cmd_flat(args):
    base = int(args.base, 0)
    size = int(args.size, 0)
    img = bytearray(b"\xFF" * size)
    written = 0
    outside = 0
    for path in args.files:
        _, records = load(path)
        for r in records:
            if "addr" not in r or r["type"] == 0x2E:
                continue
            a = r["addr"] - base
            d = r["data"]
            if a < 0 or a + len(d) > size:
                outside += len(d)
                continue
            img[a:a + len(d)] = d
            written += len(d)
    open(args.output, "wb").write(img)
    print("wrote %s: %d bytes of data placed, %d bytes outside the window" % (args.output, written, outside))
    return 0 if outside == 0 else 2


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("map")
    m.add_argument("files", nargs="+")
    f = sub.add_parser("flat")
    f.add_argument("--base", required=True)
    f.add_argument("--size", required=True)
    f.add_argument("-o", "--output", required=True)
    f.add_argument("files", nargs="+")
    args = p.parse_args()
    return cmd_map(args) if args.cmd == "map" else cmd_flat(args)


if __name__ == "__main__":
    sys.exit(main())
