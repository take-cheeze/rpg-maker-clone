#!/usr/bin/env bash

set -eu -o pipefail

# Build app/nano7/qemu/nano7_walk_qemu.elf: the real
# app/nano7/rpg2k_walk/rpg2k_walk.c, cross-compiled with the same
# arm-none-eabi-gcc -mcpu=cortex-a8 NanoApps' own sdk/hb_app.mk uses, linked
# against the bare-metal QEMU shim (docs/adr/0103) with one exported map's
# map.bin/tiles.bin embedded directly into the image -- this target has no
# filesystem at all, so there is nothing to copy onto at install time.
#
# Usage:
#   scripts/nano7_qemu_build.bash MAP_BIN TILES_BIN OUT_ELF

if [ $# -ne 3 ]; then
    echo "usage: $0 MAP_BIN TILES_BIN OUT_ELF" >&2
    exit 1
fi

map_bin=$1
tiles_bin=$2
out_elf=$3
root=$(cd "$(dirname "$0")/.." && pwd)
qemu_dir="$root/app/nano7/qemu"

CC=arm-none-eabi-gcc
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT

# objcopy's generated symbol names (_binary_<name>_start/_end) are derived
# from the exact filename given on its command line, so the blobs are
# staged under fixed names here rather than objcopy'd from wherever the
# exporter wrote them -- app/nano7/qemu/nano7_qemu_shim.c declares those
# exact symbols (_binary_map_bin_*, _binary_tiles_bin_*).
cp "$map_bin" "$build/map.bin"
cp "$tiles_bin" "$build/tiles.bin"
(cd "$build" && arm-none-eabi-objcopy -I binary -O elf32-littlearm -B arm map.bin map_bin.o)
(cd "$build" && arm-none-eabi-objcopy -I binary -O elf32-littlearm -B arm tiles.bin tiles_bin.o)

# -mcpu=cortex-a8: the real device's own core (NanoApps' sdk/hb_app.mk uses
# the same flag). -ffreestanding/-nostdlib: no libc, no OS -- this target
# *is* the entire boot image, per docs/adr/0103.
cflags=(-mcpu=cortex-a8 -marm -ffreestanding -fno-builtin -nostdlib -O2 -Wall -Wextra
        -I"$root/app/nano7/host/include" -I"$root/app/shared/rpg2k_walk")

"$CC" "${cflags[@]}" -c "$qemu_dir/boot.S" -o "$build/boot.o"
"$CC" "${cflags[@]}" -c "$qemu_dir/nano7_qemu_shim.c" -o "$build/shim.o"
"$CC" "${cflags[@]}" -c "$root/app/nano7/shim_common/hb_fb_ops.c" -o "$build/hb_fb_ops.o"
"$CC" "${cflags[@]}" -c "$root/app/shared/rpg2k_walk/rpg2k_walk_core.c" -o "$build/core.o"
"$CC" "${cflags[@]}" -c "$root/app/nano7/rpg2k_walk/rpg2k_walk.c" -o "$build/app.o"

# libgcc: the software divide/multiply helpers (__aeabi_idiv, ...) this
# code needs -- Cortex-A8 has no hardware integer divide -- same trick
# NanoApps' own sdk/hb_app.mk uses to get them without pulling in libc.
libgcc=$("$CC" -mcpu=cortex-a8 -print-libgcc-file-name)

"$CC" -mcpu=cortex-a8 -marm -ffreestanding -nostdlib -nostartfiles \
    -T "$qemu_dir/link.ld" \
    "$build"/boot.o "$build"/shim.o "$build"/hb_fb_ops.o "$build"/core.o "$build"/app.o \
    "$build"/map_bin.o "$build"/tiles_bin.o "$libgcc" \
    -o "$out_elf"

arm-none-eabi-size "$out_elf"
