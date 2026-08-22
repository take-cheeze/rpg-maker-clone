#!/usr/bin/env bash

# Boot the built engine on a real RPG Maker XP project and confirm the game's own
# engine runs, headlessly: off its title screen and onto its map.
#
# Why this exists: the RPG Maker XP runtime is written in Ruby under
# mruby-rpgxp, and the checks that cover it (scripts/rpgxp_testbed_check.rb,
# scripts/rpgxp_script_host_check.rb) load those same sources under *CRuby*.
# That cannot see mruby/CRuby divergence -- exactly the gap that had shipped two
# RPG2000 bugs (a bare `module_function`, `Enumerable#none?`) with every check
# green, which is why the LCF side grew scripts/rpg2k_boot_check.bash. This is
# the same guard for the XP side, on the same projects as
# scripts/compare-rpgxp-wine.bash.
#
# The engine aborts on an uncaught mruby exception, so simply running it is most
# of the test. What is asserted beyond that is how far the game's own engine gets
# (ADR 0030 -- there is no second engine to fall back to any more):
#
#   * `--rgss_host_move_test` taps confirm on the game's own title screen, then
#     walks the party on its map. Every scene the game reaches is logged as
#     `[RPGXP-HOST-SCENE]`, so reaching a *second* one means its title screen
#     took a keypress and started something.
#   * the walk is reported as `[RPGXP-HOST-MOVE] start=.. end=.. moved=..`,
#     which is asserted for the editor test bed: its start map is plain and
#     walkable. A released game opens on a cutscene, so its walk is logged and
#     not asserted.
#   * then `--rgss_host_menu_test` presses cancel and reports where the game
#     went as `[RPGXP-HOST-MENU] scene=.. opened=..`. That is the rung above
#     walking: a game's menu is the first thing it draws out of its own Window
#     classes, its own windowskin and its own font, none of which a map scene
#     touches. Asserted on the editor bed (stock scripts, menu enabled), logged
#     on the released game.
#   * a second pass over the editor bed calls a battle the way the game's own
#     Battle Processing command does and reports
#     `[RPGXP-HOST-BATTLE] scene=.. reached=.. called=..`. Its own pass
#     because a battle is called from the map and the pass above ends inside
#     the menu; the editor bed only, because a released game's opening is an
#     event sequence a battle call would land in the middle of -- and, found
#     tracing a real release by hand (not through this script), because a
#     real game may replace `Game_Temp` entirely with a custom one that has
#     none of the stock battle-calling attributes this probe sets, in which
#     case `called=false` (the probe never even got to ask) rather than
#     `reached=false` (it asked, but the game's own engine never brought
#     `Scene_Battle` up). This is the biggest surface of the lot: every enemy
#     in it is a `Sprite_Battler`, on top of `RPG::Sprite`.
#   * a third pass opens the game's own save screen the same way
#     (`--rgss_host_save_test`, `[RPGXP-HOST-SAVE]`). That is the one place a
#     game reads a file's timestamp back — its `Window_SaveFile` stamps each
#     slot from `File#mtime` — and where its own `save_data` writes a real file.
#     Where that file lands is asserted too: the stock `Scene_Save` writes a
#     bare `"Save1.rxdata"`, so it proves the engine ran the game from its own
#     directory rather than from wherever it was launched (gap 0j).
#   * a `script host failed` line fails the run: the game's own scripts stopping
#     is the failure this check exists to catch.
#
# Game directories that are not present are skipped with a message rather than
# silently passed over -- but if *none* of them is present the check fails,
# because then it proved nothing.
#
# Usage: RPGXP_BOOT_PASS=<pass> ./scripts/rpgxp_boot_check.bash [server_num] [game_dir...]
#   server_num  xvfb-run --server-num to use (default 112; see the reserved
#               display numbers in .github/workflows/build.yml). Each run takes
#               the next one, and build.yml reserves 112..119 for this check so
#               another probe can be added without renumbering anything else.
#   game_dir    defaults to the repo's two RPG Maker XP beds -- the editor-shaped
#               OpenGame test bed and the released Pray for You
#   RPGXP_BOOT_PASS
#               one of `script_host`, `battle`, `save`, or unset (default) to run
#               every pass that applies to each requested game, as this script
#               always did before this variable existed. The four passes across
#               the two default beds are independent full engine boots that
#               share nothing but the save-file sweep at the very end, so
#               build.yml runs one per CI step (each on its own display number)
#               instead of the four of them serially in one step -- see the
#               `RPG XP real-game boot smoke` steps there. A pass that does not
#               apply to a requested game (e.g. `battle` against a released
#               game, which only ever gets a `script_host` pass) is skipped.

set -eu -o pipefail

cd "$(dirname "$0")/.."

SERVER_NUM="${1:-112}"
shift || true

ENGINE="${ENGINE:-./build/rpg_maker_clone}"
# Wall-clock budget per run. The engine counts it in Graphics.update, but what
# has to fit inside it is a *frame* count -- the game's own title screen, then
# the settle, the four held directions of the move probe and the menu -- and CI
# has no GPU, so a 640x480 tilemap redraw is nowhere near the 40 fps RGSS
# nominally runs at. 20s was enough to reach the map and not to finish the walk;
# this is sized so the probes still land at well under ten frames a second.
TIMEOUT_MS="${RPGXP_TIMEOUT_MS:-45000}"
# Pin the random number generator, so every run of this check drives the *same*
# game. mruby seeds from the clock and a game's own engine rolls constantly --
# the encounter count as the party is placed, damage variance, and the order the
# battlers act in -- so without this the battle pass is a different fight every
# time, and it showed: it passed twice and then failed inside the game's own
# make_action_orders with no way to ask for that run back. Override to hunt a
# failure that only some seeds reach.
RANDOM_SEED="${RPGXP_RANDOM_SEED:-20260806}"

# Restrict this run to one pass (see the usage comment above). Empty means run
# every pass that applies to each requested game, same as always.
RPGXP_BOOT_PASS="${RPGXP_BOOT_PASS:-}"
case "${RPGXP_BOOT_PASS}" in
    ''|script_host|battle|save) ;;
    *) echo "error: RPGXP_BOOT_PASS must be one of: script_host, battle, save" \
            "(got '${RPGXP_BOOT_PASS}')" >&2
       exit 1 ;;
esac
want_pass() { [ -z "${RPGXP_BOOT_PASS}" ] || [ "${RPGXP_BOOT_PASS}" = "$1" ] ; }

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
#   $4 extra engine flags (may be empty),
#   $5 how many [RPGXP-HOST-SCENE] lines the game must reach (0 = do not check),
#   $6.. the markers its log must contain (all of them)
# A run fails when the engine exits non-zero (any uncaught mruby exception aborts
# it), when a marker is missing, when the script host reported a failure inside
# the game's own scripts, or when the game never got past its first scene.
run_boot() {
    local game="$1" display="$2" label="$3" flags="$4" scenes="${5:-0}"
    shift 5
    local markers=("$@")
    local log rc=0 marker missing=""
    log="$(mktemp)"
    echo "-- ${label}"
    # Start from no save files. The save pass below leaves one, and a title
    # screen offers Continue when it finds one -- which changes what the confirm
    # taps pick, so a later pass (or a second invocation) would drive a different
    # game. The repo root is swept too: it is where a save used to land before
    # the engine learned to run from the game's own directory, and a stale one
    # left over from then would still be found by a game launched from here.
    rm -f Save[0-9]*.rxdata "${game}"/Save[0-9]*.rxdata
    # Each run gets its own display number: xvfb-run -a's probe is not atomic
    # and can steal a display from a concurrent run (see build.yml).
    # shellcheck disable=SC2086 # ${flags} is a deliberate word-split flag list
    if ! xvfb-run --server-num="${display}" timeout 180 "${ENGINE}" \
            --game_dir "${game}" --test_play ${flags} \
            --rgss_random_seed="${RANDOM_SEED}" \
            --timeout_ms="${TIMEOUT_MS}" >"${log}" 2>&1 ; then
        echo "FAILED: ${game} (${label}): the engine exited non-zero" >&2
        rc=1
    else
        for marker in "${markers[@]}" ; do
            grep -q "${marker}" "${log}" || missing="${missing} ${marker}"
        done
    fi
    if [ "${rc}" -eq 0 ] && [ -n "${missing}" ] ; then
        echo "FAILED: ${game} (${label}): missing${missing}" >&2
        rc=1
    elif [ "${rc}" -eq 0 ] && grep -q 'script host failed' "${log}" ; then
        echo "FAILED: ${game} (${label}): the game's own scripts stopped" >&2
        grep 'script host failed' "${log}" >&2
        rc=1
    elif [ "${rc}" -eq 0 ] && [ "${scenes}" -gt 0 ] &&
             [ "$(grep -c '\[RPGXP-HOST-SCENE\]' "${log}")" -lt "${scenes}" ] ; then
        # One scene means the game drew its title and stayed there: the keypress
        # never reached its own engine, or its first screen could not act on it.
        echo "FAILED: ${game} (${label}): the game never left its first scene" \
             "(wanted ${scenes} scenes)" >&2
        grep '\[RPGXP-HOST-SCENE\]' "${log}" >&2
        rc=1
    elif [ "${rc}" -eq 0 ] ; then
        for marker in "${markers[@]}" ; do
            grep "${marker}" "${log}"
        done
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

    # The editor test bed opens on a plain walkable map with the stock scripts,
    # so its walk and its menu are both assertions; a released game opens on a
    # cutscene, where a walk that does not happen and a menu that does not open
    # say nothing about the engine. Both log everything either way. Only the
    # editor bed gets a battle and a save pass -- see those cases below.
    case "${game}" in
        *Testbed*) markers=('\[RPGXP-HOST-MOVE\] .*moved=true'
                            '\[RPGXP-HOST-MENU\] .*opened=true')
                   is_testbed=1 ;;
        *)         markers=('\[RPGXP-HOST-SCENE\]')
                   is_testbed=0 ;;
    esac

    passes=()
    want_pass script_host && passes+=(script_host)
    if [ "${is_testbed}" -eq 1 ] ; then
        want_pass battle && passes+=(battle)
        want_pass save && passes+=(save)
    fi
    if [ "${#passes[@]}" -eq 0 ] ; then
        if [ -n "${RPGXP_BOOT_PASS}" ] ; then
            echo "skip ${game}: no '${RPGXP_BOOT_PASS}' pass for this game"
        fi
        continue
    fi

    checked=$((checked + 1))
    echo "== ${game}"

    for pass in "${passes[@]}" ; do
        case "${pass}" in
            script_host)
                run_boot "${game}" "${num}" "script host" \
                    "--rgss_host_move_test --rgss_host_menu_test" 2 \
                    "${markers[@]}" ||
                    failed=$((failed + 1))
                ;;

            # Battle needs its own pass: it has to be called from the game's
            # own map, and the script_host pass above deliberately leaves the
            # game inside its menu. Only the editor bed, whose stock database
            # ships 32 troops -- a released game's opening is an event
            # sequence that a battle call would land in the middle of, which
            # says nothing about the engine.
            battle)
                run_boot "${game}" "${num}" "script host: battle" \
                    "--rgss_host_battle_test" 2 \
                    '\[RPGXP-HOST-BATTLE\] .*reached=true' ||
                    failed=$((failed + 1))
                ;;

            # And the save screen, its own pass for the same reason. This is
            # the only place a game reads a file's timestamp back, and the
            # only one that writes a file of its own -- which the script_host
            # and battle passes above cannot share the bed's directory with:
            # a title screen offers Continue when it finds a save, changing
            # what their confirm taps pick, and when RPGXP_BOOT_PASS splits
            # these into concurrent CI steps a save written mid-run is exactly
            # the kind of state a concurrent pass's own pre-run sweep (in
            # run_boot, below) would delete out from under this one. Run it
            # against a private copy of the bed instead, so its write can
            # never race a sibling pass reading or cleaning the shared one.
            save)
                save_dir="${game}-save-copy"
                rm -rf "${save_dir}"
                cp -a "${game}" "${save_dir}"
                if run_boot "${save_dir}" "${num}" "script host: save" \
                        "--rgss_host_save_test" 2 \
                        '\[RPGXP-HOST-SAVE\] .*reached=true' ; then
                    # ...and it has to land in the *game's* directory. The
                    # stock Scene_Save writes a bare "Save1.rxdata", so where
                    # that file ends up is the whole of what the engine's
                    # run-from-the-game's-directory behaviour is worth: before
                    # it, the file landed wherever the engine was launched
                    # from and the next game found it (Pray for You offered
                    # Continue on the strength of the editor bed's save and
                    # died reading it as its own). The private copy is still
                    # the game's own directory as far as the engine is
                    # concerned (it is exactly what --game_dir points at), so
                    # the proof holds without touching the shared original.
                    if [ ! -f "${save_dir}/Save1.rxdata" ] ; then
                        echo "FAILED: ${game} (script host: save): the" \
                             "game's own save did not land in its own" \
                             "directory" >&2
                        ls -1 "${save_dir}"/Save[0-9]*.rxdata 2>/dev/null >&2 ||
                            true
                        failed=$((failed + 1))
                    fi
                else
                    failed=$((failed + 1))
                fi
                rm -rf "${save_dir}"
                ;;
        esac
        num=$((num + 1))
    done
done

# The save pass leaves a real save file in the bed it ran on; take it back out
# so a local run does not dirty the tree.
for game in "${GAMES[@]}" ; do
    rm -f "${game}"/Save[0-9]*.rxdata
done
rm -f Save[0-9]*.rxdata

if [ "${checked}" -eq 0 ] ; then
    echo "FAILED: none of the requested game directories is present, so nothing" \
         "was checked: ${GAMES[*]}" >&2
    exit 1
fi

if [ "${failed}" -ne 0 ] ; then
    echo "rpgxp boot check: ${failed} of ${checked} run(s) FAILED" >&2
    exit 1
fi

echo "rpgxp boot check: ${checked} game(s) ran their own scripts, off their own" \
     "title screens and onto their own maps (random seed ${RANDOM_SEED})"
