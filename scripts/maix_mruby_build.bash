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
#   scripts/maix_mruby_build.bash [BUILD_DIR, default ./build-maix-mruby]
#
# Needs on PATH: ruby, rake, a native C/C++ compiler (the host half), bison
# and gperf (patches/mruby-defined-keyword.patch touches mruby-compiler's
# keywords, forcing lex.def to regenerate -- same reason the `psp` CI job
# installs them), and either PlatformIO's Kendryte toolchain (present after
# any `pio run -e maix_amigo`, which build_config.rb prefers) or a
# hand-installed riscv64-unknown-elf-gcc. CI's `maix` job installs all of
# this; the Unicode tables below are fetched the same way the `psp` job
# fetches them (same pins, same hashes).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${1:-$root/build-maix-mruby}"
tables="$root/.native-build-tables"

for tool in ruby rake bison gperf; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: '$tool' not found on PATH -- CI's \`maix\` job installs it; see $0" >&2
    exit 1
  fi
done

mkdir -p "$tables"
# url, destination, and the sha256 flake.nix pins for it (base64, as Nix
# prints) -- same bytes Nix would hand the build, not a lookalike. Keep the
# pins in sync with the `psp` job in .github/workflows/build.yml, which
# duplicates this fetch for its docker container.
fetch_table() {
  local url="$1" dest="$2" want="$3"
  if [ ! -s "$dest" ]; then
    curl -fsSL -o "$dest" "$url"
  fi
  local got
  got="$(python3 -c 'import hashlib,base64,sys; print(base64.b64encode(hashlib.sha256(open(sys.argv[1],"rb").read()).digest()).decode())' "$dest")"
  if [ "$got" != "$want" ]; then
    echo "hash mismatch for $dest" >&2
    echo "  flake.nix pins $want" >&2
    echo "  downloaded     $got" >&2
    exit 1
  fi
}
fetch_table \
  'https://www.unicode.org/Public/MAPPINGS/VENDORS/MICSFT/WindowsBestFit/bestfit932.txt' \
  "$tables/bestfit932.txt" \
  'JhTP6jXDyGxB0zGYeTqEykTt7jzw7gATphpD+6Ts4zE='
fetch_table \
  'https://www.unicode.org/Public/MAPPINGS/OBSOLETE/EASTASIA/JIS/JIS0208.TXT' \
  "$tables/JIS0208.TXT" \
  'HFcYcEV/Gcl3IGMfqD7kkVSalroUNtoSlnhqZ9hjLoc='

# Same patch list cmake/build-mruby.cmake applies before every rake build --
# keep the two in sync. (Absolute patch paths: the apply script cds into the
# submodule first.)
apply_patch() {
  "$root/scripts/apply_mruby_patch.bash" "$1" "$2"
}
for p in mruby-colon3-assign-setmcnst mruby-dollar-bang-scoped \
  mruby-defined-keyword mruby-nomemoryerror-reentrant-alloc \
  mruby-gc-type-live-counts mruby-io-maxpathlen-fallback \
  mruby-force-no-cxx-exception-escape-hatch mruby-presym-compact-table \
  mruby-cdump-const-reps mruby-no-irep-debug; do
  apply_patch "$root/3rd/mruby" "$root/patches/$p.patch"
done
apply_patch "$root/3rd/mruby-stringio" "$root/patches/mruby-stringio-native-getbyte.patch"
apply_patch "$root/3rd/mruby-marshal" "$root/patches/mruby-marshal-psp-wio-onigmo-optional.patch"

export cp932_table="$tables/bestfit932.txt"
export jis0208_table="$tables/JIS0208.TXT"
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
