# 93. WOLF RPG Editor: real ChipSet-image tile rendering

Date: 2026-09-07

## Status

Accepted

## Context

`WolfRPG::MapScene` (runtime.rb) drew every map tile as a flat colour block
keyed by `TileSetData`'s passability flags (green passable, dark red
blocked, yellow "always above characters", blue autotile) -- legibility
markers, not real graphics, mirroring the fallback `mruby-rpg2k`'s own
chipset renderer already falls back to when its ChipSet image is
unavailable. Real tile art was left as a follow-up in docs/TODO.md.

Two pieces are needed: plain base chips (straightforward, an 8-column
sheet), and autotile quarter-tile compositing. `Wolf::Map.autotile_slot`/
`.autotile_shape` already split a packed layer value into an autotile slot
and a 4-digit per-corner shape code (top-left/top-right/bottom-left/
bottom-right), but nothing turned that shape code into a real quarter-tile
blit. The shape-digit-to-pixel mapping needed independent confirmation
before committing to it:

- help/06material.html (the editor's own bundled manual, decoded as UTF-8
  per its own `<meta charset>`) documents both tileset image formats under
  "マップチップ": a base sheet is a fixed 8 columns wide, `tile_size`-square
  cells ("横にチップ8列分...の画像"); an autotile sheet is 1+ columns wide
  (one per animation frame, "横に配置したチップ分だけアニメーションを行いま
  す") and exactly 5 `tile_size`-square cells tall ("縦は5チップ長"), each
  row a complete alternate rendering of the whole tile for one connectivity
  state, top to bottom: 0 center-only ("中央への接続"), 1 vertical
  ("縦方向の接続"), 2 horizontal ("横方向の接続"), 3 outward/concave
  ("外向きの接続"), 4 fully surrounded ("周囲が塗りつぶされた状態"). A real
  quarter-tile is cut from whichever row its own corner's shape digit names.
- wolf-rpg-formats' `mps.ksy` (an independently-authored kaitai-struct spec,
  already the cross-validation source `Wolf::Map`'s own file header cites
  for other .mps details) carries a `mappixel` type whose
  `autotile_mode_top_left`/`_top_right`/`_bottom_left`/`_bottom_right` fields
  decode a raw layer value with the exact same digit positions
  `Map.autotile_shape`'s own comment already documented (`raw % 10000 /
  1000`, `% 1000 / 100`, `% 100 / 10`, `% 10` respectively) -- independent
  structural confirmation of both the digit order and that only 4 digits
  (0-4 each) are meaningful.
- The sample game's own real map data agrees with the manual's own
  semantics: an autotile placement with no matching neighbour of its own
  stores shape `0000` (every corner "center-only"), while one completely
  boxed in by like autotiles stores `4444` (every corner "fully
  surrounded") -- exactly the two rows their own descriptions name, at the
  two ends of the expected range.
- `wolfrpg-map-parser` (the `wmp` crate) and WolfTL were checked too, but
  neither models tile-rendering geometry at all (the crate is a data-model
  parser only, WolfTL a translation-string extractor); they added nothing
  beyond confirming the crate's own `Tileset` struct shape (`auto_tiles: [String; 15]`,
  a v2-file-sized fixed array) matches what `Wolf::Tileset` already reads.

`mruby-rgss/src/lib.cxx`'s own `Bitmap#blt`/`#blt_quads` (the latter's own
comment: "the map renderer's tile hot path... an autotile answers with five
fresh arrays") already exist and are already shared infrastructure with
`mruby-rpg2k`'s own chipset renderer (`Game::ChipsetLayout`/`Scene::Map#draw_tile`)
-- no native work was needed, only the WOLF-specific geometry and the
mrblib call sites.

## Decision

- `Wolf::ChipLayout` (data.rb, next to `Wolf::Map`): pure geometry, no
  `Bitmap`/`Sprite` of its own, mirroring `Game::ChipsetLayout`'s own
  design so the math is exercised directly by `mruby-wolf/test`'s CRuby-run
  suite rather than only through the native-backed renderer.
  `.base_rect(tile_size, value)` returns a plain chip's `[sx, sy]` (column
  `value % 8`, row `value / 8`); `.autotile_quads(tile_size, shape, frame)`
  returns up to four `[dx, dy, sx, sy, w, h]` quads for `Bitmap#blt_quads`,
  one per corner whose digit falls in the documented 0..4 range (an
  out-of-range digit -- malformed map data -- is skipped rather than
  sampling past the sheet's own 5 rows). `frame` always receives 0 from
  every real caller today; see Consequences.
- `WolfRPG::MapScene` loads each tileset's own base sheet and every
  autotile sheet once, up front (`#load_tileset_bitmap`, the same
  `Data/`-relative-path/`RGSS::Bitmap::LoadError`-rescue convention
  `#load_picture_bitmap` already used for Picture(150)). `#draw_tiles`
  composites every layer's every cell through the whole static
  `@map_bitmap` exactly once at scene build (this reader's existing
  "bake the whole map, then just pan the viewport" design -- no scrolling
  chipset cache like `mruby-rpg2k`'s own per-frame windowed renderer, since
  nothing here asked for that yet).
- Layer 0 draws every cell including id 0 (a real base chip, not "empty" --
  the same convention `#passable?` already keys off); layers above it skip
  a 0 cell outright, letting the layer beneath show through, matching WOLF's
  own per-cell "no tile here" encoding.
- Three independent fallbacks to the old colour blocks, each answering a
  different "no real image to draw from" case: no `@tileset` at all for
  this map's `tileset_id` (the whole map, colour blocks plus the original
  legibility grid, verbatim); a tileset present but its own base sheet or a
  particular autotile slot's file missing/failed to load (that slot's own
  cells only); and a chip/row id past the bounds of whatever image did
  load (that cell only). None of these raise -- a missing or partial asset
  set should not crash event execution, the same discipline
  `#load_picture_bitmap` already established for Picture(150).

## Consequences

- Verified by `cmake --build build` (clean build, no warnings from the new
  code), `ctest -R mruby_test` (0 crashes -- comfortably under the
  documented pre-existing baseline), `ruby scripts/wolf_testbed_check.rb`
  and `ruby scripts/wolf_interpreter_check.rb` (both pass unchanged, since
  neither touches rendering), and the compiled binary booted headless
  against the real sample game for 3 seconds with no crash and no
  `[Wolf] tileset image failed to load`/`Picture(150)` load-failure lines
  -- i.e. every one of the sample game's own tileset/autotile PNGs loaded
  and blitted successfully.
- Per-tile animation stepping (WOLF's own default 20-frame column advance,
  customisable per file via a `_FRAME=N` filename suffix) is deliberately
  out of scope: every call into `.autotile_quads` passes `frame: 0`, which
  the manual confirms is always a complete, valid rendering (each column is
  a full alternate frame, not a partial one) -- just a static one. Adding
  real stepping needs a per-cell "which autotile slots are on screen"
  tracking structure this reader's current "bake once" design has no
  equivalent of yet (unlike `mruby-rpg2k`'s own windowed tile cache, which
  already tracks exactly that for its own water/terrain animation). Left
  for a future pass rather than guessed at here.
- Event graphics (a map event's own character/tile image) are still not
  drawn -- this ADR only replaces the *tile* colour blocks, not the
  `EVENT_MARKER` ones map events still draw as. Tracked separately in
  docs/TODO.md, unaffected by this change either way.
