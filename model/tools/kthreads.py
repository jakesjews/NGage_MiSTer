#!/usr/bin/env python3
"""List EKA1 kernel threads from memory dumps made by model/gdb/dumpkern.gdb.

DThread objects are found by the vtable of the current thread (pointer at
kernel data 0x80006740); names are the DObject name at +0x170 (length word,
then UTF-16); the context saved at +0x124 (r0-r12, sp, lr) follows the
interrupt exit at ekern 0x50321974. Run with python3 -I.
"""
import struct, sys

out = sys.argv[1] if len(sys.argv) > 1 else 'model/.out'
kd = open(out + '/kdata.bin', 'rb').read()
kh = open(out + '/kheap.bin', 'rb').read()

def u32(a):
    if 0x80000000 <= a < 0x80010000:
        return struct.unpack_from('<I', kd, a - 0x80000000)[0]
    if 0x80400000 <= a < 0x80420000:
        return struct.unpack_from('<I', kh, a - 0x80400000)[0]
    return None

cur = u32(0x80006740)
vt = u32(cur)
print('current thread %08x vtable %08x' % (cur, vt))
for off in range(0, len(kh) - 0x200, 4):
    if struct.unpack_from('<I', kh, off)[0] != vt:
        continue
    t = 0x80400000 + off
    nl = u32(t + 0x170) & 0xFFFF
    if not 0 < nl < 64:
        continue
    name = kh[off + 0x174:off + 0x174 + 2 * nl].decode('utf-16-le', 'replace')
    ctx = struct.unpack_from('<15I', kh, off + 0x124)
    words = struct.unpack_from('<16I', kh, off + 0x4)
    print('%08x %s %-24s sp=%08x lr=%08x pc?=%08x | %s' % (
        t, '*' if t == cur else ' ', name, ctx[13], ctx[14],
        struct.unpack_from('<I', kh, off + 0x160)[0],
        ' '.join('%08x' % w for w in words[:12])))
