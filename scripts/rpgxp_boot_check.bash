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
# the same guard for the XP side, on the same projects and the same marker as
# scripts/compare-rpgxp-wine.bash.
#
# The engine aborts on an uncaught mruby exception, so simply running it is most
# of the test. Each game is booted twice, once per path into a running game:
#
#   1. **The default**: the RGSS script host runs the project's own
#      Data/Scripts.rxdata (ADR 0029). `--rgss_host_new_game` taps confirm on the
#      game's own title screen and each scene the game reaches is logged as
#      `[RPGXP-HOST-SCENE]`, so reaching a *second* one means the game's engine
#      took a keypress and started something. A host that fails falls back to the
#      built-in flow without changing the exit code, so the run also fails on a
#      `script host failed` line.
#   2. **The built-in reimplemented flow**: `--rpgxp_new_game` selects New Game
#      without input (which also pins the boot to that flow) and logs the
#      `[RPGXP-MAP]` marker, pushing the run past the title screen into the map
#      scene and its renderer -- the path compare-rpgxp-wine.bash measures.
#
# Game directories that are not present are skipped with a message rather than
# silently passed over -- but if *none* of them is present the check fails,
# because then it proved nothing.
#
# Usage: ./scripts/rpgxp_boot_check.bash [server_num] [game_dir...]
#   server_num  xvfb-run --server-num to use (default 112; see the reserved
#               display numbers in .github/workflows/build.yml)
#   game_dir    defaults to the repo's two RPG Maker XP beds -- the editor-shaped
#               OpenGame test bed and the released Pray for You

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

# One headless run of the engine.
#   $1 game dir, $2 display number, $3 what the run is called in the log,
#   $4 the marker its log must contain, $5 extra engine flags (may be empty),
#   $6 how many [RPGXP-HOST-SCENE] lines the game must reach (0 = do not check)
# A run fails when the engine exits non-zero (any uncaught mruby exception aborts
# it), when its marker is missing, when the script host reported a boot failure
# and quietly fell back to the built-in flow -- that fallback keeps the exit code
# at zero, so without that test a broken default would pass -- or when the game
# never got past its first scene.
run_boot() {
    local game="$1" display="$2" label="$3" marker="$4" flags="$5" scenes="${6:-0}"
    local log rc=0
    log="$(mktemp)"
    echo "-- ${label}"
    # Each run gets its own display number: xvfb-run -a's probe is not atomic
    # and can steal a display from a concurrent run (see build.yml).
    # shellcheck disable=SC2086 # ${flags} is a deliberate word-split flag list
    if ! xvfb-run --server-num="${display}" timeout 180 "${ENGINE}" \
            --game_dir "${game}" ${flags} \
            --timeout_ms="${TIMEOUT_MS}" >"${log}" 2>&1 ; then
        echo "FAILED: ${game} (${label}): the engine exited non-zero" >&2
        rc=1
    elif ! grep -q "${marker}" "${log}" ; then
        echo "FAILED: ${game} (${label}): ${marker} missing" >&2
        rc=1
    elif grep -q 'script host failed' "${log}" ; then
        echo "FAILED: ${game} (${label}): the script host fell back to the built-in flow" >&2
        grep 'script host failed' "${log}" >&2
        rc=1
    elif [ "${scenes}" -gt 0 ] &&
             [ "$(grep -c '\[RPGXP-HOST-SCENE\]' "${log}")" -lt "${scenes}" ] ; then
        # One scene means the game drew its title and stayed there: the keypress
        # never reached its own engine, or its first screen could not act on it.
        echo "FAILED: ${game} (${label}): the game never left its first scene" \
             "(wanted ${scenes} scenes)" >&2
        grep '\[RPGXP-HOST-SCENE\]' "${log}" >&2
        rc=1
    else
        grep "${marker}" "${log}"
    fi
    # ALSA has no device under CI and floods stderr; keep the rest.
    grep -v 'ALSA lib\|snd_\|Unknown PCM' "${log}" | tail -40 || true
    rm -f "${log}"
    return "${rc}"
}

for game in "${GAMES[@]}" ; do
    if [ ! -f "${game}/Game.ini" ] ; then
        echo "skip ${game}: no Game.ini (run scripts/download-opengame-xp.bash first)"
        continue
    fi
    checked=$((checked + 1))
    echo "== ${game}"

    # 1. The default boot: no flags but `--rgss_host_new_game`, so the RGSS
    #    script host runs the game's own Data/Scripts.rxdata (ADR 0029), taps
    #    confirm on the game's own title screen and logs every scene the game
    #    reaches. Asserting on the *second* scene is what makes this more than a
    #    "did not crash" check: it means the game's own title screen took a
    #    keypress and started something.
    run_boot "${game}" "${num}" "script host (default)" '\[RPGXP-HOST-SCENE\]' \
        "--rgss_host_new_game" 2 || failed=$((failed + 1))

    # 2. The built-in reimplemented flow, which `--rpgxp_new_game` selects (it
    #    drives the built-in title screen, so it also switches the host off --
    #    see RPGXP#builtin_flow_forced?). This is the render path
    #    scripts/compare-rpgxp-wine.bash measures against the genuine runtime.
    run_boot "${game}" "${num}" "built-in flow (--rpgxp_new_game)" '\[RPGXP-MAP\]' \
        "--rpgxp_new_game" || failed=$((failed + 1))

    num=$((num + 1))
done

if [ "${checked}" -eq 0 ] ; then
    echo "FAILED: none of the requested game directories is present, so nothing" \
         "was checked: ${GAMES[*]}" >&2
    exit 1
fi

if [ "${failed}" -ne 0 ] ; then
    echo "rpgxp boot check: ${failed} of $((checked * 2)) run(s) FAILED" >&2
    exit 1
fi

echo "rpgxp boot check: ${checked} game(s) booted twice -- their own scripts" \
     "under the script host, and the built-in flow into the map"
