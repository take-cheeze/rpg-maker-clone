#!/usr/bin/env bash

set -eu -o pipefail

# Smoke test for app/nano7/host (docs/adr/0102): export a real map, run the
# host build of the iPod nano 7G walk app against it, and check the result
# actually shows a real map rather than a blank/flat frame.
#
# Run via CTest as `nano7_host_smoke` (CMakeLists.txt passes the built
# nano7_walk_host executable's path as $1); can also be run by hand:
#   scripts/nano7_host_smoke.bash ./build/nano7_walk_host

if [ $# -ne 1 ]; then
    echo "usage: $0 /path/to/nano7_walk_host" >&2
    exit 1
fi

nano7_walk_host=$1
root=$(cd "$(dirname "$0")/.." && pwd)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

data_dir="$tmp/Apps/Data/RPG2kWalk"
mkdir -p "$data_dir"

ruby "$root/scripts/export_nano7_map.rb" --target nano7 \
    "$root/data/Nepheshel206beta/Nepheshel206Nbeta" 1 "$data_dir"

"$nano7_walk_host" "$tmp" --frames 60 --screenshot "$tmp/frame.bmp"

ruby "$root/scripts/nano7_host_smoke_check.rb" "$tmp/frame.bmp"
