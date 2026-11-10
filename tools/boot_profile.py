#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Profile a boot on the MiSTer with the debug overlay's per-second counters.

    tools/boot_profile.py LAUNCHER [--seconds 230] [--period 2] [--out DIR] [--keys t=KEY,...]

Loads /media/fat/_Console/LAUNCHER.mgl with the debug overlay on from the
core's first picture (the core's config file, jev_play.overlay_cfg; removed
at the end), switches it on through the OSD if the captures ever stop
decoding, and captures the panel every --period seconds for --seconds, through
tools/mister_input.py on the board (Main's own screenshot; no Zaparoo, no
model deciding anything). Every capture is decoded with tools/mister_dbg.py
and the counters go to DIR/profile.csv (seconds since the load on the
MiSTer's clock, frames, pixels, instructions, idle %, bus wait % by target,
beats); the captures stay in DIR as NNNN-tSSS.png. --keys sends keys at
given seconds after the load, e.g. --keys 185=enter,190=enter to accept the
Time and Date dialogs blind. The summary printed at the end is the same
timeline tools/jev_profile.py shows.
"""
import argparse, csv, re, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from jev_play import Board, decode_overlay, load_launcher, overlay_cfg  # noqa: E402

PAT = re.compile(r"(\d+) frames, (\d+) px, ([\d.]+) M instr, idle ([\d.]+)%, bus wait sdram ([\d.]+)% flash ([\d.]+)% other ([\d.]+)%, (\d+) beats")
CLK = 104_000_000


def overlay_on(board):
    # The fallback when the config file did not take: OSD rows before "Debug
    # overlay" (NGage.sv CONF_STR): the six file slots (F1-F4, S0, S1),
    # Rotate, Aspect ratio, Scandoubler Fx, Vertical Crop, Crop Offset,
    # Scale; the crop rows are selectable in a profile run
    # (upright, scandoubler off). Never while a launcher is still loading:
    # an Enter into the MGL sequencer leaves a file entry's browser pending,
    # and a later Enter meant for the phone selects the first file listed
    # (RH2946.0C1 was re-sent that way on 2026-10-23). Two escapes close
    # the OSD from a browser as well as from the menu.
    for k in ["f12"] + ["down"] * 12 + ["enter", "esc", "esc"]:
        board.press(k)
        time.sleep(0.4)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("launcher")
    ap.add_argument("--seconds", type=float, default=230)
    ap.add_argument("--period", type=float, default=2)
    ap.add_argument("--out")
    ap.add_argument("--keys", default="", help="t=key,... pressed at t seconds after the load")
    a = ap.parse_args()
    out = Path(a.out or f"build/hardware/boot/{a.launcher}")
    out.mkdir(parents=True, exist_ok=True)
    keys = sorted((float(t), k) for t, k in (x.split("=") for x in a.keys.split(",") if x))
    board = Board()
    core, game = a.launcher.split("-", 1)
    overlay_cfg(True)
    t0 = load_launcher(game, core)
    print(f"loaded {a.launcher} at MiSTer time {t0:.1f}", flush=True)
    w = csv.writer(open(out / "profile.csv", "w", newline=""))
    w.writerow(["t", "frames", "px", "minstr", "idle", "sdram", "flash", "other", "beats", "file"])
    n, undecoded, on, walked = 0, 0, False, False
    nxt = time.time() + 8
    while True:
        now = time.time()
        if now < nxt:
            time.sleep(min(nxt - now, 0.5))
            continue
        nxt += a.period
        n += 1
        tmp = out / f"{n:04d}.png"
        try:
            t = board.shot(tmp) - t0
        except RuntimeError as e:
            print(f"capture failed: {e}", flush=True)
            continue
        final = out / f"{n:04d}-t{t:03.0f}.png"
        tmp.rename(final)
        text = decode_overlay(final)
        while keys and keys[0][0] <= t:
            tk = board.press(keys[0][1]) - t0
            print(f"  key {keys[0][1]} at {tk:.1f} s", flush=True)
            keys.pop(0)
        m = PAT.search(text) if text else None
        if m:
            frames, px, minstr, idle, sd, fl, ot, beats = m.groups()
            w.writerow([f"{t:.1f}", frames, px, minstr, idle, sd, fl, ot, beats, final.name])
            cpi = CLK * (1 - float(idle) / 100) / (float(minstr) * 1e6) if float(minstr) > 0 else float("nan")
            print(f"{t:6.1f}s  {int(frames):3d} fps  {float(minstr):6.2f} M instr/s  CPI {cpi:5.1f}  idle {float(idle):5.1f}%  wait sdram {float(sd):5.1f}% flash {float(fl):5.1f}% other {float(ot):4.1f}%  {int(beats):8d} beats", flush=True)
            undecoded, on = 0, True
        else:
            undecoded += 1
            print(f"{t:6.1f}s  (no counters: overlay {'lost' if on else 'not on yet'})", flush=True)
            if undecoded >= 3 and t > 45 and not walked:
                overlay_on(board)    # once, and only well after the launcher's loads
                undecoded, walked = 0, True
        if t >= a.seconds:
            break
    board.close()
    overlay_cfg(False)
    print("profile in", out / "profile.csv")


if __name__ == "__main__":
    main()
