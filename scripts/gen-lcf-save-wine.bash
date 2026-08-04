#!/usr/bin/env bash

# Generate a genuine RPG Maker 2000/2003 Save<N>.lsd headlessly under wine and
# analyse it with scripts/lcf_save_check.rb.
#
# The database/map schemas are validated against real games by
# lcf_testbed_check.rb, and the save-data schema against a real 2000 save
# (Nepheshel) by lcf_save_check.rb. Getting a *2003* save was the gap: the 2003
# test games (mtf-meido-action, Song-of-the-Sea) open with a menu-disabled intro,
# so the in-game Save cannot be reached without playing the scripted opening --
# ADR 0013 deferred save-level 2003 validation for exactly this reason.
#
# The way past it is EasyRPG Player's **test-play debug menu** (F9): its first
# entry is "Save", which invokes the normal save scene from anywhere, ignoring
# whether the game currently permits saving. So booting the game under
# `--test-play`, starting a New Game, and picking F9 -> Save -> a file slot
# writes a byte-real LcfSaveData without any playthrough -- for either edition.
#
# Two things make the input actually reach the game under a headless X server:
#   * a window manager (matchbox) so the SDL window gets X input focus -- with no
#     WM, wine never marks the window foreground and keystrokes are dropped;
#   * the decision key must be *held* (keydown, pause, keyup), not tapped -- a
#     zero-length press is swallowed by the title/menu handlers. Menu cursor
#     moves, by contrast, want short taps so they advance exactly one cell.
#
# Requires: wine (win64 -- EasyRPG's Player.exe is a 64-bit PE), Xvfb,
#           matchbox-window-manager, x11-apps (xwd), ImageMagick (convert),
#           xdotool, and a Japanese locale for the CP932 text. On Debian/Ubuntu:
#     apt-get install --no-install-recommends wine wine64 xvfb \
#         matchbox-window-manager x11-apps imagemagick xdotool \
#         fonts-ipafont unar locales
#     locale-gen ja_JP.UTF-8
#
# Usage: ./scripts/gen-lcf-save-wine.bash [game_dir] [slot]
#   game_dir defaults to data/mtf-meido-action/Debug (a real RPG2003 project,
#            already part of the testbed download set; ships EasyRPG Player.exe).
#            Pass data/Nepheshel206beta/Nepheshel206Rbeta for the RPG2000 case
#            (needs a name-entry step -- see NEPHESHEL notes below).
#   slot     save file number (default 1) -> Save0<slot>.lsd.

set -eux -o pipefail

cd "$(dirname "$0")/.."

GAME_DIR="${1:-data/mtf-meido-action/Debug}"
SLOT="${2:-1}"
LSD="$(printf 'Save%02d.lsd' "${SLOT}")"

# Fetch the default test-bed if absent (ships EasyRPG Player.exe alongside data).
if [ ! -e "${GAME_DIR}/RPG_RT.ldb" ] ; then
    if [ "${GAME_DIR}" = "data/mtf-meido-action/Debug" ] ; then
        ./scripts/download-mtf-meido-action.bash
    else
        echo "No RPG_RT.ldb in ${GAME_DIR}" >&2 ; exit 1
    fi
fi

# EasyRPG Player.exe: use the one in the game dir, else borrow the test-bed's.
if [ ! -f "${GAME_DIR}/Player.exe" ] ; then
    if [ ! -f data/mtf-meido-action/Debug/Player.exe ] ; then
        ./scripts/download-mtf-meido-action.bash
    fi
    cp data/mtf-meido-action/Debug/Player.exe "${GAME_DIR}/"
fi

export WINEARCH=win64
export WINEPREFIX="${WINEPREFIX:-$HOME/.wine-rpg2k-save}"
export WINEDLLOVERRIDES="mscoree,mshtml="
export WINEDEBUG="${WINEDEBUG:--all}"
# Japanese locale so the ANSI code page is 932 and CP932 text decodes.
export LANG=ja_JP.UTF-8
export LC_ALL=ja_JP.UTF-8
# No GPU under Xvfb: ask SDL for its software renderer. Do NOT set
# SDL_VIDEODRIVER -- under wine SDL must use its "windows" driver.
export SDL_RENDER_DRIVER=software

export DISPLAY="${DISPLAY:-:1024}"
Xvfb "${DISPLAY}" -screen 0 640x480x24 >/tmp/gen-lcf-xvfb.log 2>&1 &
XVFB_PID=$!
# A window manager so the SDL window receives X input focus (see header).
matchbox-window-manager -use_titlebar no >/tmp/gen-lcf-wm.log 2>&1 &
WM_PID=$!
cleanup() {
    kill "${PLAYER_PID:-}" 2>/dev/null || true
    kill "${WM_PID}" 2>/dev/null || true
    kill "${XVFB_PID}" 2>/dev/null || true
}
trap cleanup EXIT
sleep 2

# One-time prefix bootstrap.
if [ ! -d "${WINEPREFIX}" ] ; then
    wine wineboot --init
fi

mkdir -p ss

# --- input helpers ---------------------------------------------------------
# The game window is named "EasyRPG Player"; find it, focus it, and drive it.
win() { xdotool search --name 'EasyRPG' 2>/dev/null | head -1 ; }

# hold_key SECONDS KEY...  -- press each key held for SECONDS (decision keys).
hold_key() {
    local secs="$1" ; shift
    local wid ; wid="$(win)"
    xdotool windowfocus "${wid}" 2>/dev/null || true
    xdotool windowraise "${wid}" 2>/dev/null || true
    sleep 0.3
    local k
    for k in "$@" ; do
        xdotool keydown --window "${wid}" --clearmodifiers "${k}" 2>/dev/null || true
        sleep "${secs}"
        xdotool keyup --window "${wid}" --clearmodifiers "${k}" 2>/dev/null || true
        sleep 0.35
    done
}

shot() { xwd -root -display "${DISPLAY}" -silent | convert xwd:- "png:ss/$1" ; }

# --- boot and save ---------------------------------------------------------
( cd "${GAME_DIR}" && wine Player.exe --test-play ) >/tmp/gen-lcf-player.log 2>&1 &
PLAYER_PID=$!

# Wait for the title screen, then snapshot it.
for _ in $(seq 1 30) ; do win >/dev/null && break ; sleep 1 ; done
sleep 12
shot title.png

# Start a New Game (the top menu entry). Decision keys are HELD, not tapped.
hold_key 0.25 Return
sleep 6

# NEPHESHEL note: the RPG2000 game inserts a "skip opening demo?" choice and a
# name-entry grid here; drive those first (Down + Return to skip, then navigate
# the kana grid to <決定> and Return to accept the default name) before the F9
# save. The RPG2003 test-bed drops straight into a controllable cutscene, so the
# generic path below (advance a few messages, then F9 -> Save) reaches a saveable
# state without any game-specific steps.
hold_key 0.2 Return Return Return
sleep 2

# Open the test-play debug menu (F9); its first entry, "Save", is preselected.
hold_key 0.1 F9
sleep 1.5
shot debug-menu.png
hold_key 0.25 Return          # choose "Save" -> opens the save-file scene
sleep 1
# File 1 is preselected; step down (slot-1) times to reach the requested slot.
for _ in $(seq 2 "${SLOT}") ; do hold_key 0.03 Down ; done
hold_key 0.25 Return          # confirm the file slot -> writes Save0<N>.lsd
sleep 2
shot saved.png

if [ ! -f "${GAME_DIR}/${LSD}" ] ; then
    echo "FAILED: ${GAME_DIR}/${LSD} was not written" >&2
    exit 1
fi
echo "Wrote ${GAME_DIR}/${LSD}"

# Analyse the genuine save with the same parser the runtime uses.
ruby scripts/lcf_save_check.rb "${GAME_DIR}/${LSD}"
