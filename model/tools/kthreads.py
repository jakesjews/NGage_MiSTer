#!/usr/bin/env python3
"""List EKA1 kernel threads from memory dumps made by model/threads.sh.

DThread objects are found by the vtable of the current thread (pointer at
kernel data 0x80006740). Owning process at +0x8; thread name at +0x170
(length word, then UTF-16) for kernel-created threads; process name at
+0xE0 (same layout) when present. Context saved at +0x124 (r0-r12, sp, lr)
follows the interrupt exit at ekern 0x50321974. Run with python3 -I.
"""
import os, struct, sys

out = sys.argv[1] if len(sys.argv) > 1 else 'model/.out'
kd = open(out + '/kdata.bin', 'rb').read()
kh = b''
for i in range(8):
    p = '%s/kheap%d.bin' % (out, i)
    if not os.path.exists(p) or os.path.getsize(p) != 0x20000:
        break
    kh += open(p, 'rb').read()
HEAP_END = 0x80400000 + len(kh)


def u32(a):
    if 0x80000000 <= a < 0x80010000:
        return struct.unpack_from('<I', kd, a - 0x80000000)[0]
    if 0x80400000 <= a <= HEAP_END - 4:
        return struct.unpack_from('<I', kh, a - 0x80400000)[0]
    return None


def name_at(a):
    n = u32(a)
    if n is None:
        return '?'
    n &= 0xFFFF
    if not 0 < n < 64 or a + 4 + 2 * n > HEAP_END:
        return '?'
    s = kh[a + 4 - 0x80400000:a + 4 - 0x80400000 + 2 * n]
    try:
        t = s.decode('utf-16-le')
    except UnicodeDecodeError:
        return '?'
    return t if t.isprintable() else '?'


# ROM file names by code address, for naming processes (process +0x84 = code
# address, e.g. EFile 0x503C8CA4, EStart 0x503E9964).
codenames = {}
try:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import romdis
    rom = open('research/firmware/images/nor/rh29-4.60-symrom-from-fls.bin', 'rb').read()
    for fname, addr, size in romdis.files(rom):
        if size > 0x64:
            codenames[struct.unpack_from('<I', rom, addr - romdis.BASE + 0x14)[0]] = fname
except OSError:
    pass

cur = u32(0x80006740)
vt = u32(cur)
print('current thread %08x vtable %08x, heap dump to %08x' % (cur, vt, HEAP_END))
for off in range(0, len(kh) - 0x200, 4):
    if struct.unpack_from('<I', kh, off)[0] != vt:
        continue
    t = 0x80400000 + off
    proc = u32(t + 8)
    ctx = struct.unpack_from('<15I', kh, off + 0x124)
    pname = '-'
    if proc and 0x80400000 <= proc < HEAP_END - 0x90:
        pname = codenames.get(u32(proc + 0x84), name_at(proc + 0xD8))
    print('%08x %s %-18s proc %08x %-14s sp=%08x lr=%08x' % (
        t, '*' if t == cur else ' ', name_at(t + 0x170), proc or 0, pname, ctx[13], ctx[14]))
