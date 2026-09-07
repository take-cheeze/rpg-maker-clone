#!/usr/bin/env bash
# Boots a Wio Terminal firmware ELF under Renode (docs/adr/0094) far enough
# to prove the CPU actually runs -- reaches its own setup()/loop() symbols --
# rather than checking it only compiles, which is all CI does today.
#
# Requires the Renode CLI on PATH (or RENODE_BIN pointing at the binary):
# https://github.com/renode/renode/releases -- the *-portable-dotnet.tar.gz
# asset needs no separate .NET install. Not a repo dependency: this script
# is a dev/CI-experimentation tool, nothing else here requires Renode.
#
# Usage:
#   scripts/wio_renode_boot.bash .pio/build/wio_sd_upload/firmware.elf
#   scripts/wio_renode_boot.bash .pio/build/wio_walk/firmware.elf 00:00:02
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <firmware.elf> [virtual-run-duration, default 00:00:00.300]" >&2
  exit 1
fi

elf="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
duration="${2:-00:00:00.300}"
renode="${RENODE_BIN:-renode}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v "$renode" >/dev/null 2>&1; then
  echo "error: '$renode' not found -- install Renode or set RENODE_BIN" >&2
  exit 1
fi

nm="${ARM_NM:-}"
if [[ -z "$nm" ]]; then
  if command -v arm-none-eabi-nm >/dev/null 2>&1; then
    nm=arm-none-eabi-nm
  else
    # PlatformIO's own toolchain (pio run already downloaded this to build
    # the ELF being booted) is not put on PATH by pio itself -- fall back to
    # its well-known install location rather than requiring a separate
    # system arm-none-eabi-nm (CI's `wio-renode` job relies on exactly this;
    # it never installs one).
    nm="$HOME/.platformio/packages/toolchain-gccarmnoneeabi/bin/arm-none-eabi-nm"
  fi
fi
if ! command -v "$nm" >/dev/null 2>&1; then
  echo "error: no arm-none-eabi-nm found (checked PATH and PlatformIO's toolchain) -- set ARM_NM" >&2
  exit 1
fi

setup_addr="0x$("$nm" "$elf" | awk '$3 == "setup" {print $1}')"
loop_addr="0x$("$nm" "$elf" | awk '$3 == "loop" {print $1}')"
if [[ "$setup_addr" == "0x" || "$loop_addr" == "0x" ]]; then
  echo "error: could not find setup/loop symbols in $elf" >&2
  exit 1
fi

exec "$renode" --disable-gui --console --plain \
  -e "set platform_path @$repo_root/app/wio/renode/wio_terminal.repl" \
  -e "set elf_path @$elf" \
  -e "set setup_addr $setup_addr" \
  -e "set loop_addr $loop_addr" \
  -e "set duration \"$duration\"" \
  -e "include @$repo_root/app/wio/renode/boot.resc" \
  -e "quit"
