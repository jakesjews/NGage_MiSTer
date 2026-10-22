#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The per-second counters of a tools/jev_play.py run as a timeline and phase averages.

    tools/jev_profile.py build/hardware/jev/GAME/log.csv [--every N]

Each row of the run's log that carries counters (the overlay on) becomes a
line: seconds since the load (the MiSTer's clock), the screen class, LCD
frames and pixels in the last second, million instructions, cycles an
instruction (of the non-idle clocks), idle %, bus wait % on the SDRAM, the
flash and elsewhere, bus beats. Then averages per phase: boot (load to the
Time dialog), phone (dialogs, idle screen, menu), game menus and logos,
gameplay.
"""
import argparse, csv, re, statistics, sys

CLK = 104_000_000
PAT = re.compile(r"(\d+) frames, (\d+) px, ([\d.]+) M instr, idle ([\d.]+)%, bus wait sdram ([\d.]+)% flash ([\d.]+)% other ([\d.]+)%, (\d+) beats")


def parse(path):
    rows = list(csv.DictReader(open(path)))
    t0 = None
    out = []
    for r in rows:
        if r["note"] == "load_core":
            t0 = float(r["mister_time"])
            continue
        m = PAT.search(r.get("counters", "") or "")
        if not m:
            continue
        frames, px, minstr, idle, sd, fl, ot, beats = m.groups()
        if int(frames) > 1000 or float(idle) > 100 or int(beats) > CLK or (float(minstr) == 0 and int(beats) == 0):
            continue                      # the overlay was off: panel pixels, not counters
        t = float(r["mister_time"]) if r["mister_time"] not in ("", "0.000") else None
        out.append({"t": (t - t0) if (t and t0) else None, "screen": r["screen"], "note": r["note"],
                    "frames": int(frames), "px": int(px), "minstr": float(minstr), "idle": float(idle),
                    "sdram": float(sd), "flash": float(fl), "other": float(ot), "beats": int(beats)})
    return out


def cpi(s):
    busy = CLK * (1 - s["idle"] / 100)
    return busy / (s["minstr"] * 1e6) if s["minstr"] > 0 else float("nan")


def phase(s, seen_dialog, seen_play):
    if s["screen"] == "gameplay":
        return "gameplay"
    if seen_play or s["screen"] in ("game_logo", "game_menu", "loading"):
        return "game"
    if seen_dialog or s["screen"] in ("dialog", "phone_idle", "phone_menu"):
        return "phone"
    return "boot"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--every", type=int, default=1, help="print every Nth sample")
    a = ap.parse_args()
    samples = parse(a.log)
    if not samples:
        sys.exit("no counter samples in the log (overlay off?)")
    print("   t(s)  phase     screen        fps      px/s  Minstr/s   CPI  idle%  sdram%  flash%  other%   beats/s")
    seen_dialog = seen_play = False
    phases = {}
    for i, s in enumerate(samples):
        if s["screen"] == "dialog":
            seen_dialog = True
        if s["screen"] == "gameplay":
            seen_play = True
        ph = phase(s, seen_dialog, seen_play)
        phases.setdefault(ph, []).append(s)
        if i % a.every == 0:
            print("%7s  %-8s  %-12s %4d %9d %9.2f %5.1f %6.1f %7.1f %7.1f %7.1f %9d" % (
                ("%.1f" % s["t"]) if s["t"] is not None else "?", ph, s["screen"][:12], s["frames"], s["px"],
                s["minstr"], cpi(s), s["idle"], s["sdram"], s["flash"], s["other"], s["beats"]))
    print()
    print("phase      n   Minstr/s   CPI  idle%  sdram%  flash%  other%  fps   beats/s  (medians)")
    for ph in ("boot", "phone", "game", "gameplay"):
        ss = phases.get(ph, [])
        if not ss:
            continue
        med = lambda k: statistics.median(x[k] for x in ss)  # noqa: E731
        print("%-8s %4d %9.2f %5.1f %6.1f %7.1f %7.1f %7.1f %4.0f %9.0f" % (
            ph, len(ss), med("minstr"), statistics.median(cpi(x) for x in ss), med("idle"),
            med("sdram"), med("flash"), med("other"), med("frames"), med("beats")))


if __name__ == "__main__":
    main()
