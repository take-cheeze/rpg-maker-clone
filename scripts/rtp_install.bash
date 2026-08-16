#!/usr/bin/env bash

set -eux

# Routes through the optional CI CORS proxy cache when CORS_PROXY_URL is set.
. "$(dirname "$0")/cors-proxy-url.bash"

cd $(dirname $0)

# `wget -nv` / `unar -q`: without a terminal wget still prints a dot-progress
# line per 50 KiB and unar names every file it extracts — the RTP archive alone
# is thousands of lines of CI log. Errors and the final summary still print.
if [ ! -f 2000rtp.zip ] ; then
  wget -nv -O 2000rtp.zip "$(proxied_url "https://cdn.tkool.jp/updata/rtp/2000rtp.zip")"
fi

if [ ! -d RTP* ] ; then
  unar -q -e cp932 2000rtp.zip
fi

if [ ! -f RTP2000RTP.exe ] ; then
  RTP_EXE=$(find RTP* -name RPG2000RTP.exe)
  cp ${RTP_EXE} ./RPG2000RTP.exe
fi

if [ ! -v WINEPREFIX ] ; then
  export WINEPREFIX=$HOME/.wine
fi

RTP_INSTALL_DIR="${WINEPREFIX}/drive_c/Program Files (x86)/ASCII"

# A cached WINEPREFIX (see the CI workflow's "cache wine prefix" step) already
# has the RTP installed, so skip the wine round-trip entirely and just verify
# it landed.
if [ -d "${RTP_INSTALL_DIR}" ] ; then
  ls "${RTP_INSTALL_DIR}"
  exit 0
fi

export DISPLAY=:1024
Xvfb "${DISPLAY}" -screen 0 1920x1080x24 &

export WINEDLLOVERRIDES="mscoree,mshtml="
export LC_ALL=ja_JP.UTF-8
# Silence wine's `fixme:` channel only — unimplemented-stub chatter that says
# nothing about this install. `err:`/`warn:` still print, and the `ls` below
# still fails the script if the RTP did not land.
export WINEDEBUG=fixme-all

winecfg /v win10
cp setup.iss "${WINEPREFIX}/drive_c"

wine ./RPG2000RTP.exe /s /a /s /sms /f1C:\\setup.iss

ls "${RTP_INSTALL_DIR}"

kill %1
