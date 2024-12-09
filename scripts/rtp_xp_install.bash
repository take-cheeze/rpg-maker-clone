#!/usr/bin/env bash

set -eux

cd $(dirname $0)

if [ ! -f xp_rtp103.zip ] ; then
  wget https://cdn.tkool.jp/updata/rtp/xp_rtp103.zip
fi

if [ ! -d RPGXP_RTP103 ] ; then
  unar -e cp932 xp_rtp103.zip
fi

if [ ! -v WINEPREFIX ] ; then
  export WINEPREFIX=$HOME/.wine
fi

export DISPLAY=:1024
Xvfb "${DISPLAY}" -screen 0 1920x1080x24 &

export WINEDLLOVERRIDES="mscoree,mshtml="
export LC_ALL=ja_JP.UTF-8

winecfg /v win10
cp setup.iss "${WINEPREFIX}/drive_c"

wine ./RPGXP_RTP103/Setup.exe /silent

ls "${WINEPREFIX}/drive_c/Program Files (x86)/Common Files/Enterbrain/RGSS/Standard"

kill %1
