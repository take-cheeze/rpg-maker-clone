#!/usr/bin/env bash

# Pixel-compare our RPG2000 renderer against the genuine RPG_RT.exe on an actual
# game *map*, by resuming both runtimes from the same Save<N>.lsd.
#
# scripts/compare-nepheshel-wine.bash drives both runtimes from the title screen
# by sending the same key script to each. That works for the title, but the two
# desynchronise through Nepheshel's long *timed* opening -- pictures, panning
# maps and waits -- so by the time the key script reaches the town map the two
# are on different frames and the diff is meaningless. ADR 0021 recorded the fix:
# get both to the same place by *loading a save* instead of by counting key
# presses. Loading is not timed, so it cannot drift.
#
# The save comes from scripts/gen-lcf-save-wine.bash, which drives EasyRPG
# Player's F9 debug menu under wine to write a genuine one without a
# playthrough; scripts/gen-rpg2k-save.rb then moves the party in it to whichever
# map this comparison wants.
#
# It has to be a *genuine* save. Game::State#to_lsd can emit one from nothing,
# and RPG_RT does load those now, but such a save holds only the five chunks
# that model our runtime state -- no pictures, no map events, no vehicles -- so
# it resumes into a valid but bare scene, which cannot be compared against the
# real thing. See gen-rpg2k-save.rb and ADR 0021.
#
# Each runtime is then brought to the map without input:
#   * ours with --rpg2k_continue (auto-selects Continue on the title screen);
#   * RPG_RT with a *fixed, three-key* sequence -- Down to move the title cursor
#     to Continue, Return to open the file screen, Return to load file 1. Short
#     and untimed, unlike the ~130 confirmations the opening needs.
# Both then sit on the map, and the frames are captured and diffed.
#
# Our engine's Continue prefers its own Marshal save (save<N>.mrb) over the
# .lsd, so this refuses to run when one is present: it would silently compare
# two different game states.
#
# Requires everything compare-nepheshel-wine.bash needs (see its header for the
# wine/Xvfb/32-bit libGL notes, which apply here unchanged) plus a built
# ./build/rpg_maker_clone and a CRuby for the save generator.
#
# Usage: ./scripts/compare-nepheshel-save-wine.bash [game_dir] [out_dir]
#   MAP=<id>       map to compare on (default: the game's start map)
#   AT=<x,y>       tile to stand on (default: the map's start/centre tile)
#   An existing Save01.lsd is reused; MAP/AT reposition it in place.

set -eu -o pipefail

cd "$(dirname "$0")/.."

GAME_DIR="${1:-data/Nepheshel206beta/Nepheshel206Rbeta}"
OUT_DIR="${2:-ss}"
ENGINE="${ENGINE:-./build/rpg_maker_clone}"
RUBY="${RUBY:-ruby}"

REF_DISPLAY="${REF_DISPLAY:-:1094}"
OUR_DISPLAY="${OUR_DISPLAY:-:1095}"

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

# Our Continue prefers a Marshal save over the .lsd, which would put the two
# runtimes in different states without saying so.
if ls "${GAME_DIR}"/save*.mrb >/dev/null 2>&1 ; then
    echo "error: ${GAME_DIR} holds a Marshal save (save*.mrb); our Continue" \
         "would load that instead of the .lsd both runtimes must share." \
         "Move it aside first." >&2
    exit 1
fi

mkdir -p "${OUT_DIR}"

# --- the shared save -------------------------------------------------------
# Making one takes a wine-driven EasyRPG run, so an existing save is reused
# unless the caller asks for a different spot.
if [ ! -f "${GAME_DIR}/Save01.lsd" ] ; then
    echo "no Save01.lsd yet; generating one with EasyRPG under wine"
    ./scripts/gen-lcf-save-wine.bash "${GAME_DIR}" 1
fi

if [ -n "${MAP:-}" ] || [ -n "${AT:-}" ] ; then
    gen_args=("${GAME_DIR}")
    [ -n "${MAP:-}" ] && gen_args+=(--map "${MAP}")
    [ -n "${AT:-}" ] && gen_args+=(--at "${AT}")
    "${RUBY}" scripts/gen-rpg2k-save.rb "${gen_args[@]}"
fi
"${RUBY}" scripts/lcf_save_check.rb "${GAME_DIR}/Save01.lsd" | grep -E '^  hero:'

export WINEARCH=win32
export WINEPREFIX="${WINEPREFIX:-$HOME/.wine-nepheshel32}"
export WINEDLLOVERRIDES="mscoree,mshtml="
export WINEDEBUG="${WINEDEBUG:-err+all}"
export LANG=ja_JP.UTF-8
export LC_ALL=ja_JP.UTF-8
export LIBGL_ALWAYS_SOFTWARE=1

PIDS=()
cleanup() {
    for p in "${PIDS[@]:-}" ; do
        [ -n "${p}" ] && kill "${p}" 2>/dev/null || true
    done
}
trap cleanup EXIT

start_ref() {
    Xvfb "${REF_DISPLAY}" -screen 0 640x480x16 >/tmp/neph-save-ref-xvfb.log 2>&1 &
    PIDS+=($!)
    sleep 2
    DISPLAY="${REF_DISPLAY}" matchbox-window-manager -use_titlebar no \
        >/tmp/neph-save-ref-wm.log 2>&1 &
    PIDS+=($!)
    sleep 1
    ( cd "${GAME_DIR}" && DISPLAY="${REF_DISPLAY}" wine RPG_RT.exe ) \
        >/tmp/neph-save-ref-player.log 2>&1 &
    PIDS+=($!)
    sleep "${REF_BOOT_WAIT:-25}"
}

start_ours() {
    Xvfb "${OUR_DISPLAY}" -screen 0 640x480x24 >/tmp/neph-save-our-xvfb.log 2>&1 &
    PIDS+=($!)
    sleep 2
    DISPLAY="${OUR_DISPLAY}" matchbox-window-manager -use_titlebar no \
        >/tmp/neph-save-our-wm.log 2>&1 &
    PIDS+=($!)
    sleep 1
    DISPLAY="${OUR_DISPLAY}" "${ENGINE}" --game_dir "${GAME_DIR}" \
        --rpg2k_continue --timeout_ms="${OUR_TIMEOUT_MS:-300000}" \
        >/tmp/neph-save-our-player.log 2>&1 &
    PIDS+=($!)
    sleep "${OUR_BOOT_WAIT:-10}"
}

# Hold each key ~120ms: RPG_RT polls once a frame and drops a key that goes down
# and up between two polls.
send_keys() {
    local disp="$1" ; shift
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

# ref/our frame diff for one label; prints the differing-pixel count.
diff_step() {
    local label="$1"
    local ref="${OUT_DIR}/neph-save-ref-${label}.png"
    local our="${OUT_DIR}/neph-save-ours-${label}.png"
    capture "${REF_DISPLAY}" "${ref}"
    capture "${OUR_DISPLAY}" "${our}"
    convert "${ref}" "${our}" -compose difference -composite -auto-level \
        "${OUT_DIR}/neph-save-diff-${label}.png"
    convert "${ref}" "${our}" "${OUT_DIR}/neph-save-diff-${label}.png" \
        +append "${OUT_DIR}/neph-save-cmp-${label}.png"
    # The reference runs in a 16-bit visual, so almost every pixel differs by
    # +-1 per channel from RGB565 quantisation; -fuzz keeps the metric signal.
    local total differing
    total=$(identify -format '%[fx:w*h]' "${ref}")
    differing=$(compare -metric AE -fuzz "${DIFF_FUZZ:-3%}" "${ref}" "${our}" \
        null: 2>&1 || true)
    printf '%-16s differing pixels: %s / %s\n' "${label}" "${differing}" "${total}"
}

start_ref
start_ours

# Ours auto-selects Continue; RPG_RT needs the cursor moved to it (entry 2) and
# then file 1 confirmed on the save screen.
diff_step title
send_keys "${REF_DISPLAY}" Down
diff_step title-continue
send_keys "${REF_DISPLAY}" Return
diff_step file-screen
send_keys "${REF_DISPLAY}" Return
sleep "${MAP_SETTLE:-4}"
diff_step map

# Both are now standing on the same tile of the same map: walk them together.
for step in "walk-down Down*2" "walk-left Left*2" "walk-up Up*2" ; do
    label="${step%% *}"
    keys="${step#* }"
    # shellcheck disable=SC2086
    send_keys "${REF_DISPLAY}" ${keys}
    # shellcheck disable=SC2086
    send_keys "${OUR_DISPLAY}" ${keys}
    sleep "${STEP_SETTLE:-2}"
    diff_step "${label}"
done

# The engine logs the map it resumed on; surface it so the comparison states
# which map these frames are of, and fail if it never got there.
if ! grep -q '\[RPG2k-MAP\]' /tmp/neph-save-our-player.log ; then
    echo "FAILED: our engine never reached the map (no [RPG2k-MAP] marker)" >&2
    grep -v 'ALSA lib\|snd_\|Unknown PCM' /tmp/neph-save-our-player.log | tail -20 >&2
    exit 1
fi
grep '\[RPG2k-MAP\]' /tmp/neph-save-our-player.log | tail -1

echo "frames written to ${OUT_DIR}/neph-save-{ref,ours,diff,cmp}-*.png"
