#!/usr/bin/env bash

set -eu -o pipefail

# Initializes every submodule this checkout declares except the ones named in
# $SKIP_SUBMODULES (space-separated paths, e.g. "3rd/SDL 3rd/SDL_mixer").
#
# actions/checkout's own `submodules: recursive` has no way to leave individual
# entries out, so every job that used it cloned all sixteen -- including
# 3rd/SDL and 3rd/SDL_mixer, two of the largest, on jobs that never build them:
# CMakeLists.txt only `add_subdirectory(3rd/SDL...)`s under the Android branch
# (no system SDL2 package exists for an APK to link against there); every
# other target either `find_package(SDL2)`s a system/nix package (the native
# `build`/`bc2cpp-*` jobs) or gets it as an Emscripten port (`wasm`,
# `-sUSE_SDL=2`), and the PlatformIO-driven embedded ports (wio/maix/psp/
# m5stack) never touch SDL at all. Same idea for 3rd/optcarrot: nothing in
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
git submodule update --init --depth 1 -- "${init[@]}"
