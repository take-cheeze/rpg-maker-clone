#!/usr/bin/env bash

# Boot the built engine on the RPG Maker MZ test-bed (data/mz-sample) and drive
# it into actual play: the rmmz corescript on PIXI v5 renders through the native
# surfaceless-EGL GLES2 backend, `Scene_Boot` finishes loading and hands over to
# `Scene_Title`, `--mz_new_game` picks New Game, and the requested probe then
# exercises one in-game path and reports what happened.
#
# The engine is fetched by scripts/download-mz-corescript.bash; the authored
# database and art (data/mz-sample/data, data/mz-sample/img — see
# scripts/gen-mz-sample.py) are committed. MZ#start (mruby-mvjs/mrblib/mz.rb)
# drives all of this on launch and prints:
#
#   [MZ-BOOT] booted to <scene> through the WebGL renderer
#   [MZ-SCENE] <scene>            (once per scene change)
#   [MZ-MAP]   reached the map at <x,y>
#   [MZ-MOVE]  start <x,y> / end <x,y> moved=<bool>
#   [MZ-AUDIO] op=<se_play> asset=<audio/se/Beep>
#   [MZ-MSG]   busy=<bool> window_open=<bool>
#   [MZ-MENU]  reached_menu=<bool>
#   [MZ-ANIM]  data=<bool> mv=<bool> sprites=<n> cells=<n> played=<bool>
#   [MZ-SAVE]  saved=<bool> exists=<bool> loaded=<bool>
#   [MZ-BTL]   reached_battle=<bool>
#
# or "[MZ] boot stopped at: <error>" when it stops short. Every mode asserts the
# boot marker and that the boot got past the loading scene; each then asserts
# its own probe's success line, since a probe that merely *ran* proves nothing.
#
# The mode is picked with MZ_MODE (default `play`):
#
#   play      New Game -> map, hold a direction, play an SE  (the default smoke)
#   message   New Game -> map, show a message
#   menu      New Game -> map, open the party menu
#   animation New Game -> map, play an animation on the player
#   save      New Game -> map, save + load round-trip
#   battle    New Game -> map, start a battle against MZ_TROOP (default 1)
#
# The MZ engine mirror is a CI-only fixture (© Gotcha Gotcha Games / KADOKAWA);
# if it has not been fetched the check skips with a message rather than failing,
# the same way the RPG2k/XP boot checks skip an absent downloaded game.
#
# Usage: MZ_MODE=<mode> ./scripts/mz_boot_check.bash [server_num] [game_dir]

set -eu -o pipefail

cd "$(dirname "$0")/.."

SERVER_NUM="${1:-111}"
GAME="${2:-data/mz-sample}"
ENGINE="${ENGINE:-./build/rpg_maker_clone}"
MODE="${MZ_MODE:-play}"
TROOP="${MZ_TROOP:-1}"
# The run has to reach the title, start a New Game, load the map and then play
# out its probe, all on software GL — so it is given far more in-game time than
# the MV smokes, which only need to boot.
TIMEOUT_MS="${MZ_TIMEOUT_MS:-60000}"

case "${MODE}" in
    play)
        FLAGS=(--mz_new_game --mz_move_test --mz_audio_test)
        DEFAULT_SHOT="ss/mz_play.png" ;;
    message)
        FLAGS=(--mz_message_test)
        DEFAULT_SHOT="ss/mz_message.png" ;;
    menu)
        FLAGS=(--mz_menu_test)
        DEFAULT_SHOT="ss/mz_menu.png" ;;
    animation)
        FLAGS=(--mz_animation_test)
        DEFAULT_SHOT="ss/mz_animation.png" ;;
    save)
        # Non-visual, but a frame is still captured: a save that leaves the
        # scene broken shows up in the picture.
        FLAGS=(--mz_save_test)
        DEFAULT_SHOT="ss/mz_save.png" ;;
    battle)
        FLAGS=("--mz_battle_test=${TROOP}")
        DEFAULT_SHOT="ss/mz_battle.png" ;;
    *)
        echo "error: unknown MZ_MODE '${MODE}'" \
             "(play|message|menu|animation|save|battle)" >&2
        exit 1 ;;
esac
SHOT="${MZ_SCREENSHOT:-${DEFAULT_SHOT}}"

if [ ! -x "${ENGINE}" ] ; then
    echo "error: ${ENGINE} not built; run cmake --build build first" >&2
    exit 1
fi

if [ ! -f "${GAME}/js/rmmz_core.js" ] ; then
    echo "skip ${GAME}: no js/rmmz_core.js (run scripts/download-mz-corescript.bash first)"
    exit 0
fi
if [ ! -f "${GAME}/data/System.json" ] ; then
    echo "FAILED: ${GAME}: no data/System.json (the committed database is missing)" >&2
    exit 1
fi

mkdir -p "$(dirname "${SHOT}")"

log="$(mktemp)"
echo "== ${GAME} (mode ${MODE})"
# Run with NO X server reachable: SDL's headless "dummy" video driver instead of
# Xvfb, and DISPLAY/XAUTHORITY scrubbed. MZ's renderer is off-screen (surfaceless
# EGL + an FBO), but whenever an X server is present Mesa dispatches even a
# surfaceless eglMakeCurrent through GLX to it and is denied (X BadAccess on
# X_GLXMakeCurrent) — which is why booting under Xvfb failed while the headless
# gl_test (no X) binds cleanly. With no X, Mesa uses the pure-software surfaceless
# path and MZ boots. The SERVER_NUM arg is kept for compatibility but unused.
# (LVGL v9.5 requires a window; the dummy driver provides one without a display.)
if ! env -u DISPLAY -u XAUTHORITY SDL_VIDEODRIVER=dummy \
        timeout 300 "${ENGINE}" \
        --game_dir "${GAME}" --timeout_ms="${TIMEOUT_MS}" \
        "${FLAGS[@]}" \
        --mz_screenshot="${SHOT}" \
        >"${log}" 2>&1 ; then
    echo "FAILED: ${GAME}: the engine exited non-zero" >&2
    grep -v 'ALSA lib\|snd_\|Unknown PCM' "${log}" | tail -60 || true
    rm -f "${log}"
    exit 1
fi

fail() {
    echo "FAILED: ${GAME} (mode ${MODE}): $1" >&2
    grep -iE '\[MZ|error|exception|webgl|indexeddb' "${log}" | tail -40 || true
    grep -v 'ALSA lib\|snd_\|Unknown PCM' "${log}" | tail -40 || true
    rm -f "${log}"
    exit 1
}

grep -q '\[MZ-BOOT\] booted to' "${log}" ||
    fail "never booted through the renderer ([MZ-BOOT] missing)"

# Scene_Boot is MZ's *loading* scene, so stopping there means the boot never
# finished its database/image/font/storage loads — the boot marker alone would
# happily report it.
if grep -q '\[MZ-BOOT\] booted to Scene_Boot' "${log}" ; then
    fail "the boot stopped on the loading scene (Scene_Boot)"
fi

# Every probe runs from the map, so New Game reaching it is common ground. Only
# the play mode logs [MZ-MAP] (the movement probe prints it); the others prove
# they got there by reaching Scene_Map.
grep -q '\[MZ-SCENE\] Scene_Map' "${log}" ||
    fail "New Game never reached the map (no [MZ-SCENE] Scene_Map)"

case "${MODE}" in
    play)
        grep -q '\[MZ-MAP\] reached the map' "${log}" ||
            fail "New Game never reached the map ([MZ-MAP] missing)"
        grep -q '\[MZ-MOVE\].*moved=true' "${log}" ||
            fail "input never moved the player ([MZ-MOVE] moved=true missing)"
        # The audio bridge: rmmz's AudioManager -> the op queue -> RGSS::Audio.
        # Without it MZ's sound goes to the silent Web Audio stub and nothing
        # reaches the mixer.
        grep -q '\[MZ-AUDIO\]' "${log}" ||
            fail "no audio op reached RGSS::Audio ([MZ-AUDIO] missing)"
        ;;
    message)
        # Both halves matter: the text is still queued *and* Window_Message has
        # actually opened over the map.
        grep -q '\[MZ-MSG\] busy=true window_open=true' "${log}" ||
            fail "the message window never opened ([MZ-MSG] busy/window_open)"
        ;;
    menu)
        grep -q '\[MZ-MENU\] reached_menu=true' "${log}" ||
            fail "the party menu never opened ([MZ-MENU] reached_menu=true)"
        ;;
    animation)
        # Three separate claims, and the last is the one that matters. `mv=true`
        # says the data picked the sprite-sheet animation system rather than
        # Effekseer (whose WASM runtime this host does not start, so an
        # Effekseer animation would silently play no visuals); `cells=` counts
        # cell sprites visible with a bitmap, so `played=true` means the burst
        # actually reached the screen rather than merely existing in the scene
        # graph.
        grep -q '\[MZ-ANIM\].*mv=true' "${log}" ||
            fail "animation 1 is not an MV-format animation ([MZ-ANIM] mv=true)"
        grep -q '\[MZ-ANIM\].*played=true' "${log}" ||
            fail "the animation never drew a cell ([MZ-ANIM] played=true)"
        ;;
    save)
        grep -q '\[MZ-SAVE\] saved=true exists=true loaded=true' "${log}" ||
            fail "the save/load round-trip failed ([MZ-SAVE] line)"
        ;;
    battle)
        grep -q '\[MZ-BTL\] reached_battle=true' "${log}" ||
            fail "the battle never started ([MZ-BTL] reached_battle=true)"
        ;;
esac

grep -E '\[MZ-BOOT\]|\[MZ-SCENE\]|\[MZ-MAP\]|\[MZ-MOVE\]|\[MZ-AUDIO\]|\[MZ-MSG\]|\[MZ-MENU\]|\[MZ-ANIM\]|\[MZ-SAVE\]|\[MZ-BTL\]|\[MZ\] screenshot' "${log}"
# ALSA has no device under CI and floods stderr; keep the rest for context.
grep -v 'ALSA lib\|snd_\|Unknown PCM' "${log}" | tail -20 || true
rm -f "${log}"

# Everything above read the *log*. The captured frame is the other half of the
# claim, and the two can disagree: with the M6.3e fix reverted every assertion
# above still passes while the map is missing from the picture. Check what this
# run actually drew; the cross-mode comparisons (a message window that changed
# the frame, a menu that replaced it) need more than one mode's frame and run
# from scripts/mz_frame_check.rb once they have all been captured.
if command -v ruby >/dev/null 2>&1 ; then
    ruby "$(dirname "$0")/mz_frame_check.rb" --frame "${SHOT}" ||
        { echo "FAILED: ${GAME} (mode ${MODE}): the captured frame does not" \
               "show what the log claims" >&2 ; exit 1 ; }
else
    echo "note: no ruby, so ${SHOT} was not checked"
fi

echo "mz boot check (${MODE}): OK"
exit 0
