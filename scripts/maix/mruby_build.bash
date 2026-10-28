#!/usr/bin/env bash
# Build the Maix Amigo (K210) mruby cross lib -- build_config.rb's `maix`
# MRuby::CrossBuild -- the PSP pipeline's exact analog (app/psp's EBOOT build
# drives its own `psp` cross-build the same way): a native host mruby first
# (producing mrbc, which compiles the target .rb sources to bytecode), then
# the riscv64 cross lib the PlatformIO firmware (app/maix, platformio.ini
# env:maix_amigo) links in a later slice. The bring-up firmware links neither
# libmruby nor any input bridge yet; this exists so the interpreter can be
# layered on next, and so CI breaks loudly the moment a patch or gem stops
# cross-compiling -- the same reason the `psp` job builds its EBOOT.
#
# Usage:
#   scripts/maix/mruby_build.bash [BUILD_DIR, default ./build-maix-mruby]
#
# Needs on PATH: ruby, rake, a native C/C++ compiler (the host half), bison
# and gperf (the pinned fork commit (mruby-defined-keyword, docs/patch-fork-tracking.md) touches mruby-compiler's
# keywords, forcing lex.def to regenerate -- same reason the `psp` CI job
# installs them), and either PlatformIO's Kendryte toolchain (present after
# any `pio run -e maix_amigo`, which build_config.rb prefers) or a
# hand-installed riscv64-unknown-elf-gcc. CI's `maix` job installs all of
# this; the Unicode tables below are copied from data/unicode-mappings/ the
# same way the `psp` job stages them (same pins, same hashes).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
build_dir="${1:-$root/build-maix-mruby}"
# Tools, Unicode tables and mruby patches (shared with the `closed` build).
# shellcheck source=scripts/mruby/standalone_prep.bash
. "$root/scripts/mruby/standalone_prep.bash"
# The cross build leaves the core ROM entries the closed-list proof lists out of its method tables
# (build_config.rb, bc2cpp_core_mt_exclude), so it needs the proof's output. CI's `bc2cpp-lists` job computes it
# (it needs Ruby with Prism, which this script's toolchain lacks); locally, in the nix `bc2cpp` shell:
#   export BC2CPP_STATIC_DISPATCH_LISTS="$(scripts/bc2cpp/static_dispatch_lists.bash)"
if [ -z "${BC2CPP_STATIC_DISPATCH_LISTS:-}" ] || [ ! -f "$BC2CPP_STATIC_DISPATCH_LISTS" ]; then
  echo "error: BC2CPP_STATIC_DISPATCH_LISTS must name the static dispatch lists file" >&2
  echo "  (scripts/bc2cpp/static_dispatch_lists.bash; docs/bc2cpp-unregistered-methods.md, \"Device builds\")" >&2
  exit 1
fi
# Keep mruby's own core off the real-C++-exception path (see build_config.rb's
# maix stanza): the Kendryte link drops every .eh_frame section, so a
# throw/catch-based MRB_TRY cannot unwind and the first rescued Ruby
# exception kills the firmware. setjmp/longjmp needs no unwind tables.
export MRUBY_FORCE_NO_CXX_EXCEPTION=1
cd "$root/3rd/mruby"
MRUBY_CONFIG="$root/build_config.rb" \
  MRUBY_BUILD_DIR="$build_dir" \
  PROJECT_BUILD_DIR="$build_dir" \
  MRUBY_TARGET=maix \
  rake

echo "built $build_dir/maix/lib/libmruby.a"
