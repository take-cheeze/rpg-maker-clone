#!/usr/bin/env bash

set -eu -o pipefail

# Initializes every submodule this checkout declares except the ones named in
# $SKIP_SUBMODULES (space-separated paths, e.g. "3rd/optcarrot").
#
# actions/checkout's own `submodules: recursive` has no way to leave individual
# entries out, so every job that used it cloned all sixteen -- including
# the largest vendored trees, on jobs that never build them. SDL itself is not
# a submodule any more: the Android branch of CMakeLists.txt downloads the
# pinned release tarball at configure time. Every other target either
# `find_package(SDL2)`s a system/nix package (the native `build`/`bc2cpp-*`
# jobs) or gets it as an Emscripten port (`wasm`, `-sUSE_SDL=2`), and the
# PlatformIO-driven embedded ports (wio/maix/psp/m5stack) never touch SDL. Same idea for 3rd/optcarrot: nothing in
# CMakeLists.txt references it, and only the `bc2cpp-checks` jobs' Optcarrot
# benchmark (tools/optcarrot_probe/) reads it.
#
# Run after a checkout with `submodules: false`, so this is the only thing
# that populates 3rd/.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

paths="$(git config --file .gitmodules --get-regexp '\.path$' | awk '{print $2}')"

init=()
for path in ${paths}; do
  skip_it=0
  for skip in ${SKIP_SUBMODULES:-}; do
    if [ "${path}" = "${skip}" ]; then
      skip_it=1
      break
    fi
  done
  if [ "${skip_it}" = 0 ]; then
    init+=("${path}")
  fi
done

echo "initializing: ${init[*]}"
# RECURSIVE=1 also initialises each submodule's own submodules (e.g. the
# external/ libraries of a vendored dependency). Nix's `?submodules=1` walk reads those too, so the
# flake job sets it. quickjs-ng's test262 entry is `update = none`, so this
# still leaves it out.
recursive=()
if [ "${RECURSIVE:-}" = 1 ]; then
  recursive=(--recursive)
  # 3rd/nfcxx is here for bc2cpp (its bc2cpp/ tree) only; its own submodules (the EDG front end, ~200 MB, QBE, cproc)
  # are its compiler's. They are marked `update = none` in that checkout before the recursive pass, so it leaves them
  # out the way it leaves out quickjs's test262 (scripts/skip-nfcxx-submodules.bash drops the entries for Nix).
  for path in "${init[@]}"; do
    if [ "${path}" = 3rd/nfcxx ]; then
      git submodule update --init --depth 1 -- 3rd/nfcxx
      for name in $(git -C 3rd/nfcxx config --file .gitmodules --get-regexp '\.path$' | awk '{print $1}' |
                    sed -e 's/^submodule\.//' -e 's/\.path$//'); do
        git -C 3rd/nfcxx config "submodule.${name}.update" none
      done
    fi
  done
fi

git submodule update --init --depth 1 "${recursive[@]}" -- "${init[@]}"
