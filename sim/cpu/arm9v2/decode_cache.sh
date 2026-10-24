#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
build=$root/sim/cpu/build/arm9v2-decode-cache
mkdir -p "$build"
for latency in 0 3 9; do
    dir=$build/lat-$latency
    # Cache is the actual committed sv2v netlist. Unused debug outputs are
    # intentionally unconnected, like the CPU suite's device-only benches.
    verilator --binary --timing --assert -j 8 -Wno-fatal -Wno-lint -Wno-style \
        --top-module decode_cache_tb -GLATENCY=$latency --Mdir "$dir" \
        "$root/rtl/cpu/arm925t_gen.v" "$root"/rtl/cpu/arm9v2/*.sv \
        "$root/sim/cpu/arm9v2/front_decode.sv" \
        "$root/sim/cpu/arm9v2/decode_cache_tb.sv" > "$dir.log" 2>&1 || {
        cat "$dir.log"; exit 1;
    }
    "$dir/Vdecode_cache_tb"
done
