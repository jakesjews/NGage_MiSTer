#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
build=$root/sim/cpu/build/arm9v2-execute-leaves
mkdir -p "$build"
sources=("$root/rtl/cpu/arm9v2/arm9v2_forward.sv" "$root/rtl/cpu/arm9v2/arm9v2_rotate.sv" "$root/sim/cpu/arm9v2/arm9_shift.sv")
sv2v "${sources[@]}" > "$build/leaves-gen.v"
for rtl in sv gen; do
    inputs=("${sources[@]}")
    [[ $rtl == sv ]] || inputs=("$build/leaves-gen.v")
    dir=$build/$rtl
    verilator --binary --timing --assert -j 8 -Wall -Wno-DECLFILENAME \
        --top-module execute_leaf_tb --Mdir "$dir" "${inputs[@]}" \
        "$root/sim/cpu/arm9v2/execute_leaf_tb.sv" > "$dir.log" 2>&1 || { cat "$dir.log";exit 1; }
    "$dir/Vexecute_leaf_tb"
done
