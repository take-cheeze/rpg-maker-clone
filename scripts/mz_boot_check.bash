#!/usr/bin/env bash

# Boot the built engine on the RPG Maker MZ test-bed (data/mz-sample) and drive
# it into actual play: the rmmz corescript on PIXI v5 renders through the native
# surfaceless-EGL GLES2 backend, `Scene_Boot` finishes loading and hands over to
# `Scene_Title`, `--mz_new_game` picks New Game, and `--mz_move_test` then holds
# a direction on the start map and reports whether the player actually walked.
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
#
# or "[MZ] boot stopped at: <error>" when it stops short. This asserts the boot
# marker, that the boot got past the loading scene, and — since the whole point
# is proving input moves the player — that the move probe reports moved=true.
#
# The MZ engine mirror is a CI-only fixture (© Gotcha Gotcha Games / KADOKAWA);
# if it has not been fetched the check skips with a message rather than failing,
# the same way the RPG2k/XP boot checks skip an absent downloaded game.
#
# Usage: ./scripts/mz_boot_check.bash [server_num] [game_dir]

set -eu -o pipefail

cd "$(dirname "$0")/.."

SERVER_NUM="${1:-111}"
GAME="${2:-data/mz-sample}"
ENGINE="${ENGINE:-./build/rpg_maker_clone}"
# The run has to reach the title, start a New Game, load the map and then hold a
# direction for the 80-frame probe, all on software GL — so it is given far more
# in-game time than the MV smokes, which only need to boot.
TIMEOUT_MS="${MZ_TIMEOUT_MS:-60000}"
SHOT="${MZ_SCREENSHOT:-ss/mz_play.png}"

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
echo "== ${GAME}"
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
        --mz_new_game --mz_move_test --mz_screenshot="${SHOT}" \
        >"${log}" 2>&1 ; then
    echo "FAILED: ${GAME}: the engine exited non-zero" >&2
    grep -v 'ALSA lib\|snd_\|Unknown PCM' "${log}" | tail -60 || true
    rm -f "${log}"
    exit 1
fi

fail() {
    echo "FAILED: ${GAME}: $1" >&2
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

grep -q '\[MZ-MAP\] reached the map' "${log}" ||
    fail "New Game never reached the map ([MZ-MAP] missing)"

grep -q '\[MZ-MOVE\].*moved=true' "${log}" ||
    fail "input never moved the player ([MZ-MOVE] moved=true missing)"

grep -E '\[MZ-BOOT\]|\[MZ-SCENE\]|\[MZ-MAP\]|\[MZ-MOVE\]|\[MZ\] screenshot' "${log}"
# ALSA has no device under CI and floods stderr; keep the rest for context.
grep -v 'ALSA lib\|snd_\|Unknown PCM' "${log}" | tail -20 || true
rm -f "${log}"
echo "mz boot check: OK"
exit 0
