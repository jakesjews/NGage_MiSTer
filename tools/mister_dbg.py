#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10"]
# ///
"""Decode the core's debug overlay from a MiSTer screenshot.

With the OSD option "Debug overlay" on, NGage.sv draws the CPU's committed
PC (32 bits, bit 31 leftmost) in panel rows 0-2 at x 16..47 and eight status
bits in rows 4-6 at x 16..23: cpu_reset, irq, fiq, bus activity, CS0 loaded,
CS1 loaded, CS1 save present, memory-test master. White = 1. Rows 8, 12, 16,
20, 24, 28, 32 and 36 (3 lines each, x 16..47) hold 32-bit words: interrupt
sources of bank 0, the IRQ-plane and FIQ-plane enables of bank 0, the three
words the kernel writes to on-chip RAM 0x0C0047F0/F4/F8 on Kern::Fault
(category text, then the reason), the hardware trace's first trigger PC
(rtl/mister/dbg_trace.sv) and its counts {dumps[7:0], triggers[7:0], 15'b0,
dumping}, then the wall clock {valid, 10'b0, hour[4:0], 2'b0, min[5:0],
2'b0, sec[5:0]} (rows 40-42) and its date year << 16 | month << 8 | day
(rows 44-46).

usage: tools/mister_dbg.py SHOT.png [SHOT.png ...]
The screenshot must be the whole 176x208 picture at an integer scale
(direct_video=0 for the core); the scale is taken from the image width.
"""
import sys

from PIL import Image

NAMES = ["cpu_reset", "irq", "fiq", "bus", "cs0", "cs1", "save", "memtest"]


def bit(im, scale, x, y):
    r, g, b = im.getpixel((x * scale + scale // 2, y * scale + scale // 2))[:3]
    return 1 if r + g + b > 384 else 0


def decode(path):
    im = Image.open(path).convert("RGB")
    scale = im.width // 176
    if scale < 1 or im.width != 176 * scale or im.height != 208 * scale:
        return "%s: not a 176x208 integer-scaled capture (%dx%d)" % (path, im.width, im.height)
    pc = 0
    for i in range(32):
        pc = (pc << 1) | bit(im, scale, 16 + i, 1)
    bits = [bit(im, scale, 16 + i, 5) for i in range(8)]
    flags = " ".join("%s=%d" % (n, v) for n, v in zip(NAMES, bits))
    words = []
    for row in (9, 13, 17, 21, 25, 29, 33, 37, 41, 45):
        w = 0
        for i in range(32):
            w = (w << 1) | bit(im, scale, 16 + i, row)
        words.append(w)
    cat = (words[3].to_bytes(4, "little") + words[4].to_bytes(4, "little")).rstrip(b"\0")
    cat = cat.decode("latin-1") if cat and all(32 <= c < 127 for c in cat) else ""
    w8, w9 = words[8], words[9]
    return "%s: pc=%08x %s src0=%08x en_irq0=%08x en_fiq0=%08x fault=%08x %08x %08x %r trace: pc=%08x dumps=%d triggers=%d dumping=%d rtc: valid=%d %02d:%02d:%02d %04d-%02d-%02d" % (
        path, pc, flags, words[0], words[1], words[2], words[3], words[4], words[5], cat,
        words[6], words[7] >> 24, (words[7] >> 16) & 0xFF, words[7] & 1,
        w8 >> 31, (w8 >> 16) & 0x1F, (w8 >> 8) & 0x3F, w8 & 0x3F, w9 >> 16, (w9 >> 8) & 0xFF, w9 & 0xFF)


if __name__ == "__main__":
    for p in sys.argv[1:]:
        print(decode(p))
