# 56. An in-engine Map Editor, writing back through the live Game::Map

Date: 2026-08-19

## Status

Accepted

## Context

`docs/adr/0055-lcf-text-convert.md` established the "text-first, map stays
visual" split for project-data editing, and shipped a schema-checked
binary/text converter that can already edit and save a `.ldb`/`.lmu` from
outside the running game. What it deliberately does not do is tile painting:
the map is the one case where a text/YAML representation is a worse editing
surface than a spatial one, which is exactly why `Scene::MapViewer` (the F9
debug menu's Map page) exists as a visual, in-engine tool rather than
something built on the text converter.

Until now that viewer was read-only: it drew tiles and let you inspect and
teleport, but the actual tile data — `Game::Map`'s `@lower`/`@upper` arrays
— had no writer at all, only `#substitute_tile`, a *different* mechanism
(RPG2000's Tile Substitution event command) that layers a `{old_id =>
new_id}` rewrite table on top of the pristine arrays rather than editing
them, and is deliberately reversible/session-scoped by design (see its own
comment in `game.rb`). Painting needs the opposite: an outright, persistent
edit to one specific cell.

The risk is the same one every piece of debug tooling in this engine has
been built against: this is the *original* RPG Maker 2000/2003 project
format on disk, so a writer that gets the framing wrong, or writes at the
wrong time, can corrupt a real project. The LCF binary writer itself is not
new risk — `LCF::Array1D#to_lcf`/`File#save_to` already round-trip byte-exact
(save files, and now `.ldb`/`.lmu` via the text converter) — but *when* and
*how* the map editor calls into it needed its own design: `Game::Map` holds
`@lower`/`@upper` as its own decoded-once Ruby arrays, not the same object
`unit.lower_layer` would re-decode fresh, so an edit needs an explicit sync
step before a save actually reflects it.

## Decision

- **`Game::Map#set_lower(x, y, id)` / `#set_upper(x, y, id)`** (`mruby-rpg2k/
  mrblib/game.rb`): a direct rewrite of one cell in the layer array
  (`layer[y * width + x] = id`), bumping `#revision` the same way
  `#substitute_tile` already does so `Scene::Map`'s tile-cache invalidation
  picks it up. Reads (`#lower`/`#upper`, and so ordinary field rendering) see
  the edit immediately, since they already read the same arrays — no new
  read path, no cache to invalidate beyond what already exists.
- **`Game::Map#sync_layers_to_unit`**: pushes the (possibly-edited)
  `@lower`/`@upper` arrays back into `@unit` (the `LCF::MapUnit` `File`
  object every `Game::Map` already holds a reference to, per `RPG2k#load_map`)
  via its own schema-driven `[]=` (chunks 71/72, both a plain `:int16_array`)
  — the exact same re-encoding path the text converter's `to_binary` uses,
  just called from the running engine instead of a CLI script.
- **`Scene::MapViewer` gains Edit mode**, entered with **L** from pan mode
  (parallel to **R** for the existing Select mode, reusing its cursor):
  **Ctrl** is an eyedropper (brush = the tile under the cursor on the active
  layer), **Shift** swaps the active layer, **C** paints (`set_lower`/
  `set_upper`), **R** calls `sync_layers_to_unit` then `@map.unit.save_to`
  (the path from a new shared `RPG2k#map_path`, extracted from `#load_map` so
  both the loader and the editor's save action compute the identical
  `Map0001.lmu`-style name). **B** returns to pan mode without saving — the
  edit already took effect live in this session regardless; `R` is only
  about persisting past it.
- **No typed brush.** The only way to choose what to paint is the
  eyedropper. This is a real scope cut (no free-form tile-id entry, no
  chipset picker yet — see the companion Chipset Editor work for that), but
  it buys a safety property worth keeping even once a picker exists: a
  painted tile is always an id that already validly exists somewhere on the
  currently-loaded map, never an arbitrary number that might not correspond
  to anything sane in the map's chipset.
- **The viewer still only ever shows passable/blocked colour blocks**, not
  real tile art (unchanged from the read-only viewer) — painting between two
  tiles with the same passability is invisible in this tool even though the
  underlying id genuinely changed. Verifying a paint visually still means
  looking at the real field map (which updates live) or the chipset editor's
  own view of the tile.

Covered by new checks in `scripts/rpg2k_scene_check.rb`: `Game::Map#set_lower`/
`#set_upper` rewriting one cell without disturbing an untouched one and
bumping `#revision`; `#sync_layers_to_unit` pushing the whole edited array
(not just the touched cell) to the right chunk ids; and the full Edit-mode
loop (eyedrop, paint, layer swap, save) through `Scene::MapViewer` itself,
using a `FakeMapUnit` double that records `#[]=`/`#save_to` calls rather than
re-proving the real binary writer (already proven in
`scripts/lcf_text_convert_check.rb`) — the same "test the seam, not what's
already tested elsewhere" split that check script already uses.

## Consequences

- A project's map data can be edited live, in-engine, and persisted, closing
  the one gap `docs/adr/0055-lcf-text-convert.md` deliberately left open.
  Still the original RPG Maker 2000/2003 format on disk throughout.
- `Game::Map` now has two independent tile-rewrite mechanisms —
  `#substitute_tile` (event-driven, table-based, reversible, never touches
  the arrays) and `#set_lower`/`#set_upper` (editor-driven, direct,
  persistent) — reading through the same `#lower`/`#upper` accessors. They
  do not interact: a substitution active when a cell is painted stays keyed
  to whatever id it was substituting, which may no longer be the id actually
  sitting in that cell after the paint. This mirrors real RPG Maker's own
  editor/runtime split (Tile Substitution is purely a runtime command; the
  map editor edits the map file directly) and is not expected to be a
  practical problem, since a debug session doing both to the same cell in
  the same visit is an unusual thing to do on purpose.
- Follow-up work: a chipset-grid picker (in progress, see the companion
  chipset-editor changes) would let the brush be chosen visually instead of
  only via eyedropper, without needing to relax the "always a real id" safety
  property — the picker would just be another source of *real* ids, the same
  as the eyedropper.
