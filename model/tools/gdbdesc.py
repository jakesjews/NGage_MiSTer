#!/usr/bin/env python3
"""Turn GDB output that contains "DESC len=N" lines followed by x/40hx dumps
(model/gdb/desc.gdb) into readable strings; other lines pass through.
usage: gdbdesc.py < gdb-output   (python3 -I)"""
import re, sys

lines = sys.stdin.read().split('\n')
i = 0
while i < len(lines):
    m = re.match(r'DESC len=(\d+) type=(\d+)', lines[i])
    if not m:
        print(lines[i])
        i += 1
        continue
    n = int(m.group(1))
    vals = []
    i += 1
    while i < len(lines) and re.match(r'0x[0-9a-f]+:', lines[i]):
        vals += [int(v, 16) for v in lines[i].split(':', 1)[1].split()]
        i += 1
    s = ''.join(chr(v) if 32 <= v < 127 else '.' for v in vals[:n])
    print('  "%s"' % s)
