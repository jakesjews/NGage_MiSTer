#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Independently written front-end checks against source and generated Verilog.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
build=$root/sim/cpu/build/arm9v2-frontend
mkdir -p "$build"
sources=("$root"/rtl/cpu/arm9v2/arm9v2_{fetch,predict}.sv "$root/rtl/cpu/zap/zap_ram_simple_nopipe.sv")
for bench in predict fetch; do
    top=arm9v2_$bench
    [[ $bench != predict ]] || top=arm9v2_predict
    sv2v -DSYNTHESIS --top="$top" "${sources[@]}" > "$build/$bench-gen.v"
    for rtl in sv gen; do
        inputs=("${sources[@]}")
        [[ $rtl == sv ]] || inputs=("$build/$bench-gen.v")
        configs=(1)
        [[ $bench != fetch ]] || configs=(0 1)
        for pred in "${configs[@]}"; do
            args=()
            [[ $bench != fetch ]] || args=(-GPREDICTOR=$pred)
            dir=$build/$bench-$rtl-$pred
            verilator --binary --timing --assert -j 8 -Wall -Wno-DECLFILENAME \
                --top-module "${bench}_tb" ${args[@]+"${args[@]}"} --Mdir "$dir" \
                "${inputs[@]}" "$root/sim/cpu/arm9v2/${bench}_tb.sv" > "$dir.log" 2>&1 || {
                cat "$dir.log"; exit 1;
            }
            "$dir/V${bench}_tb"
        done
    done
done
