#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run the reference model built by build_linux.sh on the boot bench's
# images (same CS0/CS1, patches already applied, C: drive not saved), with
# guest time following executed instructions as model/args.sh sets it.
#
#   run_model.sh DIR RUN SECONDS [TRACE_ARGS]
#
# DIR: the build_linux.sh directory. RUN: holds cs0.bin, cs1.bin,
# upp-quirks.txt and cbus-regs.txt; the logs go there. TRACE_ARGS: options
# for trace_plugin.c (start=N,count=M[,regs=0][,stop=1]), built here.
set -euo pipefail
dir=$(cd "$1" && pwd)
run=$(cd "$2" && pwd)
secs=$3
trace=${4:-}
qemu=$dir/build/qemu-system-arm

m="ngage-qd,flash0=$run/cs0.bin,flash1=$run/cs1.bin,probe-log=$run/probe.log,upp-log=$run/regs.log"
m+=",quirks=$run/upp-quirks.txt,cbus-regs=$run/cbus-regs.txt,cbus-log=$run/cbus.log"
m+=",kern-log=$run/kern.log,mmc-log=$run/mmc.log,lcd-log=$run/lcd.log,shot-dir=$run,screenshot=0"
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
