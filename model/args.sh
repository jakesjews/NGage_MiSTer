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
qemu=(model/.build/qemu-system-arm -M "$machine" -serial none
      -d guest_errors,unimp -D "$out/qemu.log")
