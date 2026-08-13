#!/usr/bin/env bash

# RPG2000-format test-bed game: Yume Nikki, version 0.10 -- Kikiyama's first
# public release, freeware, hosted on Vector (a long-running Japanese
# shareware/freeware archive). Distributed as an `.lzh`. Its RPG_RT.ldb is
# actually RPG Maker **2003** data (lcf_testbed_check.rb's own edition
# detection says so), same LCF format as the RPG2000 test beds beside it.
#
# Extracted with `lha` (the `lhasa` package), not `unar`: `unar` 1.10.1 reads
# this specific lh5 archive's directory silently wrong -- it reports "Failed!
# (Attempted to read more data than was available)" for about a third of the
# entries and, worse, still exits leaving *zero-byte* files behind for them
# rather than skipping them, so a check that only tests for the file's
# existence never notices half the maps came out empty. `lha` extracts every
# entry, byte-for-byte, with no such failures.
#
# `w=yumenikki0.10` pins the extraction target to a fixed directory name for
# the idempotency check below, regardless of whatever top-level layout the
# archive itself uses -- the LCF/rpg2k checks that consume test-bed games
# (lcf_testbed_check.rb, rpg2k_testbed_logic_check.rb, ...) find RPG_RT.ldb by
# scanning ./data recursively, so the exact nesting under this directory does
# not matter to them.
#
# See download-nepheshel.bash for why wget is quietened; `lha`'s own `q2`
# mirrors that for extraction.

set -eux -o pipefail

# Routes through the optional CI CORS proxy cache when CORS_PROXY_URL is set.
. "$(dirname "$0")/cors-proxy-url.bash"

mkdir -p $(dirname $0)/../data

cd $(dirname $0)/../data

if [ ! -f yumenikki0.10.lzh ] ; then
    wget -nv -O yumenikki0.10.lzh "$(proxied_url "https://ftp.vector.co.jp/43/88/3084/yumenikki0.10.lzh")"
fi

if [ ! -d yumenikki0.10 ] ; then
    lha xq2w=yumenikki0.10 yumenikki0.10.lzh
fi
