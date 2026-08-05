#!/usr/bin/env bash

set -eu -o pipefail

# Fetch the bundled default UI font into assets/fonts, where the engine looks
# for it when a project ships no font of its own.
#
# RPG Maker XP/VX projects select their UI font by family name and are expected
# to carry the file under the project's `Fonts/` folder; MV/MZ load one from
# `fonts/`. Plenty of projects ship neither, because on Windows the maker's
# default resolves to a system font (MS PGothic) that is not ours to
# redistribute. With no font file at all, RGSS::Bitmap#draw_text falls back to
# the built-in 12px shinonome bitmap font, so a window asking for 22px text
# draws it half-size — legible, but nothing like the real thing.
#
# This installs a free, complete Japanese gothic face to fall back on instead.
# It is downloaded rather than committed so the repository stays small and
# nothing here redistributes the font.
#
# Source: M PLUS 1p Regular, from the google/fonts repository pinned at a
# commit, so the bytes are immutable and checksummable (the Google Fonts API
# serves a rolling build). M+ is licensed under the SIL Open Font License 1.1 —
# OFL.txt lands next to the font and must travel with it.
#
# RPG2000/2003 is deliberately *not* affected: its text keeps rendering with
# shinonome, whose metrics match RPG_RT's MS Gothic and which the render-parity
# comparisons in scripts/compare-nepheshel-*.bash are checked against.
#
# Idempotent: re-running with the font already in place does nothing. Pass
# --force to re-download and overwrite.

# google/fonts @ 2026-08-05. Bump the commit and both checksums together.
commit="2796410152d4f9524b68ed46e69c1b60f8e0f7c3"
font_file="MPLUS1p-Regular.ttf"
font_sha256="2f294ad496432b1608f070d310e3aa2adcf1de4af429f4901df97ec4bd361ed1"
license_sha256="da15da6b1496d4de18f97e2ad1b722ef8a1c121149c2c93b2cf7eac6ac27b35c"
base="https://raw.githubusercontent.com/google/fonts/${commit}/ofl/mplus1p"

here="$(cd "$(dirname "$0")/.." && pwd)"
dest="$here/assets/fonts"

force=0
[ "${1:-}" = "--force" ] && force=1

if [ "$force" -eq 0 ] && [ -f "$dest/$font_file" ]; then
    echo "default font: already present in $dest (pass --force to re-download)"
    exit 0
fi

mkdir -p "$dest"

# Download to <name>.part and only rename after the checksum passes, so an
# interrupted run never leaves a truncated file that later looks installed. The
# font is parsed by stb_truetype at run time, where a corrupt file surfaces as
# missing text rather than a download error.
fetch() {
    local name="$1" want="$2" out="$dest/$1"

    echo "default font: downloading $base/$name"
    curl -fsSL --retry 3 --retry-delay 2 -o "$out.part" "$base/$name"

    if ! echo "$want  $out.part" | sha256sum -c --status; then
        echo "default font: checksum mismatch for $name" >&2
        echo "expected $want" >&2
        echo "actual   $(sha256sum "$out.part" | cut -d' ' -f1)" >&2
        rm -f "$out.part"
        exit 1
    fi
    mv "$out.part" "$out"
}

fetch "$font_file" "$font_sha256"
fetch "OFL.txt" "$license_sha256"

echo "default font: installed into $dest"
ruby "$here/scripts/check_default_font.rb" "$dest"
