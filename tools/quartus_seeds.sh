#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Full Quartus compiles of the core with several fitter seeds on the build
# server, LANES (default 2, the user's limit is 4) Quartus builds there at
# a time.
#
#   tools/quartus_seeds.sh TAG "SEEDS" [QSF_EDIT]   start (returns at once)
#   tools/quartus_seeds.sh TAG                      print the results so far
#   tools/quartus_seeds.sh TAG fetch SEED           copy that seed's RBF and reports here
#
# TAG names the run: the server directories are ~/dev/mister/ngage-q-TAG-SEED.
# The sources are the working tree as it is now (as build.sh sends them).
# QSF_EDIT is a sed expression applied to NGage.qsf (for example to enable a
# framework macro). Seeds run one after the other in each of LANES lanes; a
# lock on the server keeps the number of Quartus containers at LANES at most.
set -euo pipefail
cd "$(dirname "$0")/.."
host=${BUILD_HOST:-ubuntu}
lanes=${LANES:-2}
image=theypsilon/quartus-lite-c5:17.0.2.docker0
tag=$1

if [[ $# -lt 2 ]]; then
	ssh "$host" "for d in \$HOME/dev/mister/ngage-q-$tag-*; do s=\${d##*-}; [ \$s = src ] && continue; \
		t=\$(awk -F'\t' 'NR>1 && (\$2==\"setup\" || \$2==\"hold\") {printf \"%s %s %s, \", \$1, \$2, \$3}' \$d/build/timing-corners.tsv 2>/dev/null); \
		a=\$(grep -h 'Logic utilization' \$d/output_files/NGage.fit.summary 2>/dev/null | awk '{print \$6}'); \
		echo \"seed \$s: \${t:-running} \${a:+ALMs \$a}\"; done"
	exit 0
fi
if [[ $2 == fetch ]]; then
	d=dev/mister/ngage-q-$tag-$3
	mkdir -p output_files build
	rsync -a "$host:$d/output_files/NGage.rbf" "$host:$d/output_files/NGage.fit.summary" "$host:$d/output_files/NGage.sta.summary" output_files/
	rsync -a "$host:$d/build/timing-corners.tsv" "$host:$d/build/critical-paths.rpt" "$host:$d/build/hold-paths.rpt" build/
	exit 0
fi
seeds=($2)
edit=${3:-}
print_build_id() { printf '`define BUILD_DATE "%s"\n' "$(date +%y%m%d)"; }
src=dev/mister/ngage-q-$tag-src
ssh "$host" "mkdir -p $src"
rsync -a --delete --exclude build --exclude db --exclude incremental_db --exclude output_files \
	--exclude research --exclude .git --exclude '*.rbf' --exclude 'sim/build' --exclude 'sim/cpu/build' \
	--exclude 'model/.out' --exclude 'model/.build' ./ "$host:$src/"
print_build_id | ssh "$host" "cat > $src/build_id.v"
[[ -n $edit ]] && ssh "$host" "sed -i '$edit' $src/NGage.qsf"
# the lanes
lane() {
	local list=$1 i=$2
	cat <<EOF
#!/bin/sh
for s in $list; do
	d=\$HOME/dev/mister/ngage-q-$tag-\$s
	rm -rf \$d; cp -r \$HOME/$src \$d
	sed -i "s/^set_global_assignment -name SEED .*/set_global_assignment -name SEED \$s/" \$d/NGage.qsf
	name=ngq-$tag-\$s
	flock /tmp/ngage-quartus.lock sh -c 'while [ "\$(docker ps --format "{{.Image}}" | grep -c quartus)" -ge $lanes ]; do sleep 30; done; \\
		docker run -d --name '\$name' --user \$(id -u):\$(id -g) -e HOME=/tmp -v '\$d':/project -w /project $image \\
		sh -c "/opt/intelFPGA_lite/quartus/bin/quartus_sh --flow compile NGage > build_compile.log 2>&1; \\
		       /opt/intelFPGA_lite/quartus/bin/quartus_sta -t tools/report_timing.tcl > build_sta.log 2>&1" > /dev/null'
	docker wait \$name > /dev/null; docker rm \$name > /dev/null
done
EOF
}
for ((l = 0; l < lanes; l++)); do
	list=""
	for ((k = l; k < ${#seeds[@]}; k += lanes)); do list="$list ${seeds[k]}"; done
	list=${list# }
	[[ -z $list ]] && continue
	lane "$list" $l | ssh "$host" "cat > $src/lane$l.sh && chmod +x $src/lane$l.sh"
	ssh "$host" "(nohup $src/lane$l.sh > $src/lane$l.log 2>&1 < /dev/null &)"
done
echo "quartus $tag started: seeds ${seeds[*]}"
