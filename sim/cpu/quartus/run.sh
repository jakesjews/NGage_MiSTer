#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Quartus 17.0.2 trial of the CPU alone (cpu_trial.v around arm925t_gen.v),
# in the Docker image on the build server.
#   sim/cpu/quartus/run.sh            full compile, summary and worst paths
#   SEED=3 MHZ=96 sim/cpu/quartus/run.sh   another fitter seed / clock
# Results land in sim/cpu/build/quartus[-SEED-MHZ]/. At most two Quartus
# builds may run on the server at a time: this checks docker ps first.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
host=${BUILD_HOST:-ubuntu}
seed=${SEED:-1}
mhz=${MHZ:-104}
sfx=""
[[ $seed == 1 && $mhz == 104 ]] || sfx="-$seed-$mhz"
dir=${BUILD_DIR:-dev/mister/ngage-cpu-quartus$sfx}
image=theypsilon/quartus-lite-c5:17.0.2.docker0
out=$root/sim/cpu/build/quartus$sfx
mkdir -p "$out"

running=$(ssh "$host" "docker ps --format '{{.Image}}' | grep -c quartus || true")
if (( running >= 2 )); then
	echo "two Quartus builds are already running on $host; try later" >&2
	exit 1
fi
ssh "$host" "mkdir -p \$HOME/$dir"
rsync -a "$here"/cpu_trial.{v,sdc,qpf,qsf} "$here/report.tcl" "$root/rtl/cpu/arm925t_gen.v" "$host:$dir/"
period=$(awk -v m="$mhz" 'BEGIN { printf "%.3f", 1000 / m }')
ssh "$host" "cd $dir && sed -i 's/^set_global_assignment -name SEED .*/set_global_assignment -name SEED $seed/' cpu_trial.qsf && sed -i 's/-period [0-9.]*/-period $period/' cpu_trial.sdc"
docker_run="docker run --rm --user \$(id -u):\$(id -g) -e HOME=/tmp -v \$HOME/$dir:/project -w /project $image"
ssh "$host" "$docker_run /opt/intelFPGA_lite/quartus/bin/quartus_sh --flow compile cpu_trial" > "$out/compile.log" 2>&1 || true
ssh "$host" "$docker_run /opt/intelFPGA_lite/quartus/bin/quartus_sta -t report.tcl" > "$out/sta.log" 2>&1 || true
rsync -a "$host:$dir/output_files/cpu_trial.fit.summary" "$host:$dir/output_files/cpu_trial.sta.summary" \
	"$host:$dir/output_files/paths_*.txt" "$out/" 2>/dev/null || true
grep -h "Logic utilization\|Total registers\|Total RAM Blocks\|Total block memory\|Total DSP" "$out/cpu_trial.fit.summary" || true
grep -h "^CORNER" "$out/sta.log" || tail -20 "$out/compile.log"
