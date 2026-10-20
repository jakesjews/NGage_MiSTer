#!/bin/zsh
# Run the model N seconds, dump kernel memory and list the EKA1 threads.
# Usage: model/threads.sh [SECONDS]  (default 8)
set -euo pipefail
cd "$(dirname "$0")/.."
out=${NGAGE_OUT:-model/.out}
rm -f "$out"/kheap*.bin
model/gdbat.sh "${1:-8}" model/gdb/dumpkern.gdb model/gdb/dumpheap{0..7}.gdb | grep -E "^(pc|lr|cpsr)" || true
python3 -I model/tools/kthreads.py "$out"
