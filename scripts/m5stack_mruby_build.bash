#!/usr/bin/env bash
# Build the M5Stack Core (ESP32) mruby cross lib -- build_config.rb's `m5stack`
# MRuby::CrossBuild -- the wio/maix pipelines' exact analog: a native host
# mruby first (producing mrbc, which compiles the target .rb sources to
# bytecode), then the Xtensa cross lib the PlatformIO firmware (app/m5stack,
# platformio.ini env:m5stack_rgss_boot) links in a later slice. The bring-up
# firmware links neither libmruby nor any input bridge yet; this exists so the
# interpreter can be layered on next, and so CI breaks loudly the moment a
# patch or gem stops cross-compiling.
#
# The mruby compile must agree with the firmware's own ABI: same compiler
# (PlatformIO's toolchain-xtensa-esp32, which build_config.rb prefers), same
# -mlongcalls, and the real Arduino/ESP-IDF/TFT_eSPI include paths and
# defines -- extracted below from `pio run -e m5stack -t compiledb` output
# (the TFT_eSPI.cpp entry carries the union of the Arduino, ESP-IDF and
# project build_flags) rather than hardcoded, the same shape as
# scripts/wio_bc2cpp_measure.bash's own RGSS_WIO_ARDUINO_INCLUDES extraction.
#
# Usage:
#   scripts/m5stack_mruby_build.bash [BUILD_DIR, default ./build-m5stack-mruby]
#
# Needs on PATH: ruby, rake, pio, bison and gperf (patches/*-defined-keyword
# touches mruby-compiler's keywords, forcing lex.def to regenerate), and a
# previous `pio run -e m5stack` (the toolchain plus the libdeps the
# extraction reads). The Unicode tables below are fetched the same way the
# `psp`/`maix` jobs fetch them (same pins, same hashes).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${1:-$root/build-m5stack-mruby}"
# Absolutize now: the rake step below cds into 3rd/mruby, so a relative
# path would otherwise land inside the submodule checkout.
case "$build_dir" in
  /*) ;;
  *) build_dir="$PWD/$build_dir" ;;
esac
tables="$root/.native-build-tables"

for tool in ruby rake bison gperf pio; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: '$tool' not found on PATH" >&2
    exit 1
  fi
done

mkdir -p "$tables"
# url, destination, and the sha256 flake.nix pins for it (base64, as Nix
# prints) -- same bytes Nix would hand the build, not a lookalike. Keep the
# pins in sync with the `maix` job in .github/workflows/build.yml, which
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
  mruby-force-no-cxx-exception-escape-hatch; do
  apply_patch "$root/3rd/mruby" "$root/patches/$p.patch"
done
apply_patch "$root/3rd/mruby-stringio" "$root/patches/mruby-stringio-native-getbyte.patch"
apply_patch "$root/3rd/mruby-marshal" "$root/patches/mruby-marshal-psp-wio-onigmo-optional.patch"

# The include/define set that makes the cross build's m5stack.cxx HAL
# ABI-compatible with PlatformIO's own framework objects (build_config.rb's
# own comment on RGSS_M5STACK_ARDUINO_INCLUDES). The compiledb's TFT_eSPI.cpp
# entry carries the union the firmware itself compiles with (Arduino core +
# variant + libraries, ESP-IDF components, the project build_flags); take
# every -I, and every -D except the mbedtls pair (config-file machinery for
# a component nothing in the mruby build includes). Paths are absolutized
# against the entry's own directory field (compiledb emits project-relative
# ones like `.pio/libdeps/...`), and embedded double quotes are backslash-
# escaped so they survive mruby's own shell round-trip as real `"..."`.
echo "== extracting RGSS_M5STACK_ARDUINO_INCLUDES from a real env:m5stack compile"
(
  cd "$root/app/m5stack"
  pio run -e m5stack -t compiledb >/dev/null
)
extracted="$(python3 - "$root/app/m5stack/compile_commands.json" <<'PY'
import json, os, shlex, sys
db = json.load(open(sys.argv[1]))
entry = next(e for e in db if e["file"].replace("\\", "/").endswith(".pio/libdeps/m5stack/TFT_eSPI/TFT_eSPI.cpp"))
directory = entry["directory"]
args = entry.get("arguments") or shlex.split(entry["command"])
includes, defines = [], []
for a in args:
    if a.startswith("-I") and len(a) > 2:
        p = a[2:]
        if not os.path.isabs(p):
            p = os.path.join(directory, p)
        p = os.path.normpath(p)
        if p not in includes:
            includes.append(p)
    elif a.startswith("-D") and len(a) > 2:
        d = a[2:]
        if d.startswith("HAVE_CONFIG_H") or d.startswith("MBEDTLS_CONFIG_FILE"):
            continue
        d = d.replace('"', '\\"')
        if d not in defines:
            defines.append(d)
print("INCLUDES:" + ":".join(includes))
print("DEFINES:" + "\n".join(defines))
PY
)"
RGSS_M5STACK_ARDUINO_INCLUDES="$(echo "$extracted" | sed -n 's/^INCLUDES://p')"
RGSS_M5STACK_ARDUINO_DEFINES="$(echo "$extracted" | sed -n 's/^DEFINES://p')"
if [ -z "$RGSS_M5STACK_ARDUINO_INCLUDES" ]; then
  echo "error: could not extract Arduino include paths from compile_commands.json" >&2
  exit 1
fi
export RGSS_M5STACK_ARDUINO_INCLUDES RGSS_M5STACK_ARDUINO_DEFINES
echo "   ${RGSS_M5STACK_ARDUINO_INCLUDES}" | tr ':' '\n' | head -8
echo "   ... ($(echo "$RGSS_M5STACK_ARDUINO_INCLUDES" | tr ':' '\n' | wc -l) include dirs)"

mruby_dir="$build_dir/mruby"
mkdir -p "$mruby_dir/repos/host" "$mruby_dir/repos/m5stack"
ln -sfn "$root/3rd/mgem-list" "$mruby_dir/repos/host/mgem-list"
ln -sfn "$root/3rd/mgem-list" "$mruby_dir/repos/m5stack/mgem-list"

export cp932_table="$tables/bestfit932.txt"
export jis0208_table="$tables/JIS0208.TXT"
cd "$root/3rd/mruby"
MRUBY_CONFIG="$root/build_config.rb" \
  MRUBY_BUILD_DIR="$mruby_dir" \
  PROJECT_BUILD_DIR="$build_dir" \
  MRUBY_TARGET=m5stack \
  rake

echo "built $mruby_dir/m5stack/lib/libmruby.a"
xtensa-esp32-elf-size "$mruby_dir/m5stack/lib/libmruby.a" 2>/dev/null || \
  "$HOME/.platformio/packages/toolchain-xtensa-esp32/bin/xtensa-esp32-elf-size" \
    "$mruby_dir/m5stack/lib/libmruby.a" | tail -2
