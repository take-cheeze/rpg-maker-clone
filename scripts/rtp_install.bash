#!/usr/bin/env bash

set -eux

cd $(dirname $0)

if [ ! -f 2000rtp.zip ] ; then
  wget https://cdn.tkool.jp/updata/rtp/2000rtp.zip
fi

if [ ! -d RTP* ] ; then
  unzrip -O Shift_JIS 2000rtp.zip
fi

RTP_EXE=$(find -name RPG2000RTP.exe)

export LANG=ja_JP.UTF-8

if [ ! -v WINEPREFIX ] ; then
  export WINEPREFIX=$HOME/.wine
fi

cp setup.iss "${WINEPREFIX}/drive_c/setup.iss"

wine "${RTP_EXE}" /s /a /s /f1C:\\setup.iss
