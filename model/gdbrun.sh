#!/bin/zsh
# Start the model halted, run a GDB command file against it, then stop it.
# Usage: model/gdbrun.sh CMDFILE [TIMEOUT_SECONDS]   (default 30)
# The command file runs after "target remote"; use "continue" with
# breakpoints. GDB is killed after the timeout.
set -euo pipefail
cd "$(dirname "$0")/.."
cmds=$1
lim=${2:-30}
source model/args.sh
"${qemu[@]}" -display none -monitor none -s -S &
qpid=$!
sleep 0.3
timeout -s KILL "$lim" arm-none-eabi-gdb -q -batch -nx \
    -ex 'set architecture armv4t' -ex 'set pagination off' -ex 'target remote :1234' \
    -x "$cmds" 2>&1 | grep -v "^warning" || true
kill $qpid 2>/dev/null || true
wait $qpid 2>/dev/null || true
