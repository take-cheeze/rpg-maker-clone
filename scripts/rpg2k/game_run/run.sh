#!/usr/bin/env bash
# Runs one headless workload on a real RPG2000 project against a closed-world mruby build.
#
#   scripts/rpg2k/game_run/run.sh BUILD_DIR GAME_DIR WORKLOAD [TRACE_OUT]
#
#   BUILD_DIR  a closed build from scripts/bc2cpp/closed_build.bash (lib/libmruby.a and include/)
#   GAME_DIR   the directory holding RPG_RT.ldb, RPG_RT.lmt and the maps (absolute path)
#   WORKLOAD   new_game or map_menu (workloads/NAME.rb)
#   TRACE_OUT  optional: writes the BC2CPP_TRACE_TYPES dump here (needs a build made with BC2CPP_TRACE_TYPES=1)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
build="$(cd "$1" && pwd)"
game="$(cd "$2" && pwd)"
workload="$3"
trace_out="${4:-}"

cxx="${CXX:-g++}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

defs=(-DHAVE_MRUBY_IO_GEM -DKHASH_INITIAL_SIZE=16 -DMRB_DEBUG -DMRB_HEAP_PAGE_SIZE=256 -DMRB_STR_LENGTH_MAX=0
      -DMRB_USE_BIGINT -DMRB_USE_CXX_EXCEPTION -DUNI_ALGO_DISABLE_CASE -DUNI_ALGO_DISABLE_PROP
      -DUNI_ALGO_DISABLE_SCRIPT -DUNI_ALGO_DISABLE_SEGMENT_GRAPHEME -DUNI_ALGO_DISABLE_SEGMENT_WORD
      -fexceptions -std=gnu++17)

# The uni-algo tables the closed library's text code references, and the LVGL stubs (see stubs.c).
"$cxx" "${defs[@]}" -I"$build/include" -I"$root/3rd/mruby/include" -c "$here/gamedriver.cpp" -o "$work/driver.o"
"$cxx" "${defs[@]}" -c "$root/3rd/uni-algo/src/data.cpp" -o "$work/unialgo_data.o"
cc -c "$here/stubs.c" -o "$work/stubs.o"
"$cxx" "$work/driver.o" "$work/unialgo_data.o" "$work/stubs.o" "$build/lib/libmruby.a" -lm -o "$work/game"

{
  echo "GAME_DIR = \"$game\""
  echo 'RTP_DIR = ""'
  cat "$here/workloads/$workload.rb"
} > "$work/run.rb"

if [ -n "$trace_out" ]; then
  BC2CPP_TRACE_TYPES_OUT="$trace_out" "$work/game" "$work/run.rb"
else
  "$work/game" "$work/run.rb"
fi
