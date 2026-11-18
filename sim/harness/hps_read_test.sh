#!/usr/bin/env bash
# Build a host-adapter regression against an existing whole-core Verilator build.
# Usage: hps_read_test.sh BUILD/coreboot [C++ flags used by that bench]
#        hps_read_test.sh BUILD/top
set -euo pipefail
model=$(cd "$1" && pwd)
shift
harness=$(cd "$(dirname "$0")" && pwd)
vr=$(verilator -getenv VERILATOR_ROOT)
clock_flag=$(awk '{for (i = 1; i <= NF; i++) if ($i ~ /^-DNGAGE_SYS_CLK_HZ=[0-9]+$/) print $i}' "$model/Vemu.mk")
if [[ -z "$clock_flag" ]]; then
    echo "Rebuild the whole-core simulator to record its clock frequency." >&2
    exit 1
fi
flags=("$clock_flag")
[[ $(basename "$model") == top ]] && flags+=(-DHPS_TEST_TOP)
# the firmware bench's model is built --savable: its snapshot runtime goes in too
objs=("$model/Vemu__ALL.a" "$model/verilated.o" "$model/verilated_threads.o")
[[ -f "$model/verilated_save.o" ]] && objs+=("$model/verilated_save.o")
"${CXX:-c++}" -O2 -std=c++17 -pthread -I"$vr/include" -I"$vr/include/vltstd" \
    -I"$model" -I"$harness" ${flags[@]+"${flags[@]}"} "$@" "$harness/hps_read_test.cpp" \
    "${objs[@]}" -o "$model/hps_read_test"
"$model/hps_read_test" +verilator+seed+1 +verilator+rand+reset+2
