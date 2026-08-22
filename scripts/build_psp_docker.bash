#!/usr/bin/env bash

set -euo pipefail

# Build the PSP EBOOT in the same pspdev container CI uses, instead of against a
# locally installed pspdev + the Nix devshell.
#
# Why this exists: the two environments do not produce the same EBOOT. Building
# `master` natively (a local pspdev install, host tools from `nix develop`)
# yielded a binary that halts on an LVGL assert under PPSSPP-headless, while
# CI's container build of the *same commit* boots cleanly -- 23 kernel objects
# and a graceful sceKernelExitGame(), against 55 objects and
# RPG2K_PSP_LVGL_ASSERT. The PSP cross-toolchain is not the variable: the two
# pspdev installs' build manifests ($PSPDEV/build.txt) are byte-for-byte
# identical, down to the same pspsdk commit this repo already pins in
# patches/psp-fixup-imports-jal-relocation-aware.patch. What differs is the
# host half of the build -- the native compiler that builds `mrbc` and mruby's
# other host-side tools, glibc/nix here versus musl/Alpine there. So this
# script is both the way to reproduce a CI EBOOT locally and the A/B control
# for that class of bug (app/psp/README.md's bug 7 was exactly one: a pspdev
# g++ miscompile of std::vector<uint8_t>::assign).
#
# It mirrors `.github/workflows/build.yml`'s `psp` job step for step: same
# image, same apk packages, same Unicode-table plumbing, same
# psp-cmake/cmake --build invocation. Keep the two in sync -- if that job
# grows a step, this needs it too.
#
# Usage:
#   scripts/build_psp_docker.bash [BUILD_DIR]     # default: build-psp-docker
#   CLEAN=1 scripts/build_psp_docker.bash         # wipe BUILD_DIR first
#
#   The default deliberately is *not* `build-psp`, which is where the native
#   build lands: keeping them apart is what lets you boot both EBOOTs under
#   PPSSPP and compare, which is the whole point above. Pass `build-psp`
#   explicitly to match CI's own path.
#
# Needs: docker, curl and python3 on the host. Everything else -- the PSP
# toolchain, ruby, rake, a native compiler, gperf, bison -- comes from the
# image. Network access is required: apk installs those packages, and
# scripts/build_psp_fixup_imports.bash fetches pspsdk at its pinned commit.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${1:-build-psp-docker}"
IMAGE=pspdev/pspdev:latest
TABLES_DIR=.native-build-tables

cd "$REPO_ROOT"

command -v docker >/dev/null || { echo "docker not found on PATH" >&2; exit 1; }

# The submodules are the EBOOT's actual content (LVGL, mruby, uni-algo); a
# fresh clone leaves them empty and the configure fails on a missing
# CMakeLists rather than on anything to do with this script.
if [ ! -f 3rd/lvgl/CMakeLists.txt ]; then
  echo "3rd/lvgl is empty -- run: git submodule update --init --recursive" >&2
  exit 1
fi

if [ "${CLEAN:-0}" = 1 ]; then
  echo "== wiping $BUILD_DIR"
  rm -rf "${BUILD_DIR:?}"
fi

# mruby-lcf/cp932_to_unicode.rb and mruby-rgss/gen_shinonome_data.rb are
# rake-time generators that read $cp932_table / $jis0208_table. The nix
# devshell sets those from fetchurl derivations; a bare container has neither,
# so fetch them here and verify against flake.nix's own sha256 pins -- same
# approach, and the same two pins, as the `psp` CI job and
# scripts/native-build-without-nix.bash. Downloading on the host rather than
# in the container keeps them cached across runs, and Alpine ships no python3
# to check the hash with anyway.
echo "== Unicode mapping tables"
mkdir -p "$TABLES_DIR"
fetch_table() {
  local url="$1" dest="$2" want="$3"
  if [ ! -s "$dest" ]; then
    curl -fsSL -o "$dest" "$url"
  fi
  local got
  got="$(python3 -c 'import hashlib,base64,sys; print(base64.b64encode(hashlib.sha256(open(sys.argv[1],"rb").read()).digest()).decode())' "$dest")"
  if [ "$got" != "$want" ]; then
    echo "hash mismatch for $dest" >&2
    echo "  flake.nix pins $want" >&2
    echo "  downloaded     $got" >&2
    exit 1
  fi
  echo "$(basename "$dest"): hash matches flake.nix"
}
fetch_table \
  'https://www.unicode.org/Public/MAPPINGS/VENDORS/MICSFT/WindowsBestFit/bestfit932.txt' \
  "$TABLES_DIR/bestfit932.txt" 'JhTP6jXDyGxB0zGYeTqEykTt7jzw7gATphpD+6Ts4zE='
fetch_table \
  'https://www.unicode.org/Public/MAPPINGS/OBSOLETE/EASTASIA/JIS/JIS0208.TXT' \
  "$TABLES_DIR/JIS0208.TXT" 'HFcYcEV/Gcl3IGMfqD7kkVSalroUNtoSlnhqZ9hjLoc='

# -q for the same reason the CI job passes it: an implicit pull from
# `docker run` prints a per-layer progress block, which -q reduces to the
# resolved digest. Worth keeping visible -- pspdev/pspdev is a moving :latest
# tag, so the digest is the only record of which toolchain a build used.
echo "== $IMAGE"
docker pull -q "$IMAGE"

# The container runs as root, so everything it writes into the bind mount --
# BUILD_DIR, and the generated lex.def / y.tab.c and applied patches inside
# 3rd/mruby -- lands root-owned in the working tree. Hand them back at the end
# rather than running as the host user throughout, which would break `apk add`.
echo "== building $BUILD_DIR"
docker run --rm \
  -v "$REPO_ROOT:/src" -w /src \
  -e "cp932_table=/src/$TABLES_DIR/bestfit932.txt" \
  -e "jis0208_table=/src/$TABLES_DIR/JIS0208.TXT" \
  -e "BUILD_DIR=$BUILD_DIR" \
  -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" \
  "$IMAGE" sh -euc '
    apk add --no-cache ruby ruby-rake build-base git gperf bison
    bash scripts/build_psp_fixup_imports.bash
    psp-cmake -S app/psp -B "$BUILD_DIR"
    cmake --build "$BUILD_DIR" -j"$(nproc)"
    chown -R "$HOST_UID:$HOST_GID" "$BUILD_DIR" 3rd/mruby
  '

echo
echo "built $BUILD_DIR/EBOOT.PBP"
ls -la "$BUILD_DIR/EBOOT.PBP"
