#!/usr/bin/env bash

set -euo pipefail

# Build a patched replacement for pspdev's psp-fixup-imports (a host tool the
# PSP CMake toolchain runs automatically after linking rpg2k_psp), and drop it
# wherever the caller wants it -- normally straight over the pspdev
# installation's own bin/psp-fixup-imports, so the rest of the build (an
# unmodified `psp-cmake` + `cmake --build`) picks it up transparently.
#
# Why: the stock tool requires every call site referencing a given PSP module
# to already be physically contiguous in the linked binary's import metadata,
# which this project's main.cxx's own (entirely ordinary) control flow does
# not satisfy -- see patches/psp-fixup-imports-jal-relocation-aware.patch's
# own preamble and docs/adr/0047-psp-memory-budget.md's P1 for the full
# story. Without this, the EBOOT links and packs fine but several genuine,
# correctly-named PSP imports silently resolve to the wrong module at
# runtime, which is what actually stopped this port's EBOOT from booting to
# completion under PPSSPP-headless.
#
# Usage:
#   scripts/build_psp_fixup_imports.bash [OUTPUT_PATH]
#     OUTPUT_PATH defaults to $PSPDEV/bin/psp-fixup-imports, i.e. "replace the
#     toolchain's own copy in place". $PSPDEV is pspdev's own standard
#     installation-root variable, so keying on it puts the patched tool on
#     whichever SDK the build actually invokes: pspdev/pspdev:latest exports
#     PSPDEV=/usr/local/pspdev, so the psp CI job (see
#     .github/workflows/build.yml) resolves exactly the path this used to
#     hardcode, while a native SDK gets its own root -- this repo's .envrc
#     exports PSPDEV=$HOME/dev/pspdev. Hardcoding the container path instead
#     meant a native toolchain silently kept the *stock* psp-fixup-imports:
#     the script reported success, having installed into a /usr/local/pspdev
#     nothing in the build ever reads, and the EBOOT it then produced had the
#     misordered imports this whole patch exists to prevent.
#
#     Falls back to /usr/local/pspdev when $PSPDEV is unset, so a bare
#     `docker run` that skips the image's environment still works.
#
# Needs: git, a native (host) C compiler (`cc`), and network access to
# github.com. The pspdev/pspdev image ships neither by default; `apk add
# --no-cache git build-base` first (build-base is already an existing build
# dependency for the psp CI job's mruby host cross-build -- see
# .github/workflows/build.yml -- so this rarely needs installing twice).

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHES_DIR="$REPO_ROOT/patches"
PSPDEV_ROOT="${PSPDEV:-/usr/local/pspdev}"
OUTPUT_PATH="${1:-$PSPDEV_ROOT/bin/psp-fixup-imports}"

# Pinned in patches/psp-fixup-imports-jal-relocation-aware.patch's own
# preamble too; keep the two in sync if this ever moves. Confirmed (by
# disassembling and comparing object files) to match what pspdev/pspdev:latest's
# own prebuilt psp-fixup-imports binary was built from at the time this was
# written -- pspdev/pspdev is a moving `:latest` tag, so a future image update
# could in principle drift from this pin; if the patch stops applying cleanly,
# that drift is why.
PSPSDK_COMMIT=314b2083f2e1eaf145fc5de342736336fe1f0148

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

git init -q "$WORK_DIR"
git -C "$WORK_DIR" remote add origin https://github.com/pspdev/pspsdk.git
git -C "$WORK_DIR" fetch -q --depth 1 origin "$PSPSDK_COMMIT"
git -C "$WORK_DIR" checkout -q FETCH_HEAD

patch -p1 -d "$WORK_DIR" < "$PATCHES_DIR/psp-fixup-imports-jal-relocation-aware.patch"

# tools/types.h #includes "config.h" unconditionally (not HAVE_CONFIG_H-
# guarded), so it has to be named exactly that on the include path -- copy
# rather than rename the vendored copy in patches/, since "config.h" alone
# would be a confusing name to find sitting in that directory.
cp "$PATCHES_DIR/psp-fixup-imports-config.h" "$WORK_DIR/config.h"

cc -O2 -DHAVE_CONFIG_H \
  -I"$WORK_DIR" \
  -I"$WORK_DIR/tools" \
  -o "$WORK_DIR/psp-fixup-imports" \
  "$WORK_DIR/tools/psp-fixup-imports.c" \
  "$WORK_DIR/tools/getopt_long.c" \
  "$WORK_DIR/tools/sha1.c"

mkdir -p "$(dirname "$OUTPUT_PATH")"
install -m 755 "$WORK_DIR/psp-fixup-imports" "$OUTPUT_PATH"
echo "Built patched psp-fixup-imports -> $OUTPUT_PATH" >&2
