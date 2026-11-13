#!/bin/zsh
# Run the N-Gage QD reference model.
# Usage: model/run.sh [-g] [-w] [-t SECONDS] [-- extra qemu args]
#   -g   wait for GDB on :1234 (arm-none-eabi-gdb -ex 'target remote :1234')
#   -w   show the LCD in a window (cocoa); default is no display
#   -t   stop after SECONDS of wall time (default: run until killed); guest
#        time runs ahead of it while the guest idles (see NGAGE_ICOUNT)
# Environment:
#   NGAGE_FLASH0  CS0 image (default research/firmware/images/nor/rh29-4.10-cs0.bin)
#                 as flash stores it: the model decodes the scrambled area the
#                 image names at 0x174, as the phone's ASIC does on reads
#   NGAGE_FLASH1  CS1 image (default research/firmware/images/nor/rh29-4.10-cs1.bin)
#   NGAGE_OUT     output directory for logs and screenshots (default model/.out)
#   NGAGE_SAVE1   CS1 save file, the C: drive (default $NGAGE_OUT/cs1-save.bin):
#                 used instead of NGAGE_FLASH1 when present, written on exit
#                 after flash writes; "none" disables it. The image has no C:
#                 file system: format it once with NGAGE_KEYS=model/keys/format-c.txt
#   NGAGE_MMC     game-card image (raw); CID/CSD from <image>.cid / <image>.csd
#   NGAGE_TRACE   lo-hi[:lo-hi] physical ranges whose every access goes to regs.log
#   NGAGE_SHOT    LCD screenshot period in guest seconds (default 0 = only on exit)
#   NGAGE_LOGTIME on (default): kern.log has a line per kernel message and
#                 cbus.log a leading column, the guest time in seconds;
#                 off: kern.log is the bare text, as on the hardware
#   NGAGE_PCSAMPLE file for a PC sample every guest millisecond: "<guest
#                 seconds> <pc> <mode>" (busy and idle stretches on the clock)
#   NGAGE_EXCLOG  file for a record of every exception, interrupt and CP15
#                 write with the instruction count (model/plugins/excprof.c);
#                 model/tools/excstat.py turns it into kernel calls, process
#                 switches and cache/TLB flushes per second
#   NGAGE_DCSIM   FILE,t0=SEC,t1=SEC: the data accesses of guest seconds t0
#                 to t1 through simulated data caches of several sizes, with
#                 and without a next-line prefetch (model/plugins/dcsim.c);
#                 model/tools/dcstat.py prints the report
#   NGAGE_ICOUNT  QEMU -icount setting (default shift=4,sleep=off: 16 ns per
#                 instruction, idle time skipped); "none" for wall-clock time
#   NGAGE_AUDIO   host audio driver for the HLE audio device, e.g. coreaudio
#                 (default none; $NGAGE_OUT/audio.wav and audio.log are always
#                 written). Host playback keeps pace only when guest time runs
#                 in real time: NGAGE_ICOUNT=shift=4,sleep=on,align=on
#   NGAGE_RTC     start of the UEMK real-time clock, a -rtc base= value
#                 (default localtime; e.g. 2004-06-01T12:00:00)
#   NGAGE_KEYS    key script: lines "<guest seconds> down|up <key>"; keys: up down
#                 left right ok lsk rsk menu call end clear edit 0-9 star hash
#                 power (held for the first 3 guest seconds, as at switch-on)
# Window keys (-w): arrows, Return = OK, F1/F2 soft keys, F3 Menu, F4 Call,
# F5/Esc End, F6 Power, Backspace Clear, Shift Edit, digits, keypad * and / for * and #.
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
