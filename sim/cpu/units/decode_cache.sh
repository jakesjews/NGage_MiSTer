#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
build=$root/sim/cpu/build/units-decode-cache
mkdir -p "$build"
# Keep only shared modules from the CPU netlist. The pipeline is now integrated there;
# retaining it would silently shadow the component RTL under test.
sv2v --top=arm925t_icache --top=arm925t_mode_decoder --top=arm925t_register_file \
    --top=arm925t_alu --top=arm925t_ram_nopipe "$root/rtl/cpu/arm925t_gen.v" > "$build/shared-gen.v"
for latency in 0 3 9; do
    dir=$build/lat-$latency
    # Cache is the actual committed sv2v netlist. Unused debug outputs are
    # intentionally unconnected, like the CPU suite's device-only benches.
    verilator --binary --timing --assert -j 8 -Wno-fatal -Wno-lint -Wno-style \
        --top-module decode_cache_tb -GLATENCY=$latency --Mdir "$dir" \
        "$build/shared-gen.v" "$root/sim/stubs/altsyncram.sv" "$root/sim/stubs/altdpram.sv" "$root"/rtl/cpu/arm925t_{core,decode,execute,fetch,forward,front_decode,predict,rotate}.sv \
        "$root/sim/cpu/units/decode_cache_tb.sv" > "$dir.log" 2>&1 || {
        cat "$dir.log"; exit 1;
    }
    "$dir/Vdecode_cache_tb"
done
