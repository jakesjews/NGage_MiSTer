#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/../../.."
for size in 8192 16384 32768; do
    obj="$PWD/sim/cpu/build/obj-meta-$size"
    mkdir -p "$obj"
    verilator --binary --timing --assert -j 8 -Wno-fatal -Wno-lint -Wno-style \
        -Wno-PINMISSING --top-module tb_cache_metadata -Irtl/cpu/zap \
        -GCACHE_SIZE="$size" --Mdir "$obj" \
        sim/cpu/tb/tb_cache_metadata.sv rtl/cpu/zap/zap_cache_tag_ram.sv \
        rtl/cpu/zap/zap_ram_simple.sv sim/stubs/altsyncram.sv > "$obj/build.log" 2>&1 \
        || { tail -20 "$obj/build.log"; exit 1; }
    "$obj/Vtb_cache_metadata"
done
