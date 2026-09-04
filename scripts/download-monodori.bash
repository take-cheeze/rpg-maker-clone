#!/usr/bin/env bash

set -eux -o pipefail

# Routes through the optional CI CORS proxy cache when CORS_PROXY_URL is set.
. "$(dirname "$0")/cors-proxy-url.bash"

mkdir -p $(dirname $0)/../data

cd $(dirname $0)/../data

# "Monochrome Dreamer" (モノクローム・ドリーマー) -- an RPG Maker **VX** game,
# hosted on the same fgamearchives mirror as download-prayforyou.bash and
# download-killer-knights.bash. Its Game.ini reads `RTP=RPGVX` /
# `Library=RGSS202J.dll` / `Scripts=Data\Scripts.rvdata` (RGSS2, the VX
# generation -- RGSS202J.dll and the .rvdata extension, not VX Ace's
# RGSS301J.dll / .rvdata2), and the archive ships Game.exe plus a packed
# 9.6 MB `Game.rgss2a` with no loose `Data\` directory anywhere.
#
# rpgvx_testbed_check.rb's own comment says VX/VX Ace have no fetchable
# open-source test bed, because the editors and RTPs are commercial and no
# equivalent project is redistributable -- which is why that check instead
# *builds* a project of its own for each edition. This freeware release is the
# exception: a genuine RGSS2 encrypted archive to point mruby-rpgvx's rgssad
# reader at, the same "packed release, no loose files" case
# download-prayforyou.bash serves on the XP side.
#
# See download-nepheshel.bash for why wget/unar are quietened.
if [ ! -f monodori_ver1.3.zip ] ; then
    wget -nv -O monodori_ver1.3.zip "$(proxied_url "https://dl.fgamearchives.com/archives/win/3400/monodori_ver.1.3.zip")"
fi

if [ ! -d monodori_ver1.3 ] ; then
    unar -q monodori_ver1.3.zip
fi
