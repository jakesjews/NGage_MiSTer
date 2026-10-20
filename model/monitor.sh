#!/bin/zsh
# Run the model N seconds, then send QEMU monitor commands (one per argument).
# Usage: model/monitor.sh SECONDS 'xp /16wx 0x0a000000' ...
set -euo pipefail
cd "$(dirname "$0")/.."
secs=$1
shift
source model/args.sh
sock="$out/monitor.sock"
rm -f "$sock"
"${qemu[@]}" -display none -monitor "unix:$sock,server,nowait" &
qpid=$!
sleep "$secs"
for c in "$@"; do
    echo "$c" | socat - "UNIX-CONNECT:$sock" 2>/dev/null | tr -d '\r' | grep -v "^(qemu)\|QEMU.*monitor"
done
kill $qpid 2>/dev/null || true
wait $qpid 2>/dev/null || true
