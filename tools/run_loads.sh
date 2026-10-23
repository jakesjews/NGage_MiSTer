#!/bin/bash
# Game-load measurement on the debug core: tools/run_loads.sh TAG
# Boots each launcher to the idle screen, opens the phone menu, starts the
# card's game, then captures the panel and counters every second for two
# minutes while the game loads (no keys pressed during the capture, so the
# load up to the game's first key wait is what is measured).
#   build/hardware/game/load-thps-TAG/, build/hardware/game/load-shadowkey-TAG/
set -u
cd "$(dirname "$0")/.."
G=tools/game_keys.py
tag=$1
for g in tony-hawks-pro-skater the-elder-scrolls-travels-shadowkey; do
  case $g in tony-hawks-pro-skater) n=thps;; *) n=shadowkey;; esac
  O=build/hardware/game/load-$n-$tag
  rm -rf "$O"
  echo "=== $g"
  python3 $G $O "load $g NGageDbg" "wait 100" "shot idle" "tap f5" "wait 12" "tap down" "wait 1" "tap down" "wait 1" "tap down" "wait 1.5" "shot menu" "tap enter" \
    "every 1 120 ld" 2>&1 | grep -v "^ *[0-9.]*s  \(tap\|hold\) "
done
