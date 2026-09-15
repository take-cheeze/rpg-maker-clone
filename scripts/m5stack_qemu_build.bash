#!/usr/bin/env bash
# Builds a QEMU binary with this repo's downstream device patches
# (app/m5stack/qemu/patches/*.patch) for the M5Stack Core platform
# (docs/adr/0157): ILI9341 display support and FACES kit Gamepad Face
# support. Espressif's own qemu-xtensa release binaries are precompiled and
# cannot pick up new C device models, so -- exactly like
# scripts/wio_renode_build.bash does for Renode's two new peripherals --
# this clones espressif/qemu's source, applies both patches in sequence,
# and builds with meson/ninja.
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
# libgcrypt/libslirp dev headers -- `apt-get install -y git meson
# ninja-build pkg-config libglib2.0-dev libpixman-1-dev libgcrypt20-dev
# libslirp-dev`. The last two are easy to miss locally if they just happen
# to already be installed (as they were the first time this script was
# written and tested):
# - hw/misc/esp32_flash_enc.c (unrelated to this patch, and unconditionally
#   compiled for any xtensa-softmmu build of this fork) includes
#   <gcrypt.h> with no CONFIG_GCRYPT guard, so it is a hard build
#   dependency of this fork's ESP32 target -- `--disable-gcrypt` would not
#   help even if this build had a use for it.
# - net/slirp.c *is* properly gated behind meson's own `slirp` feature
#   (net/meson.build's `when: slirp`), but `--disable-slirp` does not
#   actually skip it in this exact meson.build: its slirp-detection block
#   (around meson.build's own `slirp = not_found` / `if not
#   get_option('slirp').auto() or have_system`) unconditionally
#   `declare_dependency()`-wraps the pkg-config lookup result even when
#   that lookup was itself skipped for a disabled feature, and a
#   `declare_dependency()`-wrapped dependency reports found() regardless
#   -- confirmed directly: `--disable-slirp` still left the meson summary
#   reporting "slirp support: YES" and net/slirp.c still in the build,
#   still failing the same missing-header compile it would without the
#   flag at all. Installing libslirp-dev sidesteps the bug entirely by
#   making the pkg-config lookup genuinely succeed instead of needing it
#   to genuinely fail.
# None of these are repo dependencies, same as Renode's own native-core
# toolchain requirement for the Wio port.
#
# m5stack-gamepad.patch adds hw/i2c/esp32_faces_gamepad.c, an I2C slave
# device modelling the FACES kit Gamepad Face's own real MEGA328 firmware
# (github.com/m5stack/FACES-Firmware, GameBoy.ino) on the ESP32 machine's
# internal I2C0 bus at address 0x08 -- see that new file's own header
# comment for the full protocol and for ESP32_FACES_GAMEPAD_STATE_PATH, the
# env var a test/CI script sets to simulate a held button combination (see
# scripts/m5stack_qemu_boot.bash's own M5STACK_GAMEPAD_STATE wrapper).
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
# In case an earlier run of this script left the patches applied (or
# partially applied) in a cached $SRC_DIR -- always start from a clean
# checkout of $QEMU_REF, same as wio_renode_build.bash's submodule update
# --force.
git -C "$SRC_DIR" clean -fdx hw/display hw/gpio hw/i2c hw/ssi hw/xtensa include/hw/gpio
git -C "$SRC_DIR" checkout -- hw/display hw/gpio hw/i2c hw/ssi hw/xtensa include/hw/gpio

git -C "$SRC_DIR" apply "$REPO_ROOT/app/m5stack/qemu/patches/m5stack-display.patch"
git -C "$SRC_DIR" apply "$REPO_ROOT/app/m5stack/qemu/patches/m5stack-gamepad.patch"

BUILD_DIR="$OUT_DIR/build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
# xtensa-softmmu alone (not the default all-target-list build) is what
# keeps this to a single machine model's worth of compilation -- the same
# reasoning as wio_renode_build.bash trimming Renode's CORES list down to
# arm-m.le. The --disable-* flags drop optional features this headless,
# -nographic-only use has no need for (curses/VNC UI, PNG loading,
# qemu-nbd's SELinux support, DMG/bzip2 image support) -- meson's own
# "auto" default for each would otherwise silently pull in whichever of
# their dev packages happen to already be installed on whatever machine
# runs this script, the same failure mode libgcrypt20-dev's own comment
# above just described, except here the fix is "don't need it at all"
# rather than "install it": unlike gcrypt and slirp (both genuinely
# required regardless, per that comment), curses/vnc/png/selinux/bzip2 are
# all properly gated behind their own meson `when:` conditions and
# actually do drop out cleanly when disabled -- confirmed directly, unlike
# --disable-slirp.
"$SRC_DIR/configure" --target-list=xtensa-softmmu --disable-docs \
  --disable-curses --disable-vnc --disable-png \
  --disable-selinux --disable-bzip2
ninja qemu-system-xtensa

echo "Built: $BUILD_DIR/qemu-system-xtensa"
echo "Run:   M5STACK_QEMU_BIN=$BUILD_DIR/qemu-system-xtensa scripts/m5stack_qemu_boot.bash <pio-build-dir>"
