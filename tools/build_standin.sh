#!/bin/zsh
# Build the NOS stand-in binaries that firmware-patches/rom-patches.txt places
# into CS0 (NOS, the cellular RTOS, is encrypted in flash), with the same
# steps as model/build.sh, so that the core's patch ROM (tools/gen_patchrom.py)
# and tools/mkimage.py need no ARM toolchain. The binaries are committed in
# firmware-patches/bin.
# Usage: tools/build_standin.sh [SRC_DIR [OUT_DIR]]
#   SRC_DIR  the stand-in sources (default firmware-patches/nos-stub)
#   OUT_DIR  where nos-stub.bin and nos-dll.bin go (default firmware-patches/bin)
set -euo pipefail
cd "$(dirname "$0")/.."

src=${1:-firmware-patches/nos-stub}
out=${2:-firmware-patches/bin}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out"

# the entry stub, linked at the NOS entry 0x5149E4D4 (CS0 0x9E4D4)
arm-none-eabi-as -march=armv4t -o "$tmp/nos_stub.o" "$src/nos_stub.S"
arm-none-eabi-ld -Ttext=0x5149E4D4 -o "$tmp/nos_stub.elf" "$tmp/nos_stub.o"
arm-none-eabi-objcopy -O binary "$tmp/nos_stub.elf" "$out/nos-stub.bin"

# the hidden NOS DLL's exports (CS0 0xA1CA0) and the ISI layer in C
arm-none-eabi-as -march=armv4t -o "$tmp/nos_dll.o" "$src/nos_dll.S"
arm-none-eabi-gcc -march=armv4t -marm -mthumb-interwork -Os -std=gnu11 -ffreestanding \
    -fno-builtin -fno-pic -fno-common -fno-unwind-tables -fno-asynchronous-unwind-tables \
    -Wall -Wextra -c -o "$tmp/nos_isi.o" "$src/nos_isi.c"
arm-none-eabi-ld -T "$src/nos_dll.ld" -o "$tmp/nos_dll.elf" "$tmp/nos_dll.o" "$tmp/nos_isi.o" \
    "$(arm-none-eabi-gcc -march=armv4t -marm -print-libgcc-file-name)"
arm-none-eabi-objcopy -O binary "$tmp/nos_dll.elf" "$out/nos-dll.bin"

ls -la "$out/nos-stub.bin" "$out/nos-dll.bin"
