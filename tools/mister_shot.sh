#!/bin/zsh
# Screenshot the MiSTer through Zaparoo, optionally after a key macro.
# Usage: tools/mister_shot.sh OUT.png ['{f1}{enter}' ...]   SETTLE=seconds (default 1)
# Needs the Zaparoo service running on the MiSTer (zaparoo.sh -service start)
# and direct_video=0 for the core, or the capture is low resolution.
set -euo pipefail
out=$1; shift
host=${MISTER_HOST:-mister}
Z='/media/fat/Scripts/zaparoo.sh -api'
for keys in "$@"; do
	ssh -o BatchMode=yes -o LogLevel=ERROR "root@$host" "$Z 'input.keyboard:{\"keys\":\"$keys\"}'" >/dev/null
	sleep "${SETTLE:-1}"
done
ssh -o BatchMode=yes -o LogLevel=ERROR "root@$host" "$Z screenshot" | tail -1 > "$out.json"
python3 -I - "$out.json" "$out" <<'PY'
import base64, json, sys
from pathlib import Path
r = json.load(open(sys.argv[1]))
r = r.get("result", r)
if "data" not in r:
    sys.exit("no screenshot: %s" % json.dumps(r)[:200])
Path(sys.argv[2]).write_bytes(base64.b64decode(r["data"]))
PY
rm -f "$out.json"
echo "$out"
