#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Check the registered fetch/BTB contract against the actual generated RTL.
set -euo pipefail
cd "$(dirname "$0")/.."
build=sim/cpu/build/obj-btb
mkdir -p "$build"
verilator --binary --timing --assert -j 8 --top-module tb_btb \
    -Wno-lint -Wno-style -Wno-PINCONNECTEMPTY --Mdir "$build" \
    rtl/cpu/arm925t_gen.v sim/cpu/tb/tb_btb.sv > "$build/build.log" 2>&1 || {
    cat "$build/build.log"
    exit 1
}
"$build/Vtb_btb"
