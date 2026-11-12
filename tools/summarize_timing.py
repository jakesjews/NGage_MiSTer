#!/usr/bin/env python3
"""Summarize TimeQuest path CSV by endpoint block without dumping long routes."""
import argparse
import csv
from collections import defaultdict
from decimal import Decimal
from pathlib import Path

def block(node):
    # Keep ZAP submodules individually visible rather than collapsing the CPU.
    for part in reversed(node.split('|')[:-1]):
        if ':' in part:
            return part.split(':', 1)[0]
    return 'top/other'

def summary(path):
    with path.open(newline='') as f:
        reader = csv.DictReader(f)
        required = {'slack_ns', 'data_delay_ns', 'logic_levels', 'from_node', 'to_node'}
        if not required <= set(reader.fieldnames or []):
            raise ValueError('missing path CSV columns')
        rows = list(reader)
    if not rows:
        return "No failing setup endpoints exported for this corner.\n"
    rows.sort(key=lambda r: Decimal(r['slack_ns']))
    groups = defaultdict(list)
    for r in rows:
        for field in ('slack_ns', 'data_delay_ns', 'logic_levels'):
            Decimal(r[field])
        groups[(block(r['from_node']), block(r['to_node']))].append(r)
    lines = [f'# Failing setup endpoints ({len(rows)} exported)', '',
             'One worst path per endpoint in this corner; bounded diagnostic subset, not full timing sign-off.', '',
             '| From block | To block | Paths | Worst slack ns | Max data delay ns | Max logic levels |',
             '| --- | --- | ---: | ---: | ---: | ---: |']
    for (src, dst), members in sorted(groups.items(), key=lambda g: Decimal(g[1][0]['slack_ns'])):
        lines.append(f'| {src} | {dst} | {len(members)} | {members[0]["slack_ns"]} | '
                     f'{max(Decimal(r["data_delay_ns"]) for r in members)} | '
                     f'{max(Decimal(r["logic_levels"]) for r in members)} |')
    lines += ['', '## Worst ten node pairs', '']
    for r in rows[:10]:
        lines += [f'- {r["slack_ns"]} ns, {r["logic_levels"]} levels, {r["data_delay_ns"]} ns data: '
                  f'`{r["from_node"]}` → `{r["to_node"]}`']
    return '\n'.join(lines) + '\n'

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('csv', type=Path, nargs='+')
    p.add_argument('--output', type=Path)
    a = p.parse_args()
    try:
        text = '\n'.join(f'## {path.parent.name}\n\n' + summary(path) for path in a.csv)
    except (OSError, ValueError, ArithmeticError) as e:
        p.exit(1, f'Path summary failed: {e}\n')
    if a.output:
        a.output.write_text(text)
        print(f'Wrote {a.output}')
    else:
        print(text, end='')

if __name__ == '__main__':
    main()
