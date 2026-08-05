# Default UI font (M PLUS 1p)

This directory holds the font the engine falls back to when a project ships
none. It is empty in a fresh checkout — everything except this README is
downloaded:

```sh
./scripts/download-default-font.bash
```

## Why it is needed

RPG Maker projects are expected to carry their UI font themselves: XP and VX
look for a family name under the project's `Fonts/` folder, MV and MZ load a
file from `fonts/`. Many projects ship neither, because on Windows the maker's
default (`MS PGothic` for XP/VX) resolves to a system font — one that is not
ours to redistribute and does not exist here.

With no font file at all, `RGSS::Bitmap#draw_text` falls back to the built-in
12px **shinonome** bitmap font, so a window asking for 22px text draws it
half-size. Nothing errors; the text is just wrong-looking, and the layout it
sits in was measured for the size that was asked for. This font is what those
projects get instead.

## What the script installs

| Path                   | What it is                                          |
| ---------------------- | --------------------------------------------------- |
| `MPLUS1p-Regular.ttf`  | M PLUS 1p Regular — 8676 glyphs, ~1.7 MiB           |
| `OFL.txt`              | SIL Open Font License 1.1 — the terms it ships under |

M PLUS 1p is a proportional Japanese gothic face, which is the shape both the
XP/VX default (`MS PGothic`) and MV/MZ's bundled `M+ 1m` have. Its coverage runs
from Latin through kana to JIS level-1/2 kanji, so Japanese window text draws
with real glyphs rather than blanks.

## What uses it

- **RPG Maker XP / VX / VX Ace** — `RGSS::Font.default_path` is pointed here at
  boot (`mruby-rpgxp`, `mruby-rpgvx`). A font found under the project's own
  `Fonts/` still wins; this is only reached when the project ships none.
- **RPG Maker MV / MZ** — `mruby-mvjs` falls back to it when the project's
  `fonts/` directory holds no `.ttf`/`.otf`.
- **RPG2000 / 2003** — deliberately **not** affected. Its text keeps rendering
  with shinonome, whose metrics match RPG_RT's MS Gothic; the render-parity
  comparisons (`scripts/compare-nepheshel-wine.bash`) are checked against those
  exact pixels, so swapping the face there would be a regression, not a fix.

## Where the engine looks

In order, first hit wins:

1. `RPG_DEFAULT_FONT` — an explicit override, either a font file or a directory
   holding one. Always wins, so a user can substitute any face.
2. The directory the executable was built or installed with: this one in the
   source tree (`RGSS_DEFAULT_FONT_SOURCE_DIR`), or
   `<prefix>/share/rpg-maker-clone/fonts` in an installed build.
3. `/fonts` — the Emscripten preload mount, populated by configuring the wasm
   build with `-DWASM_DEFAULT_FONT=ON` after running the download script.
4. `assets/fonts` relative to the working directory.

`scripts/check_default_font.rb` validates whatever is installed here (real
sfnt, the tables stb_truetype needs, and the script coverage the makers' UI text
needs); it is registered as the `default_font` CTest case and skips cleanly when
nothing has been downloaded.

## Provenance and licensing

The file is **M PLUS 1p Regular**, fetched from the
[`google/fonts`](https://github.com/google/fonts) repository (`ofl/mplus1p`)
pinned at a commit, so the bytes are immutable and checksummable — the Google
Fonts API serves a rolling build instead. The script verifies a pinned SHA-256
for both files before installing them.

M+ is distributed under the **SIL Open Font License 1.1**, which permits
redistribution as long as `OFL.txt` travels with the font and the font is not
sold on its own. It is not committed here, so this repository redistributes
nothing; anything that *does* ship it (a packaged build, a preloaded wasm page)
must carry `OFL.txt` alongside.
