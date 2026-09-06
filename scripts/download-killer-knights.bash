#!/usr/bin/env bash

# RPG Maker 2003 test-bed game (non-EasyRPG), hosted on the same fgamearchives
# mirror as download-prayforyou.bash. After running, the game directory is:
#   data/kk1.12
# which contains RPG_RT.ldb / RPG_RT.lmt / RPG_RT.EXE and 128 Map*.lmu files.
#
# "Killer Knights - R" (キラーナイツ－R, RPG_RT.ini's GameTitle, cp932). Its
# five swappable companions join and leave the party through Change Party
# Member and are levelled directly via Change Level (not Change EXP), so an
# actor's level and its EXP total are not derivable from one another the way
# every other test bed here happens to leave them -- exactly the shape that
# exposed the Party#to_h/#load_state Change-Class bug fixed alongside this
# download (see the "Party save/Continue does not fabricate a Change Class"
# check in rpg2k_logic_check.rb): Save/Continue used to silently switch such
# an actor onto their class's own growth curve, mis-deriving both their level
# and their learned-skill list.
#
# See download-nepheshel.bash for why wget/unar are quietened.
#
# Needs the official RPG Maker 2003 RTP to actually boot under wine (else a
# genuine RPG_RT.exe shows one "RPGツクール2003" OK-only dialog -- an
# unlabelled RTP-missing notice, its message text itself unrenderable
# without the RTP's own bitmap font resources -- then exits): run
# scripts/rtp_2003_install.bash first (WINEPREFIX must match the one used to
# boot this game). A wine prefix restored from CI's own cached-prefix step
# already has it and needs nothing further; a fresh prefix does not.
# Confirmed 2026-09-06: identical `wine RPG_RT.EXE` invocation hung on that
# dialog before the RTP install, reached the real title screen (legible
# Japanese menu text, no dialog) immediately after.
set -eux -o pipefail

# Routes through the optional CI CORS proxy cache when CORS_PROXY_URL is set.
. "$(dirname "$0")/cors-proxy-url.bash"

mkdir -p $(dirname $0)/../data

cd $(dirname $0)/../data

if [ ! -f kk1.12.zip ] ; then
    wget -nv -O kk1.12.zip "$(proxied_url "https://dl.fgamearchives.com/archives/win/4051/kk1.12.zip")"
fi

if [ ! -d kk1.12 ] ; then
    # -e cp932: the archive's internal file names are Shift_JIS (e.g.
    # Picture/キラーナイツ隊旗.png, Picture/地名：レスト城.png) -- unar's
    # default guess mangles every one of them into mojibake that the LCF/
    # RPG_RT.ldb-only checks never notice (they read no filenames a game
    # database points at) but that breaks the genuine RPG_RT.EXE outright:
    # running it live under wine, it opened cleanly up to the title screen
    # on a plain `unar -q` extraction, then failed to open a Picture file by
    # name the moment a map event actually showed one. rtp_install.bash's
    # own RTP unpack already carries this same flag for the same reason.
    unar -q -e cp932 kk1.12.zip
fi
