#!/usr/bin/env bash

set -euo pipefail

# Build and render-verify the engine on a plain Debian/Ubuntu box, without Nix.
#
# The supported way to build this project is the Nix flake (`nix develop`), which
# pins every dependency. This script is the fallback for an environment that has
# a C++ toolchain but no Nix -- notably an agent container, where the absence of
# a native build was long assumed to be permanent. It is not: everything the
# flake supplies has a plain equivalent, and the five things that actually block
# a from-scratch build are unremarkable.
#
#   1. SDL2 and SDL2_mixer headers.        CMakeLists.txt does find_package(SDL2 REQUIRED).
#   2. The `3rd/` submodules.              A plain clone leaves them empty and the
#                                          configure fails on missing CMakeLists.
#   3. `rake` on PATH.                     mruby builds itself with it, through /bin/sh,
#                                          so an rbenv shim that is only on the
#                                          interactive PATH is not enough.
#   4. Two Unicode mapping tables.         mruby-lcf/cp932_to_unicode.rb and
#                                          mruby-rgss/gen_shinonome_data.rb read them
#                                          from $cp932_table / $jis0208_table, which the
#                                          flake sets from fetchurl. They are downloaded
#                                          here and checked against the flake's own
#                                          sha256 hashes, so the build consumes the same
#                                          bytes Nix would hand it -- not a lookalike.
#   5. `gperf` and `bison`.                This project's mruby-defined-keyword.patch
#                                          touches mrbgems/mruby-compiler/core/keywords,
#                                          forcing rake to regenerate lex.def/y.tab.c on
#                                          every build (see flake.nix's own comment on
#                                          this pair) rather than only when a patch first
#                                          lands -- so both are needed unconditionally,
#                                          not just when the SDL2 headers are missing.
#
# Why bother: the Ruby harnesses (rpg2k_logic_check.rb and friends) load the
# runtime's pure-Ruby sources under *CRuby*, which cannot see mruby/CRuby
# divergence, and cannot see rendering at all. A native build reaches both --
# `--rgss_effect_probe` measures real pixels, and the boot checks drive real game
# data to the map. See docs/adr/0021 and 0022.
#
# Usage:
#   scripts/native-build-without-nix.bash [BUILD_DIR]      # default: ./build
#   VERIFY=0 scripts/native-build-without-nix.bash         # build only, no probe/boot checks
#
# Needs root for the apt step (skipped when the headers are already present).
#
# ---------------------------------------------------------------------------
# Checking formatting here, which is fiddlier than it looks
#
# The `build` job runs pre-commit as a background step, so a formatting slip
# fails CI as `build` rather than as a lint job -- worth knowing before you go
# looking for a compile error that is not there.
#
# The check that works, and the one CI runs:
#
#   pre-commit run clang-format --files <file>
#
# The hook installs its own pinned clang-format from PyPI
# (.pre-commit-config.yaml), so it formats exactly as CI does no matter what
# `clang-format` this container has on PATH -- there is no version difference
# left to work around. It rewrites the file in place and reports it as a
# failure; `git diff` then shows what it changed.
#
# Two traps, in the order they will catch you:
#
#   * If you do reach for a `clang-format` binary directly, run it *inside the
#     repository*: clang-format finds `.clang-format` by walking up from the
#     file's own directory, so checking a copy in /tmp silently formats to LLVM
#     defaults instead -- `PointerAlignment: Right` where this repo sets Left --
#     and produces a diff of hundreds of unrelated lines. Its version is also
#     not the pinned one (clang-format 18 flags three lines in
#     mruby-rgss/src/lib.cxx that 20 and later accept), so read the violations
#     your change caused and leave the rest alone.
#   * A plain line-length grep is not a substitute. `ColumnLimit` is 80, but
#     several tracked files hold longer lines that clang-format has no way to
#     break and accepts as they are (include/lv_conf.h, mruby-mvjs/src/*.cxx).
#     Length also has to be counted in *characters*: awk counts bytes, and an
#     em-dash is three of them, so `awk 'length($0) > 80'` reports comment lines
#     that are perfectly legal.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${1:-$root/build}"
tables="${TABLES_DIR:-$root/.native-build-tables}"

say() { printf '\n== %s\n' "$*"; }

say "1/5 system packages"
# Gate on every package this step installs, not just SDL2 -- a container that
# already has SDL2 dev headers (this one did) but not e.g. gperf skipped the
# whole branch and failed 700 ninja steps later with the unhelpful "sh: 1:
# gperf: not found" deep inside mruby's own rake build, since the
# mruby-defined-keyword.patch this project carries touches
# mrbgems/mruby-compiler/core/keywords and forces lex.def to regenerate on
# every build (see flake.nix's own comment on the bison/gperf pair).
if pkg-config --exists sdl2 && pkg-config --exists SDL2_mixer \
  && command -v cmake >/dev/null 2>&1 && command -v ninja >/dev/null 2>&1 \
  && command -v g++ >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1 \
  && command -v gperf >/dev/null 2>&1 && command -v bison >/dev/null 2>&1; then
  echo "system packages already present"
else
  # A stale package index 404s on the individual .deb files, which reads as a
  # network failure rather than the cache miss it is -- so always refresh first.
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    libsdl2-dev libsdl2-mixer-dev xvfb cmake ninja-build g++ gperf bison
fi

say "2/5 submodules"
# --depth 1: the history of thirteen vendored dependencies is not wanted, and
# quickjs's test262 submodule alone is enormous (the .gitmodules entry marks it
# to be skipped, which only holds if it is never asked for).
git -C "$root" submodule update --init --recursive --depth 1

say "3/5 rake on PATH"
if /bin/sh -c 'command -v rake' >/dev/null 2>&1; then
  echo "rake already reachable from /bin/sh"
else
  rake_bin="$(command -v rake || true)"
  # A version manager (rbenv, asdf, rvm) puts rake in a per-version bin that is
  # only on an *interactive* PATH, so `command -v` misses it here even though
  # `rake` works in a terminal -- and "gem install rake" is then both wrong and,
  # behind a proxy that blocks rubygems, impossible. Ruby knows where its own
  # gem executables live, so ask it before giving up.
  if [ -z "$rake_bin" ] && command -v ruby >/dev/null 2>&1; then
    gem_bin="$(ruby -e 'print Gem.bindir' 2>/dev/null || true)"
    [ -n "$gem_bin" ] && [ -x "$gem_bin/rake" ] && rake_bin="$gem_bin/rake"
  fi
  [ -n "$rake_bin" ] || {
    echo "no rake found on PATH, and ruby -e 'print Gem.bindir' has none" >&2
    echo "install it with: gem install rake" >&2
    exit 1
  }
  ln -sf "$rake_bin" /usr/local/bin/rake
  echo "linked $rake_bin -> /usr/local/bin/rake"
fi

say "4/5 Unicode mapping tables"
mkdir -p "$tables"
# url, destination, and the sha256 flake.nix pins for it (base64, as Nix prints).
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
  echo "$(basename "$dest"): hash matches flake.nix"
}
fetch_table \
  'https://www.unicode.org/Public/MAPPINGS/VENDORS/MICSFT/WindowsBestFit/bestfit932.txt' \
  "$tables/bestfit932.txt" 'JhTP6jXDyGxB0zGYeTqEykTt7jzw7gATphpD+6Ts4zE='
fetch_table \
  'https://www.unicode.org/Public/MAPPINGS/OBSOLETE/EASTASIA/JIS/JIS0208.TXT' \
  "$tables/JIS0208.TXT" 'HFcYcEV/Gcl3IGMfqD7kkVSalroUNtoSlnhqZ9hjLoc='
export cp932_table="$tables/bestfit932.txt"
export jis0208_table="$tables/JIS0208.TXT"

say "5/5 configure and build -> $build_dir"
cmake -S "$root" -B "$build_dir" -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build "$build_dir" -j"$(nproc)"
echo "built $build_dir/rpg_maker_clone"

if [ "${VERIFY:-1}" = "0" ]; then
  echo "VERIFY=0; skipping the render and boot checks"
  exit 0
fi

say "render check: --rgss_effect_probe under Xvfb"
# The probe is the one thing that proves a screen effect reached the *display*
# rather than merely storing its values -- the failure an earlier screen-tint
# attempt shipped with. It prints [RGSS-PROBE] ok only when the measured frame
# moved for every effect.
xvfb-run -a "$build_dir/rpg_maker_clone" --test_play --rgss_effect_probe

say "boot checks: real game data to the map"
ENGINE="$build_dir/rpg_maker_clone" xvfb-run -a bash "$root/scripts/rpg2k_boot_check.bash"
ENGINE="$build_dir/rpg_maker_clone" xvfb-run -a bash "$root/scripts/rpgxp_boot_check.bash"

say "done: built, render-verified and booted"
