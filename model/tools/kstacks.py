#!/usr/bin/env python3
"""User stacks of EKA1 threads, for finding where a thread waits.

usage: kstacks.py OUT gdb      write OUT/kstk/*.gdb (dumps of each thread's
                               user stack at its process's home address)
       kstacks.py OUT decode   list return addresses found on each stack

OUT holds kdata.bin and kpages/ from model/threads.sh. The moving memory
model maps a process's data chunk at 0x00400000 only while it runs; the
chunk's home address (DChunk +0x28) is always mapped, so the saved user sp
(DThread context +0x124, sp at +0x158) is read there. DChunk objects have
vtable 0x50341630. Run with python3 -I from the repository.
"""
import bisect, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import romdis  # noqa: E402

out, mode = sys.argv[1], sys.argv[2]
ROM = 'research/firmware/images/nor/rh29-4.60-symrom-from-fls.bin'
SYMS = 'research/firmware/analysis/romsyms.txt'
CHUNK_VT = 0x50341630
STACK_BYTES = 0x600

kd = open(out + '/kdata.bin', 'rb').read()
pages = {}
pdir = out + '/kpages'
for f in os.listdir(pdir):
    if f.endswith('.bin') and os.path.getsize(os.path.join(pdir, f)) == 0x1000:
        pages[0x80400000 + int(f[1:5]) * 0x1000] = open(os.path.join(pdir, f), 'rb').read()


def u32(a):
    if 0x80000000 <= a < 0x80010000:
        return struct.unpack_from('<I', kd, a - 0x80000000)[0]
    p = pages.get(a & ~0xFFF)
    return struct.unpack_from('<I', p, a & 0xFFF)[0] if p and (a & 0xFFF) <= 0xFFC else None


def name_at(a):
    n = u32(a)
    if n is None or not 0 < (n & 0xFFFF) < 64:
        return '?'
    raw = b''.join(struct.pack('<I', u32(a + 4 + 4 * i) or 0) for i in range(((n & 0xFFFF) * 2 + 3) // 4))
    t = raw[:2 * (n & 0xFFFF)].decode('utf-16-le', 'replace')
    return t if t.isprintable() else '?'


rom = open(ROM, 'rb').read()
files = sorted((f for f in romdis.files(rom) if f[2] > 0x64), key=lambda f: f[1])
starts = [f[1] for f in files]
codenames = {struct.unpack_from('<I', rom, a - romdis.BASE + 0x14)[0]: n for n, a, s in files}


def threads():
    cur = u32(0x80006740)
    vt = u32(cur)
    for base in sorted(pages):
        for off in range(0, 0x1000, 4):
            t = base + off
            if u32(t) != vt:
                continue
            proc = u32(t + 8)
            if proc is None or not 0x80400000 <= proc < 0x81000000:
                continue
            sp, lr = u32(t + 0x124 + 13 * 4), u32(t + 0x124 + 14 * 4)
            pname = codenames.get(u32(proc + 0x84) or 0, name_at(proc + 0xD8))
            yield t, proc, pname, sp or 0, lr or 0


def chunks():
    for base in sorted(pages):
        for off in range(0, 0x1000, 4):
            if u32(base + off) == CHUNK_VT:
                yield base + off


CHUNKS = None


def home_of(proc, sp):
    """(run base, home base) of the chunk of proc that holds sp. A DChunk
    keeps its owner at +0x14, committed bytes at +0x20, the run-time end
    at +0x24 and the home base at +0x28 (e.g. PhoneServer's data chunk:
    0x2000 bytes ending at 0x00402000, home 0x85000000)."""
    global CHUNKS
    if CHUNKS is None:
        CHUNKS = list(chunks())
    for ch in CHUNKS:
        if u32(ch + 0x14) != proc:
            continue
        size, end, home = u32(ch + 0x20), u32(ch + 0x24), u32(ch + 0x28)
        if size and end and home and end - size <= sp < end:
            return end - size, home
    return None


if mode == 'gdb':
    # One command file per dump: GDB stops a file at its first error.
    os.makedirs(out + '/kstk', exist_ok=True)
    for f in os.listdir(out + '/kstk'):
        os.remove(os.path.join(out + '/kstk', f))
    for t, proc, pname, sp, lr in threads():
        if 0x81000000 <= sp < 0x90000000:
            a = sp                      # fixed process: stack always mapped
        elif 0x00400000 <= sp < 0x10000000:
            h = home_of(proc, sp)
            if not h:
                print('no stack chunk: %08x %s sp=%08x' % (t, pname, sp))
                continue
            a = h[1] + (sp - h[0])
        else:
            continue
        with open('%s/kstk/%08x.gdb' % (out, t), 'w') as g:
            g.write('dump binary memory %s/stk-%08x-%08x.bin 0x%x 0x%x\n' % (out, t, sp, a, a + STACK_BYTES))
    sys.exit(0)

syms = []
for line in open(SYMS):
    p = line.split()
    if len(p) >= 3 and not p[1].startswith('slot:'):
        try:
            syms.append((int(p[0], 16), p[1]))
        except ValueError:
            pass
syms.sort()
skeys = [s[0] for s in syms]


def where(v):
    i = bisect.bisect_right(starts, v) - 1
    if i < 0 or v >= files[i][1] + files[i][2]:
        return None
    j = bisect.bisect_right(skeys, v) - 1
    return '%s+%x (%s+%x)' % (files[i][0], v - files[i][1], syms[j][1][:48], v - syms[j][0])


info = {t: (pname, lr) for t, proc, pname, sp, lr in threads()}
for f in sorted(os.listdir(out)):
    if not (f.startswith('stk-') and f.endswith('.bin')):
        continue
    t, sp = int(f[4:12], 16), int(f[13:21], 16)
    pname, lr = info.get(t, ('?', 0))
    print('== thread %08x %s sp=%08x lr=%s' % (t, pname, sp, where(lr) or '%08x' % lr))
    d = open(os.path.join(out, f), 'rb').read()
    for o in range(0, len(d) - 3, 4):
        v = struct.unpack_from('<I', d, o)[0]
        if v & 1 and 0x50000000 <= v < 0x51200000:
            w = where(v)
            if w:
                print('  %08x: %08x %s' % (sp + o, v, w))
