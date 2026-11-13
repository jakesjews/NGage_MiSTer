#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The UPP_WD2 flash scrambler: the cellular software (NOS) is stored scrambled
in CS0 and the ASIC decodes it on array reads.

Each 16-bit word is decoded by itself. With C the stored word and A the byte
address of the word in CS0 (even), every plaintext bit is

    P[i] = C[i] ^ C[j(i)] ^ k(i) ^ parity(A & amask(i)) ^ (A[a]&A[b]) ^ (A[c]&A[d])

(TABLE below: one row a bit). The formulas were worked out by Andrea Bogazzi
for the N-Gage (NEM-4, firmware 4.03) and are in his core as
rtl/ngage_descramble.v (https://github.com/asturur/test_template_1, GPL-2.0).
They hold unchanged for the N-Gage QD: decoding CS0 0xA000-0x2ACFFF of the
RH-29 4.10 and 4.60 images gives the MD5 the bootstrap's integrity table
carries for 0x50009000 upward (entry 0x8F18), which no other bytes would.
Only address bits 1-21 enter; nothing is known about a word above 4 MB.

The scrambled area is named by the flash image itself: the words at CS0 0x174
(first byte) and 0x178 (the byte after the last), both 0xA000 / 0x2AD000 in
RH-29 4.10 and 4.60. Nothing in the firmware reads them; the ASIC's boot ROM
is taken to. window() reads them the way the core does (rtl/mem/ddram_flash.sv).

The same table is in rtl/mem/ddram_flash.sv (the core) and
model/hw/ngage_scramble.h (the model and the benches).

  nos_scramble.py --selftest            the fast path against the formulas
  nos_scramble.py --emit-c              the tables of model/hw/ngage_scramble.h
  nos_scramble.py --check-c FILE        FILE holds exactly those tables
  nos_scramble.py decode IN OUT         CS0 image with the area decoded
  nos_scramble.py encode IN OUT         the reverse (the header names the area)
Run with python3 -I.
"""
import sys

# bit: (constant, partner ciphertext bit or None, address mask, AND pairs)
TABLE = (
    (0, 8,    0x020102, ((4, 10), (8, 17))),
    (0, 9,    0x000000, ((3, 13), (9, 17))),
    (0, 6,    0x102628, ((9, 10), (5, 13))),
    (1, 8,    0x040008, ((11, 12), (5, 14))),
    (0, 1,    0x004C84, ((7, 11), (10, 14))),
    (1, 15,   0x240188, ((3, 8), (7, 18))),
    (1, 11,   0x041042, ((6, 12), (4, 15))),
    (1, 5,    0x010802, ((2, 5), (11, 16))),
    (1, 6,    0x202204, ((9, 13), (7, 16))),
    (0, 13,   0x088012, ((4, 15), (8, 16))),
    (0, 0,    0x002280, ((5, 11), (7, 13))),
    (1, None, 0x084980, ()),
    (1, 14,   0x008122, ((3, 6), (8, 15))),
    (1, 2,    0x001004, ((6, 11),)),
    (0, 10,   0x000006, ((4, 15), (6, 16))),
    (0, 3,    0x100444, ((6, 10), (12, 17))),
)
ADDR_MASK = 0x3FFFFE                # the address bits the formulas use
HEADER = (0x174, 0x178)             # CS0: first byte, byte after the last
RH29_WINDOW = (0xA000, 0x2AD000)    # what RH-29 4.10 and 4.60 carry there
CS0_SIZE = 16 << 20


def _parity(x):
    return bin(x).count("1") & 1


def pad(addr):
    """The address part of a word's decoding (the formulas, bit by bit)."""
    a = addr & ADDR_MASK
    out = 0
    for i, (k, _, amask, pairs) in enumerate(TABLE):
        b = k ^ _parity(a & amask)
        for j, m in pairs:
            b ^= (a >> j) & (a >> m) & 1
        out |= b << i
    return out


def mix(c):
    """The ciphertext part: bit i is C[i] ^ C[j(i)]."""
    out = 0
    for i, (_, j, _, _) in enumerate(TABLE):
        b = (c >> i) & 1
        if j is not None:
            b ^= (c >> j) & 1
        out |= b << i
    return out


def _invert():
    """Rows of the inverse of mix over GF(2): unmix(p) bit i = parity(p & row)."""
    # Gauss-Jordan on [M | I]: row i of M is the mask of ciphertext bits in P[i]
    aug = [((1 << i) | (0 if t[1] is None else 1 << t[1]), 1 << i) for i, t in enumerate(TABLE)]
    for col in range(16):
        piv = next(r for r in range(col, 16) if (aug[r][0] >> col) & 1)
        aug[col], aug[piv] = aug[piv], aug[col]
        for r in range(16):
            if r != col and (aug[r][0] >> col) & 1:
                aug[r] = (aug[r][0] ^ aug[col][0], aug[r][1] ^ aug[col][1])
    return tuple(a[1] for a in aug)


UNMIX_ROWS = _invert()


def unmix(p):
    out = 0
    for i, row in enumerate(UNMIX_ROWS):
        out |= _parity(p & row) << i
    return out


def decode_word(c, addr):
    return mix(c) ^ pad(addr)


def encode_word(p, addr):
    return unmix(p ^ pad(addr))


# ---- whole areas: byte tables for the two linear maps, the pads a 4 KB page
# at a time (within a page only the low twelve address bits change)

def _byte_tables(f):
    return [f(n) for n in range(256)], [f(n << 8) for n in range(256)]


_MIX = _byte_tables(mix)
_UNMIX = _byte_tables(unmix)
_PAGE = {}


def _page_pads(page):
    """pad() of the 2048 words of the 4 KB page at byte address page << 12."""
    if not _PAGE:
        _PAGE["base"] = [pad(o) ^ pad(0) for o in range(0, 4096, 2)]
        for k in range(12, 22):
            # what address bit k adds to a word's pad beyond its own constant:
            # the AND pairs that join it with a bit inside the page
            row = [0] * 2048
            for i, (_, _, _, pairs) in enumerate(TABLE):
                for j, m in pairs:
                    lo, hi = min(j, m), max(j, m)
                    if hi == k and lo < 12:
                        for n in range(2048):
                            row[n] ^= (((2 * n) >> lo) & 1) << i
            _PAGE[k] = row if any(row) else None
    high = pad(page << 12)
    rows = [_PAGE[k] for k in range(12, 22) if (page >> (k - 12)) & 1 and _PAGE[k]]
    out = [b ^ high for b in _PAGE["base"]]
    for row in rows:
        out = [x ^ y for x, y in zip(out, row)]
    return out


def _convert(data, addr, tables, decode):
    if addr & 1 or len(data) & 1:
        raise ValueError("the scrambler works on whole 16-bit words: 0x%X + %d" % (addr, len(data)))
    lo_t, hi_t = tables
    out = bytearray(len(data))
    pos = 0
    while pos < len(data):
        a = addr + pos
        n = min(len(data) - pos, 4096 - (a & 4095))
        pads = _page_pads((a >> 12) & 0x3FF)[(a & 4095) >> 1:]
        chunk = data[pos:pos + n]
        if decode:
            words = [lo_t[chunk[i]] ^ hi_t[chunk[i + 1]] ^ pads[i >> 1] for i in range(0, n, 2)]
        else:
            words = []
            for i in range(0, n, 2):
                p = (chunk[i] | chunk[i + 1] << 8) ^ pads[i >> 1]
                words.append(lo_t[p & 255] ^ hi_t[p >> 8])
        for i, w in enumerate(words):
            out[pos + 2 * i] = w & 255
            out[pos + 2 * i + 1] = w >> 8
        pos += n
    return bytes(out)


def decode(data, addr):
    """Stored bytes at CS0 byte address addr (even, even length) as the CPU reads them."""
    return _convert(data, addr, _MIX, True)


def encode(data, addr):
    """The reverse: what flash holds for the bytes the CPU is to read."""
    return _convert(data, addr, _UNMIX, False)


def window(cs0):
    """The scrambled area [first, end) the image's header names, or None.

    Taken only when both words are whole 4 KB pages inside the chip and in
    order, as the core does; an erased header (the benches' images) has none."""
    first = int.from_bytes(cs0[HEADER[0]:HEADER[0] + 4], "little")
    end = int.from_bytes(cs0[HEADER[1]:HEADER[1] + 4], "little")
    if first & 0xFFF or end & 0xFFF or not first < end <= CS0_SIZE:
        return None
    return first, end


def decode_image(cs0):
    """A CS0 image (bytearray, as stored) with its scrambled area decoded in place."""
    w = window(cs0)
    if w:
        cs0[w[0]:w[1]] = decode(bytes(cs0[w[0]:w[1]]), w[0])
    return w


def encode_image(cs0, w):
    if w:
        cs0[w[0]:w[1]] = encode(bytes(cs0[w[0]:w[1]]), w[0])


def selftest():
    import random
    rng = random.Random(1)
    for _ in range(20000):
        a = rng.randrange(0, 1 << 22) & ~1
        c = rng.randrange(0, 1 << 16)
        p = decode_word(c, a)
        assert encode_word(p, a) == c
        raw = bytes((c & 255, c >> 8))
        assert decode(raw, a) == bytes((p & 255, p >> 8))
        assert encode(decode(raw, a), a) == raw
    span = bytes(rng.randrange(256) for _ in range(3 * 4096 + 6))
    base = 0x1FF000 - 2
    dec = decode(span, base)
    for i in range(0, len(span), 2):
        p = decode_word(span[i] | span[i + 1] << 8, base + i)
        assert dec[i] == p & 255 and dec[i + 1] == p >> 8
    assert encode(dec, base) == span
    print("nos_scramble: the fast path agrees with the formulas, encode inverts decode")


def emit_c():
    def row(vals, fmt):
        return ", ".join(fmt % v for v in vals)
    return "\n".join((
        "/* Generated by tools/nos_scramble.py --emit-c: one entry a plaintext bit. */",
        "static const uint8_t ngage_scr_const[16] = { %s };" % row([t[0] for t in TABLE], "%d"),
        "static const uint16_t ngage_scr_cmask[16] = {\n    %s\n};" %
        row([(1 << i) | (0 if t[1] is None else 1 << t[1]) for i, t in enumerate(TABLE)], "0x%04X"),
        "static const uint32_t ngage_scr_amask[16] = {\n    %s\n};" % row([t[2] for t in TABLE], "0x%06X"),
        "static const uint8_t ngage_scr_pairs[16][4] = {\n    %s\n};" % ", ".join(
            "{ %s }" % row([x for pair in (t[3] + ((0, 0), (0, 0)))[:2] for x in pair], "%d") for t in TABLE),
        "/* Rows of the inverse of the ciphertext part (for encoding). */",
        "static const uint16_t ngage_scr_unmix[16] = {\n    %s\n};" % row(UNMIX_ROWS, "0x%04X"),
    )) + "\n"


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest":
        return selftest()
    if len(sys.argv) == 2 and sys.argv[1] == "--emit-c":
        return sys.stdout.write(emit_c())
    if len(sys.argv) == 3 and sys.argv[1] == "--check-c":
        if emit_c() not in open(sys.argv[2]).read():
            sys.exit("nos_scramble: %s does not hold the tables of --emit-c" % sys.argv[2])
        print("%s has the reference's tables" % sys.argv[2])
        return
    if len(sys.argv) == 4 and sys.argv[1] in ("decode", "encode"):
        cs0 = bytearray(open(sys.argv[2], "rb").read())
        w = window(cs0)
        if not w:
            sys.exit("nos_scramble: %s names no scrambled area at 0x174" % sys.argv[2])
        cs0[w[0]:w[1]] = (decode if sys.argv[1] == "decode" else encode)(bytes(cs0[w[0]:w[1]]), w[0])
        open(sys.argv[3], "wb").write(cs0)
        print("%sd CS0 0x%X-0x%X" % (sys.argv[1], w[0], w[1] - 1))
        return
    sys.exit(__doc__)


if __name__ == "__main__":
    main()
