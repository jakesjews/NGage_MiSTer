#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
build=$root/sim/cpu/build/units-cache
mkdir -p "$build"
for latency in 0 3 9; do
    dir=$build/lat-$latency
    # Cache is the actual committed sv2v netlist. Unused debug outputs are
    # intentionally unconnected, like the CPU suite's device-only benches.
    verilator --binary --timing --assert -j 8 -Wno-fatal -Wno-lint -Wno-style \
        --top-module fetch_cache_tb -GLATENCY=$latency --Mdir "$dir" \
        "$root/rtl/cpu/arm925t_gen.v" "$root/sim/stubs/altsyncram.sv" "$root/sim/stubs/altdpram.sv" "$root"/rtl/cpu/arm925t_{core,decode,execute,fetch,forward,front_decode,predict,rotate}.sv \
        "$root/sim/cpu/units/fetch_cache_tb.sv" > "$dir.log" 2>&1 || {
        cat "$dir.log"; exit 1;
    }
    "$dir/Vfetch_cache_tb"
done
