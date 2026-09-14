#!/usr/bin/env bash
# Boots the M5Stack Core firmware (env:m5stack) under Espressif's own QEMU
# fork (docs/adr/0157-m5stack-core-qemu-emulator.md) -- a real ESP32 machine,
# not a from-scratch model, unlike Renode (which ships no ESP32/Xtensa
# platform at all -- see that ADR's feasibility section).
#
# Unlike the Wio Terminal's Renode setup (scripts/wio_renode_build.bash),
# this does not build anything from source: Espressif publishes a prebuilt
# qemu-xtensa release for exactly this purpose (the same binary `idf.py qemu`
# uses), fetched here the first time this script runs and cached.
#
# Needs: a Debian/Ubuntu-style libSDL2/libslirp0 runtime (the release tarball
# links against both even in -nographic mode) -- `apt-get install -y
# libsdl2-2.0-0 libslirp0` if qemu-system-xtensa fails to start with a
# "cannot open shared object file" error. Not a repo dependency, same as
# Renode for the Wio/Maix ports.
#
# Usage:
#   scripts/m5stack_qemu_boot.bash .pio/build/m5stack [timeout-seconds, default 15]
#
# $1 must be the PlatformIO build directory for env:m5stack (or m5stack_qemu,
# which extends it) -- bootloader.bin/partitions.bin/firmware.bin all come
# from there, the same three files `pio run -t upload` would normally hand to
# esptool.py write_flash for a real board.
#
# Exit status: 0 once the real Xtensa CPU has fetched and is executing this
# project's own compiled second-stage bootloader (the "load:0x...,len:..."
# lines ROM prints while loading it, then its own "entry 0x..." jump) --
# proof the exact firmware just built actually runs under QEMU, not just
# that it links.
#
# **This is not "setup complete".** Every firmware reaching that point hits a
# real assert during the app's own SPI flash re-probe (`do_core_init`,
# `esp_flash_init_default_chip() != ESP_OK`) before Serial.begin() ever runs,
# so the marker main.cxx's setup() prints is not yet a reachable checkpoint.
# This has been isolated to a real, external cause, not a bug in this
# project's own firmware/HAL code and not a QEMU limitation in general:
#
#   - A plain ESP-IDF "hello world" (`platform = espressif32, framework =
#     espidf`, no Arduino) built against ESP-IDF 6.1.0 boots this exact QEMU
#     setup cleanly all the way through `app_main()`, printing on the real
#     UART -- proof the QEMU invocation, efuse image and merge_bin flash
#     layout below are all correct.
#   - `framework-arduinoespressif32` (checked directly:
#     ~/.platformio/packages/framework-arduinoespressif32/tools/sdk/versions.txt),
#     even at the latest version PlatformIO's espressif32 platform installs,
#     still vendors **ESP-IDF v4.4.7** -- a fixed, precompiled `libspi_flash.a`
#     this project cannot change from platformio.ini. Something in that much
#     older SPI flash generic-chip driver does not get along with this QEMU
#     release's simulated flash chip; asserting on the exact same code
#     (`do_core_init`) against a current IDF works, so the fix is upstream
#     (either PlatformIO packaging a newer Arduino-ESP32 core, or an IDF
#     backport), not something to patch around here. See docs/adr/0157's
#     own "Status" section for the full isolation.
#
# This script still exits non-zero if even the bootloader-load banner is
# missing -- that would mean something upstream of the known gap regressed
# (a bad ELF, a merge_bin/efuse mismatch, QEMU itself not starting).
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <pio-build-dir> [timeout-seconds, default 15]" >&2
  exit 1
fi

build_dir="$(cd "$1" && pwd)"
timeout_s="${2:-15}"
cache_dir="${M5STACK_QEMU_CACHE_DIR:-/tmp/m5stack-qemu}"

# Espressif's own tools.json (esp-idf/tools/tools.json) pins this exact
# release; kept in sync by hand rather than fetched at run time, the same way
# scripts/wio_renode_build.bash pins RENODE_REF.
qemu_release="esp-develop-9.2.2-20260417"
qemu_tarball="qemu-xtensa-softmmu-esp_develop_9.2.2_20260417-x86_64-linux-gnu.tar.xz"
qemu_url="https://github.com/espressif/qemu/releases/download/${qemu_release}/${qemu_tarball}"

qemu_dir="$cache_dir/qemu"
qemu_bin="${M5STACK_QEMU_BIN:-$qemu_dir/qemu/bin/qemu-system-xtensa}"

if [[ ! -x "$qemu_bin" ]]; then
  mkdir -p "$qemu_dir"
  echo "m5stack_qemu_boot: fetching $qemu_url" >&2
  curl -fsSL -o "$cache_dir/qemu.tar.xz" "$qemu_url"
  tar -xJf "$cache_dir/qemu.tar.xz" -C "$qemu_dir"
fi

export LD_LIBRARY_PATH="$qemu_dir/qemu/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# A standalone `pip install esptool` (what CI's m5stack-qemu job installs,
# since it only downloads the m5stack job's build artifacts and never runs
# `pio run` itself) takes priority; otherwise fall back to whatever
# esptool.py PlatformIO's own espressif32 platform already installed to
# build $build_dir, so a local `pio run -e m5stack` + this script needs no
# separate pip dependency either.
if command -v esptool.py >/dev/null 2>&1; then
  esptool_cmd=(esptool.py)
else
  esptool_py="$(find "$HOME/.platformio/packages/tool-esptoolpy" -name esptool.py 2>/dev/null | head -1)"
  if [[ -z "$esptool_py" ]]; then
    echo "error: esptool not found -- 'pip install esptool' or run 'pio run -e m5stack' first" >&2
    exit 1
  fi
  esptool_cmd=(python3 "$esptool_py")
fi

flash_img="$cache_dir/flash.bin"
"${esptool_cmd[@]}" --chip esp32 merge_bin -o "$flash_img" \
  --flash_mode dio --flash_freq 40m --flash_size 4MB --fill-flash-size 4MB \
  0x1000 "$build_dir/bootloader.bin" \
  0x8000 "$build_dir/partitions.bin" \
  0x10000 "$build_dir/firmware.bin"

# The eFuse image real hardware would already have burned (chip revision 3,
# the same defaults `idf.py qemu` writes for the esp32 target) -- copied
# verbatim from esp-idf's tools/idf_py_actions/qemu_ext.py QEMU_TARGETS
# table. Without it, ROM's own early boot reads unburned (all-zero) chip
# revision efuse bits and behaves differently than any real board would.
efuse_img="$cache_dir/efuse.bin"
python3 -c "
import binascii
open('$efuse_img', 'wb').write(binascii.unhexlify(
    '00000000000000000000000000800000000000000000100000000000000000000000000000000000'
    '00000000000000000000000000000000000000000000000000000000000000000000000000000000'
    '00000000000000000000000000000000000000000000000000000000000000000000000000000000'
    '00000000'
))
"

log="$cache_dir/serial.log"
: > "$log"

set +e
timeout "${timeout_s}s" "$qemu_bin" -nographic -no-reboot \
  -M esp32 -m 4M \
  -drive "file=$flash_img,if=mtd,format=raw" \
  -drive "file=$efuse_img,if=none,format=raw,id=efuse" \
  -global driver=nvram.esp32.efuse,property=drive,value=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -serial mon:stdio >"$log" 2>&1
set -e

cat "$log"

# See the file header comment: this is the current, honest bar (the CPU is
# really executing this build's own second-stage bootloader), not
# "setup complete" -- the known do_core_init gap sits just past it.
if grep -q "SPI_FAST_FLASH_BOOT" "$log" && grep -q "entry 0x" "$log"; then
  echo "m5stack_qemu_boot: reached second-stage bootloader entry (known gap past this point: do_core_init flash probe, see docs/adr/0157)"
  exit 0
fi

echo "m5stack_qemu_boot: did not even reach the bootloader entry point -- see $log" >&2
exit 1
