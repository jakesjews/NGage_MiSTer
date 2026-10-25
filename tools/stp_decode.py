#!/usr/bin/env python3
"""Decode the samples a headless SignalTap run saved into a .stp (tools/stp_capture.tcl).

  stp_decode.py CAPTURE.stp INSTANCE [--csv] [--only EXPR]

Prints one line per sample: the sample number (negative before the trigger,
0 at it), then each probed signal as hex in the order of the instance's
signal set; buses are assembled from their bits. The data log is sample-major
(each sample is one bit per data node in data_index order); a counter probe
confirms the bit order. With --only, EXPR is a Python expression over the
signal names (the last path component, e.g. "stp_done_q and not stp_we_q")
that selects the samples to print.
"""
import re, sys
import xml.etree.ElementTree as ET

args = sys.argv[1:]
csv = "--csv" in args
only = None
if "--only" in args:
    only = args[args.index("--only") + 1]
    del args[args.index("--only"):args.index("--only") + 2]
args = [a for a in args if a != "--csv"]
path, inst_name = args[0], args[1]

root = ET.parse(path).getroot()
inst = next(i for i in root.iter("instance") if i.get("name") == inst_name)
sset = inst.find("signal_set")
wires = [w.get("name") for w in sset.find("signal_vec").find("data_input_vec").findall("wire")]
log = sset.find("trigger").find("log")
if log is None or log.find("data") is None:
    sys.exit(f"{inst_name}: no data log in {path}")
data = log.find("data")
depth = int(data.get("sample_depth")); tpos = int(data.get("trigger_position", "0"))
bits = re.sub(r"\s+", "", data.text or "")
n = len(wires)
if len(bits) != n * depth:
    print(f"warning: {len(bits)} data bits, expected {n}x{depth}={n*depth}", file=sys.stderr)
samples = len(bits) // n

# group the wires into signals: "name[i]" bits of one bus, scalars as is
sigs = []  # (short name, [bit indices lsb..msb])
pos = {}
for k, w in enumerate(wires):
    m = re.match(r"(.*)\[(\d+)\]$", w)
    base, bit = (m.group(1), int(m.group(2))) if m else (w, None)
    if base not in pos:
        pos[base] = len(sigs); sigs.append([base.split("|")[-1], {}])
    sigs[pos[base]][1][bit if bit is not None else 0] = k
hdr = [s[0] for s in sigs]
if csv:
    print("sample," + ",".join(hdr))
else:
    print("  sample " + " ".join(f"{h:>{max(len(h), (max(s[1])+4)//4)}}" for h, s in zip(hdr, sigs)))
for si in range(samples):
    row = bits[si * n:(si + 1) * n]
    vals = []
    for name, bm in sigs:
        v = 0
        for b, k in bm.items():
            if row[k] == "1": v |= 1 << b
        vals.append((v, (max(bm) + 4) // 4))
    if only:
        env = {name: v for (name, _), (v, _) in zip(sigs, vals)}
        try:
            if not eval(only, {}, env): continue
        except Exception as e:
            sys.exit(f"--only: {e}")
    if csv:
        print(f"{si - tpos}," + ",".join(f"{v:0{w}x}" for v, w in vals))
    else:
        print(f"{si - tpos:8d} " + " ".join(f"{v:0{max(w, len(h))}x}" for (v, w), h in zip(vals, hdr)))
