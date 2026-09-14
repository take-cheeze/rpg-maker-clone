#!/usr/bin/env bash
# Boots the M5Stack Core firmware (app/m5stack, env:m5stack) under
# Espressif's own QEMU fork (docs/adr/0157-m5stack-core-qemu-emulator.md) --
# a real ESP32 machine, not a from-scratch model, unlike Renode (which ships
# no ESP32/Xtensa platform at all -- see that ADR's feasibility section).
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
#   scripts/m5stack_qemu_boot.bash app/m5stack/.pio/build/m5stack [timeout-seconds, default 15]
#
# $1 must be a PlatformIO build directory for env:m5stack (or m5stack_qemu,
# which extends it) -- bootloader.bin/partitions.bin/firmware.bin all come
# from there, the same three files `pio run -t upload` would normally hand to
# esptool.py write_flash for a real board.
#
# Exit status: 0 once the real Xtensa CPU has run all the way through this
# project's own setup() (m5stack.cxx's LVGL display + button HAL init) and
# printed its "m5stack: setup complete" marker (app/m5stack/src/main.cxx) --
# not just booted, the actual firmware doing actual HAL work: the GPIO log
# lines from m5stack_input_init() configuring pins 39/38/37, then at least
# one "Keys: ..." line from loop() scanning them.
#
# Getting here needed `app/m5stack`'s own env:m5stack to build Arduino as an
# ESP-IDF component (`framework = arduino, espidf`), not plain
# `framework = arduino`: the precompiled Arduino static libs plain mode
# links hit a real assert in their own SPI flash re-probe under this exact
# QEMU release (`do_core_init`, `esp_flash_init_default_chip() != ESP_OK`)
# before Serial.begin() ever runs, while the exact same ESP-IDF version
# (4.4.7) built from source as a component does not -- see docs/adr/0157's
# "Status" section for the full isolation (a controlled comparison against a
# plain ESP-IDF "hello world" ruled out this script's own QEMU/merge_bin/
# eFuse setup, then a second comparison against the from-source component
# build ruled out the IDF version itself, narrowing the fault to the
# precompiled libs specifically).
#
# What's still not observable this way: no SPI TFT panel or GPIO-injection
# device exists upstream in `espressif/qemu` (checked directly against
# hw/display, hw/ssi, hw/gpio), so a rendered frame or a real button press
# stay out of reach -- see app/m5stack/README.md's own "What the emulator
# can and cannot show".
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

# See the file header comment: this is the real bar now (setup() actually
# ran, including the display/button HAL init), not just "the CPU is
# running something".
if grep -q "m5stack: setup complete" "$log" && grep -q "^Keys:" "$log"; then
  echo "m5stack_qemu_boot: reached setup() and loop(), buttons scanned"
  exit 0
fi

echo "m5stack_qemu_boot: did not reach 'm5stack: setup complete' -- see $log" >&2
exit 1
