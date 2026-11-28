# Shared QEMU command line for run.sh, where.sh and sample.sh (sourced, zsh).
# Sets the array "qemu" from NGAGE_FLASH0/1, NGAGE_C, NGAGE_PMM and NGAGE_OUT.
flash0=${NGAGE_FLASH0:-research/firmware/images/nor/rh29-4.10-cs0.bin}
flash1=${NGAGE_FLASH1:-research/firmware/images/nor/rh29-4.10-cs1.bin}
out=${NGAGE_OUT:-model/.out}
mkdir -p "$out"
machine="ngage-qd,flash0=$flash0,flash1=$flash1,probe-log=$out/probe.log,upp-log=$out/regs.log"
# What the phone writes, in the core's own files: the C: drive (CS1's upper
# 4 MiB; boot0.vhd on the MiSTer) and PMM (the top 64 KiB of CS0; boot2.vhd).
# Each is loaded over the image at the start and written back on exit after
# a flash write to it. A missing file starts as the release's: an erased C:
# and the PMM of a phone before its first start, with which the firmware
# formats C: itself. "none" leaves the image's own bytes and saves nothing.
cdrive=${NGAGE_C:-$out/c.vhd}
pmm=${NGAGE_PMM:-$out/pmm.vhd}
if [[ "$cdrive" != none ]]; then
    [[ -f "$cdrive" ]] || cp releases/boot0.vhd "$cdrive"
    machine+=",c-drive=$cdrive"
fi
if [[ "$pmm" != none ]]; then
    [[ -f "$pmm" ]] || cp releases/boot2.vhd "$pmm"
    machine+=",pmm=$pmm"
fi
machine+=",quirks=model/upp-quirks.txt,cbus-regs=model/cbus-regs.txt,cbus-log=$out/cbus.log"
# The Bluetooth module's resets and the HCI packets either way ("HCI<" from
# the phone, "HCI>" to it).
machine+=",bt-log=$out/bt.log"
# What the DSP's side of the MDI link does (its announcement, version
# replies, PCM playback) and the SIM card's selects.
machine+=",mdi-log=$out/mdi.log,sim-log=$out/sim.log"
machine+=",kern-log=$out/kern.log,mmc-log=$out/mmc.log"
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
# What the DSP plays goes to audio.wav; NGAGE_AUDIO=coreaudio (or another
# -audiodev driver) also plays it on the host.
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
