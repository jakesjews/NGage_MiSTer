#!/bin/zsh
# Run the model for N seconds, then stop it under GDB and show where the
# CPU is: registers, CP15 control, code around the PC and the call return
# address. Usage: model/where.sh [SECONDS]  (default 3)
set -euo pipefail
cd "$(dirname "$0")/.."
secs=${1:-3}
out=${NGAGE_OUT:-model/.out}
mkdir -p "$out"
flash0=${NGAGE_FLASH0:-research/firmware/images/nor/rh29-4.60-cs0-model.bin}
flash1=${NGAGE_FLASH1:-research/firmware/images/nor/rh29-4.60-cs1.bin}
model/.build/qemu-system-arm -M "ngage-qd,flash0=$flash0,flash1=$flash1,probe-log=$out/probe.log,upp-log=$out/regs.log,quirks=model/upp-quirks.txt" \
    -display none -serial none -monitor none -d guest_errors,unimp -D "$out/qemu.log" -s &
qpid=$!
sleep "$secs"
# Extra GDB commands, one per line, in NGAGE_GDB_EXTRA.
extra=()
for c in "${(@f)${NGAGE_GDB_EXTRA:-}}"; do
    [[ -n "$c" ]] && extra+=(-ex "$c")
done
arm-none-eabi-gdb -q -batch -nx \
    -ex 'set architecture armv4t' -ex 'target remote :1234' \
    -ex 'info registers r0 r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11 r12 sp lr pc cpsr' -ex 'x/12i $pc-24' -ex 'x/4i $lr-8' \
    "${extra[@]}" 2>&1 | grep -v "^warning" || true
kill $qpid 2>/dev/null || true
wait $qpid 2>/dev/null || true
