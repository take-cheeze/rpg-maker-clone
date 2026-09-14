#!/usr/bin/env bash
# Builds a QEMU binary with this repo's ILI9341 display support
# (app/m5stack/qemu/patches/m5stack-display.patch) for the M5Stack Core
# platform (docs/adr/0157). Espressif's own qemu-xtensa release binaries are
# precompiled and cannot pick up new C device models, so -- exactly like
# scripts/wio_renode_build.bash does for Renode's two new peripherals --
# this clones espressif/qemu's source, applies the patch, and builds with
# meson/ninja.
#
# The patch adds hw/display/esp32_ili9341.c (a new ILI9341 SPI TFT device,
# modelled on this repo's own Renode peripheral,
# app/wio/renode/peripherals/Video/ILI9341_SPI.cs), wires it onto the ESP32
# machine's VSPI (SPI3) CS0 with D/C on GPIO27 (matching env:m5stack's own
# TFT_eSPI build_flags in app/m5stack/platformio.ini), extends the
# previously read-only hw/gpio/esp32_gpio.c to actually drive its output
# pins (needed for the D/C line), and fixes a real upstream bug in
# hw/ssi/esp32_spi.c: esp32_spi_do_command() gated its SPI "command phase"
# on `SPI_USER.SPI_USR_COMMAND || SPI_USER2.SPI_USR_COMMAND_BITLEN`, but
# esp32_spi_reset_hold() leaves SPI_USER2.SPI_USR_COMMAND_BITLEN at a
# nonzero post-reset default (4) -- so any driver that never explicitly
# zeroes it (TFT_eSPI's ESP32 driver among them, which addresses the ILI9341
# entirely through a GPIO D/C line and never uses the SPI controller's own
# command phase) got a phantom one-byte command phase silently prepended to
# every "user" SPI transaction. Confirmed directly: a raw byte trace against
# a real TFT_eSPI ESP32 build showed every single SPI byte -- command bytes,
# CASET/PASET parameters, RAMWR pixel data alike -- preceded by an extra
# 0x00, and a standalone fillScreen()+fillRect() test firmware rendered as a
# checkerboard of correct and byte-swapped RGB565 colors (whichever half
# happened to still be byte-aligned after that phantom byte) until this fix
# landed. Per the ESP32 TRM, SPI_USER.SPI_USR_COMMAND is what enables the
# command phase at all; SPI_USER2.SPI_USR_COMMAND_BITLEN only matters once
# that phase is enabled.
#
# Needs: git, meson, ninja, pkg-config, glib2/pixman dev headers, and
# libgcrypt dev headers -- `apt-get install -y git meson ninja-build
# pkg-config libglib2.0-dev libpixman-1-dev libgcrypt20-dev`. The last one is
# easy to miss locally if it just happens to already be installed (as it was
# the first time this script was written and tested): upstream
# hw/misc/esp32_flash_enc.c (unrelated to this patch, and unconditionally
# compiled for any xtensa-softmmu build of this fork) includes <gcrypt.h>
# with no CONFIG_GCRYPT guard, so it is a hard build dependency of this
# fork's ESP32 target, not an optional one meson's own `gcrypt` feature
# option would suggest. None of these are repo dependencies, same as
# Renode's own native-core toolchain requirement for the Wio port.
#
# Usage:
#   scripts/m5stack_qemu_build.bash [output-dir, default /tmp/m5stack-qemu-build]
# Then: M5STACK_QEMU_BIN=<output-dir>/build/qemu-system-xtensa \
#       scripts/m5stack_qemu_boot.bash <pio-build-dir>
set -euo pipefail

OUT_DIR="${1:-/tmp/m5stack-qemu-build}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Espressif's own tools.json (esp-idf/tools/tools.json) pins this exact
# release; kept in sync by hand rather than fetched at run time, the same
# way scripts/wio_renode_build.bash pins RENODE_REF. Must match
# scripts/m5stack_qemu_boot.bash's own fallback (prebuilt) release tag, and
# the patch was generated against -- and verified to still apply cleanly
# against -- this exact tag.
QEMU_REF="${QEMU_REF:-esp-develop-9.2.2-20260417}"

mkdir -p "$OUT_DIR"
SRC_DIR="$OUT_DIR/qemu-src"

if [[ ! -d "$SRC_DIR" ]]; then
  git clone https://github.com/espressif/qemu.git "$SRC_DIR"
fi

git -C "$SRC_DIR" checkout "$QEMU_REF"
# In case an earlier run of this script left the patch applied (or partially
# applied) in a cached $SRC_DIR -- always start from a clean checkout of
# $QEMU_REF, same as wio_renode_build.bash's submodule update --force.
git -C "$SRC_DIR" clean -fdx hw/display hw/gpio hw/ssi hw/xtensa include/hw/gpio
git -C "$SRC_DIR" checkout -- hw/display hw/gpio hw/ssi hw/xtensa include/hw/gpio

git -C "$SRC_DIR" apply "$REPO_ROOT/app/m5stack/qemu/patches/m5stack-display.patch"

BUILD_DIR="$OUT_DIR/build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
# xtensa-softmmu alone (not the default all-target-list build) is what
# keeps this to a single machine model's worth of compilation -- the same
# reasoning as wio_renode_build.bash trimming Renode's CORES list down to
# arm-m.le.
"$SRC_DIR/configure" --target-list=xtensa-softmmu --disable-docs
ninja qemu-system-xtensa

echo "Built: $BUILD_DIR/qemu-system-xtensa"
echo "Run:   M5STACK_QEMU_BIN=$BUILD_DIR/qemu-system-xtensa scripts/m5stack_qemu_boot.bash <pio-build-dir>"
