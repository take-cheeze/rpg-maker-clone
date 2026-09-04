#!/usr/bin/env bash

set -eux -o pipefail

# Routes through the optional CI CORS proxy cache when CORS_PROXY_URL is set.
. "$(dirname "$0")/cors-proxy-url.bash"

mkdir -p $(dirname $0)/../data

cd $(dirname $0)/../data

# "Egoic Answers" (エゴイックアンサーズ！) -- an RPG Maker **MZ** game, hosted
# on the same fgamearchives mirror as download-prayforyou.bash and
# download-killer-knights.bash. Its data/System.json has both
# hasEncryptedImages and hasEncryptedAudio set, which makes it a genuine
# real-world bed for the encrypted-asset path that mz_encrypted_check.bash
# otherwise only exercises against a *derived* project (gen-mz-encrypted.py) --
# see that script's comment about "both games sampled from freem" having had
# Encrypt Images ticked; this is one of the two.
#
# The upstream archive is a full NW.js-packaged build (~900 MB, stored rather
# than deflated): the actual RPG Maker project -- data/, img/, audio/, js/,
# effects/, fonts/ -- is only about 960 MB of that even so, but the remainder
# (node.dll, nw.dll, the Chromium locales/, Game.exe, swiftshader/, ...) is
# the bundled NW.js runtime, which this repo's own engine has no use for.
# `unzip` still has to read the whole archive to find any entry (it is not
# deflated, so there is no bandwidth saved), but skipping those directories at
# extraction time keeps them off disk.
#
# Several BGM file names are Japanese (e.g. audio/bgm/#木漏れ日の散歩道.ogg_,
# encrypted so the on-disk name carries the trailing `_`), stored with zip's
# UTF-8 filename flag rather than cp932 -- unlike download-killer-knights.bash,
# so no `unar -e cp932` is needed here, but the extracting locale still has to
# be UTF-8 or `unzip` falls back to writing literal `#Uxxxx` escapes instead of
# the real characters (confirmed against the actual archive; see the
# `LANG=C.UTF-8` below).
#
# See download-nepheshel.bash for why wget is quietened.
if [ ! -f EgoicAnswers.zip ] ; then
    wget -nv -O EgoicAnswers.zip "$(proxied_url "https://dln3.fgamearchives.com/archives/win/14197/EgoicAnswers.zip")"
fi

if [ ! -d EgoicAnswers ] ; then
    LANG=C.UTF-8 LC_ALL=C.UTF-8 unzip -q EgoicAnswers.zip \
        'EgoicAnswers/data/*' 'EgoicAnswers/img/*' 'EgoicAnswers/audio/*' \
        'EgoicAnswers/js/*' 'EgoicAnswers/effects/*' 'EgoicAnswers/fonts/*'
fi
