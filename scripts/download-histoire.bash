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
# as download-yumenikki.bash: `unar` 1.10.1 mishandles this archive family --
# confirmed again here (`unar -e cp932`, kk1.12's own flag, still drops 301 of
# this archive's entries, mostly Map*.lmu, the same "Attempted to read more
# data than was available" failure yumenikki hits). Unlike that script, no
# `w=` override is needed -- the archive's own single top-level directory is
# already `histoire203`.
#
# Unlike `unar -e cp932`, `lha` has no filename-transcoding option at all
# (bare `lha` prints its whole usage banner, no `-e`/`--help` among it): every
# non-ASCII entry -- 208 of them here, System/ChipSet/CharSet/Picture art
# named in Japanese -- lands with its raw Shift_JIS bytes as the on-disk
# name, byte-identical mojibake to a UTF-8 tool or terminal. Booting the real
# engine against a first `lha`-only extraction (`rpg2k_boot_check.bash`)
# proved this is not cosmetic: the LDB's own chipset/windowskin references are
# genuine UTF-8 (cp932-decoded by the engine, like every other string it
# reads), so they never match a raw-bytes filename, and every one of those
# 208 assets logged "not found" and fell back to the no-RTP degrade path
# (colour-block tiles, a plain window panel) even though the file is right
# there on disk. `fix_cp932_names` repairs it in place: Python's `os.walk`
# already hands back each name run through `os.fsdecode` (surrogateescape on
# an undecodable byte), so `os.fsencode` recovers the exact original bytes to
# re-decode as cp932, bottom-up so a renamed directory's own children are
# already settled before it moves. A name that is not valid cp932 (none here,
# but an archive could mix in genuine ASCII/UTF-8 entries) is left alone.
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
    python3 - <<'PY'
import os


def cp932_name(name):
    try:
        return os.fsencode(name).decode('cp932')
    except UnicodeDecodeError:
        return name


renamed = 0
for dirpath, _dirnames, filenames in os.walk('histoire203', topdown=False):
    for name in filenames:
        decoded = cp932_name(name)
        if decoded != name:
            os.rename(os.path.join(dirpath, name), os.path.join(dirpath, decoded))
            renamed += 1
    base = os.path.basename(dirpath)
    decoded = cp932_name(base)
    if decoded != base:
        os.rename(dirpath, os.path.join(os.path.dirname(dirpath), decoded))
        renamed += 1
print(f'fix_cp932_names: renamed {renamed} entries')
PY
fi
