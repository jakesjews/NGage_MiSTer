#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
build=$root/sim/cpu/build/arm9v2-execute
mkdir -p "$build"
sources=("$root/rtl/cpu/arm9v2/arm9v2_execute.sv" "$root/rtl/cpu/arm9v2/arm9v2_forward.sv" "$root/rtl/cpu/arm9v2/arm9v2_rotate.sv" "$root/rtl/cpu/arm9/arm9_alu.sv" "$root/rtl/cpu/arm9/arm9_shift.sv")
sv2v "${sources[@]}" > "$build/execute-gen.v"
for rtl in sv gen; do
    inputs=("${sources[@]}");warnings=()
    [[ $rtl == sv ]] || { inputs=("$build/execute-gen.v");warnings=(-Wno-UNUSEDSIGNAL); }
    dir=$build/$rtl
    verilator --binary --timing --assert -j 8 -Wall -Wno-DECLFILENAME ${warnings[@]+"${warnings[@]}"} \
        --top-module execute_tb --Mdir "$dir" "${inputs[@]}" \
        "$root/sim/cpu/arm9v2/execute_tb.sv" > "$dir.log" 2>&1 || { cat "$dir.log";exit 1; }
    "$dir/Vexecute_tb"
done
