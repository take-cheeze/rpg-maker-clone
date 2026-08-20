#!/usr/bin/env bash

set -euo pipefail

# Idempotently apply a patch to the 3rd/mruby submodule checkout, as part of
# the mruby build (see cmake/build-mruby.cmake). A plain `patch -p1` call
# embedded directly in a CMake COMMAND is fragile to quote/escape across
# platforms once it needs a dry-run-first idempotency check (`>/dev/null 2>&1`
# inside a `sh -c "..."` string does not survive CMake's own command-line
# escaping reliably), so this is a real script instead, the same reasoning
# scripts/build_psp_fixup_imports.bash already applies for the PSP toolchain
# patch. Unlike that one, this patches a persistent, in-tree submodule
# checkout rather than a scratch clone, so it must be safe to run on every
# configure/build without re-cloning: a dry run first decides whether the
# patch still needs applying (already applied, or genuinely fails to apply
# because upstream mruby moved the patched code -- either way, do nothing and
# say why) before ever touching the working tree, so a real apply attempt
# never gets far enough to leave a stray *.rej file behind.
#
# Usage: apply_mruby_patch.bash MRUBY_DIR PATCH_FILE

if [ "$#" -ne 2 ]; then
  echo "usage: $0 MRUBY_DIR PATCH_FILE" >&2
  exit 1
fi

MRUBY_DIR="$1"
PATCH_FILE="$2"

cd "$MRUBY_DIR"

if patch -p1 -N --dry-run -s <"$PATCH_FILE" >/dev/null 2>&1; then
  patch -p1 -N -s <"$PATCH_FILE"
  echo "apply_mruby_patch: applied $(basename "$PATCH_FILE")"
elif patch -p1 -R -N --dry-run -s <"$PATCH_FILE" >/dev/null 2>&1; then
  : # Already applied (reverse-applies cleanly) -- nothing to do.
else
  echo "apply_mruby_patch: $(basename "$PATCH_FILE") no longer applies" \
       "cleanly to $MRUBY_DIR (upstream mruby likely moved) -- the fix it" \
       "carries is NOT in effect; see the patch file's own preamble" >&2
  exit 1
fi
