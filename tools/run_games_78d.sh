#!/bin/bash
# One-shot in-play measurement of Sonic N, Asphalt and Tony Hawk on the debug
# core (the overlay on; the counters print at every shot):
#   tools/run_games.sh OUTTAG  -> build/hardware/game/{sonicn,asphalt,thps}-OUTTAG/
# Timings from the 2026-10-22 runs: the save has its clock set, so the boot
# goes straight to the idle screen (~100 s); the phone menu fills in ~12 s;
# the card's game is three rows down. Sonic: the intro is skipped with 5
# (title), 5 (GAME START), 5 (Sonic at the character select), 5 (go);
# Asphalt: 5 to the race menu, four downs to Cop Chase (Instant Play is a
# random race, so runs would not compare), then 5s through its choices.
set -u
cd "$(dirname "$0")/.."
G=tools/game_keys.py
tag=$1
A=build/hardware/game/asphalt-$tag
rm -rf "$A"
echo "=== Asphalt"
python3 $G $A "load asphalt-urban-gt NGageDbg" "wait 133.3" "shot idle" "tap f1" "wait 2.0" "tap f5" "wait 16.0" "tap down" "wait 1.3" "tap down" "wait 1.3" "tap down" "wait 2.0" "shot menu" "tap enter" \
  "wait 66.7" "shot title" "hold 5 666" "wait 6.7" "shot a0" "hold down 533" "wait 1.3" "hold down 533" "wait 1.3" "hold down 533" "wait 1.3" "hold down 533" "wait 2.0" "shot a0b" "hold 5 666" "wait 6.7" "shot a1" "hold 5 666" "wait 6.7" "shot a2" "hold 5 666" "wait 6.7" "shot a2b" "hold 5 666" "wait 16.0" "shot a3" \
  "hold up 4000" "shot r0" "hold up 4000" "shot r1" "hold left 800" "hold up 4000" "shot r2" "hold up 4000" "shot r3" "hold right 800" "hold up 4000" "shot r4" \
  "hold up 4000" "shot r5" "hold 5 666" "hold up 4000" "shot r6" "hold up 4000" "shot r7" "hold left 800" "hold up 4000" "shot r8" "hold up 4000" "shot r9" 2>&1 | grep -v "^ *[0-9.]*s  \(tap\|hold\) "
H=build/hardware/game/thps-$tag
rm -rf "$H"
echo "=== Tony Hawk"
python3 $G $H "load tony-hawks-pro-skater NGageDbg" "wait 133.3" "shot idle" "tap f1" "wait 2.0" "tap f5" "wait 16.0" "tap down" "wait 1.3" "tap down" "wait 1.3" "tap down" "wait 2.0" "shot menu" "tap enter" \
  "wait 53.3" "shot intro" "hold 5 666" "wait 6.7" "shot m1" "hold 5 666" "wait 6.7" "shot m2" "hold 5 666" "wait 6.7" "shot m3" "hold 5 666" "wait 6.7" "shot m4" "hold 5 666" "wait 6.7" "shot m5" "hold 5 666" "wait 10.7" "shot course" "hold 5 666" "wait 10.7" "shot tape" \
  "hold up 4000" "shot s0" "hold 5 533" "hold up 4000" "shot s1" "hold right 1066" "hold up 4000" "shot s2" "hold 5 533" "hold up 4000" "shot s3" "hold left 1066" "hold up 4000" "shot s4" "hold 5 533" "hold up 4000" "shot s5" \
  "hold up 4000" "shot s6" "hold 5 533" "hold up 4000" "shot s7" "hold right 933" "hold up 4000" "shot s8" "hold 5 533" "hold up 4000" "shot s9" 2>&1 | grep -v "^ *[0-9.]*s  \(tap\|hold\) "
