#!/usr/bin/env bash

# Boot the built engine on a real RPG Maker XP project and confirm it reaches
# the map, headlessly.
#
# Why this exists: the RPG Maker XP runtime is written in Ruby under
# mruby-rpgxp, and the checks that cover it (scripts/rpgxp_testbed_check.rb,
# scripts/rpgxp_script_host_check.rb) load those same sources under *CRuby*.
# That cannot see mruby/CRuby divergence -- exactly the gap that had shipped two
# RPG2000 bugs (a bare `module_function`, `Enumerable#none?`) with every check
# green, which is why the LCF side grew scripts/rpg2k_boot_check.bash. This is
# the same guard for the XP side, and it is the native counterpart of
# scripts/rpgxp_browser_check.py (the same project, the same marker, in the
# browser build).
#
# The engine aborts on an uncaught mruby exception, so simply running it is most
# of the test; `--rpgxp_new_game` selects New Game without input and logs the
# `[RPGXP-MAP]` marker this asserts on, which is what pushes the run past the
# title screen into the map scene and its renderer.
#
# Game directories that are not present are skipped with a message rather than
# silently passed over -- but if *none* of them is present the check fails,
# because then it proved nothing.
#
# Usage: ./scripts/rpgxp_boot_check.bash [server_num] [game_dir...]
#   server_num  xvfb-run --server-num to use (default 112; see the reserved
#               display numbers in .github/workflows/build.yml)
#   game_dir    defaults to the repo's RPG Maker XP test bed

set -eu -o pipefail

cd "$(dirname "$0")/.."

SERVER_NUM="${1:-112}"
shift || true

ENGINE="${ENGINE:-./build/rpg_maker_clone}"
TIMEOUT_MS="${RPGXP_TIMEOUT_MS:-20000}"

GAMES=("$@")
if [ "${#GAMES[@]}" -eq 0 ] ; then
    # The editor-shaped test bed (loose Data/), and a *released* game -- Pray
    # for You ships as Game.ini + Game.rgssad with nothing loose, which is the
    # shape most RPG Maker XP games are distributed in and a different path
    # through the loader. It is also the only bed here with more than one map,
    # so it is what exercises Transfer Player and the scenes a real game's
    # opening builds. Absent directories are skipped with a message below.
    GAMES=(data/OpenGame.exe/Testbed/XP data/PrayforYou)
fi

if [ ! -x "${ENGINE}" ] ; then
    echo "error: ${ENGINE} not built; run cmake --build build first" >&2
    exit 1
fi

checked=0
failed=0
num="${SERVER_NUM}"

for game in "${GAMES[@]}" ; do
    if [ ! -f "${game}/Game.ini" ] ; then
        echo "skip ${game}: no Game.ini (run scripts/download-opengame-xp.bash first)"
        continue
    fi
    checked=$((checked + 1))
    log="$(mktemp)"
    echo "== ${game}"
    # Each game gets its own display number: xvfb-run -a's probe is not atomic
    # and can steal a display from a concurrent run (see build.yml).
    if ! xvfb-run --server-num="${num}" timeout 180 "${ENGINE}" \
            --game_dir "${game}" --rpgxp_new_game \
            --timeout_ms="${TIMEOUT_MS}" >"${log}" 2>&1 ; then
        echo "FAILED: ${game}: the engine exited non-zero" >&2
        failed=$((failed + 1))
    elif ! grep -q '\[RPGXP-MAP\]' "${log}" ; then
        echo "FAILED: ${game}: never reached the map scene ([RPGXP-MAP] missing)" >&2
        failed=$((failed + 1))
    else
        grep '\[RPGXP-MAP\]' "${log}"
    fi
    # ALSA has no device under CI and floods stderr; keep the rest.
    grep -v 'ALSA lib\|snd_\|Unknown PCM' "${log}" | tail -40 || true
    rm -f "${log}"
    num=$((num + 1))
done

if [ "${checked}" -eq 0 ] ; then
    echo "FAILED: none of the requested game directories is present, so nothing" \
         "was checked: ${GAMES[*]}" >&2
    exit 1
fi

if [ "${failed}" -ne 0 ] ; then
    echo "rpgxp boot check: ${failed} of ${checked} game(s) FAILED" >&2
    exit 1
fi

echo "rpgxp boot check: ${checked} game(s) booted into the map"
