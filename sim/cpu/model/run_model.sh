#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run the reference model built by build_linux.sh on a set of flash images
# (the firmware as it is), with guest time following executed instructions
# as model/args.sh sets it.
#
#   run_model.sh DIR RUN SECONDS [TRACE_ARGS]
#
# DIR: the build_linux.sh directory. RUN: holds cs0.bin, cs1.bin, c.vhd (the
# C: drive), pmm.vhd, upp-quirks.txt and cbus-regs.txt; the logs go there.
# The model works on copies of c.vhd and pmm.vhd (c-run.vhd, pmm-run.vhd), so
# that every run starts from the same two files. TRACE_ARGS: options for
# trace_plugin.c (start=N,count=M[,regs=0][,stop=1]), built here.
set -euo pipefail
dir=$(cd "$1" && pwd)
run=$(cd "$2" && pwd)
secs=$3
trace=${4:-}
qemu=$dir/build/qemu-system-arm

m="ngage-qd,flash0=$run/cs0.bin,flash1=$run/cs1.bin,probe-log=$run/probe.log,upp-log=$run/regs.log"
m+=",quirks=$run/upp-quirks.txt,cbus-regs=$run/cbus-regs.txt,cbus-log=$run/cbus.log"
cp "$run/c.vhd" "$run/c-run.vhd"
cp "$run/pmm.vhd" "$run/pmm-run.vhd"
m+=",c-drive=$run/c-run.vhd,pmm=$run/pmm-run.vhd,mdi-log=$run/mdi.log,sim-log=$run/sim.log,bt-log=$run/bt.log"
m+=",kern-log=$run/kern.log,mmc-log=$run/mmc.log,lcd-log=$run/lcd.log,shot-dir=$run,screenshot=0"
# MODEL_MMC: a game card (the model's raw image with .cid/.csd beside it);
# MODEL_KEYS: a key script; MODEL_SHOT: a screenshot every N guest seconds
[[ -n ${MODEL_MMC:-} ]] && m+=",mmc=$MODEL_MMC"
[[ -n ${MODEL_KEYS:-} ]] && m+=",keys=$MODEL_KEYS"
[[ -n ${MODEL_SHOT:-} ]] && m="${m/screenshot=0/screenshot=$MODEL_SHOT}"
m+=",audio-wav=$run/audio.wav,audio-log=$run/audio.log"
args=(-M "$m" -serial none -display none -monitor none -icount shift=4,sleep=off
      -rtc base=2004-06-01T12:00:00 -d guest_errors,unimp -D "$run/qemu.log")
if [[ -n $trace ]]; then
	cflags=$(PKG_CONFIG_PATH=$dir/deps/root/usr/lib/x86_64-linux-gnu/pkgconfig pkg-config --cflags glib-2.0)
	gcc -O2 -shared -fPIC -I "$dir/qemu-src/include/plugins" $cflags \
		-o "$dir/libtrace_plugin.so" "$dir/tools/trace_plugin.c"
	args+=(-plugin "$dir/libtrace_plugin.so,out=$run/trace.log,$trace")
fi
rm -f "$run"/*.log
timeout -s INT "$secs" "$qemu" "${args[@]}" || true
ls -la "$run"
