#!/usr/bin/env bash

# Side-by-side graphic comparison between the *genuine* RPG Maker XP runtime
# (the project's Game.exe driving Enterbrain's RGSS104E.dll, run under wine) and
# this project's engine, both playing the same XP project -- by default the
# OpenGame.exe "Testbed/XP" project this repo already downloads, which ships a
# real Game.exe + RGSS104E.dll beside its Data/*.rxdata.
#
# This is the RPG Maker XP counterpart of scripts/compare-nepheshel-wine.bash,
# and exists for the same reason: the XP renderer is a re-implementation of an
# engine whose behaviour is only documented by its output. The unit checks and
# scripts/rpgxp_testbed_check.rb pin the *data* we decode, but they cannot tell
# us that the title's command window sits in the wrong place or that a map layer
# is drawn in the wrong order. Booting both runtimes on the same project and
# diffing the frames can.
#
# Both runtimes are driven headlessly, each on its own Xvfb display at XP's
# native 640x480, fed the same key script, and captured with xwd. For every step
# the script writes
#   <out>/rpgxp-ref-<step>.png    the genuine RGSS frame
#   <out>/rpgxp-ours-<step>.png   our engine's frame
#   <out>/rpgxp-diff-<step>.png   their (amplified) difference
#   <out>/rpgxp-cmp-<step>.png    all three side by side
# and prints the fraction of differing pixels so a regression is visible in a
# log without opening the images.
#
# Requires: wine (with 32-bit support -- Game.exe and RGSS104E.dll are both
#           PE32), Xvfb, x11-apps (xwd), xdotool, ImageMagick, a window manager
#           (matchbox), and a built ./build/rpg_maker_clone. On Debian/Ubuntu:
#     dpkg --add-architecture i386 && apt-get update
#     apt-get install --no-install-recommends wine wine32:i386 wine64 xvfb \
#         x11-apps xdotool imagemagick unar matchbox-window-manager \
#         libgl1:i386 libgl1-mesa-dri:i386
#
# NOTES on running the genuine RGSS runtime headlessly (each one cost a
# debugging round; do not drop them):
#   * The RTP. An editor-made project stores only its database: its graphics and
#     audio ("001-Title01", "001-Grassland01", ...) live in the RPG Maker XP RTP.
#     Install it into this same wine prefix with scripts/rtp_xp_install.bash --
#     that registers Software\Enterbrain\RGSS\RTP\Standard in the prefix, which
#     is exactly where *our* engine looks it up too (see xp_rtp_path() in
#     src/main.cxx), so one install feeds both runtimes. Without it the genuine
#     runtime pops a "file not found" message box and the comparison is against
#     an error dialog.
#   * RGSS draws through DirectDraw/Direct3D, which wine implements over
#     wined3d -> OpenGL. Under Xvfb there is no GPU, so Mesa's software
#     rasteriser has to serve (LIBGL_ALWAYS_SOFTWARE=1) and the 32-bit libGL
#     must be installed, or every frame stays black.
#   * Audio must initialise, even though nobody is listening. RGSS opens
#     DirectSound at boot and, when that fails, stops on a modal "Failed to
#     initialize DirectX Audio." message box -- which is all the reference draws,
#     forever. A container with no sound card needs ALSA pointed at a null
#     device, e.g.
#         printf 'pcm.!default { type null }\nctl.!default { type null }\n' \
#             > /etc/asound.conf
#     (the MIDI warning wine then logs is harmless).
#   * A window manager must be running or wine never focuses the window and all
#     synthesised keys are dropped.
#   * Keys must be *held* (keydown, pause, keyup): a tap is often missed between
#     two of the runtime's polls.
#
# Usage: ./scripts/compare-rpgxp-wine.bash [game_dir] [out_dir]

set -eu -o pipefail

cd "$(dirname "$0")/.."

GAME_DIR="${1:-data/OpenGame.exe/Testbed/XP}"
OUT_DIR="${2:-ss}"
ENGINE="${ENGINE:-./build/rpg_maker_clone}"

REF_DISPLAY="${REF_DISPLAY:-:1092}"
OUR_DISPLAY="${OUR_DISPLAY:-:1093}"

# Fetch the test bed if it is not present yet.
if [ ! -f "${GAME_DIR}/Game.ini" ] ; then
    ./scripts/download-opengame-xp.bash
fi

if [ ! -x "${ENGINE}" ] ; then
    echo "error: ${ENGINE} not built; run cmake --build build first" >&2
    exit 1
fi

if [ ! -f "${GAME_DIR}/Game.exe" ] ; then
    echo "error: ${GAME_DIR} has no Game.exe to compare against" >&2
    exit 1
fi

mkdir -p "${OUT_DIR}"

# 32-bit prefix: both Game.exe and RGSS104E.dll are PE32. Keep it separate from
# the RPG2000 prefixes so the XP RTP registration cannot be confused with the
# RPG2000 one.
export WINEARCH="${WINEARCH:-win32}"
export WINEPREFIX="${WINEPREFIX:-$HOME/.wine-rpgxp}"
export WINEDLLOVERRIDES="mscoree,mshtml="
export WINEDEBUG="${WINEDEBUG:-err+all}"
# No GPU under Xvfb: wined3d needs a working GL, so use Mesa's rasteriser.
export LIBGL_ALWAYS_SOFTWARE=1

if [ ! -d "${WINEPREFIX}" ] ; then
    echo "== bootstrapping ${WINEPREFIX}"
    wineboot --init >/tmp/rpgxp-wineboot.log 2>&1 || true
fi

# Our engine resolves the RTP through the same prefix, so report the state once
# rather than letting both runtimes quietly fall back to placeholders.
if grep -q 'Enterbrain\\\\RGSS\\\\RTP' "${WINEPREFIX}/system.reg" 2>/dev/null ; then
    echo "== RTP registered in ${WINEPREFIX}"
else
    echo "warning: no RPG Maker XP RTP registered in ${WINEPREFIX};" \
         "run WINEPREFIX=${WINEPREFIX} ./scripts/rtp_xp_install.bash first," \
         "or the genuine runtime will only show an error dialog" >&2
fi

PIDS=()
cleanup() {
    for p in "${PIDS[@]:-}" ; do
        [ -n "${p}" ] && kill "${p}" 2>/dev/null || true
    done
}
trap cleanup EXIT

# The steps to capture: <label> <keys to send before capturing>. Keys are
# xdotool key names, space separated; "<key>*<n>" repeats one; "-" means "send
# nothing, just wait". An editor-fresh XP project opens on its title screen with
# New Game selected, so one decision key reaches the start map and the rest is
# walking around on it.
STEPS=(
    "title -"
    "title-cursor Down"
    "newgame Up Return"
    "walk-down Down*3"
    "walk-right Right*3"
    "walk-up Up*3"
)

start_ref() {
    Xvfb "${REF_DISPLAY}" -screen 0 640x480x24 >/tmp/rpgxp-ref-xvfb.log 2>&1 &
    PIDS+=($!)
    sleep 2
    DISPLAY="${REF_DISPLAY}" matchbox-window-manager -use_titlebar no \
        >/tmp/rpgxp-ref-wm.log 2>&1 &
    PIDS+=($!)
    sleep 1
    ( cd "${GAME_DIR}" && DISPLAY="${REF_DISPLAY}" wine Game.exe ) \
        >/tmp/rpgxp-ref-player.log 2>&1 &
    PIDS+=($!)
    # wine's first run in a fresh prefix bootstraps the whole prefix, so give
    # the reference a generous head start before the first capture.
    sleep "${REF_BOOT_WAIT:-25}"
}

start_ours() {
    Xvfb "${OUR_DISPLAY}" -screen 0 640x480x24 >/tmp/rpgxp-our-xvfb.log 2>&1 &
    PIDS+=($!)
    sleep 2
    DISPLAY="${OUR_DISPLAY}" matchbox-window-manager -use_titlebar no \
        >/tmp/rpgxp-our-wm.log 2>&1 &
    PIDS+=($!)
    sleep 1
    DISPLAY="${OUR_DISPLAY}" "${ENGINE}" --game_dir "${GAME_DIR}" \
        --timeout_ms="${OUR_TIMEOUT_MS:-900000}" >/tmp/rpgxp-our-player.log 2>&1 &
    PIDS+=($!)
    sleep "${OUR_BOOT_WAIT:-8}"
}

# Point the display's input focus at the game, before every key. A window
# manager focuses a window when it maps, and both runtimes map one and then
# resize it to the game's resolution -- and when the resize wins that race the
# window ends up unfocused, every synthesised key goes to the root window, and
# the run looks like an engine that ignored New Game and sat on the title
# screen. Each display runs exactly one game, so its only visible window is the
# one that should have the keys.
focus_window() {
    local disp="$1" id
    id=$(DISPLAY="${disp}" xdotool search --onlyvisible --name . 2>/dev/null |
             tail -1)
    [ -n "${id}" ] || return 0
    DISPLAY="${disp}" xdotool windowactivate --sync "${id}" 2>/dev/null || true
}

# Hold each key for ~120ms: both runtimes poll the keyboard once a frame and
# drop a key that goes down and up between two polls.
send_keys() {
    local disp="$1" ; shift
    focus_window "${disp}"
    for spec in "$@" ; do
        [ "${spec}" = "-" ] && continue
        local k="${spec%%\**}" n=1
        [ "${spec}" != "${k}" ] && n="${spec##*\*}"
        for _ in $(seq 1 "${n}") ; do
            DISPLAY="${disp}" xdotool keydown "${k}"
            sleep 0.12
            DISPLAY="${disp}" xdotool keyup "${k}"
            sleep 0.4
        done
    done
}

capture() {
    local disp="$1" out="$2"
    DISPLAY="${disp}" xwd -root -silent | convert xwd:- png:"${out}"
}

start_ref
start_ours

for step in "${STEPS[@]}" ; do
    label="${step%% *}"
    keys="${step#* }"
    # shellcheck disable=SC2086
    send_keys "${REF_DISPLAY}" ${keys}
    # shellcheck disable=SC2086
    send_keys "${OUR_DISPLAY}" ${keys}
    sleep "${STEP_SETTLE:-2}"

    ref="${OUT_DIR}/rpgxp-ref-${label}.png"
    our="${OUT_DIR}/rpgxp-ours-${label}.png"
    capture "${REF_DISPLAY}" "${ref}"
    capture "${OUR_DISPLAY}" "${our}"

    # A difference image (amplified so a few-pixel offset is visible) beside the
    # two frames, and the fraction of pixels that differ at all.
    convert "${ref}" "${our}" -compose difference -composite -auto-level \
        "${OUT_DIR}/rpgxp-diff-${label}.png"
    convert "${ref}" "${our}" "${OUT_DIR}/rpgxp-diff-${label}.png" \
        +append "${OUT_DIR}/rpgxp-cmp-${label}.png"
    # A reference frame with almost no colours means the genuine runtime did not
    # render at all (no GL, a missing RTP asset behind an error dialog, a window
    # that never got focus). Say so, or the pixel counts below read as a huge
    # regression in *our* renderer.
    ref_colours=$(convert "${ref}" -format %k info:)
    if [ "${ref_colours}" -le 2 ] ; then
        echo "warning: the reference frame for '${label}' has ${ref_colours}" \
             "colour(s) -- the genuine runtime probably rendered nothing;" \
             "check /tmp/rpgxp-ref-player.log" >&2
    fi

    total=$(identify -format '%[fx:w*h]' "${ref}")
    differing=$(compare -metric AE -fuzz "${DIFF_FUZZ:-3%}" "${ref}" "${our}" \
        null: 2>&1 || true)
    printf '%-16s differing pixels: %s / %s\n' "${label}" "${differing}" "${total}"
done

echo "frames written to ${OUT_DIR}/rpgxp-{ref,ours,diff,cmp}-*.png"
