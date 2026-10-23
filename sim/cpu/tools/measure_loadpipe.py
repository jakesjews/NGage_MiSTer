#!/usr/bin/env python3
"""Measure loadpipe's named 64-iteration regions without guest timing reads."""
import argparse
import json
from pathlib import Path
import re
import subprocess

here = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--model", type=Path, default=here / "build/obj-gen/Vtb_cpu")
parser.add_argument("--out", type=Path, required=True)
args = parser.parse_args()
symbols = {}
for line in subprocess.check_output(
    ["arm-none-eabi-nm", str(here / "build/tests/loadpipe.elf")], text=True
).splitlines():
    fields = line.split()
    if len(fields) == 3 and re.fullmatch(r"lp_\w+_(begin|end)", fields[2]):
        symbols[fields[2]] = int(fields[0], 16)
assert len(symbols) == 60, "Expected six operand classes at five distances"
args.out.mkdir(parents=True, exist_ok=True)
results = {}
for latency in ("0:0", "0:3", "2:9"):
    command = [str(args.model.resolve()), "--bin", str(here / "build/tests/loadpipe.bin"),
               "--lat", latency, "--quiet"]
    for address in symbols.values():
        command += ["--watch", hex(address)]
    run = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (args.out / f"loadpipe.{latency.replace(':', '-')}.log").write_text(run.stdout)
    if run.returncode or "PASS (" not in run.stdout:
        raise SystemExit(run.stdout)
    stamps = {int(address, 16): int(cycle) for address, cycle in
              re.findall(r"watch ([0-9a-f]+) cycle (\d+)", run.stdout)}
    results[latency] = {name[3:-6]: stamps[symbols[name[:-6] + "_end"]] - stamps[address]
                        for name, address in symbols.items() if name.endswith("_begin")}
(args.out / "regions.json").write_text(json.dumps(results, indent=2) + "\n")
print(json.dumps(results, indent=2))
