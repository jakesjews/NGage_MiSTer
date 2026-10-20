#!/bin/zsh
# Run the model N seconds, dump kernel memory and list the EKA1 threads.
# Usage: model/threads.sh [SECONDS]  (default 8)
set -euo pipefail
cd "$(dirname "$0")/.."
model/gdbat.sh "${1:-8}" model/gdb/dumpkern.gdb | grep -E "^(pc|lr|cpsr)" || true
python3 -I model/tools/kthreads.py "${NGAGE_OUT:-model/.out}"
