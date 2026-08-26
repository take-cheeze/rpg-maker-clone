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
set -eux -o pipefail

# Routes through the optional CI CORS proxy cache when CORS_PROXY_URL is set.
. "$(dirname "$0")/cors-proxy-url.bash"

mkdir -p $(dirname $0)/../data

cd $(dirname $0)/../data

if [ ! -f kk1.12.zip ] ; then
    wget -nv -O kk1.12.zip "$(proxied_url "https://dl.fgamearchives.com/archives/win/4051/kk1.12.zip")"
fi

if [ ! -d kk1.12 ] ; then
    unar -q kk1.12.zip
fi
