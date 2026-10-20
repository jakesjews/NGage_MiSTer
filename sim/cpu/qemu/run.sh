#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run one CPU test binary on QEMU's ti925t and save what the RTL bench
# saves: the signature area and an instruction trace.
#
#   sim/cpu/qemu/run.sh TEST.bin OUT_PREFIX [TRACE]
#
# Machine: "-M none" with 16 MB of RAM at 0 and nothing else, so accesses
# outside the RAM are external aborts (as on the bench). GDB (through
# QEMU's stub on a pipe) stops at the halt loop (0x40) and dumps the
# signature area to OUT_PREFIX.sig. With TRACE=1, QEMU also logs every
# instruction with the registers before it (one instruction per TB, no TB
# chaining) to OUT_PREFIX.qlog, which tools/cmp_trace.py reads.
set -euo pipefail

bin=$1
out=$2
trace=${3:-1}
QEMU=${QEMU:-qemu-system-arm}
GDB=${GDB:-arm-none-eabi-gdb}
HALT=${HALT:-0x40}
SIG_BASE=${SIG_BASE:-0xF00000}
SIG_SIZE=${SIG_SIZE:-0x10000}
TIMEOUT=${TIMEOUT:-20}
# A test that loops (an exception loop, say) must not fill the disk with
# its log: QEMU stops when the log reaches 128 MB.
ulimit -f 131072

qargs=(-M none -cpu ti925t -m 16M -device "loader,file=$bin,addr=0"
       -nographic -monitor none -serial none -S -gdb stdio)
if [[ $trace == 1 ]]; then
	qargs+=(-accel tcg,one-insn-per-tb=on -d exec,cpu,nochain,int -D "$out.qlog")
fi
rm -f "$out.sig" "$out.qlog"

sig_end=$(printf '0x%x' $((SIG_BASE + SIG_SIZE)))
timeout "$TIMEOUT" "$GDB" -nx -batch \
	-ex "set pagination off" \
	-ex "set confirm off" \
	-ex "target remote | exec $QEMU ${qargs[*]}" \
	-ex "break *$HALT" \
	-ex "continue" \
	-ex "dump binary memory $out.sig $SIG_BASE $sig_end" \
	-ex "kill" >"$out.gdb.log" 2>&1 || true
grep -q "^Breakpoint 1, " "$out.gdb.log" || {
	echo "QEMU did not reach the halt loop for $bin (see $out.gdb.log)" >&2
	exit 1
}
[[ -s $out.sig ]] || { echo "no signature from QEMU for $bin" >&2; exit 1; }
