#!/usr/bin/env bash

set -eux -o pipefail

# Routes through the optional CI CORS proxy cache when CORS_PROXY_URL is set.
. "$(dirname "$0")/cors-proxy-url.bash"

mkdir -p $(dirname $0)/../data

cd $(dirname $0)/../data

# "Sanctuary Of the Ruler" -- an RPG Maker **VX Ace** game, hosted on the same
# fgamearchives mirror as download-monodori.bash. Its Game.ini reads
# `Library=System\RGSS301.dll` / `Scripts=Data\Scripts.rvdata2` (RGSS3, the VX
# Ace generation -- RGSS301.dll and the .rvdata2 extension, not VX's
# RGSS202J.dll / .rvdata), and its whole Data\ and Graphics\ trees are packed
# into a 180 MB Game.rgss3a with nothing loose but Audio/, Fonts/ and a
# game-specific Tips/ folder of in-game help text -- the VX Ace counterpart of
# download-monodori.bash's packed-only VX bed, and (unlike that one) large
# enough that a real project actually exercises the archive reader against
# hundreds of MB of entries rather than a handful.
#
# Several file/folder names are Japanese (Audio/BGM tracks, all of Tips/),
# stored with zip's UTF-8 filename flag rather than cp932 -- see
# download-egoicanswers.bash for why the extracting locale has to be UTF-8 or
# `unzip`/`unar` mis-decodes them; unlike that script, nothing here is large
# enough to bother skipping (Game.exe and System/RGSS301.dll -- the engine
# binary and DLL this repo's own engine has no use for -- are a rounding
# error against the 180 MB archive and 216 MB of Audio), so the whole archive
# is just extracted.
#
# See download-nepheshel.bash for why wget/unar are quietened.
if [ ! -f Sanctuary_Of_the_Ruler.zip ] ; then
    wget -nv -O Sanctuary_Of_the_Ruler.zip "$(proxied_url "https://dl12.fgamearchives.com/archives/win/15451/Sanctuary_Of_the_Ruler.zip")"
fi

if [ ! -d Sanctuary_Of_the_Ruler ] ; then
    LANG=C.UTF-8 LC_ALL=C.UTF-8 unar -q Sanctuary_Of_the_Ruler.zip
fi
