#!/usr/bin/env bash

set -euo pipefail

# Prove that cmake/emscripten-probe-cache.cmake still says what the toolchain
# says.
#
# The seeded answers are only guarded by the Emscripten *version*, so they
# cannot go silently wrong across a release bump -- the guard falls back to
# probing. What the guard cannot see is the sysroot changing underneath the same
# version (a nixpkgs rebuild, a patched emscripten), or a 3rd/ submodule growing
# a check whose answer the seed happens to already carry from an older tree. In
# both cases the version still matches and the stale value is used.
#
# So: configure once with the seed disabled, which runs every probe for real,
# regenerate the file from that build tree, and diff it against the committed
# one. Any drift at all is a hard failure with the regeneration command in the
# message, because a wrong answer here silently changes what ng-log compiles.
#
# This costs a full ~110s probing configure, which is exactly the cost the seed
# exists to avoid -- so CI runs it as a `background: true` step alongside the
# wasm build rather than in front of it, and it stays off the critical path.

cd "$(dirname "$0")/.."

cache_file="cmake/emscripten-probe-cache.cmake"
build_dir="$(mktemp -d)"
expected="$(mktemp)"
trap 'rm -rf "$build_dir" "$expected"' EXIT

echo "re-probing the toolchain (seed disabled) ..."
emcmake cmake -S . -B "$build_dir" -GNinja -DEMSCRIPTEN_PROBE_CACHE=OFF >/dev/null

# Regenerate through the same generator that produced the committed file, so a
# difference can only mean the *answers* moved, never the formatting.
ruby scripts/gen_emscripten_probe_cache.rb "$build_dir/CMakeCache.txt" >"$expected"

if diff -u "$cache_file" "$expected"; then
    echo "ok: $cache_file matches the toolchain"
    exit 0
fi

# The diff above is the actionable part of the failure; keep it in the log and
# add a GitHub annotation so it surfaces on the pull request too.
echo "::error::$cache_file no longer matches the Emscripten toolchain."
cat >&2 <<EOF

The pre-seeded probe answers have drifted from what this toolchain reports, so
the wasm build is configuring with stale values. Regenerate them:

  emcmake cmake -S . -B /tmp/wasm-probe -GNinja -DEMSCRIPTEN_PROBE_CACHE=OFF
  scripts/gen_emscripten_probe_cache.rb /tmp/wasm-probe/CMakeCache.txt \\
    > $cache_file

EOF
exit 1
