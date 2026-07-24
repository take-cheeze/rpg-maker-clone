#!/usr/bin/env bash

# Run the RPG Maker 2000/2003 test-bed project (mtf-meido-action) under wine,
# headlessly via Xvfb, and grab title/in-game screenshots into ss/.
#
# The test-bed ships the EasyRPG "Player.exe" alongside its RPG_RT.* data, so
# this drives the reference runtime under wine rather than the in-repo clone.
# Handy for eyeballing how the real engine renders a map/scene we are cloning.
#
# Requires: wine (64-bit is enough - Player.exe is a 64-bit PE), Xvfb, xwd,
#           ImageMagick (convert) and xdotool. On Debian/Ubuntu:
#             apt-get install wine64 xvfb x11-apps imagemagick xdotool
#
# Usage: ./scripts/run-rpg2k-wine.bash [game_dir]
#   game_dir defaults to data/mtf-meido-action/Debug (downloaded on demand).

set -eux -o pipefail

cd "$(dirname "$0")/.."

GAME_DIR="${1:-data/mtf-meido-action/Debug}"

# Fetch the test-bed if it is not present yet.
if [ ! -e "${GAME_DIR}/RPG_RT.ldb" ] ; then
    ./scripts/download-mtf-meido-action.bash
fi

# Pick the runtime: a bundled EasyRPG Player.exe, else the classic RPG_RT.exe.
if [ -f "${GAME_DIR}/Player.exe" ] ; then
    RUNTIME=Player.exe
elif [ -f "${GAME_DIR}/RPG_RT.exe" ] ; then
    RUNTIME=RPG_RT.exe
else
    echo "No Player.exe or RPG_RT.exe found in ${GAME_DIR}" >&2
    exit 1
fi

mkdir -p ss

export WINEARCH=win64
export WINEPREFIX="${WINEPREFIX:-$HOME/.wine-rpg2k}"
export WINEDLLOVERRIDES="mscoree,mshtml="
export WINEDEBUG="${WINEDEBUG:--all}"
export LC_ALL=C
# Xvfb has no GPU, so wined3d cannot present the hardware swapchain; ask SDL for
# the software renderer (wine forwards this env var to the Windows process).
export SDL_RENDER_DRIVER=software

export DISPLAY="${DISPLAY:-:1024}"
Xvfb "${DISPLAY}" -screen 0 1280x960x24 >/tmp/rpg2k-xvfb.log 2>&1 &
XVFB_PID=$!
trap 'kill "${XVFB_PID}" 2>/dev/null || true' EXIT
sleep 2

# One-time prefix bootstrap.
if [ ! -d "${WINEPREFIX}" ] ; then
    wineboot --init
fi

( cd "${GAME_DIR}" && wine "${RUNTIME}" ) >/tmp/rpg2k-player.log 2>&1 &
PLAYER_PID=$!
trap 'kill "${PLAYER_PID}" 2>/dev/null || true; kill "${XVFB_PID}" 2>/dev/null || true' EXIT

# Let the EasyRPG splash pass and the title screen come up, then snapshot it.
sleep 14
xwd -root -display "${DISPLAY}" -silent | convert xwd:- png:ss/rpg2k-title.png

# Start a New Game (confirm = Enter / Z) and snapshot the first map.
WID="$(xdotool search --name 'EasyRPG' | head -1 || true)"
if [ -n "${WID}" ] ; then
    xdotool windowfocus "${WID}" || true
    for k in Return z Return ; do
        xdotool key --window "${WID}" --clearmodifiers "${k}"
        sleep 0.4
    done
fi
sleep 3
xwd -root -display "${DISPLAY}" -silent | convert xwd:- png:ss/rpg2k-ingame.png

echo "Screenshots written to ss/rpg2k-title.png and ss/rpg2k-ingame.png"
