#!/usr/bin/env python3
"""Make N-Gage game-card images from a card dump or a game folder, for the
reference model and for the MiSTer core.

Input, one of:
  aaru    an Aaru dump of the card (.aaruf, or the .zip it came in): sectors
          plus the card's CID, CSD and OCR as Aaru read them
  raw     a raw sector image (.img) with --cid and --csd given as hex
  folder  a game folder (the card's root, which holds System/Apps/...), or an
          archive of one (.rar, .7z, a .zip without an .aaruf; anything unar
          reads with --folder), as cracked games are passed around

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

aaru and raw: the CID and CSD are the card's own, as copy protection may
check the CID (research/peripherals/MMC.md section 4). The CRC7 of each
(x^7 + x^3 + 1 over bytes 0-14) is computed here; Aaru stores the registers
as Linux reports them, with byte 15 zero. Aaru's OCR is the voltage window
Linux negotiated, not the card's register, so the OCR written is --ocr
(default 0x00FF8000, 2.7-3.6 V, the core's and the model's default).

The Aaru reader covers what these dumps use: AaruFormat 1.x, index INDX,
data blocks DBLK (raw or LZMA), the user-data deduplication table DDT* and
the media-tag blocks 55, 56, 57 (MMC CID, CSD, OCR). Every stored block
CRC64 is checked, and the sectors against the image's own MD5/SHA-1/SHA-256
(block CKSM) or, without one, the CICM sidecar's content checksums. The dump
is read as data only; nothing in it is run.

folder: builds a writable card like an ordinary MMC of the time, laid out as
the retail cards are (MMC.md 3.3): an MBR with one partition at LBA 32 that
ends on a cylinder boundary (32 sectors a track), and in it FAT12 (16 MB) or
FAT16 (32, 64, 128 MB) with 4 KB clusters, 1 reserved sector, 2 FATs, 512
root entries, media 0xF8, OEM "MSWIN4.1", volume serial 0, "NO NAME".

  size   the smallest of 16, 32, 64 and 128 MB that holds the files with
         --free KB to spare (default 128), or --size. Capacities: 32760,
         65520, 131040, 262080 blocks (C_SIZE 4094, C_SIZE_MULT 1-4, as the
         16, 32 and 64 MB retail cards of MID 0x07); heads 2, 4, 8, 16.
  files  copied with mtools (mmd, mcopy: VFAT long names, so the names keep
         the folder's case; Symbian's FAT is case-insensitive) with their
         modification times (folders: the newest file's, so an input always
         gives the same image), archive attribute only. Left out: Thumbs.db,
         desktop.ini, .DS_Store, ._* and __MACOSX. Two packaging slips are
         put right and reported (--as-is keeps the tree unchanged): Apps,
         Libs or Programs beside System instead of in it, and System/App
         for System/Apps. Every file is then read back from the image with a
         FAT reader of its own and compared with the source.
  CID    synthetic: MID 0x00, OID 0x0000, PNM the first six letters and
         digits of the folder's name, PRV 1.0, PSN the CRC-32 of the name,
         MDT the month of the newest file. Cracked games do not check it.
  CSD    the SonicN retail CSD made writable: CCC 0x017 (block write added),
         WRITE_BL_LEN 9, R2W_FACTOR 2, no PERM/TMP_WRITE_PROTECT; TAAC 10 ms
         and NSAC 0 as the core's default card (its reads wait for the HPS);
         C_SIZE_MULT for the size.
  --cid and --csd override them; the CSD's capacity should then match.

An archive is extracted with unar (no nested archives, no resource forks)
into --src/<archive name> (default model/.out/cards/src); an earlier
extraction there is used again (delete it to extract afresh). The game's root
is the folder holding System; it must be unique. Archive contents are data:
nothing from them is run. Packages that are not folders (.blz, .sis) are
reported and not built.

--batch OUTDIR INPUT...: a folder card for each input, OUTDIR/<name>.img etc.
(name: the input's name in lower case, other characters as '-'), and
OUTDIR/cards.csv: input, card, size, file system, files, content and free
space, the Apps folders, notes. Inputs that make no card get a row saying why.

Usage: tools/mkcard.py [--cid HEX --csd HEX] [--ocr HEX] INPUT OUT
       tools/mkcard.py [--size MB] [--free KB] [--src DIR] [--as-is] FOLDER|ARCHIVE OUT
       tools/mkcard.py --batch OUTDIR [folder options] INPUT...
Run with python3 -I. Folder mode needs unar (archives) and mtools.
"""
import argparse
import csv
import hashlib
import lzma
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import time
import zipfile
import zlib

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


# ---------------------------------------------------------------------------
# folder mode: a FAT card image built from a game folder
# ---------------------------------------------------------------------------

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DEFAULT = os.path.join(REPO, 'model', '.out', 'cards', 'src')
ARCHIVES = ('.rar', '.7z', '.zip')
JUNK_FILES = {'thumbs.db', 'desktop.ini', '.ds_store'}
JUNK_DIRS = {'__macosx'}
STRAY_DIRS = {'apps', 'libs', 'programs'}
VFAT_BAD = set('"*/:<>?\\|')

PART_START = 32               # LBA of the partition, as on the retail cards
SPT = 32                      # sectors a track
SPC = 8                       # sectors a cluster: 4 KB
CLUSTER = SPC * SECTOR
RESERVED = 1
NFATS = 2
ROOT_ENTRIES = 512
ROOT_SECTORS = ROOT_ENTRIES * 32 // SECTOR
MEDIA = 0xF8
C_SIZE = 4094                 # 4095 x 2^(C_SIZE_MULT + 2) blocks
SIZES = {16: (2, 1), 32: (4, 2), 64: (8, 3), 128: (16, 4)}     # MB: heads, C_SIZE_MULT
RETAIL_CSD = bytes.fromhex('8c08032a0079a3ffb6c081e1800020')   # SonicN, MMC.md 3.2


def geometry(mb):
    """Card and FAT layout for a card of mb megabytes."""
    heads, mult = SIZES[mb]
    blocks = (C_SIZE + 1) << (mult + 2)
    cyl = blocks // (heads * SPT)
    total = cyl * heads * SPT - PART_START      # partition sectors, ends on a cylinder
    for bits in (12, 16):
        fatsz = 1
        while True:
            clusters = (total - RESERVED - NFATS * fatsz - ROOT_SECTORS) // SPC
            need = -(-((clusters + 2) * bits) // (8 * SECTOR))
            if need <= fatsz:
                break
            fatsz = need
        if (bits == 12 and clusters < 4085) or (bits == 16 and 4085 <= clusters < 65525):
            break
    else:
        raise ValueError('no FAT12/16 layout for %d MB' % mb)
    return {'mb': mb, 'heads': heads, 'mult': mult, 'blocks': blocks, 'total': total,
            'bits': bits, 'fatsz': fatsz, 'clusters': clusters,
            'root': RESERVED + NFATS * fatsz, 'data': RESERVED + NFATS * fatsz + ROOT_SECTORS}


def chs(lba, heads):
    c, h, s = lba // (heads * SPT), (lba // SPT) % heads, lba % SPT + 1
    if c > 1023:
        return bytes([254, 0xFF, 0xFF])
    return bytes([h, s | ((c >> 2) & 0xC0), c & 0xFF])


def blank_card(g):
    """MBR, boot sector, empty FATs and root directory; the rest zeros."""
    img = bytearray(g['blocks'] * SECTOR)
    end = PART_START + g['total'] - 1
    ptype = 0x01 if g['bits'] == 12 else (0x04 if g['total'] < 0x10000 else 0x06)
    img[446:462] = (bytes([0x80]) + chs(PART_START, g['heads']) + bytes([ptype]) +
                    chs(end, g['heads']) + struct.pack('<II', PART_START, g['total']))
    img[510:512] = b'\x55\xaa'
    bs = bytearray(SECTOR)
    bs[0:3] = b'\xeb\x3c\x90'
    bs[3:11] = b'MSWIN4.1'
    struct.pack_into('<HBHBHHBHHHII', bs, 11, SECTOR, SPC, RESERVED, NFATS, ROOT_ENTRIES,
                     g['total'] if g['total'] < 0x10000 else 0, MEDIA, g['fatsz'], SPT,
                     g['heads'], PART_START, 0 if g['total'] < 0x10000 else g['total'])
    struct.pack_into('<BBBI11s8s', bs, 36, 0x80, 0, 0x29, 0, b'NO NAME    ',
                     b'FAT12   ' if g['bits'] == 12 else b'FAT16   ')
    bs[510:512] = b'\x55\xaa'
    p = PART_START * SECTOR
    img[p:p + SECTOR] = bs
    head = bytes([MEDIA, 0xFF, 0xFF]) if g['bits'] == 12 else bytes([MEDIA, 0xFF, 0xFF, 0xFF])
    for i in range(NFATS):
        q = p + (RESERVED + i * g['fatsz']) * SECTOR
        img[q:q + len(head)] = head
    return img


def find_roots(top):
    """Folders under top (top included) that hold a System folder."""
    roots = []
    for d, dirs, _ in os.walk(top):
        dirs.sort()
        if any(x.lower() == 'system' for x in dirs):
            roots.append(d)
            dirs[:] = []
    return roots


def slug(name):
    s = re.sub(r"['`]", '', name.lower())
    return re.sub(r'[^a-z0-9]+', '-', s).strip('-') or 'card'


def extract(archive, srcdir):
    """Extract archive with unar into srcdir/<archive name>; reuse an earlier one."""
    stem = os.path.splitext(os.path.basename(archive))[0]
    dest = os.path.join(srcdir, stem)
    if os.path.isdir(dest):
        print('using the earlier extraction in %s' % dest)
        return dest
    if not shutil.which('unar'):
        raise ValueError('unar is needed to extract %s' % archive)
    part = dest + '.part'
    if os.path.isdir(part):
        shutil.rmtree(part)
    os.makedirs(part)
    r = subprocess.run(['unar', '-q', '-nr', '-nq', '-k', 'skip', '-D', '-f', '-o', part, archive],
                       stdin=subprocess.DEVNULL, capture_output=True, text=True)
    if r.returncode != 0:
        raise ValueError('unar failed on %s: %s' % (archive, (r.stderr or r.stdout).strip()))
    os.rename(part, dest)
    print('extracted %s into %s' % (archive, dest))
    return dest


def plan_tree(root, as_is):
    """The card's tree: {card dir (tuple of names): [(name, source path)]}, the
    set of card dirs, and notes. Names keep their case."""
    notes = []
    files = {(): []}
    dirs = {()}
    names = {(): {}}          # card dir -> {lower name: name}, to catch clashes

    def add_dir(cd):
        for i in range(1, len(cd) + 1):
            sub = cd[:i]
            if sub not in dirs:
                parent = sub[:-1]
                have = names[parent].get(sub[-1].lower())
                if have is not None and have != sub[-1]:
                    raise ValueError('%s clashes with %s (FAT names ignore case)' % ('/'.join(sub), have))
                names[parent][sub[-1].lower()] = sub[-1]
                dirs.add(sub)
                files[sub] = []
                names[sub] = {}

    def resolve(cd):
        # an existing card dir whose names match cd ignoring case
        out = ()
        for n in cd:
            out = out + (names[out].get(n.lower(), n),) if out in names else out + (n,)
        return out

    system = None
    if not as_is:
        for x in os.listdir(root):
            if x.lower() == 'system' and os.path.isdir(os.path.join(root, x)):
                system = x
    skipped = []
    for d, dn, fn in os.walk(root):
        dn.sort()
        fn.sort()
        rel = os.path.relpath(d, root)
        parts = () if rel == '.' else tuple(rel.split(os.sep))
        keep = []
        for x in dn:
            if os.path.islink(os.path.join(d, x)):
                skipped.append('/'.join(parts + (x,)) + ' (link)')
            elif x.lower() in JUNK_DIRS:
                skipped.append('/'.join(parts + (x,)) + '/')
            else:
                keep.append(x)
        dn[:] = keep
        cd = parts
        if not as_is and parts:
            if len(parts) >= 1 and parts[0].lower() in STRAY_DIRS and system:
                cd = (system,) + parts
                if len(parts) == 1:
                    notes.append('%s/ moved into %s/' % (parts[0], system))
            if len(cd) >= 2 and cd[0].lower() == 'system' and cd[1].lower() == 'app' and \
                    not any(x.lower() == 'apps' for x in os.listdir(os.path.join(root, parts[0]))):
                cd = (cd[0], 'Apps') + cd[2:]
                if len(cd) == 2:
                    notes.append('%s/%s/ renamed %s/Apps/' % (parts[0], parts[1], parts[0]))
        cd = resolve(cd)
        add_dir(cd)
        for f in fn:
            path = os.path.join(d, f)
            if os.path.islink(path) or not os.path.isfile(path):
                skipped.append('/'.join(parts + (f,)) + ' (not a file)')
                continue
            if f.lower() in JUNK_FILES or f.startswith('._'):
                skipped.append('/'.join(parts + (f,)))
                continue
            bad = [c for c in f if c in VFAT_BAD or ord(c) < 32]
            if bad or len(f) > 255:
                raise ValueError('%s: not a valid FAT long name' % path)
            have = names[cd].get(f.lower())
            if have is not None:
                raise ValueError('%s clashes with %s (FAT names ignore case)' % ('/'.join(cd + (f,)), have))
            names[cd][f.lower()] = f
            files[cd].append((f, path))
    if skipped:
        notes.append('left out: ' + ', '.join(skipped))
    for cd in dirs:
        for f, _ in files[cd]:
            full = 'E:\\' + '\\'.join(cd + (f,))
            if len(full) > 256:
                notes.append('path longer than 256 characters: ' + full)
    return files, dirs, notes


def entries(name):
    """Directory entries for a name: the short entry and (as mcopy writes them
    for any name) its long-name entries."""
    return 1 + -(-len(name) // 13)


def usage(files, dirs):
    """Clusters the tree needs (an upper bound) and root entries used."""
    clusters = 0
    root = 0
    for cd in dirs:
        n = sum(entries(f) for f, _ in files[cd])
        n += sum(entries(d[-1]) for d in dirs if len(d) == len(cd) + 1 and d[:-1] == cd)
        if cd == ():
            root = n
        else:
            clusters += max(1, -(-(n + 2) * 32 // CLUSTER))
        for _, path in files[cd]:
            clusters += -(-os.path.getsize(path) // CLUSTER)
    return clusters, root


def mtools(args, img, epoch):
    # SOURCE_DATE_EPOCH: the folders' times, so the same input gives the same image
    env = dict(os.environ, MTOOLS_SKIP_CHECK='1', MTOOLSRC=os.devnull, LC_ALL='en_US.UTF-8',
               SOURCE_DATE_EPOCH=str(int(epoch)))
    r = subprocess.run([args[0], '-i', '%s@@%d' % (img, PART_START * SECTOR)] + args[1:],
                       stdin=subprocess.DEVNULL, capture_output=True, text=True, env=env)
    if r.returncode != 0:
        raise ValueError('%s failed: %s' % (args[0], (r.stderr or r.stdout).strip()))


def fill(img, files, dirs, epoch):
    """Make the directories and copy the files in with mtools."""
    for cd in sorted(dirs, key=lambda d: (len(d), d)):
        if cd:
            mtools(['mmd', '::/' + '/'.join(cd)], img, epoch)
    for cd in sorted(dirs, key=lambda d: (len(d), d)):
        srcs = [p for _, p in files[cd]]
        for i in range(0, len(srcs), 100):
            # -b batch, -m keep the modification time, -D o never ask
            mtools(['mcopy', '-b', '-m', '-D', 'o'] + srcs[i:i + 100] + ['::/' + '/'.join(cd) + ('/' if cd else '')],
                   img, epoch)


class Fat:
    """A FAT12/16 reader, to check the image without mtools."""

    def __init__(self, img):
        self.d = img
        p = PART_START * SECTOR
        self.p = p
        bps, self.spc, res, nf, rootn, tot16, _, fatsz, _, _, _, tot32 = struct.unpack_from('<HBHBHHBHHHII', img, p + 11)
        if bps != SECTOR:
            raise ValueError('sector size %d' % bps)
        total = tot16 or tot32
        self.fat_off = p + res * SECTOR
        self.fatsz = fatsz
        self.nf = nf
        self.root_off = p + (res + nf * fatsz) * SECTOR
        self.rootn = rootn
        self.data_off = self.root_off + rootn * 32
        data_secs = total - res - nf * fatsz - rootn * 32 // SECTOR
        self.clusters = data_secs // self.spc
        self.bits = 12 if self.clusters < 4085 else 16
        self.fat = img[self.fat_off:self.fat_off + fatsz * SECTOR]

    def next(self, c):
        if self.bits == 12:
            v = self.fat[c * 3 // 2] | (self.fat[c * 3 // 2 + 1] << 8)
            return v >> 4 if c & 1 else v & 0xFFF
        return self.fat[2 * c] | (self.fat[2 * c + 1] << 8)

    def chain(self, c):
        end = 0xFF8 if self.bits == 12 else 0xFFF8
        out = []
        while 2 <= c < end:
            if c >= self.clusters + 2 or c in out:
                raise ValueError('bad cluster chain at %d' % c)
            out.append(c)
            c = self.next(c)
        return out

    def read(self, chain, size=None):
        cb = self.spc * SECTOR
        b = b''.join(self.d[self.data_off + (c - 2) * cb:self.data_off + (c - 1) * cb] for c in chain)
        return b if size is None else b[:size]

    def entries(self, raw):
        lfn = {}
        for i in range(0, len(raw), 32):
            e = raw[i:i + 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5:
                lfn = {}
                continue
            if e[11] == 0x0F:
                seq = e[0] & 0x1F
                lfn[seq] = (e[1:11] + e[14:26] + e[28:32], e[13])
                continue
            short = e[0:11]
            ck = 0
            for b in short:
                ck = (((ck & 1) << 7) + (ck >> 1) + b) & 0xFF
            if lfn and all(v[1] == ck for v in lfn.values()) and sorted(lfn) == list(range(1, len(lfn) + 1)):
                name = b''.join(lfn[k][0] for k in sorted(lfn)).decode('utf-16-le').split('\x00')[0]
            else:
                base, ext = short[:8].decode('ascii', 'replace').rstrip(), short[8:].decode('ascii', 'replace').rstrip()
                if e[12] & 0x08:        # Windows NT case flags, which mcopy uses
                    base = base.lower()
                if e[12] & 0x10:
                    ext = ext.lower()
                name = base + ('.' + ext if ext else '')
            lfn = {}
            if e[11] & 0x08:
                continue        # volume label
            cl, size = struct.unpack_from('<H', e, 26)[0], struct.unpack_from('<I', e, 28)[0]
            yield name, e[11], cl, size

    def tree(self):
        """{path tuple: (attr, first cluster, size)} and the clusters in use."""
        out = {}
        used = set()

        def walk(raw, parts):
            for name, attr, cl, size in self.entries(raw):
                if name in ('.', '..'):
                    continue
                ch = self.chain(cl)
                if used & set(ch):
                    raise ValueError('cross-linked clusters at %s' % '/'.join(parts + (name,)))
                used.update(ch)
                out[parts + (name,)] = (attr, ch, size)
                if attr & 0x10:
                    walk(self.read(ch), parts + (name,))
                elif -(-size // (self.spc * SECTOR)) != len(ch):
                    raise ValueError('%s: %d bytes in %d clusters' % ('/'.join(parts + (name,)), size, len(ch)))

        walk(self.d[self.root_off:self.data_off], ())
        return out, used


def verify(img, files, dirs):
    """Every file and folder is on the card with its name, size and contents;
    nothing else is; the FATs agree. Returns the free clusters."""
    fat = Fat(img)
    for i in range(1, fat.nf):
        o = fat.fat_off + i * fat.fatsz * SECTOR
        if img[o:o + fat.fatsz * SECTOR] != fat.fat:
            raise ValueError('FAT copy %d differs' % i)
    got, used = fat.tree()
    want = {cd for cd in dirs if cd}
    for cd in dirs:
        want.update(cd + (f,) for f, _ in files[cd])
    if set(got) != want:
        extra, missing = sorted(set(got) - want), sorted(want - set(got))
        raise ValueError('card tree differs: extra %s, missing %s' % (extra[:5], missing[:5]))
    for cd in dirs:
        if cd and not got[cd][0] & 0x10:
            raise ValueError('%s is not a folder on the card' % '/'.join(cd))
        for f, path in files[cd]:
            attr, ch, size = got[cd + (f,)]
            with open(path, 'rb') as fh:
                src = fh.read()
            if size != len(src) or fat.read(ch, size) != src:
                raise ValueError('%s differs on the card' % '/'.join(cd + (f,)))
    free = sum(1 for c in range(2, fat.clusters + 2) if fat.next(c) == 0)
    if free != fat.clusters - len(used):
        raise ValueError('%d clusters marked in use, %d reachable' % (fat.clusters - free, len(used)))
    return free


def folder_cid(name, newest):
    pnm = (re.sub(r'[^A-Z0-9]', '', name.upper())[:6] or 'NGAGE').ljust(6).encode('ascii')
    t = time.localtime(newest)
    year = min(max(t.tm_year, 1997), 2012)
    mdt = (t.tm_mon << 4) | (year - 1997)
    return bytes([0x00, 0x00, 0x00]) + pnm + bytes([0x10]) + struct.pack('>I', zlib.crc32(name.encode())) + bytes([mdt])


def folder_csd(mult):
    c = bytearray(RETAIL_CSD)
    c[1], c[2] = 0x0F, 0x00                     # TAAC 10 ms, NSAC 0
    c[4], c[5] = 0x01, 0x79                     # CCC 0x017, READ_BL_LEN 9
    c[9] = (c[9] & 0xFC) | ((mult >> 1) & 3)    # C_SIZE_MULT
    c[10] = (c[10] & 0x7F) | ((mult & 1) << 7)
    c[12] = (c[12] & 0xE0) | (2 << 2) | 0b10    # R2W_FACTOR 2, WRITE_BL_LEN[3:2]
    c[13] = (c[13] & 0x3F) | 0x40               # WRITE_BL_LEN[1:0]: 9
    c[14] &= ~0x30                              # no PERM/TMP_WRITE_PROTECT
    return bytes(c)


class NotACard(ValueError):
    pass


def folder_card(src, name, a, extracted=False):
    """Build a card from a folder tree. Returns (sectors, cid, csd, info)."""
    roots = find_roots(src)
    if not roots:
        found = [f for _, _, fn in os.walk(src) for f in fn]
        blz = [f for f in found if f.lower().endswith('.blz')]
        sis = [f for f in found if f.lower().endswith('.sis')]
        if blz:
            hdr = b''
            for d, _, fn in os.walk(src):
                for f in fn:
                    if f.lower().endswith('.blz'):
                        with open(os.path.join(d, f), 'rb') as fh:
                            hdr = fh.read(16)
            unpacked = struct.unpack_from('<I', hdr, 12)[0] if hdr[:4] == b'NGPK' else 0
            raise NotACard('BLZ package (%s%s): unpacked on the phone by the BLZ installer; not built'
                           % (', '.join(blz), ', NGPK, %d bytes unpacked' % unpacked if unpacked else ''))
        if sis:
            raise NotACard('SIS installer (%s): installed on the phone; not built' % ', '.join(sis))
        raise NotACard('no System folder: not a card tree')
    if len(roots) > 1:
        raise NotACard('more than one folder holds System: %s' % ', '.join(os.path.relpath(r, src) for r in roots))
    root = roots[0]
    files, dirs, notes = plan_tree(root, a.as_is)
    nfiles = sum(len(v) for v in files.values())
    if not nfiles:
        raise NotACard('no files')
    paths = [p for v in files.values() for _, p in v]
    content = sum(os.path.getsize(p) for p in paths)
    newest = max(os.path.getmtime(p) for p in paths)
    need, root_n = usage(files, dirs)
    if root_n > ROOT_ENTRIES:
        raise ValueError('%d root entries, the root holds %d' % (root_n, ROOT_ENTRIES))
    free_cl = -(-a.free * 1024 // CLUSTER)
    sizes = [a.size] if a.size else sorted(SIZES)
    g = None
    for mb in sizes:
        if mb not in SIZES:
            raise ValueError('--size must be one of %s' % ', '.join(map(str, sorted(SIZES))))
        t = geometry(mb)
        if t['clusters'] - need >= (0 if a.size else free_cl):
            g = t
            break
    if g is None:
        raise ValueError('%d KB of files (%d clusters) do not fit %s' % (content // 1024, need,
                         '%d MB' % a.size if a.size else 'a 128 MB card with %d KB free' % a.free))
    tmp = a.workfile
    with open(tmp, 'wb') as f:
        f.write(blank_card(g))
    fill(tmp, files, dirs, newest)
    with open(tmp, 'rb') as f:
        data = f.read()
    free = verify(data, files, dirs)
    if free < g['clusters'] - need:
        raise ValueError('mtools used more clusters than planned')
    apps = []
    for cd in dirs:
        if len(cd) == 3 and cd[0].lower() == 'system' and cd[1].lower() == 'apps':
            apps.append(cd[2])
    rootfiles = [f for f, _ in files[()]]
    if rootfiles:
        notes.append('card root: ' + ', '.join(rootfiles))
    info = {'root': os.path.relpath(root, src) if root != src else '.', 'size': g['mb'],
            'fat': 'FAT%d' % g['bits'], 'files': nfiles, 'content_kb': -(-content // 1024),
            'free_kb': free * CLUSTER // 1024, 'apps': ' '.join(sorted(apps)), 'notes': notes}
    print('%s: root %s, %d files, %d KB; %d MB card, FAT%d, %d of %d clusters free'
          % (name, info['root'], nfiles, info['content_kb'], g['mb'], g['bits'], free, g['clusters']))
    for n in notes:
        print('  note: ' + n)
    return data, folder_cid(name, newest), folder_csd(g['mult']), info


def is_folder_input(path, forced):
    if forced or os.path.isdir(path):
        return True
    low = path.lower()
    if low.endswith('.zip') and zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            return not any(n.lower().endswith('.aaruf') for n in z.namelist())
    return low.endswith(('.rar', '.7z', '.sis', '.blz'))


def folder_source(path, a):
    """The folder tree for an input: itself, or its extraction."""
    if os.path.isdir(path):
        return os.path.abspath(path)
    low = path.lower()
    if low.endswith('.sis'):
        raise NotACard('SIS installer: installed on the phone; not built')
    if low.endswith('.blz'):
        raise NotACard('BLZ package: unpacked on the phone by the BLZ installer; not built')
    return extract(os.path.abspath(path), a.src)


def write_card(out, data, cid, csd, ocr):
    cid, csd = with_crc(cid), with_crc(csd)
    text, capacity = describe(cid, csd)
    print('CID %s' % cid.hex())
    print('CSD %s' % csd.hex())
    print(text)
    if capacity != len(data):
        print('note: CSD capacity %d bytes, image %d bytes' % (capacity, len(data)))
    if data[510:512] != b'\x55\xaa':
        print('note: sector 0 has no MBR signature')
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out + '.img', 'wb') as f:
        f.write(data)
    with open(out + '.img.cid', 'w') as f:
        f.write(cid.hex() + '\n')
    with open(out + '.img.csd', 'w') as f:
        f.write(csd.hex() + '\n')
    side = bytearray(SECTOR)
    side[0:8] = SIDECAR_MAGIC
    side[8] = SIDECAR_VERSION
    side[16:32] = cid
    side[32:48] = csd
    side[48:52] = ocr
    with open(out + '.mmc', 'wb') as f:
        f.write(data)
        f.write(side)
    print('wrote %s.img (+ .cid, .csd) and %s.mmc' % (out, out))


def build_folder(inp, out, a, ocr):
    name = os.path.basename(os.path.normpath(inp))
    if not os.path.isdir(inp):
        name = os.path.splitext(name)[0]
    src = folder_source(inp, a)
    for tool in ('mmd', 'mcopy'):
        if not shutil.which(tool):
            raise ValueError('mtools (%s) is needed for folder cards' % tool)
    a.workfile = out + '.img.part'
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    try:
        data, cid, csd, info = folder_card(src, name, a)
    finally:
        if os.path.exists(a.workfile):
            os.remove(a.workfile)
    if a.cid:
        cid = hexreg(a.cid, 'cid')
    if a.csd:
        csd = hexreg(a.csd, 'csd')
    write_card(out, data, cid, csd, ocr)
    return name, info


def batch(a, ocr):
    os.makedirs(a.batch, exist_ok=True)
    rows = []
    for inp in a.inputs:
        base = os.path.basename(os.path.normpath(inp))
        name = base if os.path.isdir(inp) else os.path.splitext(base)[0]
        card = slug(name)
        row = {'input': base, 'card': '', 'size_mb': '', 'fs': '', 'files': '', 'content_kb': '',
               'free_kb': '', 'apps': '', 'notes': ''}
        print('== %s' % base)
        try:
            if not os.path.isdir(inp) and not inp.lower().endswith(ARCHIVES + ('.sis', '.blz')):
                raise NotACard('not a folder or archive')
            _, info = build_folder(inp, os.path.join(a.batch, card), a, ocr)
            row.update(card=card, size_mb=info['size'], fs=info['fat'], files=info['files'],
                       content_kb=info['content_kb'], free_kb=info['free_kb'], apps=info['apps'],
                       notes='; '.join(info['notes']))
        except NotACard as e:
            print('  not built: %s' % e)
            row['notes'] = str(e)
        except ValueError as e:
            print('  FAILED: %s' % e)
            row['notes'] = 'failed: %s' % e
        rows.append(row)
    path = os.path.join(a.batch, 'cards.csv')
    with open(path, 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]) if rows else ['input'])
        w.writeheader()
        w.writerows(rows)
    built = [r for r in rows if r['card']]
    print('%d cards built of %d inputs; %s' % (len(built), len(rows), path))
    for mb in sorted(SIZES):
        n = sum(1 for r in built if r['size_mb'] == mb)
        if n:
            print('  %d MB: %d' % (mb, n))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
                                 usage='%(prog)s [options] INPUT OUT  |  %(prog)s --batch OUTDIR [options] INPUT...')
    ap.add_argument('inputs', nargs='+', metavar='INPUT OUT', help='input and output (--batch: inputs)')
    ap.add_argument('--cid', help='CID, 15 or 16 bytes of hex (raw input; overrides aaru and folder)')
    ap.add_argument('--csd', help='CSD, 15 or 16 bytes of hex (the same)')
    ap.add_argument('--ocr', default='00FF8000', help='OCR to record (default 00FF8000)')
    ap.add_argument('--folder', action='store_true', help='treat INPUT as a folder or an archive of one')
    ap.add_argument('--size', type=int, help='folder: card size in MB (16, 32, 64, 128); default the smallest that fits')
    ap.add_argument('--free', type=int, default=128, help='folder: KB to leave free when choosing the size (default 128)')
    ap.add_argument('--src', default=SRC_DEFAULT, help='folder: where archives are extracted (default model/.out/cards/src)')
    ap.add_argument('--as-is', action='store_true', help='folder: copy the tree without the packaging fixes')
    ap.add_argument('--batch', metavar='OUTDIR', help='a folder card for each INPUT into OUTDIR, with OUTDIR/cards.csv')
    a = ap.parse_args()
    ocr = struct.pack('>I', int(a.ocr, 16))

    if a.batch:
        batch(a, ocr)
        return
    if len(a.inputs) != 2:
        ap.error('give INPUT and OUT (or --batch OUTDIR INPUT...)')
    inp, out = a.inputs

    if is_folder_input(inp, a.folder):
        try:
            build_folder(inp, out, a, ocr)
        except NotACard as e:
            raise SystemExit('mkcard: %s' % e)
        return
    if inp.lower().endswith('.img'):
        if not (a.cid and a.csd):
            ap.error('a raw image needs --cid and --csd')
        with open(inp, 'rb') as f:
            data = f.read()
        if len(data) % SECTOR:
            ap.error('image size is not a multiple of 512')
        cid, csd = hexreg(a.cid, 'cid'), hexreg(a.csd, 'csd')
    else:
        raw, cicm = read_aaru(inp)
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
        ocr_dump = img.tag(DT_MMC_OCR)
        if ocr_dump is not None:
            print('dump OCR %s (negotiated voltage, not used)' % ocr_dump.hex())
    write_card(out, data, cid, csd, ocr)


if __name__ == '__main__':
    try:
        main()
    except ValueError as e:
        raise SystemExit('mkcard: %s' % e)
