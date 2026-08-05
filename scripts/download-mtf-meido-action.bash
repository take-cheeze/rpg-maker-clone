#!/usr/bin/env bash

# RPG Maker 2000 test-bed game (non-EasyRPG), hosted on GitHub so it is
# reachable from sandboxed/proxied environments where the tkool CDN is blocked.
# After running, the game directory is:
#   data/mtf-meido-action/Debug
# which contains RPG_RT.ldb / RPG_RT.lmt / RPG_RT.ini and Map0001..0013.lmu.

set -eux -o pipefail

# Retried because these external clones fail intermittently in CI.
. "$(dirname "$0")/git-clone-retry.bash"

mkdir -p $(dirname $0)/../data

cd $(dirname $0)/../data

if [ ! -d mtf-meido-action ] ; then
    clone_retry --quiet --depth 1 --filter=blob:none --sparse \
        https://github.com/lychees/mtf-meido-action.git
    git -C mtf-meido-action sparse-checkout set Debug
fi
