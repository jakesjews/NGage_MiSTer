#!/usr/bin/env python3
"""Validate and compare exclusive CPU profiles, at milestones or guest seconds."""
import argparse
import csv
import json
from pathlib import Path

GROUPS = {
    "Retired": ["retired"],
    "Data wait": ["dc_uncached", "dc_write_through", "dc_tlb", "dc_lock", "dc_miss_busy", "dc_request_other"],
    "Dependency": ["dep_multiply", "dep_shift", "dep_load_use", "dep_other"],
    "Fetch starvation": ["fetch_tlb", "fetch_icache", "fetch_redirect", "fetch_other"],
    "Branch/return recovery": ["branch_a", "branch_decode_early", "return_pc_repair"],
    "Serial/CP15": ["serial_cp15", "serial_refill"],
    "Replay/reservation": ["replay", "reservation_recovery"],
    "Structural": ["structural_uop", "structural_block", "structural_pipeline", "thumb_continuation"],
    "Reset/exception/WFI": ["reset", "exception", "wfi"],
}


def read(path):
    with Path(path).open() as f:
        reader = csv.DictReader(f)
        columns = reader.fieldnames
        classes = columns[columns.index("reset"):columns.index("mix_other")]
        mixes = [k for k in columns if k.startswith("mix_")]
        rows = []
        for raw in reader:
            row = {k: v if k in ("core", "scope", "label") else int(v) for k, v in raw.items()}
            assert row["clocks"] == row["end"] - row["start"], (path, row["label"], "range")
            assert sum(row[k] for k in classes) == row["clocks"], (path, row["label"], "classes")
            assert sum(row[k] for k in mixes) == row["retired"], (path, row["label"], "mix")
            rows.append(row)
    assert set(classes) == {k for group in GROUPS.values() for k in group}
    return rows, classes, mixes


def interval(path, start="zero", end="end", seconds=None):
    rows, classes, mixes = read(path)
    numbers = [k for k in rows[0] if k not in ("core", "scope", "label", "start", "end")]
    if seconds:
        first, last = (int(s) * 104000000 for s in seconds.split(":"))
        selected = [r for r in rows if r["scope"] == "interval" and first <= r["start"] < r["end"] <= last]
        assert selected and selected[0]["start"] == first and selected[-1]["end"] == last, "incomplete second range"
        assert all(a["end"] == b["start"] for a, b in zip(selected, selected[1:])), "interval gap"
        result = {k: sum(r[k] for r in selected) for k in numbers}
    else:
        def boundary(label):
            if label == "zero":
                return {k: 0 for k in numbers + ["end"]}
            selected = [r for r in rows if r["scope"] == "cumulative" and r["label"] == label]
            assert len(selected) == 1, f"{path}: expected one cumulative {label}"
            return selected[0]
        a, b = boundary(start), boundary(end)
        first, last = a["end"], b["end"]
        assert first <= last
        result = {k: b[k] - a[k] for k in numbers}
    result.update(core=rows[0]["core"], start=first, end=last)
    assert sum(result[k] for k in classes) == result["clocks"]
    assert sum(result[k] for k in mixes) == result["retired"]
    return result, classes, mixes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profiles", nargs="+")
    parser.add_argument("--from", dest="start", default="zero", help="cumulative milestone label, or zero")
    parser.add_argument("--to", dest="end", default="end")
    parser.add_argument("--seconds", help="half-open guest-second range, e.g. 200:235")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--detail", action="store_true", help="show every exclusive class")
    args = parser.parse_args()
    data = [interval(p, args.start, args.end, args.seconds) for p in args.profiles]
    if args.json:
        print(json.dumps({p: d[0] for p, d in zip(args.profiles, data)}, indent=2))
        return
    samples = [d[0] for d in data]
    print("| Class | " + " | ".join(s["core"] for s in samples) + " |")
    print("|---|" + "---:|" * len(samples))
    print("| Clocks | " + " | ".join(f'{s["clocks"]:,}' for s in samples) + " |")
    groups = {k: [k] for k in data[0][1]} if args.detail else GROUPS
    for name, keys in groups.items():
        cells = []
        for s in samples:
            n = sum(s[k] for k in keys)
            cells.append(f'{n:,} ({n / s["clocks"]:.2%})' if s["clocks"] else "0")
        print(f"| {name} | " + " | ".join(cells) + " |")
    print("\n| Instruction mix / event | " + " | ".join(s["core"] for s in samples) + " |")
    print("|---|" + "---:|" * len(samples))
    for key in data[0][2] + ["thumb", "condition_failed", "load_words", "store_words", "branches_taken", "branches_not_taken", "returns", "e29", "e30", "e31", "retired_dfill", "retired_dlock", "retired_ifill"]:
        print(f"| {key} | " + " | ".join(f'{s[key]:,}' for s in samples) + " |")


if __name__ == "__main__":
    main()
