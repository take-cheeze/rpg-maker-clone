#!/usr/bin/env bash

# RPG Maker 2000 test-bed game: Yume Nikki, version 0.10 -- Kikiyama's first
# public release, freeware, hosted on Vector (a long-running Japanese
# shareware/freeware archive). Distributed as a self-extracting .lzh, which
# `unar` (already relied on for the Nepheshel/Pray-for-You .zip archives)
# reads natively.
#
# `-o yumenikki0.10` pins the extraction target to a fixed directory name for
# the idempotency check below, regardless of whatever top-level layout the
# archive itself uses -- the LCF/rpg2k checks that consume test-bed games
# (lcf_testbed_check.rb, rpg2k_testbed_logic_check.rb, ...) find RPG_RT.ldb by
# scanning ./data recursively, so the exact nesting under this directory does
# not matter to them.
#
# See download-nepheshel.bash for why wget/unar are quietened.

set -eux -o pipefail

# Routes through the optional CI CORS proxy cache when CORS_PROXY_URL is set.
. "$(dirname "$0")/cors-proxy-url.bash"

mkdir -p $(dirname $0)/../data

cd $(dirname $0)/../data

if [ ! -f yumenikki0.10.lzh ] ; then
    wget -nv -O yumenikki0.10.lzh "$(proxied_url "https://ftp.vector.co.jp/43/88/3084/yumenikki0.10.lzh")"
fi

if [ ! -d yumenikki0.10 ] ; then
    unar -q -o yumenikki0.10 yumenikki0.10.lzh
fi
