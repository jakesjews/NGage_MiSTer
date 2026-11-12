#!/bin/zsh
# Check tools/mkimage.py against the reference model: build the model's own
# flash patcher (model/hw/ngage_patch.c, as it is, with tools/patchcheck's
# stand-ins for QEMU), let it patch CS0/CS1 images with
# firmware-patches/rom-patches.txt and the stand-in binaries the list names
# (firmware-patches/bin), and compare the result byte for byte with
# mkimage.py flat on the same images: what the model's patcher makes of them.
# Usage: tools/patchcheck.sh CS0.bin CS1.bin
set -euo pipefail
cd "$(dirname "$0")/.."
(( $# == 2 )) || { echo "usage: tools/patchcheck.sh CS0.bin CS1.bin" >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
libs=()
[[ $(uname) == Darwin ]] || libs=(-lcrypto)
cc -O2 -Wall -Wno-deprecated-declarations -I tools/patchcheck/shim -o "$tmp/patchcheck" \
    tools/patchcheck/main.c model/hw/ngage_patch.c "${libs[@]}"
"$tmp/patchcheck" firmware-patches/rom-patches.txt "$1" "$2" "$tmp/model0.bin" "$tmp/model1.bin" 2>/dev/null
python3 -I tools/mkimage.py flat "$1" "$2" -o "$tmp/mk" >/dev/null
cmp "$tmp/model0.bin" "$tmp/mk/cs0.bin"
cmp "$tmp/model1.bin" "$tmp/mk/cs1.bin"
echo "patchcheck: mkimage.py's images equal what the model's patcher makes of $1 and $2"
