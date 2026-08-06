# 22. RPG Maker XP: Tilemap priority layering

Date: 2026-08-04

## Status

Proposed

## Context

The native `RGSS::Tilemap` (`mruby-rgss/src/lib.cxx`) now renders the map:
regular tiles, autotiles (with the 48-shape quad table) and autotile animation
all draw into a single `lv_canvas` sized to the viewport, at the tilemap's own
`z`. What it does **not** do is honour per-tile **priority**.

In RMXP a tileset carries a `priorities` `Table` indexed by tile id (0..5 per
id). Priority 0 is flat ground drawn below the characters. Priority ≥ 1 means the
tile stands "up" out of the map — a wall top, a roof, a tree crown — and must
draw **above** a character who is standing lower on the screen than the tile, but
**below** a character standing higher. That per-row interleaving is what lets you
walk behind the crown of a tree while still standing in front of its trunk. Stock
`Spriteset_Map` relies on the engine's `Tilemap` to do this internally: it gives
character sprites a `z` of roughly their on-screen feet position (`screen_y`,
~0..map-pixel-height) and leaves fog/weather/pictures at fixed high `z`
(fog ≈ 3000, weather ≈ 1000 in stock scripts). The `Tilemap` is expected to place
its priority tiles into that same `z` continuum.

Today all tiles land on one flat canvas at one `z`, so every priority tile draws
on the same plane as the ground — characters always walk in front of roofs and
tree crowns. This is the last substantial gap for `Tilemap` (autotile animation
and `flash_data` aside).

Two constraints make this more than a one-line change:

1. **It cannot be verified headlessly.** The `mruby-rgss` test binary has no live
   display, so `Tilemap` rendering is only ever exercised by a running game. Every
   other render slice this cycle shipped "compile-verified, render-verified in a
   game run"; priority layering additionally introduces new *z-ordered objects*
   and a custom dispose path, so a mistake risks a crash on map load, not just a
   cosmetic glitch. That raises the bar for landing it blind.

   **Partly lifted since.** `scripts/native-build-without-nix.bash` builds the
   engine on a plain box and runs `scripts/rpgxp_boot_check.bash` under Xvfb, so
   crash-on-map-load — the failure this called out as worse than cosmetic — is now
   catchable before review rather than after. What that still does *not* give is
   the cosmetic half: the XP test bed ships no image assets, so its tilesets load
   as blank bitmaps. Structure and survival are verifiable; a roof actually
   occluding a character is not, and wants a project with real graphics.
2. **The `z` scheme is shared with conventions set elsewhere.** Above-priority
   tiles must interleave with per-row character `z` values yet stay below
   fog/weather. A single flat "above" layer at one fixed `z` cannot satisfy both:
   pick a `z` above all characters and roofs cover characters who should occlude
   them; pick one below fog and it still can't interleave per row. Correct
   behaviour needs a *per-row* set of `z` values, matching how RMXP spreads
   priority tiles through the character `z` range.

For reference, the non-script reimplementation (`mruby-rpgxp/mrblib/scene.rb`,
`Scene_Map`) already fakes a coarse version of this with three sprites —
`@lower_sprite` (`z = 0`), `@player_sprite` (`z = 100`), `@upper_sprite`
(`z = 200`) — but it splits by *map layer index*, not the `priorities` table, and
draws flat colour rects, so it is only a placeholder and does not inform the
correct `z` maths. The proper implementation belongs in the native `Tilemap` that
serves the script-host path.

## Decision

Render the map in **two passes split by priority**, with the above-priority tiles
spread across **per-row `z` strips** so they interleave with character sprites:

- **Ground pass — the existing canvas.** Priority-0 tiles (and any tile when no
  `priorities` table is set) keep drawing into `@_tm_canvas` at the tilemap's `z`,
  exactly as now. No behaviour change when a map has no priority tiles.

- **Above pass — one canvas strip per map row.** For each visible map row `ty`
  that contains at least one priority ≥ 1 tile, allocate (lazily, reused across
  frames) a full-width `lv_canvas` strip and draw that row's priority tiles into
  it. Give the strip a `z` derived from the RMXP rule — the tile's on-screen foot
  row plus its priority — so it sorts into the character `z` continuum:

  > **How tall a strip is, is not settled here — see "Strip height" below.** It
  > is the one part of this design that has to be decided before implementing,
  > because the obvious readings are respectively unaffordable and wrong.

  ```
  z = (ty + prio) * TILE_SIZE + TILE_SIZE - oy
  ```

  **Confirmed against the test bed's own scripts** (read out of
  `data/OpenGame.exe/Testbed/XP/Data/Scripts.rxdata`), which is what this
  originally left open. `Game_Character#screen_z` is:

  ```ruby
  z = (@real_y - $game_map.display_y + 3) / 4 + 32
  return z + $game_map.priorities[@tile_id] * 32   if @tile_id > 0
  ```

  So a character's `z` **is its on-screen pixel y**, and RMXP adds `priority * 32`
  for a tile — the same term, from the engine's own hand. Substituting the map's
  units (`real_y = ty * 128`, and `display_y = oy * 4` because `Spriteset_Map`
  sets `@tilemap.oy = $game_map.display_y / 4`) gives `ty * 32 + 32 - oy` for
  priority 0, which is the formula above with `TILE_SIZE = 32`. A priority-`n`
  tile therefore sorts as though it stood `n` rows lower, exactly as a tile event
  does. `@always_on_top` returns 999 unconditionally, which is the ceiling the
  strips must stay under.

  Because each strip is at the `z` of its own row, a character one row lower sorts
  in front of it and a character one row higher sorts behind it — the per-row
  occlusion RMXP gives. The natural bucket key is `ty + prio` rather than `ty`,
  since that is what the formula sorts on: one strip per distinct `ty + prio`.

- **Strips are z-ordered companion objects.** Each strip is wrapped as an internal
  mruby data object (`mrb_data_object_alloc(... , &obj_type)`, then the same
  `lv_obj_set_user_data` + `LV_EVENT_DELETE` hook `wrap_lv_obj` installs) and
  registered via `register_zobj`, so `gfx_update`'s existing per-parent `z` sort
  interleaves them with the character sprites that share the viewport. The strips
  are held in an ivar array on the tilemap (`@_tm_above`) so the GC keeps them
  alive, and their `z` is refreshed on scroll (`oy` change).

- **`priorities=` becomes native.** It currently is a Ruby `attr_accessor`, so
  assigning it does not re-render. Make it a native setter that stores the table
  and calls `tilemap_refresh`, matching `tileset=`/`map_data=` — otherwise the
  common `tilemap.priorities = tileset.priorities` after `map_data=` would not
  take effect.

- **Custom dispose.** `Tilemap#dispose` must delete every strip's `lv_obj` (via
  the wrapper's `dfree`, which routes through `on_lv_delete` and nulls the
  wrapper — no double free) before disposing the main canvas, so no strip lingers
  in the `z` set or on screen after the map is torn down.

Priority is looked up as `priorities[id]` for every tile id (autotile ids 48..383
and regular ids ≥ 384 alike); an out-of-range id or a nil table is treated as
priority 0.

## Strip height: open

Added 2026-08-06, before any implementation.

"One canvas strip per row" above does not say how tall a strip is, and both
readings that first suggest themselves fail. The numbers are for XP's viewport,
which `Spriteset_Map` creates as `Viewport.new(0, 0, 640, 480)` — and the strips
are sized from the viewport rect, exactly as the current single above-canvas is.
Sixteen tile rows are visible (15 whole plus a partial) and priorities run 1..5,
so `ty + prio` takes up to **21** distinct values.

| reading | cost | verdict |
|---|---|---|
| a full-screen canvas per bucket, like today's single above layer | 1.17 MiB × 21 = **24.6 MiB** | unaffordable |
| a one-tile-row strip per bucket | 80 KiB × 21 = 1.6 MiB | **wrong** — see below |
| a five-row strip per bucket | 400 KiB × 21 = 8.2 MiB | plausible, still heavy |

The one-row reading is not merely tight, it cannot express the layout. A bucket
is keyed on `ty + prio`, so bucket `B` holds every tile with `ty = B - prio` for
`prio` in 1..5 — up to **five different map rows**, each drawing at its own
screen `y`. One row of pixels cannot hold them.

That same arithmetic bounds the strip, which is where the third row of the table
comes from: a bucket spans rows `B-5 .. B-1`, so a strip five tile rows tall,
positioned at `(B - 5) * TILE_SIZE - oy`, covers every tile that can land in it.

8.2 MiB is still seven times what the flat layer costs today, and this code is
shared with the `psp` and `wio` targets, so the worst case wants to be much
smaller than the worst case. Two levers, neither costed yet:

- **Lazy allocation.** Only buckets that actually hold a tile need a strip. A map
  whose tileset only uses priority 1 collapses the bucket set to one per row, and
  a map with no priority tiles allocates nothing — which is also what keeps the
  no-priority-table path free.
- **~~Bucketing by row rather than by `ty + prio`~~ — ruled out by the data.**
  One strip per *row* (16, not 21), one row tall, taking its `z` from the highest
  priority it holds would be 1.3 MiB and simple. It is also an approximation: two
  tiles on the same row with different priorities sort together where RMXP sorts
  them apart. That looked like it might be harmless in practice, so the test bed
  was asked — and it is not. Of the XP test bed's priority-bearing map rows,
  **4 of 9 (44%) carry more than one distinct priority**, one of them three at
  once:

  | row | priorities present |
  |---|---|
  | 3 | 4, 5 |
  | 4 | 3, 4 |
  | 5 | **2, 3, 5** |
  | 6 | 2, 4 |

  So row-bucketing would visibly mis-sort the first map of the only XP project
  available, not some hypothetical one. (One map, 15 rows — a small sample, and
  the only sample there is.)

What remains open is therefore narrower: the strip **height**, and how hard to
lean on lazy allocation to keep the common case cheap. That is a
memory-against-redraw trade on `psp` / `wio` hardware that cannot be profiled
from the environment this was written in, so it is left open rather than guessed
at.

## Consequences

- **Correct occlusion.** Characters walk behind roofs/tree crowns above them and
  in front of the same tiles below them, the defining RMXP map look, for the
  script-host path.
- **New moving parts.** The tilemap goes from one `lv_obj` to 1 + N (N = visible
  rows carrying priority tiles, bounded by the viewport height — ~15 on a 480px
  screen). That means more `z`-set churn on scroll and a custom dispose; both are
  bounded and follow the existing `wrap_lv_obj`/`on_lv_delete`/`register_zobj`
  patterns, but they are the first place `mruby-rgss` mints z-ordered objects that
  a script never sees.
- **Must be verified in a game.** The `z` constant and the strip lifecycle can
  only be confirmed against a running map (ideally the testbed `Spriteset_Map`);
  this ADR exists so that scheme is agreed before the ~100–150 line, crash-capable
  change lands, rather than shipped blind like the cosmetic slices.
- **Cheaper fallback rejected.** A single flat "above" canvas at a fixed high `z`
  was considered and rejected: it is far simpler (one companion object, no per-row
  maths) but cannot both interleave with per-row characters and stay under fog, so
  it would trade one wrong look (roofs always behind) for another (roofs always in
  front). If an interim step is wanted, it should be labelled explicitly as a
  known-approximate stopgap.
- **Out of scope.** `flash_data` (the map flash overlay) and multi-frame
  correctness of animated *priority* autotiles are unchanged and remain follow-ups.
