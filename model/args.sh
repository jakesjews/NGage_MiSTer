# Shared QEMU command line for run.sh, where.sh and sample.sh (sourced, zsh).
# Sets the array "qemu" from NGAGE_FLASH0/1, NGAGE_SAVE1 and NGAGE_OUT.
flash0=${NGAGE_FLASH0:-research/firmware/images/nor/rh29-4.60-cs0-model.bin}
flash1=${NGAGE_FLASH1:-research/firmware/images/nor/rh29-4.60-cs1.bin}
out=${NGAGE_OUT:-model/.out}
mkdir -p "$out"
machine="ngage-qd,flash0=$flash0,flash1=$flash1,probe-log=$out/probe.log,upp-log=$out/regs.log"
# C: drive persistence: CS1 starts from $out/cs1-save.bin when it exists and is
# saved there on exit after any flash write. NGAGE_SAVE1=none starts from the image.
save1=${NGAGE_SAVE1:-$out/cs1-save.bin}
[[ "$save1" != none ]] && machine+=",flash1-save=$save1"
machine+=",quirks=model/upp-quirks.txt,cbus-regs=model/cbus-regs.txt,cbus-log=$out/cbus.log"
machine+=",rom-patches=${NGAGE_PATCHES:-model/rom-patches.txt},kern-log=$out/kern.log,mmc-log=$out/mmc.log"
[[ -n "${NGAGE_TRACE:-}" ]] && machine+=",trace=$NGAGE_TRACE"
[[ -n "${NGAGE_KEYS:-}" ]] && machine+=",keys=$NGAGE_KEYS"
[[ -n "${NGAGE_MMC:-}" ]] && machine+=",mmc=$NGAGE_MMC"
machine+=",lcd-log=$out/lcd.log,shot-dir=$out,screenshot=${NGAGE_SHOT:-0}"
# Guest-time stamps: kern.log one line per kernel message, cbus.log lines,
# each led by the guest time in seconds. NGAGE_LOGTIME=off gives the bare
# text (as the hardware's STI ring holds it) and the boot bench's CBUS format.
machine+=",log-time=${NGAGE_LOGTIME:-on}"
# NGAGE_PCSAMPLE=FILE: guest time, PC and mode every guest millisecond.
[[ -n "${NGAGE_PCSAMPLE:-}" ]] && machine+=",pc-sample=$NGAGE_PCSAMPLE"
# HLE audio device (an emulator invention): what it plays goes to audio.wav;
# NGAGE_AUDIO=coreaudio (or another -audiodev driver) also plays it on the host.
machine+=",audio-wav=$out/audio.wav,audio-log=$out/audio.log"
audiodev=()
if [[ -n "${NGAGE_AUDIO:-}" && "${NGAGE_AUDIO}" != none ]]; then
    audiodev=(-audiodev "${NGAGE_AUDIO},id=snd0")
    machine+=",audiodev=snd0"
fi
# The UEMK RTC starts at the QEMU RTC: local time unless NGAGE_RTC says otherwise
# (a -rtc base= value, e.g. 2004-06-01T12:00:00).
qemu=(model/.build/qemu-system-arm "${audiodev[@]}" -M "$machine" -serial none
      -rtc "base=${NGAGE_RTC:-localtime}"
      -d guest_errors,unimp -D "$out/qemu.log")
# Guest time follows executed instructions (16 ns each, about 62 MIPS) and
# skips ahead when the CPU idles: timers fire on time however busy the host
# is (medint.pdd programs C: one word per 14.7 us timer FIQ) and runs repeat.
# NGAGE_ICOUNT=none uses wall-clock time instead.
icount=${NGAGE_ICOUNT:-shift=4,sleep=off}
[[ "$icount" != none ]] && qemu+=(-icount "$icount")
# NGAGE_EXCLOG=FILE: every exception, interrupt and CP15 write with the
# count of instructions executed (plugins/excprof.c; tools/excstat.py).
# FILE,footprint=on adds the code and data pages touched between the
# kernel's D-TLB invalidations (several times slower).
if [[ -n "${NGAGE_EXCLOG:-}" ]]; then
    qemu+=(-plugin "model/.build/excprof.so,out=$NGAGE_EXCLOG")
fi
# NGAGE_DCSIM=FILE,t0=SEC,t1=SEC: the data accesses of guest seconds t0 to
# t1 through simulated data caches (plugins/dcsim.c; tools/dcstat.py).
if [[ -n "${NGAGE_DCSIM:-}" ]]; then
    qemu+=(-plugin "model/.build/dcsim.so,out=$NGAGE_DCSIM")
fi
