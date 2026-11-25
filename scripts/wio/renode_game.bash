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
board=real config='frames=600' seconds=120 font='' log='' trace='' trace_at=25 expects=()
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
    *) usage ;;
  esac
  shift 2
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
ruby "$repo_root/scripts/wio/game_rom.rb" "$work/game.rom" "$game" --config "$config" "${adds[@]}" \
  --limit $((0x05000000 - rom_base)) >&2
result=$(addr '(anonymous namespace)::g_result')
step=5
{
  echo 'mach create "wio"'
  echo "machine LoadPlatformDescription @$repl"
  echo "machine LoadPlatformDescription @$repo_root/app/wio/renode/game_rom.repl"
  echo "sysbus LoadELF @$elf"
  echo "sysbus LoadBinary @$work/game.rom $rom_base"
  # The buttons and the 5-way switch are active low: release them all.
  for p in 26 27 28; do echo "portc OnGPIO $p true"; done
  for p in 20 12 9 8 10; do echo "portd OnGPIO $p true"; done
  for s in HardFault_Handler Dummy_Handler; do
    echo "cpu0 AddHook $(addr $s) \"print('=== FAULT $s LR=0x%x' % cpu.GetRegisterUnsafe(14).RawValue); cpu.RemoveHooksAt(cpu.PC)\""
  done
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
  echo 'echo "DIAG_BEGIN"'
  echo 'sysbus ReadBytes 0x06000000 0x10000'
  echo 'echo "DIAG_END"'
} > "$work/run.resc"

"$renode" --disable-gui --console --plain \
  -e "include @$repo_root/app/wio/renode/peripherals/SPI/SAMD51_SERCOM_SPI.cs" \
  -e "include @$repo_root/app/wio/renode/peripherals/Video/ILI9341_SPI.cs" \
  -e "include @$work/run.resc" -e "quit" < /dev/null > "$work/renode.out" 2>&1 || true

ruby -e '
  out = File.binread(ARGV[0])
  results = out.scan(/RESULT\s+(0x\h+)/).flatten
  bytes = out[/DIAG_BEGIN(.*)DIAG_END/m, 1].to_s.scan(/0x(\h\h)/).flatten.map { |h| h.to_i(16) }
  n = bytes[0, 4].pack("C*").unpack1("V").to_i
  text = bytes[16, n].to_a.pack("C*").force_encoding("UTF-8").scrub
  out.each_line { |l| puts l.strip if l.include?("=== ") }
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
