#!/bin/zsh
# Copy the freshly built core to the MiSTer and load it.
# Usage: ./deploy.sh [host]   (default host: mister)
set -euo pipefail
cd "$(dirname "$0")"
host=${1:-mister}
rbf=output_files/NGage.rbf
test -s "$rbf"
name="NGage_$(date +%Y%m%d).rbf"
ssh "root@$host" "mkdir -p /media/fat/_Console/_NGage /media/fat/games/NGage && rm -f /media/fat/_Console/_NGage/NGage_*.rbf"
scp -q "$rbf" "root@$host:/media/fat/_Console/_NGage/$name"
ssh "root@$host" "echo load_core /media/fat/_Console/_NGage/$name > /dev/MiSTer_cmd"
print "loaded $name"
