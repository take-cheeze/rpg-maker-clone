#!/usr/bin/env bash
# Standalone riscv64 build of 3rd/uni-algo for the Maix Amigo firmware link.
#
# PlatformIO's LDF cannot build it (no library.json -- platformio.ini's own
# comment on env:maix_rgss_boot says so), so compile the one translation
# unit that carries the tables (src/data.cpp -- uni-algo is header-only
# otherwise) with the exact trim defines cmake/uni-algo-trim.cmake documents
# (the PUBLIC list plus the data-TU-only NFKC/NFKD define) and the same K210
# flags as the mruby cross build. Mirrors scripts/wio_bc2cpp_measure.bash's
# own build_unialgo for arm-none-eabi.
#
# Usage:
#   scripts/maix_unialgo_build.bash [OUT_DIR, default ./build-maix-unialgo]
#
# Needs the Kendryte toolchain: present after any `pio run -e maix_amigo`
# (preferred, same compiler the final link uses), else a hand-installed
# riscv64-unknown-elf-g++ on PATH.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${1:-$root/build-maix-unialgo}"

pio_toolchain="$HOME/.platformio/packages/toolchain-kendryte210/bin"
if [ -x "$pio_toolchain/riscv64-unknown-elf-g++" ]; then
  cxx="$pio_toolchain/riscv64-unknown-elf-g++"
  ar="$pio_toolchain/riscv64-unknown-elf-ar"
else
  cxx=riscv64-unknown-elf-g++
  ar=riscv64-unknown-elf-ar
  command -v "$cxx" >/dev/null || {
    echo "error: no riscv64-unknown-elf-g++ (checked PlatformIO's package and PATH)" >&2
    exit 1
  }
fi

if [ ! -s "$root/3rd/uni-algo/src/data.cpp" ]; then
  echo "error: 3rd/uni-algo is empty -- run: git submodule update --init --recursive" >&2
  exit 1
fi

if [ -s "$out_dir/libuni-algo.a" ]; then
  echo "libuni-algo.a already built at $out_dir -- remove it to rebuild"
  exit 0
fi

mkdir -p "$out_dir"
"$cxx" -std=gnu++17 -Os -c \
  -mcmodel=medany -mabi=lp64f -march=rv64imafc \
  -I "$root/3rd/uni-algo/include" \
  -DUNI_ALGO_DISABLE_CASE -DUNI_ALGO_DISABLE_PROP \
  -DUNI_ALGO_DISABLE_SCRIPT -DUNI_ALGO_DISABLE_SEGMENT_GRAPHEME \
  -DUNI_ALGO_DISABLE_SEGMENT_WORD -DUNI_ALGO_DISABLE_NFKC_NFKD \
  "$root/3rd/uni-algo/src/data.cpp" -o "$out_dir/data.o"
"$ar" rcs "$out_dir/libuni-algo.a" "$out_dir/data.o"
echo "built $out_dir/libuni-algo.a"
