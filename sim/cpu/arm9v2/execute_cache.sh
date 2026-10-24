#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
build=$root/sim/cpu/build/arm9v2-execute-cache
mkdir -p "$build"
# Generate only V2; the committed CPU netlist supplies the shared I-cache,
# Thumb expansion, RF and ALU modules in both runs.
sv2v --top=arm9v2_front_execute "$root"/rtl/cpu/arm9v2/*.sv \
    "$root/sim/cpu/arm9v2/front_decode.sv" "$root/sim/cpu/arm9v2/front_execute.sv" > "$build/front-execute-gen.v"
for rtl in sv gen; do
  inputs=("$root"/rtl/cpu/arm9v2/*.sv "$root/sim/cpu/arm9v2/front_decode.sv" "$root/sim/cpu/arm9v2/front_execute.sv")
  [[ $rtl == sv ]] || inputs=("$build/front-execute-gen.v")
  for latency in 0 3 9; do
    dir=$build/$rtl-lat-$latency
    verilator --binary --timing --assert -j 8 -Wno-fatal -Wno-lint -Wno-style \
        --top-module execute_cache_tb -GLATENCY=$latency --Mdir "$dir" \
        "$root/rtl/cpu/arm925t_gen.v" "${inputs[@]}" \
        "$root/sim/cpu/arm9v2/execute_cache_tb.sv" > "$dir.log" 2>&1 || { cat "$dir.log";exit 1; }
    "$dir/Vexecute_cache_tb"
  done
done
