#!/usr/bin/env bash

set -eux

# Routes through the optional CI CORS proxy cache when CORS_PROXY_URL is set.
. "$(dirname "$0")/cors-proxy-url.bash"

cd $(dirname $0)

# ~186 MiB -- by far the largest of the RTP downloads (2000/2003/XP/VX are all
# under 40 MiB) since VX Ace's RTP audio ships as .ogg rather than .mid. See
# rtp_install.bash for why wget/unar are quietened.
if [ ! -f vxace_rtp100.zip ] ; then
  wget -nv -O vxace_rtp100.zip "$(proxied_url "https://cdn.tkool.jp/updata/rtp/vxace_rtp100.zip")"
fi

if [ ! -d RPGVXAce_RTP100 ] ; then
  unar -q -e cp932 vxace_rtp100.zip
fi

if [ ! -v WINEPREFIX ] ; then
  export WINEPREFIX=$HOME/.wine
fi

# Same Inno Setup installer technology as XP's and VX's (see
# rtp_xp_install.bash / rtp_vx_install.bash), so no custom InstallShield
# response file is needed here -- just /verysilent.
RTP_INSTALL_DIR_X86="${WINEPREFIX}/drive_c/Program Files (x86)/Common Files/Enterbrain/RGSS3/RPGVXAce"
RTP_INSTALL_DIR="${WINEPREFIX}/drive_c/Program Files/Common Files/Enterbrain/RGSS3/RPGVXAce"

# A cached WINEPREFIX (see the CI workflow's "cache wine prefix" step) already
# has the RTP installed, so skip the wine round-trip entirely and just verify
# it landed.
if [ -d "${RTP_INSTALL_DIR_X86}" ] || [ -d "${RTP_INSTALL_DIR}" ] ; then
  ls "${RTP_INSTALL_DIR_X86}" || ls "${RTP_INSTALL_DIR}"
  exit 0
fi

export DISPLAY=:1024
Xvfb "${DISPLAY}" -screen 0 1920x1080x24 &

export WINEDLLOVERRIDES="mscoree,mshtml="
export LC_ALL=ja_JP.UTF-8
# Drop wine's `fixme:` stub chatter; `err:`/`warn:` still print. See
# rtp_install.bash.
export WINEDEBUG=fixme-all

winecfg /v win10

wine ./RPGVXAce_RTP100/Setup.exe /verysilent

ls "${RTP_INSTALL_DIR_X86}" || ls "${RTP_INSTALL_DIR}"

kill %1
