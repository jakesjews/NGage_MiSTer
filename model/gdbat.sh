#!/bin/zsh
# Run the model for N seconds, then attach GDB and run command files.
# Usage: model/gdbat.sh SECONDS CMDFILE [CMDFILE...]
# Each file runs even if an earlier one stops on an error.
set -euo pipefail
cd "$(dirname "$0")/.."
secs=$1
shift
xs=()
for f in "$@"; do xs+=(-x "$f"); done
source model/args.sh
"${qemu[@]}" -display none -monitor none -s &
qpid=$!
sleep "$secs"
timeout -s KILL 60 arm-none-eabi-gdb -q -batch -nx \
    -ex 'set architecture armv4t' -ex 'set pagination off' -ex 'target remote :1234' \
    "${xs[@]}" 2>&1 | grep -v "^warning" || true
kill $qpid 2>/dev/null || true
wait $qpid 2>/dev/null || true
