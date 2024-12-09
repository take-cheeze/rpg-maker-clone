#!/usr/bin/env bash

set -eux

cd $(dirname $0)

if [ ! -f 2000rtp.zip ] ; then
  wget https://cdn.tkool.jp/updata/rtp/2000rtp.zip
fi

if [ ! -d RTP* ] ; then
  unar -e cp932 2000rtp.zip
fi

if [ ! -f RTP2000RTP.exe ] ; then
  RTP_EXE=$(find RTP* -name RPG2000RTP.exe)
  cp ${RTP_EXE} ./RPG2000RTP.exe
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

wine ./RPG2000RTP.exe /s /a /s /sms /f1C:\\setup.iss

ls "${WINEPREFIX}/drive_c/Program Files (x86)/ASCII"

kill %1
