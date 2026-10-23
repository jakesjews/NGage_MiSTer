#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Scripted keys and captures on the MiSTer, for measuring a game in play.

    tools/game_keys.py OUTDIR action ...

actions: "load GAME [CORE]"   load /media/fat/_Console/.../CORE-GAME.mgl (CORE
                              default NGageDbg; the load time is kept in
                              OUTDIR/t0 for the following invocations)
         "tap KEY"            a key tap
         "hold KEY MS"        a key held MS milliseconds (games poll the keypad
                              once a frame and miss a short tap: hold 500)
         "wait S"             sleep
         "shot NAME"          capture OUTDIR/NAME.png and print the overlay's
                              per-second counters from it
         "every PERIOD COUNT NAME"  COUNT captures PERIOD s apart, the counters
                              to OUTDIR/NAME.csv

Keys and captures go through tools/mister_input.py on the board, as
tools/jev_play.py sends them, with no model choosing anything: the keys are
the script's. The debug overlay is on from the core's first picture through
the core's config file (jev_play.overlay_cfg), which is removed when the
invocation ends unless more actions follow ("load" keeps it until an
invocation with no "load" ends). Times printed are seconds after the load on
the MiSTer's clock, like tools/boot_profile.py. A session that measured Sonic
N and Asphalt in play: docs/PROGRESS-LOG.md, 2026-10-22, game speed.
"""
import csv, re, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from jev_play import Board, decode_overlay, load_launcher, overlay_cfg  # noqa: E402

PAT = re.compile(r"(\d+) frames, (\d+) px, ([\d.]+) M instr, idle ([\d.]+)%, bus wait sdram ([\d.]+)% flash ([\d.]+)% other ([\d.]+)%, (\d+) beats")
CLK = 104e6


def fmt(t, text):
    m = PAT.search(text) if text else None
    if not m:
        return f"{t:7.1f}s  (no counters)"
    fr, px, mi, idle, sd, fl, ot, beats = m.groups()
    mi = float(mi)
    busy = CLK * (1 - float(idle) / 100)
    cpi = busy / (mi * 1e6) if mi > 0 else 0
    stalls = text.split(" | stalls: ", 1)[1] if " | stalls: " in text else ""
    return (f"{t:7.1f}s  {int(fr):3d} fps  {int(px):7d} px  {mi:6.2f} Minstr/s  CPI {cpi:5.1f}  idle {float(idle):5.1f}%  wait sdram {float(sd):5.1f}% flash {float(fl):5.1f}% other {float(ot):4.1f}%  {int(beats):8d} beats"
            + (f"\n           stalls: {stalls}" if stalls else ""))


def main():
    out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
    t0f = out / "t0"
    t0 = float(t0f.read_text()) if t0f.exists() else 0.0
    b = Board()
    loaded = False
    try:
        for a in sys.argv[2:]:
            op, *args = a.split()
            if op == "load":
                overlay_cfg(True)
                loaded = True
                t0 = load_launcher(args[0], args[1] if len(args) > 1 else "NGageDbg")
                t0f.write_text(str(t0))
                print(f"loaded {args[0]} at MiSTer time {t0:.1f}", flush=True)
            elif op == "tap":
                t = b.press(args[0]) - t0
                print(f"{t:7.1f}s  tap {args[0]}", flush=True)
            elif op == "hold":
                t = b.press(args[0], int(args[1])) - t0
                print(f"{t:7.1f}s  hold {args[0]} {args[1]} ms", flush=True)
            elif op == "wait":
                time.sleep(float(args[0]))
            elif op == "shot":
                p = out / f"{args[0]}.png"
                t = b.shot(p) - t0
                print(fmt(t, decode_overlay(p)) + f"   [{args[0]}]", flush=True)
            elif op == "every":
                period, count, name = float(args[0]), int(args[1]), args[2]
                w = csv.writer(open(out / f"{name}.csv", "a", newline=""))
                nxt = time.time()
                for i in range(count):
                    while time.time() < nxt:
                        time.sleep(0.2)
                    nxt += period
                    p = out / f"{name}-{i:03d}.png"
                    t = b.shot(p) - t0
                    text = decode_overlay(p)
                    print(fmt(t, text), flush=True)
                    m = PAT.search(text) if text else None
                    w.writerow([f"{t:.1f}"] + (list(m.groups()) if m else []) + [p.name])
            else:
                print("unknown action", a)
    finally:
        b.close()
        if not loaded:
            overlay_cfg(False)


if __name__ == "__main__":
    main()
