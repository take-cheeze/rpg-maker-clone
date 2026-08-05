# 28. Downloaded default UI font for projects that ship none

Date: 2026-08-05

## Status

Accepted

## Context

RPG Maker projects are expected to carry their UI font themselves. XP and VX
select one by *family name* (`Font.default_name`, `"MS PGothic"` as the maker
ships it) and expect the file under the project's `Fonts/` folder; MV and MZ
load a file from `fonts/` and reference it from CSS as `GameFont`. `src/lib.cxx`
already implements exactly that: it scans `GAME_DIR/Fonts` and `RTP_DIR/Fonts`,
leniently matches the requested family against the file names, and rasterises
with stb_truetype.

Plenty of projects ship no font at all, because on Windows the default family
resolves to a system font — one that is not ours to redistribute and does not
exist here. Deployments that strip the RTP land in the same place. With no font
file, `RGSS::Bitmap#draw_text` falls back to the built-in **shinonome** bitmap
font, which exists at one size: 12 pixels. A VX window asking for 22px text gets
12px text, inside a layout measured for 22px. Nothing errors; the screen is just
wrong, and wrong in a way that reads as a bug in the window code rather than a
missing asset. MV/MZ are worse off still — every glyph they draw goes through
the TrueType path, so with no font their entire UI is blank.

Ways to give those projects a font:

- **Commit one** — works on a fresh clone with no setup step, at the cost of
  ~1.7 MiB in the repository forever, and makes this repository a redistributor
  of the font.
- **Download it with a script** — the repository stays small and redistributes
  nothing; the cost is a setup step, which this repository already has eight of
  (`scripts/download-*.bash`, `scripts/rtp_install.bash`) plus a CI barrier that
  waits on them, and a run-time state where the font is absent.
- **Use a system font** — nothing to fetch, but "which system font" has no
  portable answer, the result differs per machine (so screenshots and the
  render-parity comparisons stop being reproducible), and the headless CI
  containers have no Japanese font at all.
- **Synthesise a larger bitmap font from shinonome** — no new asset, but scaling
  a 12px bitmap to 22px looks like a scaled 12px bitmap, and shinonome's
  coverage stops where its tables do.

Which face also matters. The RPG2000 renderer must **not** change: shinonome's
metrics match RPG_RT's MS Gothic, and `scripts/compare-nepheshel-wine.bash`
diffs our frames against the real runtime's pixels (see ADR 0021). Anything that
silently swapped RPG2000's face would turn a passing parity comparison into a
failing one — correctly, because the output would be wrong.

## Decision

Fetch a default UI font with a script, the way the MIDI patch set is fetched
(ADR 0026), and make the fallback **opt-in per maker** rather than automatic.

- `scripts/download-default-font.bash` installs **M PLUS 1p Regular** into
  `assets/fonts` (git-ignored except its README), verifying a pinned SHA-256.
  The bytes come from the `google/fonts` repository pinned at a commit, so they
  are immutable and checksummable — the Google Fonts API serves a rolling build.
  M+ is under the SIL Open Font License 1.1; `OFL.txt` is installed beside it
  and travels with it into packaged builds.
  - M PLUS 1p is a proportional Japanese gothic, the shape both the XP/VX
    default (`MS PGothic`) and MV/MZ's own `M+ 1m` have, and it covers Latin,
    kana and JIS level-1/2 kanji in 8676 glyphs.
- The lookup lives in `mruby-rgss/src/default_font.cxx` behind
  `include/default_font.hxx`, because that gem rasterises the text. It is
  dependency-free POSIX code: the gem is also built for the terminal-only and
  Emscripten variants and must not grow build-system or SDL wiring. The
  executable hands it the paths its build baked in
  (`RGSS_DEFAULT_FONT_SOURCE_DIR` / `..._INSTALL_DIR`), and the search order is
  `$RPG_DEFAULT_FONT` → those directories → `/fonts` (the wasm preload mount) →
  `assets/fonts` relative to the working directory.
- `RGSS::Font.default_path` is the switch. It is `nil` by default; the XP and VX
  boots set it to `RGSS.default_font_path`, and `mruby-mvjs` falls back to the
  same file directly (MV/MZ have no bitmap path to protect). **RPG2000 leaves it
  nil**, so its text keeps rendering with shinonome and the parity comparisons
  keep measuring what they were written to measure.
- A font under the project's own `Fonts/` still wins. The fallback is consulted
  only when that search comes back empty.

The paths are baked into the binary unconditionally and probed at run time,
never checked at configure time — the download is independent of the configure,
so an `EXISTS` check would freeze whichever ran first, exactly as ADR 0026 found
for the patch set.

## Consequences

- XP/VX/MV/MZ projects that ship no font now draw at the size they asked for,
  with Japanese glyphs, on a fresh machine and in CI. MV/MZ projects like the
  committed MZ sample (which sets `mainFontFilename` to `""`) get text at all.
- One more setup step, and one more run-time state to keep honest: with the font
  absent, everything still works and falls back to shinonome. The `default_font`
  CTest case (`scripts/check_default_font.rb`) validates whatever is installed —
  real sfnt, the tables stb_truetype reads, coverage from Latin through kanji —
  and skips cleanly when nothing is, because a truncated download would
  otherwise surface only as blank text at draw time.
- The engine now has a notion of "the font a game did not ask for", which is a
  visible product decision, not just plumbing: two engines rendering the same
  fontless project will not agree pixel-for-pixel unless they picked the same
  face. `RPG_DEFAULT_FONT` exists so that choice can be overridden without a
  rebuild.
- The web build grows ~1.7 MiB of `index.data` when `-DWASM_DEFAULT_FONT=ON`
  (on for the deployed page, off by default, since emcc fails the link if the
  preloaded directory is missing).
- Anything that redistributes a built copy — a packaged release, the deployed
  page — is now shipping an OFL font and must carry `OFL.txt`. The install rule
  and the wasm preload both take the whole directory, so they do.
- Follow-up left open: bold and italic are still synthesised (a smeared and a
  sheared render of the regular face) rather than loaded from real weights, and
  only one face is installed. A project wanting a specific look should still
  ship its own font, which continues to win.
