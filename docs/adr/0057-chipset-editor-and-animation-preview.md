# 57. A chipset passability editor and a battle-animation preview

Date: 2026-08-19

## Status

Accepted

## Context

Two more pieces of the debugging/editor roadmap `docs/adr/0055-lcf-text-
convert.md` and `docs/adr/0056-map-editor.md` set out:

- **Chipset passability.** A chipset's passability tables (`passable_data_
  lower`/`passable_data_upper`, chunks 4/5 on the database's `chipset`
  Array2D) are the same kind of problem the map itself is: 162 (lower) / 144
  (upper) cells of spatial data, where "which cell am I even looking at" is
  most of the difficulty. `scripts/lcf_text_convert.rb` can already edit
  these fields as raw byte arrays, but picking out entry 87 of 162 by
  counting through a YAML list is exactly the friction a grid and a cursor
  exist to remove — the same argument that kept the map itself out of the
  text converter's scope to begin with.
- **Battle animation preview.** Confirmed as wanted alongside the map/
  chipset editors: authoring or tuning a battle animation (a timed sequence
  of sprite frames, screen flashes, per-target offsets) is very hard to
  verify from data alone — there is no way to know whether an edit is right
  without seeing it play.

Both needed their own research before writing anything, and both turned out
to be small once done, because the substrate already existed:

- `Game::ChipSet#landable_tile?` (`mruby-rpg2k/mrblib/game.rb`) already
  defines "passable" as *any* of the four direction bits (`DIR_BIT[2/4/6/8]`,
  together `ALL_DIRS = 0x0F`) being set, and treats `ABOVE_BIT` (0x10, the
  editor's "star" — draws in front of the hero) and `COUNTER_BIT` (0x40,
  talk-across) as orthogonal flags in the same byte. A coarse toggle that
  flips only the low nibble between fully-clear and fully-set, reading
  "currently passable" the identical any-bit-set way, matches the runtime's
  own semantics exactly and can't clobber the other two flags.
- The battle animation player is not part of `Scene::Battle` at all — it
  lives entirely in `Scene::Map` (`build_animation`, `anim_target`,
  `step_map_animation`, `draw_map_animation`, the `@animation_sprite`
  it owns), and `Scene::Battle#start_battle_animation` already calls into it
  exactly the way a preview would want to: `build_animation(id, [target],
  true)` then `map_animation = anim`. `Scene::Map#update`/`#render` already
  call `step_ownerless_map_animation`/`draw_map_animation` unconditionally
  every frame for a fire-and-forget play (no interpreter/battle owning it),
  which is exactly what an animation fired from a menu is. So a preview
  needs no new rendering code at all — it only needs to reach the *live*
  `Scene::Map` instance and call four already-public methods on it, then get
  out of the way so that scene's own ordinary update/render loop (suspended
  while any menu sits on top of it) resumes and does the rest.

## Decision

- **`RPG2k#map_scene`** (`mruby-rpg2k/mrblib/main.rb`): `@scenes.first`,
  named and documented rather than left as an inline array index — the base
  `Scene::Map` underneath whatever's currently pushed, which `#pop_to_map`
  already relies on being true. This is the seam both new features need:
  the debug menu itself only carries `@state`, not a live scene reference.
- **`RPG2k#db_path`**, extracted the same way `#map_path` was in ADR 0056,
  used by both `#initialize`'s own `@db` load and `Scene::ChipsetEditor`'s
  save action.
- **`Scene::Map#rebuild_chipset` made public** (it already existed, for
  Change Map Tileset) — `Scene::ChipsetEditor` calls it after saving so an
  edited chipset is visible in the field map immediately rather than only on
  the next map load. Deliberately only on save, not on every toggle: a
  rebuild also reloads the chipset's tile graphic from disk, so toggling
  ten cells while experimenting does not mean ten redundant file reads.
- **`Scene::ChipsetEditor`** (`mruby-rpg2k/mrblib/scene/chipset_editor.rb`),
  reached from the F9 menu's new Chipset page: a grid of solid colour
  blocks — like `Scene::MapViewer`, no real tile art, the same simplifying
  choice for the same reason — one per chip index, cursor-navigable, L
  switching the Lower/Upper table, C toggling passability (the coarse,
  flag-preserving toggle described above), R saving and rebuilding.
  Terrain id and other per-field chipset data are not covered — they stay a
  `lcf_text_convert.rb` job, matching ADR 0055's original split precisely
  (spatial data gets a grid; everything else stays text).
- **`Scene::DebugMenu`'s Animation page**, the fifth mode: Up/Down adjusts a
  candidate id by one, L/R by ten (mirroring the Switch/Variable pages' own
  Up/Down-by-one, L/R-by-block-of-ten convention), and C fires it through
  `@parent.map_scene`'s `build_animation`/`anim_target`/`map_animation=`,
  then `pop_to_map` so the animation is what's left on screen. No new scene
  class needed — the whole feature is inline in `DebugMenu`, the same way
  the Variable page's own digit editor is, since firing an animation is a
  single action rather than something with its own multi-step UI.

Covered by new checks in `scripts/rpg2k_scene_check.rb`: the chipset
toggle's flag-preservation (an upper cell's star/counter bits survive a
passability toggle) and its save+rebuild call, both via a `FakeChipsetRow`
double that answers the same integer-chunk-id `#[]`/`#[]=` protocol a real
`LCF::Array1D` does (matching `FakeMapUnit` from ADR 0056 — proving the
wiring, not re-proving the LCF writer `lcf_text_convert_check.rb` already
covers); and the Animation page's id adjustment and its play/pop_to_map call
against a narrow `map_scene` double answering just the four methods reached.

## Consequences

- Chipset passability is now editable the same way map tiles are: visually,
  live in the running game, persisted to the real `.ldb` on request — still
  the original RPG Maker 2000/2003 format on disk throughout.
- Battle animations can be previewed standalone without needing a save file
  positioned near an encounter or a real fight to trigger one, the same
  "verify one thing in isolation" convenience `--rpg2k_preview_map` already
  gives maps.
- The F9 menu is now five pages; `MODES` in `debug_menu.rb` stays the single
  place that ordering lives, so a further page is a one-line addition plus
  its own `refresh_*_page`/`update_*` pair, the pattern already established
  by Map/Chipset/Animation alike.
- Follow-up work: the chipset editor's grid is a natural source for a Map
  Editor brush picker (ADR 0056 noted this gap deliberately, eyedropper-only
  for now) — wiring "pick a cell here, use it as the Map Editor's brush"
  would let painting choose from chipset cells that have never yet appeared
  on the currently-loaded map, without relaxing the "always a real id"
  safety property, since a chipset cell is exactly as real an id as an
  eyedropped one.
