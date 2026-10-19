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

# Our sources go into the tree as copies so the checkout stays a plain release.
cp hw/ngage.h "$SRC/include/hw/arm/ngage.h"
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
