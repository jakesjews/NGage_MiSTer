#!/bin/zsh
# Make a blank test game card for the model: 16 MB, MBR with one FAT12
# partition at LBA 32 (the layout of retail cards, research/peripherals/MMC.md),
# a GAME.ID file, and a generic CID/CSD written by the model when the
# .cid/.csd sidecars are absent. Usage: model/tools/mkcard.sh OUT.img
set -euo pipefail
out=$1
size=$((16 * 1024 * 1024))
sectors=$((size / 512))
python3 -I - "$out" $sectors <<'PY'
import struct, sys
out, sectors = sys.argv[1], int(sys.argv[2])
img = bytearray(sectors * 512)
start, count = 32, sectors - 32
part = struct.pack('<B3sB3sII', 0x80, b'\x00\x02\x00', 0x01, b'\xff\xff\xff', start, count)
img[446:462] = part
img[510:512] = b'\x55\xaa'
open(out, 'wb').write(img)
PY
# FAT12 with 4 KB clusters, as on retail cards (Symbian 6.1 has no FAT32).
mformat -i "$out@@16384" -T $((sectors - 32)) -h 2 -s 32 -c 8 -r 32 -v NGAGEMODEL ::
printf 'Model test card\r\n' > "$out.gameid"
mcopy -i "$out@@16384" "$out.gameid" ::/GAME.ID
rm -f "$out.gameid"
mdir -i "$out@@16384" ::
