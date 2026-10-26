#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
build=$root/sim/cpu/build/arm9v2-decode
mkdir -p "$build"
sources=("$root/rtl/cpu/arm9v2/arm9v2_decode.sv" "$root/rtl/cpu/zap/zap_mode16_decoder.sv" "$root/rtl/cpu/zap/zap_register_file.sv")
sv2v -DSYNTHESIS -I "$root/rtl/cpu/zap" --top=arm9v2_decode "${sources[@]}" > "$build/decode-gen.v"
for cuts in 0 1; do
for rtl in sv gen; do
    inputs=("${sources[@]}")
    [[ $rtl == sv ]] || inputs=("$build/decode-gen.v")
    warnings=()
    # sv2v flattens unused struct fields and expands legacy Thumb X literals.
    [[ $rtl == sv ]] || warnings=(-Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL)
    dir=$build/$rtl-$cuts
    verilator --binary --timing --assert -j 8 -Wall -Wno-DECLFILENAME \
        -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY ${warnings[@]+"${warnings[@]}"} -DSYNTHESIS -I"$root/rtl/cpu/zap" \
        --top-module decode_tb -GCUTS=$cuts --Mdir "$dir" "${inputs[@]}" \
        "$root/sim/cpu/arm9v2/decode_tb.sv" > "$dir.log" 2>&1 || { cat "$dir.log";exit 1; }
    "$dir/Vdecode_tb"
done
done
