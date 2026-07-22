#!/usr/bin/env bash

set -eux -o pipefail

mkdir -p $(dirname $0)/../data

cd $(dirname $0)/../data

if [ ! -f PrayforYou.zip ] ; then
    wget -O PrayforYou.zip "https://dl.fgamearchives.com/archives/win/3271/PrayforYou.zip"
fi

if [ ! -d PrayforYou ] ; then
    unar PrayforYou.zip
fi
