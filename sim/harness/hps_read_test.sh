#!/usr/bin/env bash
# Build a host-adapter regression against an existing whole-core Verilator build.
# Usage: hps_read_test.sh BUILD/coreboot [C++ flags used by that bench]
#        hps_read_test.sh BUILD/top
set -euo pipefail
model=$(cd "$1" && pwd)
shift
harness=$(cd "$(dirname "$0")" && pwd)
vr=$(verilator -getenv VERILATOR_ROOT)
flags=()
[[ $(basename "$model") == top ]] && flags+=(-DHPS_TEST_TOP)
"${CXX:-c++}" -O2 -std=c++17 -pthread -I"$vr/include" -I"$vr/include/vltstd" \
    -I"$model" -I"$harness" "${flags[@]}" "$@" "$harness/hps_read_test.cpp" \
    "$model/Vemu__ALL.a" "$model/verilated.o" "$model/verilated_threads.o" \
    -o "$model/hps_read_test"
"$model/hps_read_test" +verilator+seed+1 +verilator+rand+reset+2
