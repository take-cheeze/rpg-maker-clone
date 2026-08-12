#!/usr/bin/env bash

set -eux -o pipefail

# Routes through the optional CI CORS proxy cache when CORS_PROXY_URL is set.
. "$(dirname "$0")/cors-proxy-url.bash"

mkdir -p $(dirname $0)/../data

cd $(dirname $0)/../data

# "Pray for You" -- an RPG Maker **XP** game, despite living among the RPG2000
# download scripts. Its Game.ini reads `Library=RGSS103J.dll` /
# `Scripts=Data\Scripts.rxdata`, and the archive ships RGSS103J.dll, Game.exe
# and a 14.8 MB packed `Game.rgssad` with no RPG_RT.ldb / .lmu / .lmt in sight.
# That makes it a useful test-bed for the **encrypted-archive** path
# (mruby-rpgxp's rgssad reader) rather than for anything LCF: the whole database
# lives inside the .rgssad with no loose Data/ directory to fall back on, which
# is exactly the "packed release, no loose files" case that path exists for.
# `RPGXP::RGSSAD.open` reads it cleanly -- 222 entries, with
# `Data\Scripts.rxdata` coming out as 212792 bytes that start with Marshal's
# 4 8 magic.
#
# See download-nepheshel.bash for why wget/unar are quietened.
if [ ! -f PrayforYou.zip ] ; then
    wget -nv -O PrayforYou.zip "$(proxied_url "https://dl.fgamearchives.com/archives/win/3271/PrayforYou.zip")"
fi

if [ ! -d PrayforYou ] ; then
    unar -q PrayforYou.zip
fi
