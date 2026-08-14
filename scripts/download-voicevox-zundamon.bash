#!/usr/bin/env bash

set -eu -o pipefail

# Fetch a fully offline VOICEVOX synthesis stack into assets/voicevox, where
# src/voicevox_tts.cxx looks for it: the VOICEVOX CORE C API shared library,
# its ONNX Runtime, the Open JTalk dictionary it uses for Japanese text
# analysis, and Zundamon (ずんだもん)'s "ノーマル" voice model. Together these
# let --zundamon_tts read the rpg2k message window's text aloud with no
# network access at play time and no separate VOICEVOX Engine process to run.
#
# ~90 MiB combined, so it is downloaded here rather than committed — the
# repository stays small and nothing here redistributes VOICEVOX itself.
#
# Sources, all pinned GitHub release assets so the bytes are immutable and
# checksummable:
#   - VOICEVOX/voicevox_core   -- CORE C API, MIT licensed (linux-x64 build;
#     src/voicevox_tts.cxx dlopen()s libvoicevox_core.so at run time, so no
#     link-time dependency is added to the build).
#   - VOICEVOX/onnxruntime-builder -- the ONNX Runtime build CORE dlopen()s in
#     turn (CPU-only; see docs/adr for GPU scope).
#   - r9y9/open_jtalk -- the UTF-8 Open JTalk dictionary CORE's Japanese
#     front-end (accent/pronunciation analysis) reads from.
#   - VOICEVOX/voicevox_vvm -- Zundamon's "ノーマル" style (style id 3, the
#     one file `0.vvm`), not the whole multi-character model pack.
#
# The CORE, ONNX Runtime and VVM versions are pinned *together*, not
# independently: a `.vvm`'s `vvm_format_version` (2, for the voicevox_vvm
# release pinned below) only loads on a CORE build new enough to understand
# it -- CORE 0.16.4 rejects it outright ("不正な形式です") -- and CORE prints
# a compatibility warning if the ONNX Runtime build is not the version it was
# built against. Bumping any one of the three needs re-checking the others.
#
# IMPORTANT — licence: audio generated with this voice model must be credited
# "VOICEVOX:ずんだもん" per assets/voicevox/models/TERMS.txt, whether the use
# is commercial or not. See docs/adr for the full attribution note.
#
# Idempotent: re-running with the assets already in place does nothing. Pass
# --force to re-download and overwrite.

core_version="0.17.0"
core_sha256="00a80c5688e2fde093a3e2c1a4c39170b1c86760d92638a554c8a971a9d97077"
core_url="https://github.com/VOICEVOX/voicevox_core/releases/download/${core_version}/voicevox_core-linux-x64-${core_version}.zip"

ort_version="1.23.2"
ort_sha256="0860cfbd5a80201b1bf95cae13ca2db8dc01f32f5674cc8193146047a9212fdb"
ort_url="https://github.com/VOICEVOX/onnxruntime-builder/releases/download/voicevox_onnxruntime-${ort_version}/voicevox_onnxruntime-linux-x64-${ort_version}.tgz"

dict_version="1.11.1"
dict_sha256="fe6ba0e43542cef98339abdffd903e062008ea170b04e7e2a35da805902f382a"
dict_url="https://github.com/r9y9/open_jtalk/releases/download/v${dict_version}/open_jtalk_dic_utf_8-1.11.tar.gz"

vvm_version="0.17.0"
vvm_sha256="ecd35374d4182cd883cba5040376f7f888cc6ba248b1c2f4cea07cdb34bb1318"
vvm_url="https://github.com/VOICEVOX/voicevox_vvm/releases/download/${vvm_version}/0.vvm"

# Routes through the optional CI CORS proxy cache when CORS_PROXY_URL is set.
. "$(dirname "$0")/cors-proxy-url.bash"

here="$(cd "$(dirname "$0")/.." && pwd)"
dest="$here/assets/voicevox"
cache="$here/assets/.voicevox"

force=0
[ "${1:-}" = "--force" ] && force=1

if [ "$force" -eq 0 ] && [ -f "$dest/core/lib/libvoicevox_core.so" ] &&
    [ -f "$dest/onnxruntime/lib/libvoicevox_onnxruntime.so" ] &&
    [ -f "$dest/dict/open_jtalk_dic_utf_8-1.11/sys.dic" ] &&
    [ -f "$dest/models/0.vvm" ]; then
    echo "voicevox: already present in $dest (pass --force to re-download)"
    exit 0
fi

mkdir -p "$cache"

# Download to a cache tarball keyed by name, re-using it only when it matches
# the pinned checksum -- a truncated download from an interrupted run must not
# be trusted. Each of these is fed to a native loader (dlopen, an ONNX Runtime
# session, a VVM model reader) that would otherwise surface a corrupt archive
# as a confusing runtime failure rather than a download error.
fetch() {
    local name="$1" url="$2" want="$3" out="$cache/$1"

    if [ -f "$out" ] && ! echo "$want  $out" | sha256sum -c --status; then
        echo "voicevox: cached $name failed checksum, re-downloading" >&2
        rm -f "$out"
    fi

    if [ ! -f "$out" ]; then
        echo "voicevox: downloading $url"
        curl -fsSL --retry 3 --retry-delay 2 -o "$out.part" "$(proxied_url "$url")"
        mv "$out.part" "$out"
    fi

    if ! echo "$want  $out" | sha256sum -c --status; then
        echo "voicevox: checksum mismatch for $name" >&2
        echo "expected $want" >&2
        echo "actual   $(sha256sum "$out" | cut -d' ' -f1)" >&2
        exit 1
    fi
}

fetch "voicevox_core-${core_version}.zip" "$core_url" "$core_sha256"
fetch "voicevox_onnxruntime-${ort_version}.tgz" "$ort_url" "$ort_sha256"
fetch "open_jtalk_dic_utf_8-1.11.tar.gz" "$dict_url" "$dict_sha256"
fetch "0.vvm" "$vvm_url" "$vvm_sha256"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Only the subdirectories this script owns -- not $dest itself, which also
# holds the checked-in README.md (see download-freepats.bash's Tone_000/
# Drum_000 removal for the same reasoning).
rm -rf "$dest/core" "$dest/onnxruntime" "$dest/dict" "$dest/models"
mkdir -p "$dest/core" "$dest/onnxruntime" "$dest/dict" "$dest/models"

unzip -q "$cache/voicevox_core-${core_version}.zip" -d "$work/core"
core_root="$work/core/voicevox_core-linux-x64-${core_version}"
for required in lib/libvoicevox_core.so include/voicevox_core.h LICENSE; do
    if [ ! -e "$core_root/$required" ]; then
        echo "voicevox: core archive is missing $required" >&2
        exit 1
    fi
done
cp -r "$core_root/lib" "$core_root/include" "$dest/core/"
cp "$core_root/LICENSE" "$dest/core/LICENSE"

mkdir -p "$work/ort"
tar xzf "$cache/voicevox_onnxruntime-${ort_version}.tgz" -C "$work/ort"
ort_root="$work/ort/voicevox_onnxruntime-linux-x64-${ort_version}"
if [ ! -e "$ort_root/lib/libvoicevox_onnxruntime.so" ]; then
    echo "voicevox: onnxruntime archive is missing lib/libvoicevox_onnxruntime.so" >&2
    exit 1
fi
cp -r "$ort_root/lib" "$dest/onnxruntime/"
cp "$ort_root/TERMS.txt" "$dest/onnxruntime/TERMS.txt"

mkdir -p "$work/dict"
tar xzf "$cache/open_jtalk_dic_utf_8-1.11.tar.gz" -C "$work/dict"
if [ ! -e "$work/dict/open_jtalk_dic_utf_8-1.11/sys.dic" ]; then
    echo "voicevox: open_jtalk dictionary archive is missing sys.dic" >&2
    exit 1
fi
cp -r "$work/dict/open_jtalk_dic_utf_8-1.11" "$dest/dict/"

cp "$cache/0.vvm" "$dest/models/0.vvm"

# Zundamon's usage terms (Japanese; see docs/adr for the English gist) travel
# with the model file, same as the FreePats/M+ licences travel with their
# assets. Written here rather than fetched again: `voicevox_vvm`'s own
# TERMS.txt is the release tag's tree, not a release asset, and browsing it
# needs the GitHub API rather than a pinned download URL.
cat >"$dest/models/TERMS.txt" <<'EOF'
VOICEVOX:ずんだもん — usage terms (summary)

Audio generated with this voice model may be used for commercial and
non-commercial purposes alike, provided it is credited as "VOICEVOX:ずんだもん"
(e.g. in a game's credits screen or README). Full terms:
https://github.com/VOICEVOX/voicevox_vvm/blob/main/README.md
EOF

echo "voicevox: installed into $dest"
ruby "$here/scripts/check_voicevox_assets.rb" "$dest"
