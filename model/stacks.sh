#!/bin/zsh
# Run the model N seconds, then list each thread's user-stack return
# addresses (model/tools/kstacks.py): where blocked threads wait.
# Usage: model/stacks.sh [SECONDS] [HEAP_KB]  (defaults 30 and 2048)
# Two GDB sessions on the same run: the first dumps the kernel heap, the
# second dumps the stacks the first one located.
set -euo pipefail
cd "$(dirname "$0")/.."
out=${NGAGE_OUT:-model/.out}
pages=$(( ${2:-2048} / 4 ))
rm -rf "$out/kpages" "$out"/stk-*.bin(N)
mkdir -p "$out/kpages"
cmds=()
for (( i = 0; i < pages; i++ )); do
    a=$(( 0x80400000 + i * 0x1000 ))
    f=$(printf '%s/kpages/p%04d.gdb' "$out" $i)
    printf 'dump binary memory %s/kpages/p%04d.bin 0x%x 0x%x\n' "$out" $i $a $(( a + 0x1000 )) > "$f"
    cmds+=(-x "$f")
done
gdb=(timeout -s KILL 120 arm-none-eabi-gdb -q -batch -nx
    -ex 'set architecture armv4t' -ex 'set pagination off' -ex 'target remote :1234')
source model/args.sh
"${qemu[@]}" -display none -monitor none -s &
qpid=$!
sleep "${1:-30}"
"${gdb[@]}" -x model/gdb/dumpkern.gdb "${cmds[@]}" >/dev/null 2>&1 || true
python3 -I model/tools/kstacks.py "$out" gdb
"${gdb[@]}" ${(z)$(printf -- '-x %s ' "$out"/kstk/*.gdb(N))} >/dev/null 2>&1 || true
kill $qpid 2>/dev/null || true
wait $qpid 2>/dev/null || true
python3 -I model/tools/kstacks.py "$out" decode
