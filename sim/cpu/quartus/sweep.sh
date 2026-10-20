#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Fitter-seed sweep of the CPU trial on the build server, one compile at a
# time and never more than two Quartus builds on the server in all.
#
#   sim/cpu/quartus/sweep.sh TAG "SEEDS" [QSF_EDIT]   start (returns at once)
#   sim/cpu/quartus/sweep.sh TAG                      print the results so far
#
# TAG names the run (server directories ~/dev/mister/ngage-cpu-q-TAG-SEED);
# the netlist is the current rtl/cpu/arm925t_gen.v. QSF_EDIT is a sed
# expression applied to cpu_trial.qsf (e.g. to switch register retiming off).
# MHZ (default 104) sets the clock.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
host=${BUILD_HOST:-ubuntu}
tag=$1
image=theypsilon/quartus-lite-c5:17.0.2.docker0

if [[ $# -lt 2 ]]; then
	ssh "$host" "for d in \$HOME/dev/mister/ngage-cpu-q-$tag-*; do s=\${d##*-}; \
		c=\$(grep '^CORNER' \$d/sta.log 2>/dev/null | awk '{printf \"%s \", \$NF}'); \
		h=\$(grep '^HOLD' \$d/sta.log 2>/dev/null | awk '{printf \"%s \", \$NF}'); \
		a=\$(grep -h 'Logic utilization' \$d/output_files/cpu_trial.fit.summary 2>/dev/null | awk '{print \$6}'); \
		echo \"seed \$s: \${c:-running} \${h:+hold \$h}\${a:+ALMs \$a}\"; done"
	exit 0
fi
seeds=$2
edit=${3:-}
mhz=${MHZ:-104}
period=$(awk -v m="$mhz" 'BEGIN { printf "%.3f", 1000 / m }')
stage=$(mktemp -d "${TMPDIR:-/tmp}/sweep.XXXXXX")
cp "$here"/cpu_trial.{v,sdc,qpf,qsf} "$here/report.tcl" "$root/rtl/cpu/arm925t_gen.v" "$stage/"
sed -i '' "s/-period [0-9.]*/-period $period/" "$stage/cpu_trial.sdc"
[[ -n $edit ]] && sed -i '' "$edit" "$stage/cpu_trial.qsf"
ssh "$host" "mkdir -p dev/mister/ngage-cpu-q-$tag-src"
rsync -a --delete "$stage/" "$host:dev/mister/ngage-cpu-q-$tag-src/"
rm -rf "$stage"
ssh "$host" "cat > dev/mister/ngage-cpu-q-$tag-src/loop.sh" <<EOF
#!/bin/sh
for s in $seeds; do
	d=\$HOME/dev/mister/ngage-cpu-q-$tag-\$s
	rm -rf \$d; cp -r \$HOME/dev/mister/ngage-cpu-q-$tag-src \$d
	sed -i "s/^set_global_assignment -name SEED .*/set_global_assignment -name SEED \$s/" \$d/cpu_trial.qsf
	while [ "\$(docker ps --format '{{.Image}}' | grep -c quartus)" -ge 2 ]; do sleep 30; done
	docker run --rm --user \$(id -u):\$(id -g) -e HOME=/tmp -v \$d:/project -w /project $image \\
		/opt/intelFPGA_lite/quartus/bin/quartus_sh --flow compile cpu_trial > \$d/compile.log 2>&1
	docker run --rm --user \$(id -u):\$(id -g) -e HOME=/tmp -v \$d:/project -w /project $image \\
		/opt/intelFPGA_lite/quartus/bin/quartus_sta -t report.tcl > \$d/sta.log 2>&1
done
EOF
ssh "$host" "chmod +x dev/mister/ngage-cpu-q-$tag-src/loop.sh && \
	(nohup dev/mister/ngage-cpu-q-$tag-src/loop.sh > dev/mister/ngage-cpu-q-$tag-src/loop.log 2>&1 < /dev/null &)"
echo "sweep $tag started: seeds $seeds at $mhz MHz"
