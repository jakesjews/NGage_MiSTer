#!/bin/zsh
# Run the model N seconds, dump kernel memory and list the EKA1 threads.
# Usage: model/threads.sh [SECONDS] [HEAP_KB]  (defaults 8 and 2048)
# The kernel heap (0x80400000 on) is committed sparsely, so it is dumped one
# 4 KB page per GDB command file; pages GDB cannot read are left out.
set -euo pipefail
cd "$(dirname "$0")/.."
out=${NGAGE_OUT:-model/.out}
pages=$(( ${2:-2048} / 4 ))
rm -rf "$out"/kheap*.bin(N) "$out/kpages"
mkdir -p "$out/kpages"
cmds=()
for (( i = 0; i < pages; i++ )); do
    a=$(( 0x80400000 + i * 0x1000 ))
    f=$(printf '%s/kpages/p%04d.gdb' "$out" $i)
    printf 'dump binary memory %s/kpages/p%04d.bin 0x%x 0x%x\n' "$out" $i $a $(( a + 0x1000 )) > "$f"
    cmds+=("$f")
done
model/gdbat.sh "${1:-8}" model/gdb/dumpkern.gdb "${cmds[@]}" 2>&1 | grep -E "^(pc|lr|cpsr)" || true
python3 -I model/tools/kthreads.py "$out"
