#!/bin/zsh
# Check tools/mkimage.py against the reference model: build the model's own
# flash patcher (model/hw/ngage_patch.c, as it is, with tools/patchcheck's
# stand-ins for QEMU), let it patch CS0/CS1 images with model/rom-patches.txt
# and the model's stand-in binaries (model/.build, from model/build.sh), and
# compare the result byte for byte with mkimage.py flat --model-build on the
# same images: what the model presents in its flash after loading them.
# Usage: tools/patchcheck.sh CS0.bin CS1.bin
set -euo pipefail
cd "$(dirname "$0")/.."
(( $# == 2 )) || { echo "usage: tools/patchcheck.sh CS0.bin CS1.bin" >&2; exit 2; }
for f in model/.build/nos-stub.bin model/.build/nos-dll.bin; do
    [[ -f $f ]] || { echo "patchcheck: $f missing (model/build.sh builds it)" >&2; exit 2; }
done
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
libs=()
[[ $(uname) == Darwin ]] || libs=(-lcrypto)
cc -O2 -Wall -Wno-deprecated-declarations -I tools/patchcheck/shim -o "$tmp/patchcheck" \
    tools/patchcheck/main.c model/hw/ngage_patch.c "${libs[@]}"
"$tmp/patchcheck" model/rom-patches.txt "$1" "$2" "$tmp/model0.bin" "$tmp/model1.bin" 2>/dev/null
python3 -I tools/mkimage.py flat "$1" "$2" -o "$tmp/mk" --model-build >/dev/null
cmp "$tmp/model0.bin" "$tmp/mk/cs0.bin"
cmp "$tmp/model1.bin" "$tmp/mk/cs1.bin"
echo "patchcheck: mkimage.py's images equal what the model's patcher makes of $1 and $2"
