#!/usr/bin/env bash
# Boots a Maix Amigo firmware ELF under stock Renode (app/maix/renode/) far
# enough to prove the CPU actually runs -- reaches its own setup()/loop()
# symbols and prints "maix-amigo hello" plus the heartbeat over the emulated
# UARTHS -- rather than checking it only compiles, which is all the `maix` CI
# job does.
#
# Requires a Renode CLI on PATH (or RENODE_BIN pointing at the binary):
# https://github.com/renode/renode/releases -- the linux-portable asset needs
# no separate .NET install, and no from-source build: the K210 SoC
# description this boots (dual RV64, UARTHS, CLINT, PLIC) ships in stock
# Renode, with only the two tiny Python stubs in app/maix/renode/ on top.
# CI's `maix-smoke` job pins the release it downloads.
#
# Usage:
#   scripts/maix_renode_boot.bash .pio/build/maix_amigo/firmware.elf
#   scripts/maix_renode_boot.bash .pio/build/maix_amigo/firmware.elf 00:00:10
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <firmware.elf> [virtual-run-duration, default 00:00:05]" >&2
  exit 1
fi

elf="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
duration="${2:-00:00:05}"
renode="${RENODE_BIN:-renode}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
renode_dir="$repo_root/app/maix/renode"

if ! command -v "$renode" >/dev/null 2>&1; then
  echo "error: '$renode' not found -- install Renode or set RENODE_BIN" >&2
  exit 1
fi

nm="${RISCV_NM:-}"
if [[ -z "$nm" ]]; then
  if command -v riscv64-unknown-elf-nm >/dev/null 2>&1; then
    nm=riscv64-unknown-elf-nm
  else
    # PlatformIO's own toolchain (pio run already downloaded this to build
    # the ELF being booted) is not put on PATH by pio itself -- fall back to
    # its well-known install location rather than requiring a separate
    # system riscv64-unknown-elf-nm (CI's `maix-smoke` job relies on exactly
    # this; it never installs one). Mirrors scripts/wio_renode_boot.bash.
    nm="$HOME/.platformio/packages/toolchain-kendryte210/bin/riscv64-unknown-elf-nm"
  fi
fi
if ! command -v "$nm" >/dev/null 2>&1; then
  echo "error: no riscv64-unknown-elf-nm found (checked PATH and PlatformIO's toolchain) -- set RISCV_NM" >&2
  exit 1
fi

setup_addr="0x$("$nm" "$elf" | awk '$3 == "setup" {print $1}')"
loop_addr="0x$("$nm" "$elf" | awk '$3 == "loop" {print $1}')"
if [[ "$setup_addr" == "0x" || "$loop_addr" == "0x" ]]; then
  echo "error: could not find setup/loop symbols in $elf" >&2
  exit 1
fi

# Address of the DMA copy hook (boot.resc): 0x0 when the ELF has
# no such symbol (a firmware that never uses DMA) -- an address PC never
# reaches, so the hook is inert rather than failing the boot.
dma_enable_addr="0x$("$nm" "$elf" | awk '$3 == "dmac_channel_enable" {print $1}')"
[[ "$dma_enable_addr" == "0x" ]] && dma_enable_addr="0x0"

# The capture stream (the DMA hook's `D` lines) lands here when set (else
# /tmp/maix-spi.log). Truncated up front so a rerun never appends to a stale
# capture.
export MAIX_SPI_LOG="${MAIX_SPI_LOG:-${TMPDIR:-/tmp}/maix-spi.log}"
rm -f "$MAIX_SPI_LOG"

# amigo.repl.template and dma_hook.py.template are not loadable as-is: a
# .repl cannot take -e "set" variables the way boot.resc does, so the Python
# stub paths and the hook address are filled in here (see the templates' own
# comments). Fixed location, not mktemp: a failed boot is debugged by
# re-running Renode on exactly these files.
repl_out="${TMPDIR:-/tmp}/maix-renode-amigo.repl"
hook_out="${TMPDIR:-/tmp}/maix-dma-hook.py"
sed "s|@MAIX_RENODE_DIR@|$renode_dir|" "$renode_dir/amigo.repl.template" > "$repl_out"
sed "s|@DMA_ADDR@|$dma_enable_addr|" "$renode_dir/dma_hook.py.template" > "$hook_out"

exec "$renode" --disable-gui --console --plain \
  -e "set repl_path @$repl_out" \
  -e "set elf_path @$elf" \
  -e "set setup_addr $setup_addr" \
  -e "set loop_addr $loop_addr" \
  -e "set dma_hook_path @$hook_out" \
  -e "set duration \"$duration\"" \
  -e "include @$renode_dir/boot.resc" \
  -e "quit"
