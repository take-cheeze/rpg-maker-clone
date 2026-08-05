#!/usr/bin/env bash

set -eux -o pipefail

mkdir -p $(dirname $0)/../data

cd $(dirname $0)/../data

# See download-nepheshel.bash for why wget/unar are quietened.
if [ ! -f PrayforYou.zip ] ; then
    wget -nv -O PrayforYou.zip "https://dl.fgamearchives.com/archives/win/3271/PrayforYou.zip"
fi

if [ ! -d PrayforYou ] ; then
    unar -q PrayforYou.zip
fi
