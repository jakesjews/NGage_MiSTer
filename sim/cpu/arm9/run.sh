#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Independent execute reference checks, source and sv2v netlist, one at a time.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
build=$root/sim/cpu/build/arm9-execute
mkdir -p "$build"
sv2v -DSYNTHESIS --top=arm9_execute "$root"/rtl/cpu/arm9/arm9_{execute,forward,shift,alu}.sv > "$build/execute_gen.v"
for rtl in sv gen; do
    sources=("$root"/rtl/cpu/arm9/arm9_{execute,forward,shift,alu}.sv)
    [[ $rtl == sv ]] || sources=("$build/execute_gen.v")
    for split in 0 1; do
        dir=$build/$rtl-$split
        mkdir -p "$dir"
        verilator --cc --exe --build -j 8 -Wall -Wno-DECLFILENAME \
            --top-module arm9_execute -GPRE_SHIFTED=$split --Mdir "$dir" \
            -CFLAGS "-O2 -std=c++17 -DPRE_SHIFTED=$split" \
            "${sources[@]}" "$root/sim/cpu/arm9/execute_test.cpp" > "$dir/build.log" 2>&1 || {
                cat "$dir/build.log"; exit 1;
            }
        "$dir/Varm9_execute"
    done
done
