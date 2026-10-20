#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build the N-Gage reference model (the steps of model/build.sh) on Linux,
# for traces to compare with the RTL boot bench without using the Mac's
# QEMU. Runs on the Verilator machine; sim/cpu/Makefile (boot-model)
# copies the model sources of git HEAD there first.
#
#   build_linux.sh MODEL_SRC DIR [DEPS_ROOT]
#
# MODEL_SRC: a copy of model/ (hw/*.c, hw/ngage.h). DIR: where the QEMU
# checkout (DIR/qemu-src) and build (DIR/build) go. DEPS_ROOT: an extracted
# root with the glib and pixman development files when the system has none
# (pkg-config files there must have their prefix pointed at it).
#
# Differences from model/build.sh: GNU sed, no SDL display, and the NOS
# stand-in is not assembled here (no ARM toolchain on this machine; the boot
# bench's images already carry it, see sim/cpu/boot/prep.py).
set -euo pipefail

msrc=$(cd "$1" && pwd)
mkdir -p "$2"; dir=$(cd "$2" && pwd)
deps=${3:-}
QEMU_TAG=v11.1.2
SRC=$dir/qemu-src
BUILD=$dir/build
mkdir -p "$dir"

if [[ ! -d $SRC ]]; then
	git clone -q --depth 1 --branch "$QEMU_TAG" https://gitlab.com/qemu-project/qemu.git "$SRC"
fi

cp "$msrc/hw/ngage.h" "$SRC/include/hw/arm/ngage.h"
cp "$msrc"/hw/ngage*.c "$SRC/hw/arm/"

if ! grep -q '^config NGAGE' "$SRC/hw/arm/Kconfig"; then
	printf '\nconfig NGAGE\n    bool\n    default y\n    depends on TCG && ARM\n' >> "$SRC/hw/arm/Kconfig"
fi
srcs=$(cd "$msrc/hw" && ls ngage*.c | sed "s/.*/'&'/" | paste -sd, -)
line="arm_common_ss.add(when: 'CONFIG_NGAGE', if_true: files($srcs))"
if grep -q "CONFIG_NGAGE" "$SRC/hw/arm/meson.build"; then
	sed -i "s|^arm_common_ss.add(when: 'CONFIG_NGAGE'.*|$line|" "$SRC/hw/arm/meson.build"
else
	sed -i "s|^arm_common_ss.add(files('boot.c'))|$line\narm_common_ss.add(files('boot.c'))|" "$SRC/hw/arm/meson.build"
fi

if [[ -n $deps ]]; then
	export PKG_CONFIG_PATH=$deps/usr/lib/x86_64-linux-gnu/pkgconfig
	export LIBRARY_PATH=$deps/usr/lib/x86_64-linux-gnu
fi
if [[ ! -f $BUILD/build.ninja ]]; then
	mkdir -p "$BUILD"
	(cd "$BUILD" && "$SRC/configure" --target-list=arm-softmmu --enable-plugins \
		--disable-sdl --disable-gtk --disable-docs --disable-werror --disable-guest-agent \
		--disable-tools >/dev/null)
fi
ninja -C "$BUILD" qemu-system-arm contrib-plugins 2>&1 | tail -3
ls -la "$BUILD/qemu-system-arm"
