#!/usr/bin/env bash

# Boot the built engine on real RPG Maker 2000/2003 data and confirm it reaches
# the map, headlessly. It also drives a real project into the *battle* scene
# (--rpg2k_battle_troop, see the section below) so the 2003 battle path is
# exercised end to end rather than only reached up to the map.
#
# Why this exists: the RPG2000 runtime is written in Ruby under mruby-rpg2k, and
# the checks that cover it (scripts/rpg2k_logic_check.rb, rpg2k_scene_check.rb,
# rpg2k_render_check.rb) load those same sources under *CRuby*. That cannot see
# mruby/CRuby divergence, and two such bugs shipped: a bare `module_function`
# (a documented no-op in mruby, so Game::ChipsetLayout's methods did not exist)
# and `Enumerable#none?` (absent from this build's gem set). Both left the
# New Game -> map path raising in the actual binary while every check passed.
# See ADR 0021.
#
# The engine aborts on an uncaught mruby exception, so simply running it is most
# of the test; `--rpg2k_new_game` selects New Game without input and logs the
# `[RPG2k-MAP]` marker this asserts on, which is what pushes the run past the
# title screen and through the map renderer.
#
# Game directories that are not present are skipped with a message rather than
# silently passed over -- but if *none* of them is present the check fails,
# because then it proved nothing.
#
# Usage: ./scripts/rpg2k_boot_check.bash [server_num] [game_dir...]
#   server_num  xvfb-run --server-num to use (default 109; see the reserved
#               display numbers in .github/workflows/build.yml)
#   game_dir    defaults to the repo's RPG2000/2003 test-beds

set -eu -o pipefail

cd "$(dirname "$0")/.."

SERVER_NUM="${1:-109}"
shift || true

ENGINE="${ENGINE:-./build/rpg_maker_clone}"
TIMEOUT_MS="${RPG2K_TIMEOUT_MS:-20000}"

GAMES=("$@")
if [ "${#GAMES[@]}" -eq 0 ] ; then
    GAMES=(data/Nepheshel206beta/Nepheshel206Rbeta data/mtf-meido-action/Debug)
fi

if [ ! -x "${ENGINE}" ] ; then
    echo "error: ${ENGINE} not built; run cmake --build build first" >&2
    exit 1
fi

checked=0
failed=0
num="${SERVER_NUM}"

for game in "${GAMES[@]}" ; do
    if [ ! -f "${game}/RPG_RT.ldb" ] ; then
        echo "skip ${game}: no RPG_RT.ldb (run scripts/download-*.bash first)"
        continue
    fi
    checked=$((checked + 1))
    log="$(mktemp)"
    echo "== ${game}"
    # Each game gets its own display number: xvfb-run -a's probe is not atomic
    # and can steal a display from a concurrent run (see build.yml).
    if ! xvfb-run --server-num="${num}" timeout 180 "${ENGINE}" \
            --game_dir "${game}" --test_play --rpg2k_new_game \
            --timeout_ms="${TIMEOUT_MS}" >"${log}" 2>&1 ; then
        echo "FAILED: ${game}: the engine exited non-zero" >&2
        failed=$((failed + 1))
    elif ! grep -q '\[RPG2k-MAP\]' "${log}" ; then
        echo "FAILED: ${game}: never reached the map scene ([RPG2k-MAP] missing)" >&2
        failed=$((failed + 1))
    elif grep -q 'title BGM playback failed' "${log}" ; then
        # The title screen plays System > title music, reading the record off
        # the database. That runs on real data only here, and it is rescued so
        # a schema mismatch would degrade to silence instead of failing --
        # which is why the log is checked rather than the exit status.
        echo "FAILED: ${game}: title BGM raised" >&2
        grep 'title BGM playback failed' "${log}" >&2
        failed=$((failed + 1))
    else
        grep '\[RPG2k-MAP\]' "${log}"
    fi
    # ALSA has no device under CI and floods stderr; keep the rest.
    grep -v 'ALSA lib\|snd_\|Unknown PCM' "${log}" | tail -40 || true
    rm -f "${log}"
    num=$((num + 1))
done

# --rpg2k_battle: a bare boot only ever reaches the map -- the RPG2003 test
# beds ship no encounters, so nothing drives the game into a fight on its own.
# The flag opens a battle against a named troop once New Game's map is up, and
# Scene::Battle#start logs the [RPG2k-BATTLE] marker when the fight's UI is
# really on screen. This pass asserts that marker (and that the battle scene
# never raised), exercising the 2003 battle path -- scene routing, troop
# sprites, actor sprites, the gauge-card status panel, per-frame gauge advance
# -- end to end against real data (ADR 0053 Phase 3). Overridable so a
# different project/troop can be driven instead.
BATTLE_GAME="${RPG2K_BATTLE_GAME:-data/mtf-meido-action/Debug}"
BATTLE_TROOP="${RPG2K_BATTLE_TROOP:-14}"
if [ -f "${BATTLE_GAME}/RPG_RT.ldb" ] ; then
    checked=$((checked + 1))
    log="$(mktemp)"
    echo "== ${BATTLE_GAME} (battle --rpg2k_battle_troop=${BATTLE_TROOP})"
    if ! xvfb-run --server-num="${num}" timeout 180 "${ENGINE}" \
            --game_dir "${BATTLE_GAME}" --test_play \
            --rpg2k_battle_troop="${BATTLE_TROOP}" \
            --timeout_ms="${TIMEOUT_MS}" >"${log}" 2>&1 ; then
        echo "FAILED: ${BATTLE_GAME}: the engine exited non-zero" >&2
        failed=$((failed + 1))
    elif ! grep -q '\[RPG2k-BATTLE\]' "${log}" ; then
        echo "FAILED: ${BATTLE_GAME}: never reached the battle scene" \
             "([RPG2k-BATTLE] missing)" >&2
        failed=$((failed + 1))
    elif grep -q '\[RPG2k\] battle failed' "${log}" ; then
        echo "FAILED: ${BATTLE_GAME}: the battle scene raised" >&2
        grep '\[RPG2k\] battle failed' "${log}" >&2
        failed=$((failed + 1))
    else
        grep '\[RPG2k-BATTLE\]' "${log}"
    fi
    grep -v 'ALSA lib\|snd_\|Unknown PCM' "${log}" | tail -40 || true
    rm -f "${log}"
    num=$((num + 1))
else
    echo "skip ${BATTLE_GAME}: no RPG_RT.ldb (run scripts/download-mtf-meido-action.bash first)"
fi

if [ "${checked}" -eq 0 ] ; then
    echo "FAILED: none of the requested game directories is present, so nothing" \
         "was checked: ${GAMES[*]}" >&2
    exit 1
fi

if [ "${failed}" -ne 0 ] ; then
    echo "rpg2k boot check: ${failed} of ${checked} run(s) FAILED" >&2
    exit 1
fi

echo "rpg2k boot check: ${checked} run(s) reached their scene"
