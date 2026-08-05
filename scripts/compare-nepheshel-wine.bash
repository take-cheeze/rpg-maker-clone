#!/usr/bin/env bash

# Side-by-side graphic comparison between the *genuine* RPG Maker 2000 runtime
# (RPG_RT.exe, run under wine) and this project's engine, both playing the same
# game -- by default "Nepheshel", the RPG2000 test-bed this repo tracks.
#
# Why this exists: the RPG2000 renderer is a re-implementation of an engine
# whose behaviour is only documented by its output. Unit checks
# (scripts/rpg2k_render_check.rb) pin the *geometry* we ported, but they cannot
# tell us that a window sits four pixels too low or that menu text is missing
# the windowskin's colour gradient. Booting both runtimes on the same data and
# diffing the frames can, and that is how the discrepancies fixed in
# docs/adr/0021-nepheshel-render-parity-under-wine.md were found.
#
# Both runtimes are driven headlessly, each on its own Xvfb display at the same
# 640x480 (RPG2000's 320x240 screen at 2x), fed the same key script, and
# captured with xwd. For every step the script writes
#   <out>/neph-ref-<step>.png    the genuine RPG_RT frame
#   <out>/neph-ours-<step>.png   our engine's frame
#   <out>/neph-cmp-<step>.png    the two side by side, plus their difference
# and prints the fraction of differing pixels so a regression is visible in a
# log without opening the images.
#
# Requires: wine (win32 + 32-bit libGL), Xvfb, x11-apps (xwd), xdotool,
#           ImageMagick, unar, a Japanese locale for the CP932 text, and a
#           built ./build/rpg_maker_clone. On Debian/Ubuntu:
#     dpkg --add-architecture i386 && apt-get update
#     apt-get install --no-install-recommends wine wine32:i386 wine64 xvfb \
#         x11-apps xdotool imagemagick unar fonts-ipafont locales \
#         libgl1:i386 libgl1-mesa-dri matchbox-window-manager
#     locale-gen ja_JP.UTF-8
#
# NOTES on running the genuine RPG_RT.exe headlessly (each one cost a debugging
# round; do not drop them):
#   * RPG_RT drives DirectDraw, which wine implements over wined3d -> OpenGL.
#     Without a 32-bit libGL wine logs "Failed to load libGL" and every frame
#     stays black. Mesa's software rasteriser is enough
#     (LIBGL_ALWAYS_SOFTWARE=1); no GPU is needed.
#   * RPG_RT asks for a 640x480 16-bit mode. Xvfb cannot switch modes, so the
#     screen must already *be* 640x480x16 or the mode change fails and the game
#     renders nothing.
#   * A window manager must be running or wine never focuses the window and all
#     synthesised keys are dropped.
#   * Keys must be *held* (keydown, pause, keyup): a tap is often missed
#     between two of RPG_RT's polls.
#
# Usage: ./scripts/compare-nepheshel-wine.bash [game_dir] [out_dir]

set -eu -o pipefail

cd "$(dirname "$0")/.."

GAME_DIR="${1:-data/Nepheshel206beta/Nepheshel206Rbeta}"
OUT_DIR="${2:-ss}"
ENGINE="${ENGINE:-./build/rpg_maker_clone}"

REF_DISPLAY="${REF_DISPLAY:-:1090}"
OUR_DISPLAY="${OUR_DISPLAY:-:1091}"

# Fetch the game if it is not present yet.
if [ ! -e "${GAME_DIR}/RPG_RT.ldb" ] ; then
    ./scripts/download-nepheshel.bash
fi

if [ ! -x "${ENGINE}" ] ; then
    echo "error: ${ENGINE} not built; run cmake --build build first" >&2
    exit 1
fi

if [ ! -f "${GAME_DIR}/RPG_RT.exe" ] ; then
    echo "error: ${GAME_DIR} has no RPG_RT.exe to compare against" >&2
    exit 1
fi

mkdir -p "${OUT_DIR}"

export WINEARCH=win32
export WINEPREFIX="${WINEPREFIX:-$HOME/.wine-nepheshel32}"
export WINEDLLOVERRIDES="mscoree,mshtml="
export WINEDEBUG="${WINEDEBUG:-err+all}"
# Japanese locale so RPG_RT's ANSI code page is 932 and its CP932 text decodes.
export LANG=ja_JP.UTF-8
export LC_ALL=ja_JP.UTF-8
# No GPU under Xvfb: wined3d needs a working GL, so use Mesa's rasteriser.
export LIBGL_ALWAYS_SOFTWARE=1

PIDS=()
cleanup() {
    for p in "${PIDS[@]:-}" ; do
        [ -n "${p}" ] && kill "${p}" 2>/dev/null || true
    done
}
trap cleanup EXIT

# The steps to capture: <label> <keys to send before capturing>. Keys are
# xdotool key names, space separated; "<key>*<n>" repeats one; "-" means "send
# nothing, just wait". Nepheshel opens on its title screen, and New Game runs a
# long narrated opening (pictures, panning maps and messages), so the walkable
# town map only appears after roughly fifty confirmations -- hence the bulk
# Return steps below rather than a handful.
STEPS=(
    "title -"
    "title-cursor Down"
    "newgame Up Return"
    "intro-1 Return*30"
    "intro-2 Return*30"
    "intro-3 Return*30"
    "intro-4 Return*30"
    "map Return*10"
    "walk-down Down*3"
    "walk-left Left*3"
)

start_ref() {
    Xvfb "${REF_DISPLAY}" -screen 0 640x480x16 >/tmp/neph-ref-xvfb.log 2>&1 &
    PIDS+=($!)
    sleep 2
    DISPLAY="${REF_DISPLAY}" matchbox-window-manager -use_titlebar no \
        >/tmp/neph-ref-wm.log 2>&1 &
    PIDS+=($!)
    sleep 1
    ( cd "${GAME_DIR}" && DISPLAY="${REF_DISPLAY}" wine RPG_RT.exe ) \
        >/tmp/neph-ref-player.log 2>&1 &
    PIDS+=($!)
    # wine's first run in a fresh prefix bootstraps the whole prefix, so give
    # the reference a generous head start before the first capture.
    sleep "${REF_BOOT_WAIT:-25}"
}

start_ours() {
    Xvfb "${OUR_DISPLAY}" -screen 0 640x480x24 >/tmp/neph-our-xvfb.log 2>&1 &
    PIDS+=($!)
    sleep 2
    DISPLAY="${OUR_DISPLAY}" matchbox-window-manager -use_titlebar no \
        >/tmp/neph-our-wm.log 2>&1 &
    PIDS+=($!)
    sleep 1
    DISPLAY="${OUR_DISPLAY}" "${ENGINE}" --game_dir "${GAME_DIR}" \
        --timeout_ms="${OUR_TIMEOUT_MS:-900000}" >/tmp/neph-our-player.log 2>&1 &
    PIDS+=($!)
    sleep "${OUR_BOOT_WAIT:-8}"
}

# Hold each key for ~120ms: RPG_RT polls the keyboard once a frame and drops a
# key that goes down and up between two polls.
# Point the display's input focus at the game, before every key. A window
# manager focuses a window when it maps, and both runtimes map one and then
# resize it to the game's resolution -- and when the resize wins that race the
# window ends up unfocused and every synthesised key goes to the root window
# instead, which reads as a runtime that ignored half the script. Each display
# runs exactly one game, so its only visible window is the one that should have
# the keys.
focus_window() {
    local disp="$1" id
    id=$(DISPLAY="${disp}" xdotool search --onlyvisible --name . 2>/dev/null |
             tail -1)
    [ -n "${id}" ] || return 0
    DISPLAY="${disp}" xdotool windowactivate --sync "${id}" 2>/dev/null || true
}

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

status=0
for step in "${STEPS[@]}" ; do
    label="${step%% *}"
    keys="${step#* }"
    # shellcheck disable=SC2086
    send_keys "${REF_DISPLAY}" ${keys}
    # shellcheck disable=SC2086
    send_keys "${OUR_DISPLAY}" ${keys}
    sleep "${STEP_SETTLE:-2}"

    ref="${OUT_DIR}/neph-ref-${label}.png"
    our="${OUT_DIR}/neph-ours-${label}.png"
    cmp_out="${OUT_DIR}/neph-cmp-${label}.png"
    capture "${REF_DISPLAY}" "${ref}"
    capture "${OUR_DISPLAY}" "${our}"

    # A difference image (amplified so a few-pixel offset is visible) beside the
    # two frames, and the fraction of pixels that differ at all.
    convert "${ref}" "${our}" -compose difference -composite -auto-level \
        "${OUT_DIR}/neph-diff-${label}.png"
    convert "${ref}" "${our}" "${OUT_DIR}/neph-diff-${label}.png" \
        +append "${cmp_out}"
    # The reference runs in a 16-bit X visual (RPG_RT asks for a 640x480x16
    # mode), so nearly every pixel differs from ours by +-1 per channel purely
    # from RGB565 quantisation. Count only differences beyond that with -fuzz,
    # or the metric drowns in noise and reports "everything differs".
    total=$(identify -format '%[fx:w*h]' "${ref}")
    differing=$(compare -metric AE -fuzz "${DIFF_FUZZ:-3%}" "${ref}" "${our}" \
        null: 2>&1 || true)
    printf '%-16s differing pixels: %s / %s\n' "${label}" "${differing}" "${total}"
done

echo "frames written to ${OUT_DIR}/neph-{ref,ours,diff,cmp}-*.png"
exit "${status}"
