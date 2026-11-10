#!/bin/zsh
# Quartus 17.0.2 build of the NGage core, either in the Docker image on the
# Ubuntu server (default) or locally through CrossOver.
# Usage: ./build.sh [remote|local] [map|compile]
set -euo pipefail
cd "$(dirname "$0")"

where=${1:-remote}
# FAST=1: append tools/fast-fit.qsf to the settings for this build only (a
# fast fit for debug cores: about a third of the fitter time, 1-2 ns worse).
if [[ -n "${FAST:-}" ]]; then
    cp NGage.qsf build/NGage.qsf.orig 2>/dev/null || { mkdir -p build; cp NGage.qsf build/NGage.qsf.orig; }
    printf '\n' >> NGage.qsf    # the settings file may lack a final newline
    cat tools/fast-fit.qsf >> NGage.qsf
    trap 'cp build/NGage.qsf.orig NGage.qsf' EXIT
fi
build_mode=${2:-compile}
case "$where" in remote|local) ;; *) print -u2 'Usage: ./build.sh [remote|local] [map|compile]'; exit 1 ;; esac
case "$build_mode" in map|compile) ;; *) print -u2 'Usage: ./build.sh [remote|local] [map|compile]'; exit 1 ;; esac
proj=NGage

mkdir -p build
# Synthesis-only runs do not invoke the framework pre-flow date generator.
print -r -- "\`define BUILD_DATE \"$(date +%y%m%d)\"" > build_id.v

if [[ "$where" == remote ]]; then
    host=${BUILD_HOST:-ubuntu}
    dir=${BUILD_DIR:-dev/mister/NGage_MiSTer}
    image=theypsilon/quartus-lite-c5:17.0.2.docker0
    ssh "$host" "mkdir -p \$HOME/$dir"
    rsync -a --delete --exclude build --exclude db --exclude incremental_db --exclude output_files \
        --exclude research --exclude .git --exclude '*.rbf' --exclude 'sim/build' --exclude 'sim/cpu/build' \
        --exclude 'model/.out' --exclude 'model/.qemu-src' --exclude 'model/.build' ./ "$host:$dir/"
    docker_run="docker run --rm --user \$(id -u):\$(id -g) -e HOME=/tmp -v \$HOME/$dir:/project -w /project $image"
    if [[ "$build_mode" == map ]]; then
        ssh "$host" "$docker_run /opt/intelFPGA_lite/quartus/bin/quartus_map --read_settings_files=on --write_settings_files=off $proj -c $proj" \
            2>&1 | tee build/quartus-map.log
    else
        # A SignalTap file named in the settings needs quartus_stp before the
        # compile (the GUI runs it as a flow stage; quartus_sh --flow compile
        # does not): it turns the .stp into the SLD_* tap assignments.
        stp_file=$(sed -n 's/^set_global_assignment -name USE_SIGNALTAP_FILE //p' $proj.qsf | tail -1)
        if [[ -n "$stp_file" ]]; then
            ssh "$host" "$docker_run /opt/intelFPGA_lite/quartus/bin/quartus_stp $proj --stp_file=$stp_file --enable" 2>&1 | tee build/quartus-stp.log
        fi
        ssh "$host" "$docker_run /opt/intelFPGA_lite/quartus/bin/quartus_sh --flow compile $proj" 2>&1 | tee build/quartus-compile.log
        # The report script exits 3 while any slack is negative: keep going so
        # the rbf and the reports still come back, then exit with its code.
        sta_rc=0
        ssh "$host" "$docker_run /opt/intelFPGA_lite/quartus/bin/quartus_sta -t tools/report_timing.tcl" 2>&1 | tee build/timing-report.log || sta_rc=$?
        mkdir -p output_files
        rsync -a "$host:$dir/output_files/$proj.rbf" output_files/
        rsync -a "$host:$dir/output_files/$proj.fit.summary" "$host:$dir/output_files/$proj.sta.summary" output_files/ 2>/dev/null || true
        rsync -a "$host:$dir/build/" build/ 2>/dev/null || true
        if grep -q 'Timing requirements not met' build/quartus-compile.log; then
            print -u2 'Quartus produced output, but timing requirements were not met.'
            exit 2
        fi
        test -s output_files/$proj.rbf
        exit $sta_rc
    fi
else
    cx_bin=${CROSSOVER_BIN:-/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin}
    quartus_bottle=${QUARTUS_BOTTLE:-Quartus}
    quartus_bin=${QUARTUS_BIN:-C:/intelFPGA_lite/17.0/quartus/bin64}
    run_q() { "$cx_bin/wine" --bottle "$quartus_bottle" --workdir "$PWD" --cx-app "$quartus_bin/$1" "${@:2}"; }
    if [[ "$build_mode" == map ]]; then
        run_q quartus_map.exe --read_settings_files=on --write_settings_files=off $proj -c $proj 2>&1 | tee build/quartus-map.log
    else
        run_q quartus_sh.exe --flow compile $proj 2>&1 | tee build/quartus-compile.log
        sta_rc=0
        run_q quartus_sta.exe -t tools/report_timing.tcl 2>&1 | tee build/timing-report.log || sta_rc=$?
        if grep -q 'Timing requirements not met' build/quartus-compile.log; then
            print -u2 'Quartus produced output, but timing requirements were not met.'
            exit 2
        fi
        exit $sta_rc
    fi
fi
