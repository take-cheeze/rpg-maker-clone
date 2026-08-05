#!/usr/bin/env bash

# Boot the built engine on the RPG Maker MZ test-bed (data/mz-sample) and confirm
# it gets past the old WebGL wall — Graphics creates the PIXI v5 renderer on the
# native surfaceless-EGL GLES2 backend and SceneManager.run(Scene_Boot) renders.
#
# The engine is fetched by scripts/download-mz-corescript.bash; the authored
# database (data/mz-sample/data) is committed. MZ#start (mruby-mvjs/mrblib/mz.rb)
# drives the boot on launch and prints "[MZ-BOOT] booted to <scene>" on success
# or "[MZ] boot stopped at: <error>" otherwise — this asserts on the former.
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
TIMEOUT_MS="${MZ_TIMEOUT_MS:-30000}"

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
        timeout 180 "${ENGINE}" \
        --game_dir "${GAME}" --timeout_ms="${TIMEOUT_MS}" >"${log}" 2>&1 ; then
    echo "FAILED: ${GAME}: the engine exited non-zero" >&2
    grep -v 'ALSA lib\|snd_\|Unknown PCM' "${log}" | tail -60 || true
    rm -f "${log}"
    exit 1
fi

if grep -q '\[MZ-BOOT\] booted to' "${log}" ; then
    grep '\[MZ-BOOT\]' "${log}"
    # ALSA has no device under CI and floods stderr; keep the rest for context.
    grep -v 'ALSA lib\|snd_\|Unknown PCM' "${log}" | tail -20 || true
    rm -f "${log}"
    echo "mz boot check: OK"
    exit 0
fi

echo "FAILED: ${GAME}: never booted through the renderer ([MZ-BOOT] missing)" >&2
grep -iE '\[MZ|error|exception|webgl|indexeddb' "${log}" | tail -40 || true
grep -v 'ALSA lib\|snd_\|Unknown PCM' "${log}" | tail -40 || true
rm -f "${log}"
exit 1
