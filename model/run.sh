#!/bin/zsh
# Run the N-Gage QD reference model.
# Usage: model/run.sh [-g] [-w] [-t SECONDS] [-- extra qemu args]
#   -g   wait for GDB on :1234 (arm-none-eabi-gdb -ex 'target remote :1234')
#   -w   show the LCD in a window (cocoa); default is no display
#   -t   stop after SECONDS of wall time (default: run until killed)
# Environment:
#   NGAGE_FLASH0  CS0 image (default research/firmware/images/nor/rh29-4.60-cs0-model.bin)
#   NGAGE_FLASH1  CS1 image (default research/firmware/images/nor/rh29-4.60-cs1.bin)
#   NGAGE_OUT     output directory for logs and screenshots (default model/.out)
#   NGAGE_MMC     game-card image (raw); CID/CSD from <image>.cid / <image>.csd
#   NGAGE_TRACE   lo-hi[:lo-hi] physical ranges whose every access goes to regs.log
#   NGAGE_SHOT    screenshot period in seconds (0 = only on exit; default: off)
set -euo pipefail
cd "$(dirname "$0")/.."

gdb=()
display=(-display none)
timeout=0
while getopts "gwt:" opt; do
    case $opt in
        g) gdb=(-S -s) ;;
        w) display=(-display cocoa) ;;
        t) timeout=$OPTARG ;;
        *) exit 1 ;;
    esac
done
shift $((OPTIND - 1))
[[ "${1:-}" == "--" ]] && shift

source model/args.sh
cmd=("${qemu[@]}" "${display[@]}" -monitor none "${gdb[@]}" "$@")
if (( timeout > 0 )); then
    timeout -s INT "$timeout" "${cmd[@]}" || true
else
    "${cmd[@]}"
fi
