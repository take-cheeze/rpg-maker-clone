#!/usr/bin/env bash

# Boot the MZ test bed with its assets **encrypted**, the way a deployed game
# ships them.
#
# This is a different loading path from every other MZ check, not a variation on
# one. With "Encrypt Images" ticked — which both games sampled from freem had —
# nothing is ever opened by name: the engine XHRs `img/x.png_` as an
# ArrayBuffer, decrypts it in its own JavaScript, wraps the plaintext in a
# `Blob` and hands the object URL to an `Image`. A host missing `Blob` or
# `URL.createObjectURL` cannot load a single asset, and the boot dies in
# Scene_Boot with a black screen — which is what every encrypted game did here
# until M6.3r.
#
# The encrypted project is *derived* rather than committed (see
# scripts/gen-mz-encrypted.py): it is byte-for-byte as large as the plain bed,
# and deriving it keeps scripts/gen-mz-sample.py the single source of truth for
# what the bed contains.
#
# `play` mode is the right check here because it asserts the whole chain — the
# map is reached *and* a held key walks the player — and the frame check that
# follows proves the art actually decoded rather than resolving to the empty
# bitmap a failed load falls back to.
#
# Usage: mz_encrypted_check.bash [server_num] [src_project] [dst_project]

set -eu -o pipefail

cd "$(dirname "$0")/.."

SERVER_NUM="${1:-113}"
SRC="${2:-data/mz-sample}"
DST="${3:-build/mz-sample-encrypted}"

if [ ! -f "${SRC}/js/rmmz_core.js" ] ; then
    echo "skip ${SRC}: no js/rmmz_core.js (run scripts/download-mz-corescript.bash first)"
    exit 0
fi

python3 scripts/gen-mz-encrypted.py "${SRC}" "${DST}"

MZ_SCREENSHOT="${MZ_SCREENSHOT:-ss/mz_encrypted.png}" \
    MZ_MODE=play ./scripts/mz_boot_check.bash "${SERVER_NUM}" "${DST}"

# The picture is the half the log cannot make: a project whose images silently
# failed to decrypt still reaches the map and still reports `moved=true`, it
# just draws nothing (a failed image load resolves to a 1x1 transparent bitmap).
ruby scripts/mz_frame_check.rb --frame "${MZ_SCREENSHOT:-ss/mz_encrypted.png}"
