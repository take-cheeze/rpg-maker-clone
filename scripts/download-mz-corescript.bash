#!/usr/bin/env bash

set -eux -o pipefail

# Retried because these external clones fail intermittently in CI.
. "$(dirname "$0")/git-clone-retry.bash"

# Fetch the RPG Maker MZ corescript (rmmz_*.js + libs/pixi.js ...) into the
# committed sample project (data/mz-sample). The sample commits only our
# authored data + shell; the engine is fetched here so it is never redistributed
# by this repository — the same arrangement as data/mv-sample and the fetched
# RPG2k/XP test-bed games. See data/mz-sample/README.md.
#
# Unlike MV — whose corescript is KADOKAWA's official MIT release
# (rpgtkoolmv/corescript) — MZ has no official open-source engine, so we fetch a
# community mirror (stak/rmmz-corescript). It carries no separate licence file;
# the rmmz engine is © Gotcha Gotcha Games / KADOKAWA and is used here only as a
# fetched, uncommitted test fixture (CI-only), exactly like the proprietary
# RPG2k/XP games the other beds download.

here="$(cd "$(dirname "$0")/.." && pwd)"
sample="$here/data/mz-sample"
cache="$here/data/.mz-corescript"

if [ ! -d "$cache" ]; then
    clone_retry --quiet --depth 1 https://github.com/stak/rmmz-corescript.git "$cache"
fi

mkdir -p "$sample/js/libs"

# The engine modules and the entry loader (main.js), verbatim.
for f in rmmz_core.js rmmz_managers.js rmmz_objects.js rmmz_scenes.js \
         rmmz_sprites.js rmmz_windows.js main.js; do
    cp "$cache/$f" "$sample/js/$f"
done

# The vendored libraries (PIXI v5, pako, localforage, effekseer, vorbis).
cp "$cache"/libs/*.js "$sample/js/libs/"
# effekseer.wasm is a binary blob only needed for battle animations; the boot
# path (Graphics.effekseer) guards on it, so copy it when present but do not
# require it.
cp "$cache"/libs/effekseer.wasm "$sample/js/libs/" 2>/dev/null || true

echo "MZ corescript ready in $sample/js"
