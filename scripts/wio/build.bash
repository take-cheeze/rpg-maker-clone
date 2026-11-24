#!/usr/bin/env bash
# Builds the Wio game firmware (`pio run -e wio`) from a bare checkout: the wio-world static dispatch lists, the
# closed-world wio libmruby (WIO_MRUBY_BUILD_DIR), a standalone arm-none-eabi uni-algo (WIO_UNIALGO_LIB_DIR), then
# the firmware link. CI's `wio` job runs this.
#
# The image does not fit the board's flash yet, so the link runs with --noinhibit-exec: the ELF and the size lines
# are the measurement, an overflow is reported, and only an undefined reference or a failed vector-table check
# (scripts/wio/vector_table_check.rb) fails the script.
#
# Usage:
#   scripts/wio/build.bash [BUILD_DIR, default ./build-wio]
# The link log is BUILD_DIR/pio-wio.log (scripts/wio/size_report.rb reads it); the ELF is .pio/build/wio/firmware.elf.
#
# Needs pio on PATH and what scripts/bc2cpp/static_dispatch_lists.bash needs (ruby with prism, rake, gcc, bison,
# gperf): the nix `bc2cpp` shell. MRBC, when set, is a host mrbc of this tree's mruby pin (else one is built).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
build_dir="${1:-$root/build-wio}"
mkdir -p "$build_dir"
build_dir="$(cd "$build_dir" && pwd)"
cd "$root" || exit 1
# The nix shell's LD is the host linker, which the cross build would otherwise pick up.
unset LD

# The arm-none-eabi toolchain, the Arduino framework and the lib_deps whose headers the mruby-rgss HAL compiles
# against. A fresh machine has none of them until PlatformIO installs them.
pio pkg install -s -e wio
pio pkg install -s -e wio_sd_upload
pio_home="${PLATFORMIO_CORE_DIR:-$HOME/.platformio}"
toolchain="$pio_home/packages/toolchain-gccarmnoneeabi/bin"
framework="$pio_home/packages/framework-arduino-samd-seeed"

lists="$(BC2CPP_LISTS_WORLD=wio scripts/bc2cpp/static_dispatch_lists.bash "$build_dir")"
export BC2CPP_STATIC_DISPATCH_LISTS="$lists"

# uni-algo is header-only but for the tables in src/data.cpp, built with cmake/uni-algo-trim.cmake's defines (the
# PUBLIC list plus the data-TU-only NFKC/NFKD one) and the firmware's Cortex-M4F flags.
unialgo="$build_dir/unialgo"
if [ ! -s "$unialgo/libuni-algo.a" ]; then
  mkdir -p "$unialgo"
  "$toolchain/arm-none-eabi-g++" -std=gnu++17 -Os -c \
    -mcpu=cortex-m4 -mthumb -mfloat-abi=hard -mfpu=fpv4-sp-d16 \
    -I "$root/3rd/uni-algo/include" \
    -DUNI_ALGO_DISABLE_CASE -DUNI_ALGO_DISABLE_PROP \
    -DUNI_ALGO_DISABLE_SCRIPT -DUNI_ALGO_DISABLE_SEGMENT_GRAPHEME \
    -DUNI_ALGO_DISABLE_SEGMENT_WORD -DUNI_ALGO_DISABLE_NFKC_NFKD \
    "$root/3rd/uni-algo/src/data.cpp" -o "$unialgo/data.o"
  "$toolchain/arm-none-eabi-ar" rcs "$unialgo/libuni-algo.a" "$unialgo/data.o"
fi

# The framework's own headers, so the HAL's wio.o has the ABI the PlatformIO objects have (build_config.rb,
# RGSS_WIO_ARDUINO_INCLUDES).
inc=""
for d in "$framework"/libraries/*/ "$framework"/libraries/*/src/; do inc="$inc${d%/}:"; done
inc="$inc$pio_home/packages/framework-cmsis-atmel/CMSIS/Device/ATMEL/samd51/include"
inc="$inc:$pio_home/packages/framework-cmsis/CMSIS/Core/Include:$framework/cores/arduino"
inc="$inc:$framework/variants/wio_terminal:$root/.pio/libdeps/wio_sd_upload/Seeed Arduino FS/src:$root/app/wio"

# shellcheck source=scripts/mruby/standalone_prep.bash
. "$root/scripts/mruby/standalone_prep.bash"
(
  cd "$root/3rd/mruby" || exit 1
  RPGMAKER_BC2CPP=1 MRUBY_TARGET=wio MRUBY_BUILD_DIR="$build_dir" PROJECT_BUILD_DIR="$build_dir" \
    RGSS_WIO_ARDUINO_INCLUDES="$inc" MRUBY_CONFIG="$root/build_config.rb" rake -m -j"$(nproc)"
)

log="$build_dir/pio-wio.log"
rc=0
WIO_MRUBY_BUILD_DIR="$build_dir/wio" WIO_UNIALGO_LIB_DIR="$unialgo" \
  PLATFORMIO_BUILD_FLAGS="-Wl,--noinhibit-exec -Wl,--print-memory-usage" \
  pio run -e wio >"$log" 2>&1 || rc=$?
cat "$log"
elf="$root/.pio/build/wio/firmware.elf"
undefined="$(grep -c 'undefined reference' "$log" || true)"
echo "undefined refs: $undefined"
grep -E "region \`[A-Z]+' overflowed by [0-9]+ bytes" "$log" || true
[ "$undefined" = 0 ] || exit 1
# With --noinhibit-exec pio still exits non-zero on the overflow; the ELF must exist all the same.
[ -s "$elf" ] || { echo "error: pio run -e wio (exit $rc) wrote no $elf" >&2; exit 1; }
ruby "$root/scripts/wio/vector_table_check.rb" "$elf"
