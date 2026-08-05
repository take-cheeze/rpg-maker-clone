#!/usr/bin/env bash

set -eux -o pipefail

# Retried because these external clones fail intermittently in CI.
. "$(dirname "$0")/git-clone-retry.bash"

# Fetch the MIT-licensed community RPG Maker MV corescript and build the engine
# files into the committed sample project (data/mv-sample). The sample commits
# only our authored data + shell; the engine (js/rpg_core.js ... and js/libs/*)
# is fetched here so it is never redistributed by this repository. See
# data/mv-sample/README.md.
#
# rpgtkoolmv/corescript stores the engine as many small modules and builds each
# single-file rpg_*.js by concatenating them in the order listed in
# <module>.json (its concat.js does the same). We replicate that with a short
# Python pass so no Node/npm is needed.

here="$(cd "$(dirname "$0")/.." && pwd)"
sample="$here/data/mv-sample"
cache="$here/data/.mv-corescript"

if [ ! -d "$cache" ]; then
    clone_retry --quiet --depth 1 https://github.com/rpgtkoolmv/corescript.git "$cache"
fi

mkdir -p "$sample/js/libs"

python3 - "$cache" "$sample/js" <<'PY'
import json
import os
import sys

cache, outdir = sys.argv[1], sys.argv[2]
for module in json.load(open(os.path.join(cache, "modules.json"))):
    order = json.load(open(os.path.join(cache, module + ".json")))
    parts = []
    for rel in order:
        with open(os.path.join(cache, rel), encoding="utf-8") as f:
            parts.append(f.read())
    with open(os.path.join(outdir, module + ".js"), "w", encoding="utf-8") as f:
        f.write("\n".join(parts))
    print("built %s.js from %d files" % (module, len(order)))
PY

cp "$cache"/js/libs/*.js "$sample/js/libs/"
echo "MV corescript ready in $sample/js"
