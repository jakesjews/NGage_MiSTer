#!/bin/zsh
# Run the N-Gage QD reference model.
# Usage: model/run.sh [-g] [-t SECONDS] [-- extra qemu args]
#   -g   wait for GDB on :1234 (arm-none-eabi-gdb -ex 'target remote :1234')
#   -t   stop after SECONDS of wall time (default: run until killed)
# Environment:
#   NGAGE_FLASH0  CS0 image (default research/firmware/images/nor/rh29-4.60-cs0-model.bin)
#   NGAGE_FLASH1  CS1 image (default research/firmware/images/nor/rh29-4.60-cs1.bin)
#   NGAGE_OUT     output directory for logs (default model/.out)
set -euo pipefail
cd "$(dirname "$0")/.."

gdb=()
timeout=0
while getopts "gt:" opt; do
    case $opt in
        g) gdb=(-S -s) ;;
        t) timeout=$OPTARG ;;
        *) exit 1 ;;
    esac
done
shift $((OPTIND - 1))
[[ "${1:-}" == "--" ]] && shift

flash0=${NGAGE_FLASH0:-research/firmware/images/nor/rh29-4.60-cs0-model.bin}
flash1=${NGAGE_FLASH1:-research/firmware/images/nor/rh29-4.60-cs1.bin}
out=${NGAGE_OUT:-model/.out}
mkdir -p "$out"

cmd=(model/.build/qemu-system-arm -M "ngage-qd,flash0=$flash0,flash1=$flash1,probe-log=$out/probe.log,upp-log=$out/regs.log,quirks=model/upp-quirks.txt"
     -display none -serial none -monitor none -d guest_errors,unimp -D "$out/qemu.log" "${gdb[@]}" "$@")
if (( timeout > 0 )); then
    timeout -s INT "$timeout" "${cmd[@]}" || true
else
    "${cmd[@]}"
fi
