#!/bin/zsh
# Run the model and sample the guest PC through the QEMU monitor.
# Usage: model/sample.sh [SECONDS] [SAMPLES]   (defaults 6 and 40)
# Samples are taken evenly over the last half of the run; prints a histogram
# of PC, mode and LR so busy loops stand out.
set -euo pipefail
cd "$(dirname "$0")/.."
source model/args.sh
secs=${1:-6}
n=${2:-40}
sock="$out/monitor.sock"
rm -f "$sock"
"${qemu[@]}" -display none -monitor "unix:$sock,server,nowait" &
qpid=$!
half=$(( secs / 2.0 ))
sleep "$half"
step=$(( half / n ))
for i in {1..$n}; do
    echo "info registers" | socat - "UNIX-CONNECT:$sock" 2>/dev/null |
        tr -d '\r' | awk '/R12=/{for(i=1;i<=NF;i++) if($i ~ /^R14=/) lr=$i; else if ($i ~ /^R15=/) pc=$i}
                          /PSR=/{for(i=1;i<=NF;i++) if($i ~ /^(usr|svc|irq|fiq|und|abt|sys)/) m=$i}
                          END{print pc, lr, m}'
    sleep "$step"
done | sort | uniq -c | sort -rn
kill $qpid 2>/dev/null || true
wait $qpid 2>/dev/null || true
