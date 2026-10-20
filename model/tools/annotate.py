#!/usr/bin/env python3
"""Annotate an objdump listing of a ROM file with export names.

usage: annotate.py ROM SYMS LISTING > OUT
Calls (bl/blx/b) to an import thunk (ARM "ldr ip,[pc]; ldr pc,[ip]" or
Thumb "ldr r3,[pc,#4]; ldr r3,[r3]; bx r3", literal at thunk+8 = export
slot) or straight to an exported function get "; <name>" appended. SYMS is
research/firmware/analysis/romsyms.txt from romsyms.py. Run with python3 -I.
"""
import re, struct, sys

rom = open(sys.argv[1], 'rb').read()
fn, slot = {}, {}
for line in open(sys.argv[2]):
    a, name, dll, ordn = line.split()
    a = int(a, 16)
    if name.startswith('slot:'):
        slot[a] = '%s!%s' % (dll.rsplit('\\', 1)[-1], name[5:])
    else:
        fn[a] = '%s!%s' % (dll.rsplit('\\', 1)[-1], name)


def word(a):
    o = a - 0x50000000
    return struct.unpack_from('<I', rom, o)[0] if 0 <= o <= len(rom) - 4 else None


def name_of(t):
    if t in fn:
        return fn[t]
    # Import thunks keep the export-table slot in a literal: Thumb "ldr r3,
    # [pc,#4]" (+8), Thumb "push {r6}; ldr r6, [pc,#8]" (+12), ARM "ldr ip,
    # [pc]" (+8) or "ldr ip, [pc,#4]; ldr ip,[ip]; bx ip" (+12).
    for off in (8, 12):
        lit = word((t + off) & ~3)
        if lit in slot:
            return slot[lit]
    return None


pat = re.compile(r'\s(bl|blx|b|bl\.w)\s+0x([0-9a-f]+)')
for line in open(sys.argv[3]):
    line = line.rstrip('\n')
    m = pat.search(line)
    if m:
        n = name_of(int(m.group(2), 16))
        if n:
            line += '\t; ' + n
    print(line)
