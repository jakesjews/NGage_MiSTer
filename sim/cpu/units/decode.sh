#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
build=$root/sim/cpu/build/units-decode
mkdir -p "$build"
sources=("$root/rtl/cpu/arm925t_decode.sv" "$root/rtl/cpu/arm925t_mode_decoder.sv" "$root/rtl/cpu/arm925t_register_file.sv")
sv2v -I "$root/rtl/cpu" --top=arm925t_decode "${sources[@]}" > "$build/decode-gen.v"
for rtl in sv gen; do
    inputs=("${sources[@]}")
    [[ $rtl == sv ]] || inputs=("$build/decode-gen.v")
    warnings=()
    # sv2v flattens unused struct fields and expands legacy Thumb X literals.
    [[ $rtl == sv ]] || warnings=(-Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL)
    dir=$build/$rtl
    verilator --binary --timing --assert -j 8 -Wall -Wno-DECLFILENAME \
        -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY ${warnings[@]+"${warnings[@]}"} -I"$root/rtl/cpu" \
        --top-module decode_tb --Mdir "$dir" "${inputs[@]}" \
        "$root/sim/cpu/units/decode_tb.sv" > "$dir.log" 2>&1 || { cat "$dir.log";exit 1; }
    "$dir/Vdecode_tb"
done
