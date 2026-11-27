#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The N-Gage QD's permanent memory (PMM) as a phone has it before its first
start: the image the core mounts as boot2.vhd.

PMM is the top 64 KiB of the CS0 flash (0xFF0000-0xFFFFFF), eight 8 KiB
sectors, kept by the cellular software (NOS). One record in it decides the
first start: group 212, record 3, the "AUX startup reason" (2 bytes). EStart
asks for it through HelperDrv ("auxstart") when the C: drive does not mount,
and formats C: only on 105. NOS answers 100 when the record is missing, C:
then stays erased and the phone stops at the Nokia logo. With the record at
105 the firmware formats C: and writes the record again as 100 itself.

So the image holds the sector marks NOS writes to an erased PMM and that one
record; NOS adds its other records, with their defaults, at the first start.

The record also erases a C: that is in use: EStart asks at every start and
formats on 105 whatever C: holds. To go on with an existing C: under a new
PMM, start from an erased one (--erased, every byte FF): NOS fills it in,
without the record, and C: stays as it is.

The layout was read from what RH-29 4.10's NOS wrote to an erased PMM on the
core (2026-11-26); it is not from Nokia documentation:

  a sector in use     F0 F0 F8 FF 02 00 "PMMCAT" 01 00 00 00, a 32-bit word
                      (0 in the first sector, 0x00020000 in the seventh),
                      FF FF FF FF 02 00, then records from offset 0x20
  a free sector       F0 F0 FE, and 01 00 00 00 at offset 0x0C
  a record            F4, group, record (16 bits), 55 FF FF FF, length (16
                      bits), the offset of the next record in the sector (16
                      bits), then the data. Numbers are little-endian. When
                      a record is written again the old one's first byte is
                      programmed down to A4.

  mkpmm.py OUT            write the image (65536 bytes)
  mkpmm.py --erased OUT   write an erased PMM, for a C: that is to be kept
  mkpmm.py --check FILE   FILE is exactly the image this tool writes
  mkpmm.py --list FILE    the records in use in a PMM image
"""
import struct
import sys

USAGE = "mkpmm.py [--erased] OUT | mkpmm.py --check FILE | mkpmm.py --list FILE"
SECTOR = 0x2000
SECTORS = 8
RECORDS_AT = 0x20
AUX_GROUP, AUX_RECORD, AUX_FORMAT = 212, 3, 105


def catalogue(word):
    return (b"\xF0\xF0\xF8\xFF\x02\x00PMMCAT\x01\x00\x00\x00" + struct.pack("<I", word)
            + b"\xFF\xFF\xFF\xFF\x02\x00").ljust(RECORDS_AT, b"\xFF")


def free_sector():
    return b"\xF0\xF0\xFE".ljust(0x0C, b"\xFF") + b"\x01\x00\x00\x00"


def record(at, group, number, data):
    return (bytes([0xF4, group]) + struct.pack("<H", number) + b"\x55\xFF\xFF\xFF"
            + struct.pack("<HH", len(data), at + 12 + len(data)) + data)


def image():
    img = bytearray(b"\xFF" * (SECTOR * SECTORS))
    for s in range(SECTORS):
        head = catalogue(0) if s == 0 else catalogue(0x00020000) if s == 6 else free_sector()
        img[s * SECTOR:s * SECTOR + len(head)] = head
    rec = record(RECORDS_AT, AUX_GROUP, AUX_RECORD, struct.pack("<H", AUX_FORMAT))
    img[RECORDS_AT:RECORDS_AT + len(rec)] = rec
    return bytes(img)


def records(img):
    """(sector, offset, group, number, data) of every record in use, in flash order."""
    for s in range(0, len(img), SECTOR):
        sec = img[s:s + SECTOR]
        if sec[6:12] != b"PMMCAT":
            continue
        at = RECORDS_AT
        while at + 12 <= SECTOR and sec[at] != 0xFF:
            number, = struct.unpack_from("<H", sec, at + 2)
            length, nxt = struct.unpack_from("<HH", sec, at + 8)
            if sec[at] == 0xF4:
                yield s, at, sec[at + 1], number, sec[at + 12:at + 12 + length]
            if nxt <= at:
                break
            at = nxt


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--list":
        img = open(sys.argv[2], "rb").read()
        if len(img) != SECTOR * SECTORS:
            sys.exit("mkpmm: a PMM image is %d bytes" % (SECTOR * SECTORS))
        for s, at, group, number, data in sorted(records(img), key=lambda r: (r[2], r[3], r[0], r[1])):
            print("group %3d record %3d  %2d bytes at 0x%04X  %s" % (group, number, len(data), s + at, data.hex()))
        return
    if len(sys.argv) == 3 and sys.argv[1] == "--check":
        if open(sys.argv[2], "rb").read() != image():
            sys.exit("mkpmm: %s is not the image this tool writes" % sys.argv[2])
        return
    erased = len(sys.argv) == 3 and sys.argv[1] == "--erased"
    if len(sys.argv) != 2 + erased or sys.argv[-1].startswith("-"):
        sys.exit("usage: " + USAGE)
    with open(sys.argv[-1], "wb") as f:
        f.write(b"\xFF" * (SECTOR * SECTORS) if erased else image())


if __name__ == "__main__":
    main()
