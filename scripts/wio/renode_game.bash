#!/usr/bin/env bash
# Plays a game on the wio_renode_game firmware under Renode and checks it got
# where it was sent: packs GAME_DIR (scripts/wio/game_rom.rb), boots the ELF on
# the chosen board with the image at the QSPI window, runs until the firmware
# says it is done, then prints its log (stderr plus one "P <phase>" heap line
# per phase) and fails unless the run finished and every --expect pattern is
# in the log.
#
# Usage:
#   scripts/wio/renode_game.bash ELF GAME_DIR [options]
#     --board real|big|FILE.repl  real: the board's 192 KB of RAM (default);
#                        big: 16 MB (the wio_renode_game_big ELF); or a
#                        board description of your own
#     --config 'k=v;..'  the run (see app/wio/src/wio_renode_game_main.cxx)
#     --expect REGEX     a line the log must have (repeatable)
#     --seconds N        virtual-time budget (default 120)
#     --font FILE        gothic.bin for kanji (the wio libmruby build's)
#     --log FILE         keep the log there
#     --trace FILE       also write Renode's PC trace of half a virtual second
#                        to FILE (scripts/wio/qspi_xip_hot.rb reads it), from
#     --trace-at N       virtual second N (default 25: map frames by then)
#     --heapwalk DIR     HEAPWALK: a wio_renode_game_heapwalk[_big] ELF saves its
#                        heap snapshots to DIR (scripts/wio/heapwalk_report.rb
#                        reads them); the image window grows to 32 MB so every
#                        palette image fits decoded
#     --sd pack|nopack   the game on an SD card image, in its /rpg2k, instead
#                        of in the image (which then carries the config and the
#                        font only); with `pack`, with its wio_bitmaps.bin
#                        (scripts/wio/sd_bitmaps.rb) for the QSPI image cache
#     --qspi-out FILE    save the 4 MB QSPI flash when the run is over
#     --qspi-in FILE     start from a saved flash (the same ELF and --config):
#                        a reboot, with the image cache as the last run left it
#     --rom-graph FILE   ROM_GRAPH: a rom_graph=1 run's class graph C goes to FILE
#     --framehash FILE   FRAMEHASH: the run's "FH <frame> <hash>" lines go to FILE
#                        (scripts/compare/framehash.rb compares two)
# RENODE_BIN is the Renode binary (see app/wio/renode/README.md); RENODE_GAME_RAW
# names a file to keep Renode's own output in (per-step PC and log length).
set -euo pipefail

usage() {
  sed -n '2,/^set /p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 64
}
[[ $# -ge 2 ]] || usage
elf="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
game="$2"
shift 2
board=real config='frames=600' seconds=120 font='' log='' trace='' trace_at=25 heapwalk='' sd='' qspi_out='' qspi_in='' rom_graph='' framehash=''
expects=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --board) board=$2 ;;
    --config) config=$2 ;;
    --expect) expects+=("$2") ;;
    --seconds) seconds=$2 ;;
    --font) font=$2 ;;
    --log) log=$2 ;;
    --trace) trace=$2 ;;
    --trace-at) trace_at=$2 ;;
    --heapwalk) heapwalk=$(mkdir -p "$2" && cd "$2" && pwd) ;;
    --sd) [[ $2 == pack || $2 == nopack ]] || usage; sd=$2 ;;
    --qspi-out) qspi_out=$(cd "$(dirname "$2")" && pwd)/$(basename "$2") ;;
    --qspi-in) qspi_in=$(cd "$(dirname "$2")" && pwd)/$(basename "$2") ;;
    --rom-graph) rom_graph=$(cd "$(dirname "$2")" && pwd)/$(basename "$2") ;;
    --framehash) framehash=$(cd "$(dirname "$2")" && pwd)/$(basename "$2") ;;
    *) usage ;;
  esac
  shift 2
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -n "$framehash" ]] && config="$config;framehash=1"
renode="${RENODE_BIN:-renode}"
nm="${ARM_NM:-$HOME/.platformio/packages/toolchain-gccarmnoneeabi/bin/arm-none-eabi-nm}"
case $board in
  real) repl=$repo_root/app/wio/renode/wio_terminal_oversized_flash.repl ;;
  big) repl=$repo_root/app/wio/renode/wio_terminal_oversized_flash_and_16m_ram.repl ;;
  *.repl) repl=$(cd "$(dirname "$board")" && pwd)/$(basename "$board") ;;
  *) usage ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
adds=()
[[ -n "$font" ]] && adds=(--add "$font:/gothic.bin")
addr() { printf '0x%x' $((0x$("$nm" -C "$elf" | awk -v s="$1" '{n=$3; for (i = 4; i <= NF; i++) n = n " " $i} n == s {print $1; exit}') & ~1)); }
# A QSPI_XIP firmware (app/wio/qspi_xip.ld) runs code from the window's start, and the game image follows it.
rom_base=0x04000000
"$nm" "$elf" | awk '$3 == "__wio_game_rom_base" {f = 1} END {exit !f}' && rom_base=$(addr __wio_game_rom_base)
rom_end=0x05000000
[[ -n "$heapwalk" ]] && rom_end=0x06000000
rom_game=$game
if [[ -n "$sd" ]]; then
  # The card: the game folder as game_rom.rb would pack it (no audio, no Windows binaries), at /rpg2k.
  card=$work/card
  mkdir -p "$card" "$work/nogame"
  for f in "$game"/*; do
    case $(basename "$f") in Music | Sound | Movie | *.exe | *.EXE | *.dll | *.DLL) continue ;; esac
    cp -r "$f" "$card/"
  done
  [[ $sd == pack ]] && ruby "$repo_root/scripts/wio/sd_bitmaps.rb" "$card" >&2
  mb=$(($(du -sm "$card" | cut -f1) * 5 / 4 + 16))
  dd if=/dev/zero of="$work/sdcard.img" bs=1M count="$mb" status=none
  # mtools and dosfstools, else from nixpkgs (as scripts/wio/renode_sdcard.bash does).
  fat() { if command -v mkfs.vfat >/dev/null && command -v mcopy >/dev/null; then "$@"; else nix-shell -p dosfstools mtools --run "$(printf '%q ' "$@")"; fi; }
  fat mkfs.vfat -F 16 -n WIOSD "$work/sdcard.img" >/dev/null
  fat env LC_ALL=C.UTF-8 mcopy -s -i "$work/sdcard.img" "$card" ::/rpg2k
  rm -rf "$card"
  printf 'sdcard: SD.SDCard @ sercom6_spi\n    imageFile: "%s"\n    capacity: %d\n    persistent: false\n    spiMode: true\n' \
    "$work/sdcard.img" $((mb * 1024 * 1024)) > "$work/sdcard.repl"
  rom_game=$work/nogame
fi
ruby "$repo_root/scripts/wio/game_rom.rb" "$work/game.rom" "$rom_game" --config "$config" "${adds[@]}" \
  --limit $((rom_end - rom_base)) >&2
result=$(addr '(anonymous namespace)::g_result')
step=5
{
  echo 'mach create "wio"'
  echo "machine LoadPlatformDescription @$repl"
  echo "machine LoadPlatformDescription @$repo_root/app/wio/renode/game_rom.repl"
  [[ -n "$heapwalk" ]] && echo "machine LoadPlatformDescription @$repo_root/app/wio/renode/heapwalk.repl"
  [[ -n "$rom_graph" ]] && echo "machine LoadPlatformDescription @$repo_root/app/wio/renode/rom_graph.repl"
  [[ -n "$framehash" ]] && echo "machine LoadPlatformDescription @$repo_root/app/wio/renode/framehash.repl"
  [[ -n "$sd" ]] && echo "machine LoadPlatformDescription @$work/sdcard.repl"
  echo "sysbus LoadELF @$elf"
  echo "sysbus LoadBinary @$work/game.rom $rom_base"
  [[ -n "$qspi_in" ]] && echo "sysbus LoadBinary @$qspi_in 0x04000000"
  # The buttons and the 5-way switch are active low: release them all.
  for p in 26 27 28; do echo "portc OnGPIO $p true"; done
  for p in 20 12 9 8 10; do echo "portd OnGPIO $p true"; done
  for s in HardFault_Handler Dummy_Handler; do
    echo "cpu0 AddHook $(addr $s) \"print('=== FAULT $s LR=0x%x' % cpu.GetRegisterUnsafe(14).RawValue); cpu.RemoveHooksAt(cpu.PC)\""
  done
  # heapwalk_flush(slot, out_len, heap, heap_len): the output window and the heap, as snapshot `slot`.
  if [[ -n "$heapwalk" ]]; then
    echo "cpu0 AddHook $(addr heapwalk_flush) \"import System; r = [int(cpu.GetRegisterUnsafe(i).RawValue) for i in range(4)]; System.IO.File.WriteAllBytes('$heapwalk/snap-%04d.out' % r[0], machine.SystemBus.ReadBytes(0x0A000000, r[1])); System.IO.File.WriteAllBytes('$heapwalk/snap-%04d.heap' % r[0], machine.SystemBus.ReadBytes(r[2], r[3]))\""
  fi
  # rom_graph_flush(len): the graph's C, [0x0C000000, +len).
  if [[ -n "$rom_graph" ]]; then
    echo "cpu0 AddHook $(addr rom_graph_flush) \"import System; System.IO.File.WriteAllBytes('$rom_graph', machine.SystemBus.ReadBytes(0x0C000000, int(cpu.GetRegisterUnsafe(0).RawValue)))\""
  fi
  echo "cpu0 AddHook $(addr mrb_raise_nomemory) \"print('=== NOMEMORY'); cpu.RemoveHooksAt(cpu.PC)\""
  echo 'logLevel 3'
  for ((t = 0; t < seconds; t += step)); do
    if [[ -n "$trace" && $t == "$trace_at" ]]; then
      echo "cpu0 CreateExecutionTracing \"trace\" @$trace PC"
      echo 'emulation RunFor "00:00:00.5"'
      echo 'cpu0 DisableExecutionTracing'
    fi
    echo "emulation RunFor \"00:00:0$step\""
    echo "echo \"RESULT\""
    echo "sysbus ReadDoubleWord $result"
    echo "echo \"LOGLEN\""
    echo "sysbus ReadDoubleWord 0x06000000"
    echo "cpu0 PC"
  done
  [[ -n "$qspi_out" ]] &&
    echo "python \"import System; System.IO.File.WriteAllBytes('$qspi_out', monitor.Machine.SystemBus.ReadBytes(0x04000000, 0x400000))\""
  # The FH log: u32 bytes written at 0x0E040000, the text 16 bytes on.
  [[ -n "$framehash" ]] &&
    echo "python \"import System; b = monitor.Machine.SystemBus; System.IO.File.WriteAllBytes('$framehash', b.ReadBytes(0x0E040010, int(b.ReadDoubleWord(0x0E040000))))\""
  echo 'echo "QSPI_ERASES"'
  echo 'qspi EraseCount'
  echo 'echo "DIAG_BEGIN"'
  echo 'sysbus ReadBytes 0x06000000 0x10000'
  echo 'echo "DIAG_END"'
} > "$work/run.resc"

# This repo's peripherals, but for those a scripts/wio/renode_build.bash binary has built in: Renode stops at an
# include of one it already has.
includes=()
built_in=$(dirname "$(command -v "$renode")")/src/Infrastructure/src/Emulator/Peripherals/Peripherals
for p in SPI/SAMD51_SERCOM_SPI.cs Video/ILI9341_SPI.cs SPI/SAMD51_QSPI.cs; do
  [[ -f "$built_in/$p" ]] || includes+=(-e "include @$repo_root/app/wio/renode/peripherals/$p")
done
# An open stdin with no input: a closed one (/dev/null) trips Renode's ConsoleIOSource SemaphoreFullException on long
# runs, which aborts it before the end-of-run dumps.
mkfifo "$work/stdin"
sleep 100000 > "$work/stdin" &
holder=$!
"$renode" --disable-gui --console --plain "${includes[@]}" \
  -e "include @$work/run.resc" -e "quit" < "$work/stdin" > "$work/renode.out" 2>&1 || true
kill "$holder" 2>/dev/null || true

ruby -e '
  out = File.binread(ARGV[0])
  results = out.scan(/RESULT\s+(0x\h+)/).flatten
  bytes = out[/DIAG_BEGIN(.*)DIAG_END/m, 1].to_s.scan(/0x(\h\h)/).flatten.map { |h| h.to_i(16) }
  n = bytes[0, 4].pack("C*").unpack1("V").to_i
  text = bytes[16, n].to_a.pack("C*").force_encoding("UTF-8").scrub
  out.each_line { |l| puts l.strip if l.include?("=== ") }
  qspi = out.scan(/QSPI_ERASES\s+(0x\h+|\d+)/).flatten.last
  puts "QSPI erases #{Integer(qspi)}" if qspi
  puts text
  puts "RESULT #{results.last}"
' "$work/renode.out" > "$work/log.txt"
cat "$work/log.txt"
[[ -n "${RENODE_GAME_RAW:-}" ]] && cp "$work/renode.out" "$RENODE_GAME_RAW"
[[ -n "$log" ]] && cp "$work/log.txt" "$log"

ok=1
grep -qi 'RESULT 0x6a6e00d0' "$work/log.txt" || { echo "renode_game: the run did not finish" >&2; ok=0; }
for e in "${expects[@]}"; do
  grep -Eq "$e" "$work/log.txt" || { echo "renode_game: no line matches /$e/" >&2; ok=0; }
done
[[ $ok == 1 ]]
