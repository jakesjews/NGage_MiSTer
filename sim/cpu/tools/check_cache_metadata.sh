#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/../../.."
for pf in 0 1; do
  sizes="8192 16384 32768"
  if [[ "$pf" == 1 ]]; then sizes="16384"; fi
  for size in $sizes; do
    for short in 0 1; do
        obj="$PWD/sim/cpu/build/obj-meta-$size-$short-$pf"
        mkdir -p "$obj"
        verilator --binary --timing --assert -j 8 -Wno-fatal -Wno-lint -Wno-style \
            -Wno-PINMISSING --top-module tb_cache_metadata -Irtl/cpu/zap \
            -GCACHE_SIZE="$size" -GSHORT_READ="$short" -GPREFETCH="$pf" --Mdir "$obj" \
            sim/cpu/tb/tb_cache_metadata.sv rtl/cpu/zap/zap_cache_tag_ram.sv \
            rtl/cpu/zap/zap_ram_simple.sv rtl/cpu/port/zap_ram_simple_ben.sv > "$obj/build.log" 2>&1
        "$obj/Vtb_cache_metadata"
    done
done
done
