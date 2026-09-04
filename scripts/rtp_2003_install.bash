#!/usr/bin/env bash

set -eux

# Routes through the optional CI CORS proxy cache when CORS_PROXY_URL is set.
. "$(dirname "$0")/cors-proxy-url.bash"

cd $(dirname $0)

# See rtp_install.bash for why wget/unar are quietened.
if [ ! -f 2003rtp.zip ] ; then
  wget -nv -O 2003rtp.zip "$(proxied_url "https://cdn.tkool.jp/updata/rtp/2003rtp.zip")"
fi

if [ ! -d 2003RTP* ] ; then
  unar -q -e cp932 2003rtp.zip
fi

if [ ! -f RPG2003RTP.exe ] ; then
  RTP_EXE=$(find 2003RTP* -name RPG2003RTP.exe)
  cp ${RTP_EXE} ./RPG2003RTP.exe
fi

if [ ! -v WINEPREFIX ] ; then
  export WINEPREFIX=$HOME/.wine
fi

RTP_INSTALL_DIR="${WINEPREFIX}/drive_c/Program Files (x86)/Enterbrain/RPG2003"

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
# Unlike XP's installer, this one is not a copy of 2000's InstallShield
# project: a different component GUID, a different default install directory,
# and a different registry key (confirmed by extracting the installer's own
# compiled script and by a real install under wine: it writes
# Software\Enterbrain\RPG2003\RuntimePackagePath, not 2000's
# Software\ASCII\RPG2000 one), so it needs its own response file rather than
# reusing setup.iss.
cp setup_2003.iss "${WINEPREFIX}/drive_c"

wine ./RPG2003RTP.exe /s /a /s /sms /f1C:\\setup_2003.iss

ls "${RTP_INSTALL_DIR}"

kill %1
