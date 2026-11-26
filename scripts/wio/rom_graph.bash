#!/usr/bin/env bash
# ROM_GRAPH: the Wio firmware's classes as const data (mruby's MRB_ROM_CLASS_GRAPH, mruby/rom_graph.h). The class
# graph the boot leaves is dumped as C by a rom_graph=1 run of the wio_renode_game_big firmware under Renode; linked
# back in (BUILD_DIR/wio/lib/rom_graph.o, which app/wio/rom_graph.py adds to every wio link), its classes are in flash.
#
# Usage:
#   scripts/wio/rom_graph.bash lib BUILD_DIR [GRAPH.c]   compile GRAPH.c into BUILD_DIR/wio/lib/rom_graph.o
#                                                       (no GRAPH.c: none, every class on the heap)
#   scripts/wio/rom_graph.bash dump BUILD_DIR GAME_DIR OUT.c
#                                                       dump the graph of a firmware linked with no graph
#   scripts/wio/rom_graph.bash check BUILD_DIR GAME_DIR GRAPH.c
#                                                       boot on GRAPH.c and fail unless the boot dumps it again
# BUILD_DIR is scripts/wio/build.bash's (its libmruby and uni-algo); dump and check need RENODE_BIN (app/wio/renode/
# README.md) and pio. scripts/wio/build.bash links WIO_ROM_GRAPH=GRAPH.c into the firmware.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mode=${1:-}
build_dir="$(cd "${2:?usage: rom_graph.bash lib|dump|check BUILD_DIR ...}" && pwd)"
pio_home="${PLATFORMIO_CORE_DIR:-$HOME/.platformio}"
toolchain="$pio_home/packages/toolchain-gccarmnoneeabi/bin"
graph_obj="$build_dir/wio/lib/rom_graph.o"

lib() { # [GRAPH.c]
  rm -f "$graph_obj"
  if [ -n "${1:-}" ]; then
    "$toolchain/arm-none-eabi-gcc" -std=gnu99 -Os -c -mcpu=cortex-m4 -mthumb -mfloat-abi=hard -mfpu=fpv4-sp-d16 \
      -I "$build_dir/wio/include" -I "$root/3rd/mruby/include" "$1" -o "$graph_obj"
  fi
}

dump() { # GAME_DIR OUT.c
  local env=wio_renode_game_big log
  log="$build_dir/rom_graph-$env.log"
  (cd "$root" && unset LD && WIO_MRUBY_BUILD_DIR="$build_dir/wio" WIO_UNIALGO_LIB_DIR="$build_dir/unialgo" \
    pio run -e "$env" >"$log" 2>&1) || { tail -30 "$log" >&2; exit 1; }
  rm -f "$2"
  "$root/scripts/wio/renode_game.bash" "$root/.pio/build/$env/firmware.elf" "$1" --board big \
    --config 'frames=1;rom_graph=1' --seconds 60 --rom-graph "$2" --expect '^ROM_GRAPH [0-9]+ bytes' \
    > "$build_dir/rom_graph-renode.log" 2>&1 || { tail -30 "$build_dir/rom_graph-renode.log" >&2; exit 1; }
  [ -s "$2" ] || { echo "rom_graph: the run wrote no graph" >&2; exit 1; }
  grep '^ROM_GRAPH ' "$build_dir/rom_graph-renode.log"
}

case $mode in
  lib) lib "${3:-}" ;;
  dump)
    lib
    dump "${3:?GAME_DIR}" "${4:?OUT.c}"
    head -1 "$4"
    ;;
  check)
    graph="$(cd "$(dirname "${4:?GRAPH.c}")" && pwd)/$(basename "$4")"
    lib "$graph"
    again="$build_dir/rom_graph.again.c"
    dump "${3:?GAME_DIR}" "$again"
    grep -q '^ROM_GRAPH .*(on the graph)' "$build_dir/rom_graph-renode.log" ||
      { echo "rom_graph: the firmware did not take its graph" >&2; exit 1; }
    if ! cmp -s "$graph" "$again"; then
      echo "rom_graph: the boot on $graph left a different graph" >&2
      diff "$graph" "$again" | head -40 >&2
      exit 1
    fi
    echo "rom_graph: the boot on the graph leaves it as it was"
    ;;
  *)
    sed -n '2,/^set /p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
    exit 64
    ;;
esac
