#!/usr/bin/env bash

# Run the RPG Maker 2000 game "Nepheshel" under wine via EasyRPG Player, headless
# through Xvfb, so it can write a real Save<N>.lsd that scripts/lcf_save_check.rb
# then analyses.
#
# Why EasyRPG rather than the genuine RPG_RT.exe (as in run-rpg2k-rpgrt-wine.bash):
# RPG_RT.exe drives DirectDraw in a fullscreen-exclusive mode that fails under
# Xvfb ("DirectDraw Error (DDERR_UNSUPPORTED)") and runs unthrottled, so its
# frame timing and input are hard to automate. EasyRPG Player is an SDL2
# reimplementation that renders reliably to a window under Xvfb, is properly
# frame-limited, and writes byte-compatible LcfSaveData files -- exactly what we
# want a save fixture from. It is a 64-bit PE, so a win64 wine prefix is enough.
#
# Requires: wine (win64), Xvfb, x11-apps (xwd), ImageMagick (convert), unar,
#           a Japanese font + locale for the CP932 text. On Debian/Ubuntu:
#     apt-get install --no-install-recommends wine wine64 xvfb x11-apps \
#                     imagemagick unar fonts-ipafont locales
#     locale-gen ja_JP.UTF-8
#
# Nepheshel saves only at "Gates". The hero starts with one Gate Crystal; the
# first Gate is at the town entrance (map 12, "町１G"). After skipping the
# opening the route is:
#   room -> shop 2F -> shop -> town, then walk to the Gate, choose
#   "クリスタルをはめる" (insert crystal) -> "SAVE" -> file 1.
# That writes Save01.lsd next to RPG_RT.ldb, which you can then inspect with:
#   ruby scripts/lcf_save_check.rb <GAME_DIR>/Save01.lsd
#
# Usage: ./scripts/run-nepheshel-easyrpg-wine.bash [game_dir]
#   game_dir defaults to data/Nepheshel206beta/Nepheshel206Rbeta.

set -eux -o pipefail

cd "$(dirname "$0")/.."

GAME_DIR="${1:-data/Nepheshel206beta/Nepheshel206Rbeta}"

# Fetch Nepheshel if it is not present yet.
if [ ! -e "${GAME_DIR}/RPG_RT.ldb" ] ; then
    ./scripts/download-nepheshel.bash
fi

# EasyRPG ships a Player.exe alongside the mtf-meido-action test-bed; reuse it.
if [ ! -f "${GAME_DIR}/Player.exe" ] ; then
    if [ ! -f data/mtf-meido-action/Debug/Player.exe ] ; then
        ./scripts/download-mtf-meido-action.bash
    fi
    cp data/mtf-meido-action/Debug/Player.exe "${GAME_DIR}/"
fi

mkdir -p ss

export WINEARCH=win64
export WINEPREFIX="${WINEPREFIX:-$HOME/.wine-nepheshel}"
export WINEDLLOVERRIDES="mscoree,mshtml="
export WINEDEBUG="${WINEDEBUG:--all}"
# Japanese locale so the ANSI code page is 932 and CP932 text decodes.
export LANG=ja_JP.UTF-8
export LC_ALL=ja_JP.UTF-8
# No GPU under Xvfb: ask SDL for its software renderer. Do NOT set
# SDL_VIDEODRIVER here -- under wine SDL must use its "windows" driver, and
# forcing "x11" (a native-Linux driver) makes Player.exe abort with
# "Couldn't initialize SDL. x11 not available".
export SDL_RENDER_DRIVER=software

export DISPLAY="${DISPLAY:-:1024}"
Xvfb "${DISPLAY}" -screen 0 640x480x24 >/tmp/nepheshel-xvfb.log 2>&1 &
XVFB_PID=$!
trap 'kill "${XVFB_PID}" 2>/dev/null || true' EXIT
sleep 2

# One-time prefix bootstrap.
if [ ! -d "${WINEPREFIX}" ] ; then
    wine wineboot --init
fi

# --test-play enables the in-game Debug menu; drop it for a plain playthrough.
( cd "${GAME_DIR}" && wine Player.exe --test-play ) >/tmp/nepheshel-player.log 2>&1 &
PLAYER_PID=$!
trap 'kill "${PLAYER_PID}" 2>/dev/null || true; kill "${XVFB_PID}" 2>/dev/null || true' EXIT

# Let EasyRPG boot to the Nepheshel title screen, then snapshot it.
sleep 12
xwd -root -display "${DISPLAY}" -silent | convert xwd:- png:ss/nepheshel-title.png

echo "Title screenshot written to ss/nepheshel-title.png"
echo "Play to the town-entrance Gate and save; then analyse the result with:"
echo "  ruby scripts/lcf_save_check.rb \"${GAME_DIR}/Save01.lsd\""
