#!/usr/bin/env bash

# Run a real RPG_RT.exe RPG Maker 2000/2003 project under wine (headless via
# Xvfb) - i.e. the genuine Enterbrain runtime, NOT the EasyRPG re-implementation
# used by run-rpg2k-wine.bash.
#
# The repo's own rpg2k test-bed (mtf-meido-action) only ships EasyRPG's
# Player.exe, and the classic RPG_RT.exe games referenced by the other download
# scripts (Nepheshel, PrayforYou) live on hosts that are blocked from
# sandboxed/proxied CI. So this pulls "Song-of-the-Sea" (by lychees, the same
# author as the mtf-meido-action test-bed), which ships a real 32-bit
# RPG_RT.exe (RPG Maker 2003) directly in git.
#
# RPG_RT.exe is a 32-bit binary, so 32-bit wine is required:
#   dpkg --add-architecture i386 && apt-get update
#   apt-get install wine wine32 wine64 xvfb x11-apps imagemagick \
#                   fonts-wqy-zenhei locales
#   locale-gen zh_CN.UTF-8
#
# NOTE on text: Song-of-the-Sea is a Chinese fan-game on a Japanese engine, so
# it stores GBK (CP936) text and ships a Locale-Emulator profile
# (RPG_RT.exe.le.config) because it needs a Chinese locale even on Windows. We
# reproduce that by creating the wine prefix under zh_CN.UTF-8 (GetACP -> 936)
# and substituting a CJK font. The engine, title art, window skin and the
# "RPGツクール2003" logo all render; menu text drawn via the special Windows
# "System" logical font may still show as boxes, which is a known wine
# limitation (wine's built-in System raster font has no CJK glyphs).

set -eux -o pipefail

cd "$(dirname "$0")/.."

GAME_DIR="${1:-data/Song-of-the-Sea/Ch.1}"

# Fetch the test-bed (sparse: only the Ch.1 game folder, no LFS blobs needed).
if [ ! -e "${GAME_DIR}/RPG_RT.exe" ] ; then
    mkdir -p data
    if [ ! -d data/Song-of-the-Sea ] ; then
        GIT_LFS_SKIP_SMUDGE=1 git -C data clone --depth 1 --filter=blob:none \
            --sparse https://github.com/lychees/Song-of-the-Sea.git
        git -C data/Song-of-the-Sea sparse-checkout set Ch.1
    fi
fi

mkdir -p ss

export WINEARCH=win32
export WINEPREFIX="${WINEPREFIX:-$HOME/.wine-rpg2k3}"
export WINEDLLOVERRIDES="mscoree,mshtml="
export WINEDEBUG="${WINEDEBUG:--all}"
# Chinese locale so RPG_RT's ANSI code page is 936 and GBK text decodes.
export LANG=zh_CN.UTF-8
export LC_ALL=zh_CN.UTF-8
export SDL_RENDER_DRIVER=software

export DISPLAY="${DISPLAY:-:1024}"
Xvfb "${DISPLAY}" -screen 0 1280x960x24 >/tmp/rpgrt-xvfb.log 2>&1 &
XVFB_PID=$!
trap 'kill "${XVFB_PID}" 2>/dev/null || true' EXIT
sleep 2

# Create the prefix under the Chinese locale so GetACP() == 936.
if [ ! -d "${WINEPREFIX}" ] ; then
    wine wineboot --init
fi

# Map the Windows "System"/CJK font names onto an installed CJK font so the
# engine can draw Chinese (best-effort; see NOTE above).
CJK_TTC=/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc
if [ -f "${CJK_TTC}" ] ; then
    cp -f "${CJK_TTC}" "${WINEPREFIX}/drive_c/windows/Fonts/"
    python3 - <<'PY'
import os
subs = ["System", "FixedSys", "MS Sans Serif",
        "MS Gothic", "MS Mincho", "MS UI Gothic",
        "SimSun", "NSimSun", "SimHei", "宋体", "新宋体", "黑体"]
lines = ["Windows Registry Editor Version 5.00", "",
         r"[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes]"]
lines += [f'"{s}"="WenQuanYi Zen Hei"' for s in subs]
lines += ["", r"[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\Fonts]",
          '"WenQuanYi Zen Hei (TrueType)"="wqy-zenhei.ttc"', ""]
open("/tmp/rpgrt-cjkfont.reg", "wb").write(b"\xff\xfe" + "\r\n".join(lines).encode("utf-16-le"))
PY
    wine regedit /tmp/rpgrt-cjkfont.reg
fi

( cd "${GAME_DIR}" && wine RPG_RT.exe ) >/tmp/rpgrt-player.log 2>&1 &
PLAYER_PID=$!
trap 'kill "${PLAYER_PID}" 2>/dev/null || true; kill "${XVFB_PID}" 2>/dev/null || true' EXIT

# Let the engine boot to the title screen, then snapshot it.
sleep 13
xwd -root -display "${DISPLAY}" -silent | convert xwd:- png:ss/rpgrt-title.png

echo "Screenshot written to ss/rpgrt-title.png"
