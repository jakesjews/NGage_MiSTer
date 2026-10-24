#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Quartus 17.0.2 trial of the CPU alone (cpu_trial.v around arm925t_gen.v),
# in the Docker image on the build server.
#   sim/cpu/quartus/run.sh            full compile, summary and worst paths
#   TRIAL=arm9_core sim/cpu/quartus/run.sh   experimental integrated ARM9
#   TRIAL=arm9v2_execute sim/cpu/quartus/run.sh   F1/F2/D1/D2/S/A with registered producers
#   TRIAL=arm9v2_decode sim/cpu/quartus/run.sh   F1/F2/D1/D2 and register file
#   TRIAL=arm9v2_frontend sim/cpu/quartus/run.sh   F1/F2 component only
#   TRIAL=arm9_execute sim/cpu/quartus/run.sh   execute datapath only
#   TRIAL=arm9_decode_shift sim/cpu/quartus/run.sh   shift in D, including E-to-D bypass
#   SEED=3 MHZ=96 sim/cpu/quartus/run.sh   another fitter seed / clock
# Results land in sim/cpu/build/quartus[-SEED-MHZ]/. At most two Quartus
# builds may run on the server at a time (the user's limit): this checks
# docker ps first.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
host=${BUILD_HOST:-ubuntu}
seed=${SEED:-1}
mhz=${MHZ:-104}
trial=${TRIAL:-cpu}
case "$trial" in
    cpu) trial_suffix="" ;;
    arm9_core) trial_suffix="-arm9-core" ;;
    arm9v2_frontend) trial_suffix="-arm9v2-frontend" ;;
    arm9v2_decode) trial_suffix="-arm9v2-decode" ;;
    arm9v2_execute) trial_suffix="-arm9v2-execute" ;;
    arm9_execute) trial_suffix="-arm9-execute" ;;
    arm9_decode_shift) trial_suffix="-arm9-decode-shift" ;;
    *) echo "unknown TRIAL: $trial" >&2; exit 2 ;;
esac
sfx="$trial_suffix"
[[ $seed == 1 && $mhz == 104 ]] || sfx="$trial_suffix-$seed-$mhz"
dir=${BUILD_DIR:-dev/mister/ngage-cpu-quartus$sfx}
image=theypsilon/quartus-lite-c5:17.0.2.docker0
out=$root/sim/cpu/build/quartus$sfx
mkdir -p "$out"

running=$(ssh "$host" "docker ps --format '{{.Image}}' | grep -c quartus || true")
if (( running >= 2 )); then
	echo "two Quartus builds are already running on $host; try later" >&2
	exit 1
fi
if [[ $trial == arm9v2_* || $dir == *arm9v2* ]]; then
    ours=$(ssh "$host" "docker ps -q --filter ancestor=$image | xargs -r docker inspect --format '{{range .Mounts}}{{.Source}} {{end}}' | grep -ic arm9v2 || true")
    if (( ours >= 2 )); then
        echo "two ARM9V2 Quartus containers already run on $host; try later" >&2
        exit 1
    fi
fi
ssh "$host" "mkdir -p \$HOME/$dir"
if [[ $trial == arm9_core ]]; then
    sed 's/arm925t cpu (/arm925t #(.CORE("ARM9")) cpu (/' "$here/cpu_trial.v" > "$out/cpu_trial.v"
    cp "$root/rtl/cpu/arm925t_gen.v" "$out/arm925t_gen.v"
    rsync -a "$out/cpu_trial.v" "$out/arm925t_gen.v" "$host:$dir/"
elif [[ $trial == arm9v2_execute ]]; then
    sv2v -DSYNTHESIS -I "$root/rtl/cpu/zap" --top=cpu_trial "$root"/rtl/cpu/arm9v2/*.sv \
        "$root/rtl/cpu/arm9/arm9_alu.sv" "$root/rtl/cpu/zap/zap_ram_simple_nopipe.sv" \
        "$root/rtl/cpu/zap/zap_mode16_decoder.sv" "$root/rtl/cpu/zap/zap_register_file.sv" \
        "$root/sim/cpu/arm9v2/front_execute.sv" \
        "$here/arm9v2_execute_trial.sv" > "$out/arm925t_gen.v"
    printf '// Component top included in arm925t_gen.v\n' > "$out/cpu_trial.v"
    rsync -a "$out/arm925t_gen.v" "$out/cpu_trial.v" "$host:$dir/"
elif [[ $trial == arm9v2_decode ]]; then
    sv2v -DSYNTHESIS -I "$root/rtl/cpu/zap" --top=cpu_trial "$root"/rtl/cpu/arm9v2/*.sv \
        "$root/rtl/cpu/zap/zap_ram_simple_nopipe.sv" \
        "$root/rtl/cpu/zap/zap_mode16_decoder.sv" "$root/rtl/cpu/zap/zap_register_file.sv" \
        "$here/arm9v2_decode_trial.sv" > "$out/arm925t_gen.v"
    printf '// Component top included in arm925t_gen.v\n' > "$out/cpu_trial.v"
    rsync -a "$out/arm925t_gen.v" "$out/cpu_trial.v" "$host:$dir/"
elif [[ $trial == arm9v2_frontend ]]; then
    sv2v -DSYNTHESIS --top=cpu_trial "$root"/rtl/cpu/arm9v2/arm9v2_{fetch,predict}.sv \
        "$root/rtl/cpu/zap/zap_ram_simple_nopipe.sv" "$here/arm9v2_frontend_trial.sv" > "$out/arm925t_gen.v"
    printf '// Component top included in arm925t_gen.v\n' > "$out/cpu_trial.v"
    rsync -a "$out/arm925t_gen.v" "$out/cpu_trial.v" "$host:$dir/"
elif [[ $trial != cpu ]]; then
    defines=(-DSYNTHESIS)
    [[ $trial != arm9_decode_shift ]] || defines+=(-DARM9_TRIAL_SPLIT)
    sv2v "${defines[@]}" --top=cpu_trial "$root"/rtl/cpu/arm9/arm9_{execute,forward,shift,alu}.sv \
        "$root/rtl/cpu/zap/zap_register_file.sv" "$here/arm9_execute_trial.sv" > "$out/arm925t_gen.v"
    # The generated trial contains its own cpu_trial top.
    printf '// Top included in arm925t_gen.v\n' > "$out/cpu_trial.v"
    rsync -a "$out/arm925t_gen.v" "$out/cpu_trial.v" "$host:$dir/"
else
    rsync -a "$here/cpu_trial.v" "$root/rtl/cpu/arm925t_gen.v" "$host:$dir/"
fi
rsync -a "$here"/cpu_trial.{sdc,qpf,qsf} "$here/report.tcl" "$host:$dir/"
period=$(awk -v m="$mhz" 'BEGIN { printf "%.3f", 1000 / m }')
ssh "$host" "cd $dir && sed -i 's/^set_global_assignment -name SEED .*/set_global_assignment -name SEED $seed/' cpu_trial.qsf && sed -i 's/-period [0-9.]*/-period $period/' cpu_trial.sdc"
docker_run="docker run --rm --user \$(id -u):\$(id -g) -e HOME=/tmp -v \$HOME/$dir:/project -w /project $image"
ssh "$host" "$docker_run /opt/intelFPGA_lite/quartus/bin/quartus_sh --flow compile cpu_trial" > "$out/compile.log" 2>&1 || { tail -40 "$out/compile.log"; exit 1; }
ssh "$host" "$docker_run /opt/intelFPGA_lite/quartus/bin/quartus_sta -t report.tcl" > "$out/sta.log" 2>&1 || { tail -40 "$out/sta.log"; exit 1; }
rsync -a "$host:$dir/output_files/cpu_trial.fit.summary" "$host:$dir/output_files/cpu_trial.sta.summary" \
	"$host:$dir/output_files/paths_*.txt" "$host:$dir/output_files/detail_*.txt" "$out/"
grep -h "Logic utilization\|Total registers\|Total RAM Blocks\|Total block memory\|Total DSP" "$out/cpu_trial.fit.summary" || true
grep -h "^CORNER\|^HOLD" "$out/sta.log" || tail -20 "$out/compile.log"
