#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10"]
# ///
"""Decode the core's debug overlay from a MiSTer screenshot.

With the OSD option "Debug overlay" on, NGage.sv draws the CPU's committed
PC (32 bits, bit 31 leftmost) in panel rows 0-2 at x 16..47 and eight status
bits in rows 4-6 at x 16..23: cpu_reset, irq, fiq, bus activity, CS0 loaded,
CS1 loaded, CS1 save present, memory-test master. White = 1.

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
    return "%s: pc=%08x %s" % (path, pc, flags)


if __name__ == "__main__":
    for p in sys.argv[1:]:
        print(decode(p))
