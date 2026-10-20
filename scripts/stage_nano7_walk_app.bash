#!/usr/bin/env bash

set -eu -o pipefail

# Stage the iPod nano 7G map-walk app into a NanoApps checkout, ready to
# build there (see app/nano7/rpg2k_walk/README.md and docs/adr/0061).
#
# Two directories go into one: the NanoApps half of the app
# (app/nano7/rpg2k_walk) and the shared engine core it runs
# (app/shared/rpg2k_walk, which the Wio Terminal walk firmware runs too, see
# docs/adr/0091). NanoApps builds an app from inside its own tree and
# sdk/hb_app.mk resolves SRCS relative to the app directory, so the core has
# to be copied in beside the app rather than referenced where it lives.
#
# Copies, never symlinks: a symlinked app directory resolves
# ../../sdk/hb_app.mk against the physical path, which lands outside NanoApps
# and fails.
#
# Usage:
#   scripts/stage_nano7_walk_app.bash /path/to/NanoApps
#   cd /path/to/NanoApps && ./start build rpg2k_walk

if [ $# -ne 1 ] ; then
    echo "usage: $0 /path/to/NanoApps" >&2
    exit 1
fi

nanoapps=$1
if [ ! -f "$nanoapps/sdk/hb_app.mk" ] ; then
    echo "$nanoapps does not look like a NanoApps checkout (no sdk/hb_app.mk)" >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
dest=$nanoapps/apps/rpg2k_walk

mkdir -p "$dest"
cp "$root"/app/nano7/rpg2k_walk/Makefile \
   "$root"/app/nano7/rpg2k_walk/Info.plist \
   "$root"/app/nano7/rpg2k_walk/rpg2k_walk.c \
   "$root"/app/shared/rpg2k_walk/rpg2k_walk_core.c \
   "$root"/app/shared/rpg2k_walk/rpg2k_walk_core.h \
   "$dest"

echo "staged $dest -- build it with: (cd $nanoapps && ./start build rpg2k_walk)"
