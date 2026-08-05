#!/usr/bin/env bash

# RPG Maker XP test-bed project (non-EasyRPG), hosted on GitHub so it is
# reachable from sandboxed/proxied environments where the tkool CDN is blocked.
# After running, the game directory is:
#   data/OpenGame.exe/Testbed/XP
# which contains a full Data/*.rxdata set (Scripts, System, Actors, Map001, ...).

set -eux -o pipefail

# Retried because these external clones fail intermittently in CI.
. "$(dirname "$0")/git-clone-retry.bash"

mkdir -p $(dirname $0)/../data

cd $(dirname $0)/../data

if [ ! -d OpenGame.exe ] ; then
    clone_retry --quiet --depth 1 --filter=blob:none --sparse \
        https://github.com/aphadeon/OpenGame.exe.git
    git -C OpenGame.exe sparse-checkout set Testbed/XP
fi
