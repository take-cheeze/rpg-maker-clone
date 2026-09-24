#!/usr/bin/env bash
# Produces the Wio Terminal flash/RAM measurement ADRs 0104-0144 have so far
# only been able to take by hand: a real `wio_rgss_boot` link for both the
# baseline and the `RPGMAKER_BC2CPP=1` configuration, with the linker map each
# one writes. CI's `wio-bc2cpp` job runs this and feeds the output to
# scripts/wio_overflow_report.rb (see docs/adr/0152); it is also how a dev
# machine reproduces those numbers locally.
#
# `env:wio_rgss_boot` needs two things nothing else in this repo's build
# produces (platformio.ini's own comment on the env says so): a
# `MRUBY_TARGET=wio` cross-build of mruby (WIO_MRUBY_BUILD_DIR) and a standalone
# arm-none-eabi build of 3rd/uni-algo (WIO_UNIALGO_LIB_DIR). This script
# produces both, plus the RGSS_WIO_ARDUINO_INCLUDES set the link needs so the
# mruby-rgss HAL's `wio.o` is ABI-compatible with PlatformIO's own Arduino
# framework objects. The recipe is the one docs/adr/0141/0143/0144 record, with
# the patches/table/toolchain pieces lifted from cmake/build-mruby.cmake and
# scripts/build_psp_docker.bash.
#
# Both links are *expected to fail*: `wio_rgss_boot` overflows the real 507904
# -byte FLASH budget, baseline and bc2cpp alike (docs/adr/0104 onward). `ld`
# still writes a complete firmware.map before refusing, so that is the artifact
# the report reads; a link that fails for any *other* reason is a real error
# here and fails the script.
#
# Needs: bash, git, curl, python3, a host C/C++ toolchain, ruby + rake, gperf +
# bison, and PlatformIO (`pio`) on PATH -- the last one supplies the pinned
# arm-none-eabi 14.2.1 toolchain at ~/.platformio/packages/
# toolchain-gccarmnoneeabi, the same one build_config.rb prefers and the final
# link uses. The repo's submodules must be checked out.
#
# Usage:
#   scripts/wio_bc2cpp_measure.bash [OUT_DIR]   # default /tmp/wio-bc2cpp
#
# Writes, under OUT_DIR:
#   baseline/{rake.log,build.log,firmware.map}
#   bc2cpp/{rake.log,build.log,firmware.map}
# Then: ruby scripts/wio_overflow_report.rb \
#         baseline:OUT_DIR/baseline/firmware.map bc2cpp:OUT_DIR/bc2cpp/firmware.map
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-/tmp/wio-bc2cpp}"
TABLES_DIR="$OUT_DIR/tables"
UNIALGO_DIR="$OUT_DIR/unialgo"

cd "$REPO_ROOT"

# Disk is the one resource this build can plausibly run out of on a CI runner
# (two mruby cross-build trees plus PlatformIO), and a full disk surfaces as an
# opaque tool failure -- print the headroom up front and after each link.
df -h "$OUT_DIR" "$REPO_ROOT" 2>/dev/null || true

if ! command -v pio >/dev/null 2>&1; then
  echo "error: 'pio' not found on PATH -- install PlatformIO" >&2
  exit 1
fi

for sub in 3rd/mruby 3rd/uni-algo 3rd/lvgl 3rd/mruby-marshal \
          3rd/mruby-stringio 3rd/mruby-onig-regexp 3rd/mgem-list; do
  if [ -z "$(ls -A "$sub" 2>/dev/null)" ]; then
    echo "error: $sub is empty -- run: git submodule update --init --recursive" >&2
    exit 1
  fi
done

# Build env:wio first. Two reasons: it installs the pinned arm-none-eabi
# toolchain this script and build_config.rb's cross build resolve from
# ~/.platformio/packages/toolchain-gccarmnoneeabi (a fresh runner has no such
# package until something asks PlatformIO for it), and with -t compiledb it
# also writes the compile_commands.json the include extraction below reads.
echo "== pio run -e wio -t compiledb (installs the pinned arm-none-eabi toolchain)"
pio run -e wio -t compiledb >/dev/null 2>&1

# Prefer PlatformIO's own bundled toolchain, exactly as build_config.rb's wio
# cross build does: its arm-none-eabi 14.2.1 is the compiler the final
# PlatformIO link uses, and mixing it with a distro compiler silently disagrees
# on ABI/codegen defaults (that file's own comment has the full account).
pio_toolchain="$HOME/.platformio/packages/toolchain-gccarmnoneeabi/bin"
if [ -x "$pio_toolchain/arm-none-eabi-g++" ]; then
  ARM_GCC="$pio_toolchain/arm-none-eabi-gcc"
  ARM_GXX="$pio_toolchain/arm-none-eabi-g++"
  ARM_AR="$pio_toolchain/arm-none-eabi-ar"
else
  ARM_GCC=arm-none-eabi-gcc
  ARM_GXX=arm-none-eabi-g++
  ARM_AR=arm-none-eabi-ar
  command -v "$ARM_GXX" >/dev/null || {
    echo "error: no arm-none-eabi-g++ (checked PlatformIO's package and PATH)" >&2
    exit 1
  }
fi

# mruby-lcf/cp932_to_unicode.rb and mruby-rgss/gen_shinonome_data.rb are
# rake-time generators that read $cp932_table / $jis0208_table. The nix
# devshell sets those from fetchurl derivations; a bare environment has
# neither, so fetch them and verify against flake.nix's own sha256 pins -- the
# same two pins and the same check scripts/build_psp_docker.bash and
# scripts/native-build-without-nix.bash already use.
echo "== Unicode mapping tables"
mkdir -p "$TABLES_DIR"
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
  "$TABLES_DIR/bestfit932.txt" 'JhTP6jXDyGxB0zGYeTqEykTt7jzw7gATphpD+6Ts4zE='
fetch_table \
  'https://www.unicode.org/Public/MAPPINGS/OBSOLETE/EASTASIA/JIS/JIS0208.TXT' \
  "$TABLES_DIR/JIS0208.TXT" 'HFcYcEV/Gcl3IGMfqD7kkVSalroUNtoSlnhqZ9hjLoc='
export cp932_table="$TABLES_DIR/bestfit932.txt"
export jis0208_table="$TABLES_DIR/JIS0208.TXT"

# The patches cmake/build-mruby.cmake applies, in its own order, applied
# with the same idempotent helper it uses (scripts/apply_mruby_patch.bash).
# Two target mruby's own submodules; the rest target 3rd/mruby.
echo "== applying mruby patches"
apply() { scripts/apply_mruby_patch.bash "$1" "$REPO_ROOT/patches/$2"; }
apply 3rd/mruby mruby-colon3-assign-setmcnst.patch
apply 3rd/mruby mruby-dollar-bang-scoped.patch
apply 3rd/mruby mruby-defined-keyword.patch
apply 3rd/mruby mruby-nomemoryerror-reentrant-alloc.patch
apply 3rd/mruby mruby-gc-type-live-counts.patch
apply 3rd/mruby mruby-io-maxpathlen-fallback.patch
apply 3rd/mruby-stringio mruby-stringio-native-getbyte.patch
apply 3rd/mruby-marshal mruby-marshal-psp-wio-onigmo-optional.patch
apply 3rd/mruby mruby-force-no-cxx-exception-escape-hatch.patch
apply 3rd/mruby mruby-presym-compact-table.patch
apply 3rd/mruby mruby-cdump-const-reps.patch
apply 3rd/mruby mruby-no-irep-debug.patch

# The standalone arm-none-eabi uni-algo. PlatformIO's LDF cannot build it (no
# library.json, platformio.ini's own comment on env:wio_rgss_boot), so compile
# the one translation unit that carries the tables, with the exact trim defines
# cmake/uni-algo-trim.cmake documents (the PUBLIC list plus the data-TU-only
# NFKC/NFKD define) and the same Cortex-M4F flags as the mruby cross build.
build_unialgo() {
  [ -s "$UNIALGO_DIR/libuni-algo.a" ] && return 0
  echo "== building standalone arm-none-eabi libuni-algo.a"
  mkdir -p "$UNIALGO_DIR"
  "$ARM_GXX" -std=gnu++17 -Os -c \
    -mcpu=cortex-m4 -mthumb -mfloat-abi=hard -mfpu=fpv4-sp-d16 \
    -I "$REPO_ROOT/3rd/uni-algo/include" \
    -DUNI_ALGO_DISABLE_CASE -DUNI_ALGO_DISABLE_PROP \
    -DUNI_ALGO_DISABLE_SCRIPT -DUNI_ALGO_DISABLE_SEGMENT_GRAPHEME \
    -DUNI_ALGO_DISABLE_SEGMENT_WORD -DUNI_ALGO_DISABLE_NFKC_NFKD \
    "$REPO_ROOT/3rd/uni-algo/src/data.cpp" -o "$UNIALGO_DIR/data.o"
  "$ARM_AR" rcs "$UNIALGO_DIR/libuni-algo.a" "$UNIALGO_DIR/data.o"
}
build_unialgo

# The include set that makes the mruby cross build's wio.cxx HAL ABI-compatible
# with PlatformIO's own framework objects (build_config.rb's own comment on
# RGSS_WIO_ARDUINO_INCLUDES). Extract it from the compile_commands.json the
# env:wio build above wrote, rather than hardcoding the PlatformIO package
# cache paths, which are host- and version-specific.
echo "== extracting RGSS_WIO_ARDUINO_INCLUDES from a real env:wio compile"
RGSS_WIO_ARDUINO_INCLUDES="$(python3 - "$REPO_ROOT/compile_commands.json" "$REPO_ROOT" <<'PY'
import json, os, shlex, sys
db = json.load(open(sys.argv[1]))
repo = sys.argv[2]
entry = next(e for e in db if e["file"].replace("\\", "/").endswith("app/wio/src/main.cxx"))
args = entry.get("arguments") or shlex.split(entry["command"])
seen = []
for a in args:
    if a.startswith("-I") and len(a) > 2:
        p = a[2:]
        if not os.path.isabs(p):
            p = os.path.join(repo, p)
        p = os.path.normpath(p)
        if p not in seen:
            seen.append(p)
print(":".join(seen))
PY
)"
if [ -z "$RGSS_WIO_ARDUINO_INCLUDES" ]; then
  echo "error: could not extract Arduino include paths from compile_commands.json" >&2
  exit 1
fi
export RGSS_WIO_ARDUINO_INCLUDES

# One full cross-build per configuration. Each gets its own MRUBY_BUILD_DIR
# (including its own host mrbc), wiped first -- two fully isolated builds is
# the conservative reading of docs/adr/0143's stale-build warning, at the cost
# of building host twice. The mgem-list symlinks mirror
# cmake/build-mruby.cmake's own setup so mruby resolves its gem index from the
# vendored submodule instead of cloning one.
run_rake() {
  local label="$1" bc2cpp="$2"
  local mruby_dir="$OUT_DIR/mruby-$label"
  local dir="$OUT_DIR/$label"
  # A CI cache hit restores a previously built pair; the cache key hashes every
  # input that feeds libmruby.a, so a hit is provably current (see the job
  # comment in .github/workflows/build.yml). The link below still runs fresh.
  if [ -s "$mruby_dir/wio/lib/libmruby.a" ]; then
    echo "== using existing MRUBY_TARGET=wio build ($label)"
    return 0
  fi
  echo "== MRUBY_TARGET=wio rake ($label)"
  rm -rf "$mruby_dir"
  mkdir -p "$mruby_dir/repos/host" "$mruby_dir/repos/wio"
  ln -sfn "$REPO_ROOT/3rd/mgem-list" "$mruby_dir/repos/host/mgem-list"
  ln -sfn "$REPO_ROOT/3rd/mgem-list" "$mruby_dir/repos/wio/mgem-list"
  mkdir -p "$dir"
  # -u first so an RPGMAKER_BC2CPP inherited from the caller can never leak
  # into the baseline build; the bc2cpp run re-sets it after.
  # MRUBY_BC2CPP_SKIP_HOST: the cross build's bootstrap host only makes mrbc,
  # and the CI host GCC rejects the AOT-generated C++ the compiled gems emit
  # (see build_config.rb's own comment). Only the wio libmruby is measured, so
  # skip them there; the target build still compiles them.
  local env_args=(-u RPGMAKER_BC2CPP
                  MRUBY_BC2CPP_SKIP_HOST=1
                  MRUBY_CONFIG="$REPO_ROOT/build_config.rb"
                  MRUBY_BUILD_DIR="$mruby_dir"
                  MRUBY_TARGET=wio
                  PROJECT_BUILD_DIR="$OUT_DIR/project-$label")
  if [ "$bc2cpp" = 1 ]; then
    env_args+=(RPGMAKER_BC2CPP=1)
  fi
  # Deliberately NOT streamed to the job log. mruby's generated gem_init.c makes
  # the compiler emit diagnostics that contain NUL bytes, and GitHub Actions
  # truncates a step's log at the first NUL -- so streaming would hide the real
  # error (and everything after it). Keep the complete output on disk and print
  # a tail of it only if rake fails; on success the job summary is the report.
  local rc=0
  ( cd "$REPO_ROOT/3rd/mruby" && env "${env_args[@]}" rake ) >"$dir/rake.log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    # Keep a durable note for the report (which runs with if: always()), and
    # print the tail so the CI log shows it too.
    tail -60 "$dir/rake.log" >"$dir/rake-failed.txt" 2>/dev/null || true
    echo "error: rake ($label) exited $rc -- last 60 lines of $dir/rake.log:" >&2
    tail -60 "$dir/rake.log" >&2
    return 1
  fi
  echo "== rake ($label) done"
  # host/ (the bootstrap mrbc and its gems) was only needed to produce this
  # variant's libmruby.a, which stays for the link and the cache; dropping it
  # halves the peak footprint of having two variants on disk.
  rm -rf "$mruby_dir/host"
}

# Both links are expected to overflow; the map is still written and is what the
# report needs. Any other failure is real and aborts. The map path
# (.pio/build/wio_rgss_boot/firmware.map) is fixed by the env's own -Wl,-Map, so
# it is copied out before the next link can overwrite it.
OVERFLOW_RE="region \`(FLASH|RAM)' overflowed by [0-9]+ bytes"
run_link() {
  # Separate `local` statements on purpose: bash expands every word of a single
  # `local a=1 b=$a` before assigning any of them, so $label there is the outer
  # (unset) variable -- an unbound-variable error under `set -u`.
  local label="$1"
  local mruby_dir="$OUT_DIR/mruby-$label"
  local dir="$OUT_DIR/$label"
  mkdir -p "$dir"
  echo "== pio run -e wio_rgss_boot ($label)"
  rm -rf .pio/build/wio_rgss_boot
  local rc=0
  # tr -d '\000' before tee for the same reason the rake output is not streamed
  # at all: a NUL byte would truncate this step's log in GitHub Actions.
  WIO_MRUBY_BUILD_DIR="$mruby_dir/wio" \
  WIO_UNIALGO_LIB_DIR="$UNIALGO_DIR" \
    pio run -e wio_rgss_boot 2>&1 | tr -d '\000' | tee "$dir/build.log" || rc=$?
  if [ -f .pio/build/wio_rgss_boot/firmware.map ]; then
    cp .pio/build/wio_rgss_boot/firmware.map "$dir/firmware.map"
  fi
  if [ "$rc" -ne 0 ] && ! grep -qE "$OVERFLOW_RE" "$dir/build.log"; then
    echo "error: $label link failed without a FLASH/RAM overflow -- last 60" >&2
    echo "       lines of $dir/build.log:" >&2
    tail -60 "$dir/build.log" >&2
    return 1
  fi
  if [ "$rc" -eq 0 ]; then
    echo "note: $label link fit the board (no overflow) -- unexpected but not fatal"
  fi
  df -h "$dir" 2>/dev/null || true
}

run_rake baseline 0
run_link baseline

# The bc2cpp configuration is *reported*, not required. Its generated code
# currently fails to compile under some filesystem orderings on the CI runners
# (`could not convert '1' from 'int' to 'mrb_value'`), which is a real bc2cpp
# codegen bug to fix separately -- not something this measurement script should
# turn into a red job. The report surfaces the failure and still shows the
# baseline row. The baseline above stays fatal: if it cannot be built, the
# measurement is meaningless.
if run_rake bc2cpp 1; then
  run_link bc2cpp
else
  echo "warning: bc2cpp build failed -- the report will show baseline only" >&2
fi

echo
echo "measurements written under $OUT_DIR"
echo "  ruby scripts/wio_overflow_report.rb \\"
echo "    baseline:$OUT_DIR/baseline/firmware.map bc2cpp:$OUT_DIR/bc2cpp/firmware.map"
