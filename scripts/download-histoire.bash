#!/usr/bin/env bash

# RPG2000-format test-bed game: イストワール (Histoire), version 2.03,
# freeware, hosted on Vector (a long-running Japanese shareware/freeware
# archive) like download-yumenikki.bash's game. Distributed as an `.lzh`.
#
# By far the largest test bed here: 774 maps (RPG_RT.lmt tops out at
# Map0794.lmu), 20448 events and 149967 move commands, against Nepheshel's
# ~250 maps and mtf-meido-action's single Debug map -- a genuine stress case
# for anything that assumes a small map/event table. lcf_testbed_check.rb
# parses all of it cleanly; rpg2k_testbed_logic_check.rb needed three of its
# own checks widened for real data this big turned up for the first time (a
# menu-invisible switch skill meant only for a map/battle event's Force Skill
# Use, a blank unused item-table row left over from editing 610 items, and a
# sealing state whose restrict_skill and restrict_magic thresholds are both 0
# -- a total-paralysis status, not a Silence) -- see that file's own comments
# at each site.
#
# Extracted with `lha` (the `lhasa` package), not `unar`, for the same reason
# as download-yumenikki.bash: `unar` 1.10.1 mishandles this archive family.
# Unlike that script, no `w=` override is needed -- the archive's own single
# top-level directory is already `histoire203`.
#
# See download-nepheshel.bash for why wget is quietened; `lha`'s own `q2`
# mirrors that for extraction.

set -eux -o pipefail

# Routes through the optional CI CORS proxy cache when CORS_PROXY_URL is set.
. "$(dirname "$0")/cors-proxy-url.bash"

mkdir -p $(dirname $0)/../data

cd $(dirname $0)/../data

if [ ! -f histoire203.lzh ] ; then
    wget -nv -O histoire203.lzh "$(proxied_url "https://ftp.vector.co.jp/34/63/3171/histoire203.lzh")"
fi

if [ ! -d histoire203 ] ; then
    lha xq2 histoire203.lzh
fi
