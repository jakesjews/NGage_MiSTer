#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/../../.."
obj="$PWD/sim/cpu/build/obj-fetch-handshake"
mkdir -p "$obj"
verilator --binary --timing --assert -Wno-fatal -Wno-lint -Wno-style \
    -Wno-PINMISSING -Wno-MULTIDRIVEN --top-module tb_fetch_handshake \
    -Irtl/cpu/zap --Mdir "$obj" \
    sim/cpu/tb/tb_fetch_handshake.sv rtl/cpu/zap/*.sv > "$obj/build.log" 2>&1
"$obj/Vtb_fetch_handshake"
