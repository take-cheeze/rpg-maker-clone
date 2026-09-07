#!/usr/bin/env bash
# Builds a Renode binary with this repo's two new peripherals
# (app/wio/renode/peripherals/) for the Wio Terminal platform's P3
# (docs/adr/0094): SPI.SAMD51_SERCOM_SPI (a real SERCOM-in-SPI-mode
# controller -- nothing upstream models SERCOM in any mode) and
# Video.ILI9341_SPI (an SPI-command-stream -> framebuffer model -- nothing
# upstream models any SPI TFT). Renode's own release binaries are
# precompiled and cannot pick up new C# peripherals, so this clones Renode's
# source, drops the two files in, and builds with build.sh --no-gui.
#
# Needs: git, cmake, gcc/g++ (for tlib's native CPU cores) and the .NET 8
# SDK (not just the runtime the portable release bundles) -- none of them
# repo dependencies, same as Renode itself.
#
# Usage:
#   scripts/wio_renode_build.bash [output-dir, default /tmp/wio-renode-build]
# Then: RENODE_BIN=<output-dir>/renode-src/renode scripts/wio_renode_boot.bash ...
set -euo pipefail

OUT_DIR="${1:-/tmp/wio-renode-build}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RENODE_REF="${RENODE_REF:-ab721d88e135a1bcb8ed2ecc5a38f51cbe61fdd2}"

mkdir -p "$OUT_DIR"
SRC_DIR="$OUT_DIR/renode-src"

if [[ ! -d "$SRC_DIR" ]]; then
  git clone --recurse-submodules --shallow-submodules https://github.com/renode/renode.git "$SRC_DIR"
fi

git -C "$SRC_DIR" checkout "$RENODE_REF"
git -C "$SRC_DIR" submodule update --init --recursive

peripherals_dir="$SRC_DIR/src/Infrastructure/src/Emulator/Peripherals/Peripherals"
cp "$REPO_ROOT/app/wio/renode/peripherals/SPI/SAMD51_SERCOM_SPI.cs" "$peripherals_dir/SPI/"
cp "$REPO_ROOT/app/wio/renode/peripherals/Video/ILI9341_SPI.cs" "$peripherals_dir/Video/"

cd "$SRC_DIR"
./build.sh --no-gui

echo "Built: $SRC_DIR/renode"
echo "Run:   RENODE_BIN=$SRC_DIR/renode scripts/wio_renode_boot.bash <firmware.elf>"
