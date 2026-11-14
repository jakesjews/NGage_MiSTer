#!/bin/zsh
# Build the N-Gage QD reference model: QEMU (pinned release) plus the
# ngage-qd machine from model/hw. The QEMU checkout and build tree live in
# model/.qemu-src and model/.build (both gitignored).
# Usage: model/build.sh [clean]
set -euo pipefail
cd "$(dirname "$0")"

QEMU_TAG=v11.1.2
SRC=.qemu-src
BUILD=.build

if [[ "${1:-}" == clean ]]; then
    rm -rf "$BUILD"
    exit 0
fi

if [[ ! -d $SRC ]]; then
    git clone -q --depth 1 --branch "$QEMU_TAG" https://gitlab.com/qemu-project/qemu.git "$SRC"
fi

# QEMU changes the model needs (qemu-patches/*.patch), each applied once.
for p in qemu-patches/*.patch(N); do
    if ! git -C "$SRC" apply --reverse --check "../$p" 2>/dev/null; then
        git -C "$SRC" apply "../$p"
    fi
done

# Our sources go into the tree as copies so the checkout stays a plain release.
cp hw/ngage.h "$SRC/include/hw/arm/ngage.h"
cp hw/ngage_scramble.h "$SRC/include/hw/arm/ngage_scramble.h"
cp hw/ngage_bt_chip.h "$SRC/include/hw/arm/ngage_bt_chip.h"
for f in hw/ngage*.c; do
    cp "$f" "$SRC/hw/arm/"
done

# Wire the machine into Kconfig, the default arm config and meson (idempotent).
if ! grep -q '^config NGAGE' "$SRC/hw/arm/Kconfig"; then
    printf '\nconfig NGAGE\n    bool\n    default y\n    depends on TCG && ARM\n' >> "$SRC/hw/arm/Kconfig"
fi
srcs=$(cd hw && ls ngage*.c | sed "s/.*/'&'/" | paste -sd, -)
line="arm_common_ss.add(when: 'CONFIG_NGAGE', if_true: files($srcs))"
if grep -q "CONFIG_NGAGE" "$SRC/hw/arm/meson.build"; then
    sed -i '' "s|^arm_common_ss.add(when: 'CONFIG_NGAGE'.*|$line|" "$SRC/hw/arm/meson.build"
else
    sed -i '' "s|^arm_common_ss.add(files('boot.c'))|$line\\
arm_common_ss.add(files('boot.c'))|" "$SRC/hw/arm/meson.build"
fi

if [[ ! -f $BUILD/build.ninja ]]; then
    mkdir -p "$BUILD"
    (cd "$BUILD" && ../$SRC/configure --target-list=arm-softmmu --enable-plugins --enable-sdl \
        --disable-docs --disable-werror --disable-guest-agent --disable-tools >/dev/null)
fi
ninja -C "$BUILD" qemu-system-arm
ls -la "$BUILD/qemu-system-arm"

# The plugins: the exception log (plugins/excprof.c; NGAGE_EXCLOG in run.sh)
# and the data-cache simulation (plugins/dcsim.c; NGAGE_DCSIM).
if [[ $(uname -s) == Darwin ]]; then
    plugin_ld=(-bundle -Wl,-undefined,dynamic_lookup)
else
    plugin_ld=(-shared -fPIC)
fi
for p in excprof dcsim; do
    cc -O2 -Wall -I"$SRC/include/plugins" $(pkg-config --cflags glib-2.0) $plugin_ld \
        -o "$BUILD/$p.so" plugins/$p.c $(pkg-config --libs glib-2.0)
    ls -la "$BUILD/$p.so"
done

# NOS stand-in (firmware patch, see ../firmware-patches/rom-patches.txt), built
# here from the working tree so that the model runs the sources as they are
# (args.sh); linked at the NOS entry
# 0x5149E4C4 (CS0 0x9E4C4 seen through the kernel's NOS window at 0x51400000).
NOS=../firmware-patches/nos-stub
arm-none-eabi-as -march=armv4t -o "$BUILD/nos_stub.o" $NOS/nos_stub.S
arm-none-eabi-ld -Ttext=0x5149E4C4 -o "$BUILD/nos_stub.elf" "$BUILD/nos_stub.o"
arm-none-eabi-objcopy -O binary "$BUILD/nos_stub.elf" "$BUILD/nos-stub.bin"
arm-none-eabi-as -march=armv4t -o "$BUILD/nos_dll.o" $NOS/nos_dll.S
arm-none-eabi-gcc -march=armv4t -marm -mthumb-interwork -Os -std=gnu11 -ffreestanding \
    -fno-builtin -fno-pic -fno-common -fno-unwind-tables -fno-asynchronous-unwind-tables \
    -Wall -Wextra -c -o "$BUILD/nos_isi.o" $NOS/nos_isi.c
arm-none-eabi-ld -T $NOS/nos_dll.ld -o "$BUILD/nos_dll.elf" "$BUILD/nos_dll.o" "$BUILD/nos_isi.o" \
    "$(arm-none-eabi-gcc -march=armv4t -marm -print-libgcc-file-name)"
arm-none-eabi-objcopy -O binary "$BUILD/nos_dll.elf" "$BUILD/nos-dll.bin"
ls -la "$BUILD/nos-stub.bin" "$BUILD/nos-dll.bin"
