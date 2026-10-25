#!/usr/bin/env python3
# Worst slow-corner setup slack per endpoint family from report.tcl's
# detail_family_*_Slow_*.txt files; several directories side by side.
#   families.py LABEL=DIR [LABEL=DIR ...]
import glob
import os
import re
import sys

cols = [a.split('=', 1) for a in sys.argv[1:]]
data = {}
for label, d in cols:
    for f in glob.glob(os.path.join(d, 'detail_family_*_Slow_*.txt')):
        fam = re.match(r'detail_family_(.+)_Slow_', os.path.basename(f)).group(1)
        t = open(f, errors='replace').read()
        m = re.search(r'Worst case slack is (-?[\d.]+)', t)
        if not m:
            continue
        slack = float(m.group(1))
        row = re.search(r'^; (-?[\d.]+) +; (\S+) +; (\S+) +; \S+ +; \S+ +; [\d.]+ +; -?[\d.]+ +; ([\d.]+) +;', t, re.M)
        frm = to = dd = ''
        if row:
            frm, to, dd = row.group(2).split('|')[-1], row.group(3).split('|')[-1], row.group(4)
        key = (label, fam)
        if key not in data or slack < data[key][0]:
            data[key] = (slack, frm, to, dd)
fams = sorted({f for (_, f) in data}, key=lambda f: min(data.get((l, f), (99,))[0] for l, _ in cols))
print('| Family | ' + ' | '.join(l for l, _ in cols) + ' | Start -> endpoint (' + cols[-1][0] + ') |')
print('|---|' + '---:|' * len(cols) + '---|')
for f in fams:
    vals = [f'{data[(l, f)][0]:.3f}' if (l, f) in data else '-' for l, _ in cols]
    last = data.get((cols[-1][0], f))
    path = f'{last[1]} -> {last[2]} ({last[3]} ns)' if last else ''
    print(f'| {f} | ' + ' | '.join(vals) + f' | {path} |')
