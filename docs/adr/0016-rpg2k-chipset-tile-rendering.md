# 0016. RPG2000 chipset tile rendering

Date: 2026-08-03

## Status

Accepted

## Context

`Scene::Map` renders the walkable map, but until now each tile was drawn as a
solid colour block keyed by its tile id — a navigable placeholder. The map data
already decodes correctly (`LCF::MapUnit` lower/upper layers, `chipset_id`) and
the chipset database chunk parses (`RPG_RT.ldb` chunk 20: `chipset_name`,
passability, terrain, animation type/speed), so the missing piece was purely the
*geometry*: turning a tile id into the pixel rectangle(s) it occupies in the
`ChipSet/<name>.png` graphic.

RPG Maker 2000 does not store whole 16×16 tiles for every map cell. Tile ids are
partitioned into blocks, and two of those blocks — water (A/B) and terrain (D) —
are **autotiles**: the id encodes a border/corner *combination* the editor chose
from the cell's neighbours, and the drawn tile is assembled at runtime from four
8×8 quarter-tiles, each copied from a different chip of the chipset. Reproducing
this from a prose description is error-prone; the exact quarter-selection tables
and block offsets matter.

Two additional constraints shaped the approach:

- This environment cannot build or run the native SDL/mruby binary, so the
  logic has to be verifiable as pure Ruby under CRuby, the way the existing
  loader/logic/scene harnesses are.
- The renderer already exposes an alpha-blending `Bitmap#blt(x, y, src, rect)`
  (C) and loads indexed PNGs with palette-index-0 transparency (the flag already
  used for the windowskin), which is exactly what chipset blitting needs.

## Decision

Add `Game::ChipsetLayout` (pure Ruby in `mruby-rpg2k/mrblib/game.rb`)
implementing RPG2000's chipset tile geometry, and drive `Scene::Map` from it.

- The chipset image is the fixed RPG2000 480×256 grid of 16×16 chips. A tile id
  maps to a block: water A/B (`0..2999`), animated C (`3000..3149`), terrain D
  (`4000..4599`), lower E (`5000..5143`), upper F (`10000..10143`).
- `ChipsetLayout.quads(id, abf, cf)` returns the blit rectangles for a tile:
  one 16×16 chip for blocks C/E/F, or four 8×8 quarters for the A/B and D
  autotiles. The quarter-selection tables (`BLOCK_A_SUBTILES`,
  `BLOCK_D_SUBTILES`) and the block offsets encode the water A+B combining step
  and the set-1/set-2 column and row remaps. Because the map already stores the
  fully-resolved combination id, no neighbour recomputation is needed at render
  time.
- Water tiles cycle through three animation columns and the block-C tiles
  through four frames; `anim_ab`/`anim_c` cycle on a fast/slow timing (every
  12/24 frames; type 0 walks `0,1,2,1`, type 1 cycles `0,1,2`). `Game::ChipSet`
  now also reads the chipset `animation_type`/`animation_speed`.
- `Scene::Map` loads `ChipSet/<name>` (with the palette-0 transparency flag),
  keeps a per-scene frame counter, and blits every visible lower/upper tile each
  frame via `ChipsetLayout`. When the chipset image is missing it falls back to
  the previous solid-colour blocks, so a game with an unresolved graphic stays
  navigable and the failure is logged (`[RPG2k] chipset graphic load failed …`).

Passability and terrain lookup are unchanged — they keep using the existing
`ChipSet` tables — so this change is rendering-only.

## Consequences

- Maps now look like the real game: proper ground/wall/water graphics, correct
  autotile borders and cliffs, and animated water/tiles, instead of a mosaic of
  coloured squares. Upper-layer chips blend with transparency over the lower
  layer as intended. ADR 0021's later side-by-side comparison against a genuine
  RPG_RT.exe under wine confirmed this geometry pixel-identical on real maps —
  autotiles, chipset layering and animated water included.
- The geometry is exercised without any native build or real image by
  `scripts/rpg2k_render_check.rb` (run in CI next to the logic/scene checks),
  which sweeps every water and terrain combination and asserts every quad lands
  inside the 480×256 grid; `scripts/rpg2k_scene_check.rb` now exercises the blit
  wiring through its RGSS stubs.
- The scene redraws every visible tile every frame (as the placeholder did),
  now at up to four blits per autotile. This is acceptable at RPG2000's small
  resolution; if it becomes a bottleneck the obvious follow-up is to redraw only
  when the camera or animation frame changes, or to pre-compose an autotile
  cache the way EasyRPG does.
- Not yet covered: the *Replace Chipset Tiles* event command (the runtime uses
  an identity chip substitution — correct for a fresh game) and screen-tone
  tinting of tiles. Both are noted as follow-ups in `docs/TODO.md`.
