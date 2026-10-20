#!/usr/bin/env python3
"""Make N-Gage game-card images from a card dump, for the reference model and
for the MiSTer core.

Input, either:
  aaru  an Aaru dump of the card (.aaruf, or the .zip it came in): sectors
        plus the card's CID, CSD and OCR as Aaru read them
  raw   a raw sector image (.img) with --cid and --csd given as hex

Output, for OUT (e.g. model/.out/cards/sonicn):
  OUT.img, OUT.img.cid, OUT.img.csd
        the model's card (NGAGE_MMC=OUT.img): the sectors, and CID and CSD as
        32 hex digits each, card order, byte 15 = CRC7 << 1 | 1 (the form
        model/hw/ngage_mmc.c reads)
  OUT.mmc
        the core's card image (OSD "Mount MMC card"): the sectors followed by
        the 512-byte sidecar that rtl/board/mmc_card.sv reads from the last
        block of the image:
          0   "NGAGEMMC"
          8   version, 1
          16  CID, 16 bytes, card order (the core recomputes byte 15)
          32  CSD, the same
          48  OCR, 4 bytes, most significant first

The CID and CSD are the card's own, as copy protection may check the CID
(research/peripherals/MMC.md section 4). The CRC7 of each (x^7 + x^3 + 1
over bytes 0-14) is computed here; Aaru stores the registers as Linux reports
them, with byte 15 zero. Aaru's OCR is the voltage window Linux negotiated,
not the card's register, so the OCR written is --ocr (default 0x00FF8000,
2.7-3.6 V, the core's and the model's default).

The Aaru reader covers what these dumps use: AaruFormat 1.x, index INDX,
data blocks DBLK (raw or LZMA), the user-data deduplication table DDT* and
the media-tag blocks 55, 56, 57 (MMC CID, CSD, OCR). Every stored block
CRC64 is checked, and the sectors against the image's own MD5/SHA-1/SHA-256
(block CKSM) or, without one, the CICM sidecar's content checksums. The dump
is read as data only; nothing in it is run.

Usage: tools/mkcard.py [--cid HEX --csd HEX] [--ocr HEX] INPUT OUT
Run with python3 -I.
"""
import argparse
import hashlib
import lzma
import os
import re
import struct
import sys
import zipfile

SECTOR = 512
SIDECAR_MAGIC = b'NGAGEMMC'
SIDECAR_VERSION = 1

# AaruFormat block identifiers (little-endian ASCII) and data types
ID_DBLK = b'DBLK'
ID_DDT = b'DDT*'
ID_INDX = b'INDX'
ID_CKSM = b'CKSM'
DT_USERDATA = 1
DT_MMC_CID = 55
DT_MMC_CSD = 56
DT_MMC_OCR = 57
COMP_NONE = 0
COMP_LZMA = 1


def crc7(data):
    """MMC CRC7, x^7 + x^3 + 1, MSB first."""
    crc = 0
    for byte in data:
        for bit in range(7, -1, -1):
            fb = ((crc >> 6) & 1) ^ ((byte >> bit) & 1)
            crc = (crc << 1) & 0x7F
            if fb:
                crc ^= 0x09
    return crc


def with_crc(reg):
    reg = bytes(reg[:15])
    return reg + bytes([(crc7(reg) << 1) | 1])


_CRC64_TABLE = None


def crc64_ecma(data):
    """CRC-64/XZ (ECMA-182, reflected). Aaru stores it byte-swapped (the
    digest's bytes, most significant first, read as a little-endian word):
    compare with aaru_crc()."""
    global _CRC64_TABLE
    if _CRC64_TABLE is None:
        poly = 0xC96C5795D7870F42
        t = []
        for i in range(256):
            c = i
            for _ in range(8):
                c = (c >> 1) ^ poly if c & 1 else c >> 1
            t.append(c)
        _CRC64_TABLE = t
    t = _CRC64_TABLE
    crc = 0xFFFFFFFFFFFFFFFF
    for b in data:
        crc = t[(crc ^ b) & 0xFF] ^ (crc >> 8)
    return crc ^ 0xFFFFFFFFFFFFFFFF


def aaru_crc(data):
    return int.from_bytes(crc64_ecma(data).to_bytes(8, 'big'), 'little')


def lzma_raw(props, stream, length):
    """Aaru's LZMA: 5 property bytes, then a raw LZMA1 stream."""
    p = props[0]
    lc, lp, pb = p % 9, (p // 9) % 5, p // 45
    dict_size = struct.unpack('<I', props[1:5])[0]
    dec = lzma.LZMADecompressor(format=lzma.FORMAT_RAW, filters=[{
        'id': lzma.FILTER_LZMA1, 'dict_size': dict_size, 'lc': lc, 'lp': lp, 'pb': pb}])
    out = dec.decompress(stream, max_length=length)
    if len(out) != length:
        raise ValueError('LZMA block decodes to %d bytes, expected %d' % (len(out), length))
    return out


class Aaru:
    """A minimal AaruFormat 1.x reader for block-media (MMC) dumps."""

    def __init__(self, data):
        self.f = data
        if data[:8] not in (b'AARUFRMT', b'DICMFRMT'):
            raise ValueError('not an AaruFormat image')
        self.major = data[72]
        if self.major != 1:
            raise ValueError('AaruFormat version %d not supported' % self.major)
        index_off = struct.unpack_from('<Q', data, 80)[0]
        if data[index_off:index_off + 4] != ID_INDX:
            raise ValueError('no INDX index at 0x%x' % index_off)
        n = struct.unpack_from('<H', data, index_off + 4)[0]
        self.index = []
        p = index_off + 14
        for _ in range(n):
            bt, dt, off = struct.unpack_from('<4sHQ', data, p)
            self.index.append((bt, dt, off))
            p += 14
        self._blocks = {}

    def payload(self, p, comp, clen, length, ccrc, crc, what):
        """A block's data, checked against its CRC64s (stored ones only:
        Aaru leaves some at 0): ccrc covers the stored bytes (for LZMA the
        five property bytes and the stream), crc the decoded data."""
        stored = self.f[p:p + (length if comp == COMP_NONE else clen)]
        if comp == COMP_NONE:
            data = stored
        elif comp == COMP_LZMA:
            if ccrc and aaru_crc(stored) != ccrc:
                raise ValueError('CRC64 mismatch in the stored bytes of %s' % what)
            data = lzma_raw(stored[:5], stored[5:], length)
        else:
            raise ValueError('compression %d not supported (%s)' % (comp, what))
        if crc and aaru_crc(data) != crc:
            raise ValueError('CRC64 mismatch in %s' % what)
        return data

    def block(self, off):
        """Data block at off: header (36 bytes) and decoded, CRC-checked data."""
        if off in self._blocks:
            return self._blocks[off]
        ident, dtype, comp, ssize, clen, length, ccrc, crc = struct.unpack_from('<4sHHIIIQQ', self.f, off)
        if ident != ID_DBLK:
            raise ValueError('no DBLK at 0x%x' % off)
        data = self.payload(off + 36, comp, clen, length, ccrc, crc, 'block 0x%x' % off)
        self._blocks[off] = (ssize, data)
        return ssize, data

    def tag(self, dtype):
        for bt, dt, off in self.index:
            if bt == ID_DBLK and dt == dtype:
                return self.block(off)[1]
        return None

    def sectors(self):
        """The user data, sector by sector, and the list of sectors not dumped."""
        ddt = [off for bt, dt, off in self.index if bt == ID_DDT and dt == DT_USERDATA]
        if len(ddt) != 1:
            raise ValueError('expected one user-data DDT, found %d' % len(ddt))
        off = ddt[0]
        ident, dtype, comp, shift, entries, clen, length, ccrc, crc = struct.unpack_from('<4sHHBQQQQQ', self.f, off)
        table = self.payload(off + 49, comp, clen, length, ccrc, crc, 'the DDT')
        mask = (1 << shift) - 1
        out = bytearray(entries * SECTOR)
        missing = []
        for i, e in enumerate(struct.unpack_from('<%dQ' % entries, table)):
            if e == 0:
                missing.append(i)
                continue
            ssize, data = self.block(e >> shift)
            if ssize != SECTOR:
                raise ValueError('sector size %d not supported' % ssize)
            k = (e & mask) * SECTOR
            out[i * SECTOR:(i + 1) * SECTOR] = data[k:k + SECTOR]
        return bytes(out), missing

    def checksums(self):
        """The image's own checksums of the user data: {name: bytes}."""
        names = {1: 'md5', 2: 'sha1', 3: 'sha256'}
        out = {}
        for bt, dt, off in self.index:
            if bt != ID_CKSM:
                continue
            length, n = struct.unpack_from('<IB', self.f, off + 4)
            p = off + 9
            for _ in range(n):
                typ, ln = struct.unpack_from('<BI', self.f, p)
                p += 5
                if typ in names:
                    out[names[typ]] = self.f[p:p + ln]
                p += ln
        return out


def read_aaru(path):
    """The .aaruf bytes, from the file or from the single .aaruf in a zip,
    and the text of the dump's CICM sidecar (.cicm.xml) if there is one."""
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            names = [n for n in z.namelist() if n.lower().endswith('.aaruf')]
            if len(names) != 1:
                raise ValueError('%s: expected one .aaruf, found %d' % (path, len(names)))
            cicm = [n for n in z.namelist() if n.lower().endswith('.cicm.xml')]
            return z.read(names[0]), z.read(cicm[0]).decode('utf-8', 'replace') if len(cicm) == 1 else None
    side = path[:-len('.aaruf')] + '.cicm.xml' if path.lower().endswith('.aaruf') else None
    cicm = None
    if side and os.path.exists(side):
        with open(side, encoding='utf-8', errors='replace') as f:
            cicm = f.read()
    with open(path, 'rb') as f:
        return f.read(), cicm


def cicm_sums(text):
    """MD5 and SHA-1 of the user data from a CICM sidecar's <ContentChecksums>
    (read with a pattern, not an XML parser)."""
    m = re.search(r'<ContentChecksums>(.*?)</ContentChecksums>', text, re.S)
    out = {}
    if m:
        for typ, val in re.findall(r'<Checksum type="(md5|sha1)">([0-9a-fA-F]+)</Checksum>', m.group(1)):
            out[typ] = bytes.fromhex(val)
    return out


def hexreg(s, name):
    s = ''.join(c for c in s if c in '0123456789abcdefABCDEF')
    if len(s) not in (30, 32):
        raise ValueError('--%s needs 15 or 16 bytes of hex' % name)
    return bytes.fromhex(s)


def describe(cid, csd):
    pnm = cid[3:9]
    psn = struct.unpack('>I', cid[10:14])[0]
    ccc = (csd[4] << 4) | (csd[5] >> 4)
    c_size = ((csd[6] & 3) << 10) | (csd[7] << 2) | (csd[8] >> 6)
    mult = ((csd[9] & 3) << 1) | (csd[10] >> 7)
    rbl = csd[5] & 0xF
    blocks = (c_size + 1) << (mult + 2)
    return ('MID %02x OID %02x%02x PNM %s PRV %02x PSN %08x MDT %02x; CCC %03x, %d blocks of %d bytes%s'
            % (cid[0], cid[1], cid[2], pnm.hex(' '), cid[9], psn, cid[14], ccc, blocks, 1 << rbl,
               ', PERM_WRITE_PROTECT' if csd[14] & 0x20 else '')), blocks << rbl


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('input')
    ap.add_argument('out')
    ap.add_argument('--cid', help='CID, 15 or 16 bytes of hex (raw input)')
    ap.add_argument('--csd', help='CSD, 15 or 16 bytes of hex (raw input)')
    ap.add_argument('--ocr', default='00FF8000', help='OCR to record (default 00FF8000)')
    a = ap.parse_args()

    if a.input.lower().endswith('.img'):
        if not (a.cid and a.csd):
            ap.error('a raw image needs --cid and --csd')
        with open(a.input, 'rb') as f:
            data = f.read()
        if len(data) % SECTOR:
            ap.error('image size is not a multiple of 512')
        cid, csd = hexreg(a.cid, 'cid'), hexreg(a.csd, 'csd')
    else:
        raw, cicm = read_aaru(a.input)
        img = Aaru(raw)
        cid, csd = img.tag(DT_MMC_CID), img.tag(DT_MMC_CSD)
        if cid is None or csd is None or len(cid) < 15 or len(csd) < 15:
            raise SystemExit('the dump has no CID/CSD')
        if a.cid:
            cid = hexreg(a.cid, 'cid')
        if a.csd:
            csd = hexreg(a.csd, 'csd')
        data, missing = img.sectors()
        if missing:
            print('warning: %d sectors were not dumped (zeros), first %d' % (len(missing), missing[0]))
        sums, where = img.checksums(), 'dump'
        if not sums and cicm:
            sums, where = cicm_sums(cicm), 'CICM sidecar'
        for name, want in sums.items():
            got = hashlib.new(name, data).digest()
            if got != want:
                raise SystemExit('%s of the sectors does not match the %s (%s)' % (name, where, want.hex()))
        if sums:
            print('sectors match the %s: %s' % (where, ', '.join(sorted(sums))))
        else:
            print('warning: no checksums to verify the sectors against')
        ocr = img.tag(DT_MMC_OCR)
        if ocr is not None:
            print('dump OCR %s (negotiated voltage, not used)' % ocr.hex())

    cid, csd = with_crc(cid), with_crc(csd)
    ocr = struct.pack('>I', int(a.ocr, 16))
    text, capacity = describe(cid, csd)
    print('CID %s' % cid.hex())
    print('CSD %s' % csd.hex())
    print(text)
    if capacity != len(data):
        print('note: CSD capacity %d bytes, image %d bytes' % (capacity, len(data)))
    if data[510:512] != b'\x55\xaa':
        print('note: sector 0 has no MBR signature')

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out + '.img', 'wb') as f:
        f.write(data)
    with open(a.out + '.img.cid', 'w') as f:
        f.write(cid.hex() + '\n')
    with open(a.out + '.img.csd', 'w') as f:
        f.write(csd.hex() + '\n')
    side = bytearray(SECTOR)
    side[0:8] = SIDECAR_MAGIC
    side[8] = SIDECAR_VERSION
    side[16:32] = cid
    side[32:48] = csd
    side[48:52] = ocr
    with open(a.out + '.mmc', 'wb') as f:
        f.write(data)
        f.write(side)
    print('wrote %s.img (+ .cid, .csd) and %s.mmc' % (a.out, a.out))


if __name__ == '__main__':
    try:
        main()
    except ValueError as e:
        raise SystemExit('mkcard: %s' % e)
