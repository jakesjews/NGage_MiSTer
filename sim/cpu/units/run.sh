#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Independently written front-end checks against source and generated Verilog.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
build=$root/sim/cpu/build/units-frontend
mkdir -p "$build"
sources=("$root"/rtl/cpu/arm925t_{fetch,predict}.sv "$root/rtl/cpu/arm925t_ram_nopipe.sv")
for bench in predict fetch; do
    top=arm925t_$bench
    [[ $bench != predict ]] || top=arm925t_predict
    sv2v -DSYNTHESIS --top="$top" "${sources[@]}" > "$build/$bench-gen.v"
    for rtl in sv gen; do
        inputs=("${sources[@]}")
        [[ $rtl == sv ]] || inputs=("$build/$bench-gen.v")
        # One configuration, the core's: the modules' own defaults.
        dir=$build/$bench-$rtl
        verilator --binary --timing --assert -j 8 -Wall -Wno-DECLFILENAME \
            --top-module "${bench}_tb" --Mdir "$dir" \
            "${inputs[@]}" "$root/sim/cpu/units/${bench}_tb.sv" > "$dir.log" 2>&1 || {
            cat "$dir.log"; exit 1;
        }
        "$dir/V${bench}_tb"
    done
done
