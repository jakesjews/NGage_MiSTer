# Shared QEMU command line for run.sh, where.sh and sample.sh (sourced, zsh).
# Sets the array "qemu" from NGAGE_FLASH0/1 and NGAGE_OUT.
flash0=${NGAGE_FLASH0:-research/firmware/images/nor/rh29-4.60-cs0-model.bin}
flash1=${NGAGE_FLASH1:-research/firmware/images/nor/rh29-4.60-cs1.bin}
out=${NGAGE_OUT:-model/.out}
mkdir -p "$out"
machine="ngage-qd,flash0=$flash0,flash1=$flash1,probe-log=$out/probe.log,upp-log=$out/regs.log"
machine+=",quirks=model/upp-quirks.txt,cbus-regs=model/cbus-regs.txt,cbus-log=$out/cbus.log"
machine+=",rom-patches=${NGAGE_PATCHES:-model/rom-patches.txt},kern-log=$out/kern.log,mmc-log=$out/mmc.log"
[[ -n "${NGAGE_TRACE:-}" ]] && machine+=",trace=$NGAGE_TRACE"
[[ -n "${NGAGE_MMC:-}" ]] && machine+=",mmc=$NGAGE_MMC"
[[ -n "${NGAGE_SHOT:-}" ]] && machine+=",screenshot=$NGAGE_SHOT"
qemu=(model/.build/qemu-system-arm -M "$machine" -serial none
      -d guest_errors,unimp -D "$out/qemu.log")
