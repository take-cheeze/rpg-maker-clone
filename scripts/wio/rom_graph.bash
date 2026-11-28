#!/usr/bin/env bash
# ROM_GRAPH: the Wio firmware's classes as const data (mruby's MRB_ROM_CLASS_GRAPH, mruby/rom_graph.h). The class
# graph the boot leaves is dumped as C; linked back in (BUILD_DIR/wio/lib/rom_graph.o, which app/wio/rom_graph.py adds
# to every wio link), its classes are in flash.
#
# ROM_GRAPH_PROBE: `probe` boots the wio libmruby.a itself under qemu-arm (scripts/wio/rom_graph_probe/), in seconds
# and before any firmware link. `dump` boots a wio_renode_game_big firmware under Renode, and `oracle` holds the
# probe's graph to that dump, byte for byte.
#
# Usage:
#   scripts/wio/rom_graph.bash lib BUILD_DIR [GRAPH.c]   compile GRAPH.c into BUILD_DIR/wio/lib/rom_graph.o
#                                                       (no GRAPH.c: none, every class on the heap)
#   scripts/wio/rom_graph.bash probe BUILD_DIR OUT.c     dump the graph under qemu-arm, then boot on it there and
#                                                       fail unless that boot dumps it again
#   scripts/wio/rom_graph.bash dump BUILD_DIR GAME_DIR OUT.c
#                                                       dump the graph of a firmware linked with no graph (Renode)
#   scripts/wio/rom_graph.bash check BUILD_DIR GAME_DIR GRAPH.c
#                                                       boot on GRAPH.c and fail unless the boot dumps it again
#   scripts/wio/rom_graph.bash oracle BUILD_DIR GAME_DIR GRAPH.c
#                                                       fail unless the Renode dump is GRAPH.c; links GRAPH.c again
# BUILD_DIR is scripts/wio/build.bash's (its libmruby and uni-algo). probe needs qemu-arm (QEMU_ARM, else qemu-arm or
# qemu-arm-static on PATH); dump, check and oracle need RENODE_BIN (app/wio/renode/README.md) and pio.
# scripts/wio/build.bash links WIO_ROM_GRAPH=GRAPH.c into the firmware, or the probe's graph for WIO_ROM_GRAPH=probe.
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

cpu_flags=(-mcpu=cortex-m4 -mthumb -mfloat-abi=hard -mfpu=fpv4-sp-d16)

probe_libs=("$build_dir/wio/lib/libmruby.a" "$build_dir/unialgo/libuni-algo.a" -lstdc++ -lm -lc -lgcc)
# shellcheck disable=SC2054 # -Wl,... is one argument
probe_ld=("$toolchain/arm-none-eabi-g++" "${cpu_flags[@]}" -flto=auto -nostartfiles -static -Wl,--gc-sections)

# What the firmware links beside libmruby.a, as stubs: a first link's undefined references (stubs.rb).
probe_stubs() { # DIR
  "${probe_ld[@]}" -Wl,--no-demangle "$1/probe.o" "${probe_libs[@]}" -o "$1/unstubbed.elf" >"$1/unstubbed.log" 2>&1 &&
    { echo "rom_graph: the probe links with nothing stubbed" >&2; exit 1; }
  ruby "$root/scripts/wio/rom_graph_probe/stubs.rb" "$1/unstubbed.log" >"$1/stubs.S"
  "$toolchain/arm-none-eabi-gcc" "${cpu_flags[@]}" -c "$1/stubs.S" -o "$1/stubs.o"
}

probe_link() { # DIR OUT.elf OBJ...
  local dir=$1 out=$2
  shift 2
  "${probe_ld[@]}" "$dir/probe.o" "$dir/stubs.o" "$@" "${probe_libs[@]}" -o "$out" >"$out.log" 2>&1 ||
    { tail -30 "$out.log" >&2; exit 1; }
}

probe_run() { # ELF OUT.c
  local qemu=${QEMU_ARM:-}
  [ -n "$qemu" ] || qemu=$(command -v qemu-arm || command -v qemu-arm-static) ||
    { echo "rom_graph: no qemu-arm (set QEMU_ARM)" >&2; exit 1; }
  rm -f "$2"
  "$qemu" -cpu max "$1" >"$2" 2>"$1.run.log" || { cat "$1.run.log" >&2; rm -f "$2"; exit 1; }
  [ -s "$2" ] || { echo "rom_graph: the probe wrote no graph" >&2; exit 1; }
}

probe() { # OUT.c
  local dir=$build_dir/rom_graph_probe
  mkdir -p "$dir"
  "$toolchain/arm-none-eabi-gcc" -std=gnu99 -O1 "${cpu_flags[@]}" -I "$build_dir/wio/include" \
    -I "$root/3rd/mruby/include" -I "$root/include" -c "$root/scripts/wio/rom_graph_probe/probe.c" -o "$dir/probe.o"
  probe_stubs "$dir"
  probe_link "$dir" "$dir/probe.elf"
  probe_run "$dir/probe.elf" "$1"
  grep -q '^probe: heap classes' "$dir/probe.elf.run.log" || { echo "rom_graph: the probe booted on a graph" >&2; exit 1; }
  lib "$1"
  probe_link "$dir" "$dir/probe-graph.elf" "$graph_obj"
  probe_run "$dir/probe-graph.elf" "$dir/again.c"
  grep -q '^probe: on the graph' "$dir/probe-graph.elf.run.log" ||
    { echo "rom_graph: the probe did not take its graph" >&2; exit 1; }
  if ! cmp -s "$1" "$dir/again.c"; then
    echo "rom_graph: the boot on $1 left a different graph" >&2
    diff "$1" "$dir/again.c" | head -40 >&2
    exit 1
  fi
  head -1 "$1"
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
  probe) probe "$(cd "$(dirname "${3:?OUT.c}")" && pwd)/$(basename "$3")" ;;
  oracle)
    graph="$(cd "$(dirname "${4:?GRAPH.c}")" && pwd)/$(basename "$4")"
    lib
    dump "${3:?GAME_DIR}" "$build_dir/rom_graph.renode.c"
    lib "$graph"
    if ! cmp -s "$graph" "$build_dir/rom_graph.renode.c"; then
      echo "rom_graph: the Renode boot left a graph other than $graph" >&2
      diff "$graph" "$build_dir/rom_graph.renode.c" | head -40 >&2
      exit 1
    fi
    echo "rom_graph: the Renode boot leaves $graph"
    ;;
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
