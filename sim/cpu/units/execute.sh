#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
build=$root/sim/cpu/build/units-execute
mkdir -p "$build"
sources=("$root/rtl/cpu/arm925t_execute.sv" "$root/rtl/cpu/arm925t_forward.sv" "$root/rtl/cpu/arm925t_rotate.sv" "$root/rtl/cpu/arm925t_alu.sv" "$root/sim/cpu/units/arm9_shift.sv")
sv2v "${sources[@]}" > "$build/execute-gen.v"
for cuts in 0 1; do
for rtl in sv gen; do
    inputs=("${sources[@]}");warnings=()
    [[ $rtl == sv ]] || { inputs=("$build/execute-gen.v");warnings=(-Wno-UNUSEDSIGNAL); }
    dir=$build/$rtl-$cuts
    verilator --binary --timing --assert -j 8 -Wall -Wno-DECLFILENAME ${warnings[@]+"${warnings[@]}"} \
        --top-module execute_tb -GCUTS=$cuts --Mdir "$dir" "${inputs[@]}" \
        "$root/sim/cpu/units/execute_tb.sv" > "$dir.log" 2>&1 || { cat "$dir.log";exit 1; }
    "$dir/Vexecute_tb"
done
done
