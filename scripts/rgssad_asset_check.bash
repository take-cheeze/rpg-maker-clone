#!/usr/bin/env bash

# Boot a *packed* RPG Maker XP release and confirm the engine finds its art
# inside the encrypted archive.
#
# Why this exists: a released game ships one Game.rgssad holding its whole tree
# -- Data/ and Graphics/ and Audio/ -- with nothing loose on disk. The data
# layer has read Data/ out of the archive for a while, but the native asset
# loaders only ever opened files, so a packed release booted with no graphics at
# all. Bitmap now falls back to RGSS.asset_archive, and this is the check that
# the whole chain works in the real binary: boot shell registers the archive ->
# Bitmap#initialize misses on disk and asks it -> the entry decrypts -> the
# native decoder reads the bytes.
#
# It is an A/B, not a single run, so it cannot pass vacuously. The same project
# is packed twice, differing only in whether the title graphic is inside the
# archive:
#
#   with    -> the engine must NOT log "title graphic load failed"
#   without -> it must, and must still boot (a missing asset is not fatal)
#
# A change that quietly stopped consulting the archive turns the first run into
# the second, and this fails.
#
# The engine also aborts on an uncaught mruby exception, so both runs reaching
# [RPGXP-MAP] is part of the test.
#
# Usage: ./scripts/rgssad_asset_check.bash [server_num] [game_dir]
#   server_num  xvfb-run --server-num to use (default 113; see the reserved
#               display numbers in .github/workflows/build.yml)
#   game_dir    defaults to the repo's RPG Maker XP test bed

set -eu -o pipefail

cd "$(dirname "$0")/.."

SERVER_NUM="${1:-113}"
GAME="${2:-data/OpenGame.exe/Testbed/XP}"
ENGINE="${ENGINE:-./build/rpg_maker_clone}"
TIMEOUT_MS="${RGSSAD_TIMEOUT_MS:-20000}"

if [ ! -x "${ENGINE}" ] ; then
    echo "error: ${ENGINE} not built; run cmake --build build first" >&2
    exit 1
fi
if [ ! -f "${GAME}/Data/System.rxdata" ] ; then
    echo "FAILED: ${GAME} has no Data/System.rxdata; run" \
         "scripts/download-opengame-xp.bash first" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Pack the bed's real Data/ into two archives. `with` also carries a title
# graphic named after the project's own System.title_name, which is the file the
# title scene asks for; `without` is otherwise identical. Neither directory has a
# loose Data/ or Graphics/, so the archive is the only possible source.
#
# The picture is a 3x2 XYZ (RPG Maker's own indexed format, decoded natively):
# "XYZ1", uint16 LE width/height, then a zlib stream of a 768-byte palette plus
# one index per pixel.
ruby - "${GAME}" "${WORK}" <<'RUBY'
require "fileutils"

# Marshal instantiates by name, so the RGSS value types have to exist before the
# database loads. Only presence matters here (the real ones are native); this
# mirrors what scripts/rpgxp_testbed_check.rb sets up.
class Table; def self._load(s) = allocate; end
class Color; def self._load(s) = allocate; end
class Tone;  def self._load(s) = allocate; end
class Rect;  def self._load(s) = allocate; end

load File.join(Dir.pwd, "mruby-rpgxp/mrblib/rgssad.rb")
load File.join(Dir.pwd, "mruby-rpgxp/mrblib/rgss_data.rb")

game, work = ARGV
data = Dir[File.join(game, "Data", "*.rxdata")].sort.map do |f|
  ["Data/#{File.basename(f)}", File.binread(f)]
end
abort "no Data/*.rxdata under #{game}" if data.empty?

# Ask the project which title graphic it wants, through the same schema the
# engine uses, so the title scene really does look for the file we pack.
title = RPGXP::RGSSData.new(game).system.title_name
abort "#{game} names no title graphic" if title.nil? || title.empty?
puts "title graphic: #{title}"

xyz = ("\x58\x59\x5a\x31\x03\x00\x02\x00\x78\x9c\xe3\x12\x91\xfb\xcf\xc0" \
       "\xc0\x00\xc2\xa3\x60\x14\x8c\x3c\xc0\xc8\xc4\xc4\xc8\x00\x00\xb4" \
       "\x8b\x02\x41").b

{ "with" => data + [["Graphics/Titles/#{title}.xyz", xyz]],
  "without" => data }.each do |which, files|
  dir = File.join(work, which)
  FileUtils.mkdir_p dir
  File.binwrite(File.join(dir, "Game.rgssad"), RPGXP::RGSSAD.pack_v1(files))
  File.write(File.join(dir, "Game.ini"), "[Game]\nTitle=Packed XP\n")
end
RUBY

fail=0
num="${SERVER_NUM}"
for which in with without ; do
    log="${WORK}/${which}.log"
    echo "== packed ${which} the title graphic"
    # Each run gets its own display: xvfb-run -a's probe is not atomic and can
    # steal a display from a concurrent run (see build.yml).
    if ! xvfb-run --server-num="${num}" timeout 180 "${ENGINE}" \
            --game_dir "${WORK}/${which}" --rpgxp_new_game \
            --timeout_ms="${TIMEOUT_MS}" >"${log}" 2>&1 ; then
        echo "FAILED: packed ${which}: the engine exited non-zero" >&2
        fail=1
    elif ! grep -q '\[RPGXP-MAP\]' "${log}" ; then
        echo "FAILED: packed ${which}: never reached the map ([RPGXP-MAP] missing)" >&2
        fail=1
    fi
    grep '\[RPGXP-MAP\]' "${log}" || true
    num=$((num + 1))
done

if grep -q 'title graphic load failed' "${WORK}/with.log" ; then
    echo "FAILED: the title graphic was in the archive and the engine did not" \
         "find it -- the packed-asset path is broken" >&2
    grep 'title graphic load failed' "${WORK}/with.log" >&2
    fail=1
fi
# The other half of the A/B: without the entry the load must fail, or the check
# above proves nothing (e.g. a loose copy leaking in from somewhere).
if ! grep -q 'title graphic load failed' "${WORK}/without.log" ; then
    echo "FAILED: the title graphic was NOT in the archive and the engine" \
         "loaded one anyway -- this check cannot tell the two apart" >&2
    fail=1
fi

if [ "${fail}" -ne 0 ] ; then
    # ALSA has no device under CI and floods stderr; keep the rest.
    for which in with without ; do
        echo "--- packed ${which}" >&2
        grep -v 'ALSA lib\|snd_\|Unknown PCM' "${WORK}/${which}.log" | tail -30 >&2 || true
    done
    exit 1
fi

echo "rgssad asset check: a packed release loaded its title graphic out of" \
     "Game.rgssad (and reported the miss when it was not packed)"
