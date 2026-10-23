#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/../../.."
obj="$PWD/sim/cpu/build/obj-icache-restart"
mkdir -p "$obj"
verilator --binary --timing --assert -Wno-PINMISSING --top-module tb_icache_restart \
    -Irtl/cpu/zap --Mdir "$obj" \
    sim/cpu/tb/tb_icache_restart.sv rtl/cpu/zap/zap_cache_fsm.sv \
    rtl/cpu/zap/zap_fifo.sv rtl/cpu/zap/zap_sync_fifo.sv > "$obj/build.log" 2>&1
"$obj/Vtb_icache_restart"
