#!/bin/bash
# Seed sweep on the build server: one Quartus build per seed, each from its
# own pinned worktree (../NGage_MiSTer-sw-<seed>), so the builds run in
# parallel (keep to the server's four lanes). Results: build/sweeps/<tag>-s<seed>/
# (critical-paths.rpt, timing-corners.tsv, the build log) and
# build/hardware/NGage-<tag>-s<seed>.rbf.
#   tools/seed_sweep.sh COMMIT TAG MACRO SEED...
# MACRO is a VERILOG_MACRO name whose commented line in NGage.qsf is
# uncommented for the sweep (e.g. NGAGE_DEBUG for a measurement core), or "".
set -u
commit=$1; tag=$2; macro=$3; shift 3
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
for seed in "$@"; do
  d=../NGage_MiSTer-sw-$seed
  [ -d $d ] || git worktree add -q --detach $d $commit
  git -C $d checkout -q -- . && git -C $d checkout -q --detach $commit
  sed -i '' "s/^set_global_assignment -name SEED .*/set_global_assignment -name SEED $seed/" $d/NGage.qsf
  [ -n "$macro" ] && sed -i '' "s/^#\(set_global_assignment -name VERILOG_MACRO \"$macro=1\"\)/\1/" $d/NGage.qsf
  out=$root/build/sweeps/$tag-s$seed; mkdir -p "$out"
  ( cd $d && BUILD_DIR=dev/mister/NGage_MiSTer-$tag-s$seed ./build.sh remote compile > "$out/build.log" 2>&1; rc=$?
    cp build/critical-paths.rpt build/timing-corners.tsv "$out/" 2>/dev/null
    cp output_files/NGage.rbf "$root/build/hardware/NGage-$tag-s$seed.rbf" 2>/dev/null
    printf "%s seed %s: exit %s  slack %s  %s\n" "$tag" "$seed" "$rc" "$(sed -n 2p build/timing-corners.tsv | cut -f3)" "$(grep -i 'ALMs' output_files/NGage.fit.summary | tr -s ' ')" ) &
done
wait
