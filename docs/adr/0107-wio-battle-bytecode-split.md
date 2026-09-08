# 107. Split battle out of mruby-rpg2k's compiled bytecode for wio

Date: 2026-09-08

## Status

Accepted

## Context

Per-mrbgem measurement (a real per-file `mrbc` compile, not a guess) showed
`mruby-rpg2k`'s own bytecode dominates what's left of the Wio Terminal's
flash overflow — `game.rb` and `scene/map.rb` together are ~60%. Battle,
though, is different from the rest: unlike party/map/menu code, a session
can run indefinitely — save/load, shopping, exploring, viewing status —
without ever starting a single fight. The real cost, split across two
places nothing until now had separated:

- `Game::Battle`, the headless combat model, was inline inside `game.rb`
  itself — at 4,413 lines the single largest class in the file, but not its
  own file, so it could not be excluded from a build's compiled bytecode
  the way `docs/adr/0097`'s debug-tools trim already excludes
  `debug_menu.rb`/etc.
- `scene/battle.rb` and `scene/battle_rpg2k3.rb`, the turn-based and
  RPG2003 active-time battle scenes, already were their own files.

A real per-file `mrbc` compile of all three together: **180,368 bytes** —
a sixth of the board's entire 496 KB flash budget, for code most of a given
play session never reaches.

## Decision

**`Game::Battle` moved into its own file**, `mruby-rpg2k/mrblib/game/battle.rb`
— a pure move (the same class body, reopening `module Game`), so it can be
named in `spec.rbfiles` the same way `scene/battle.rb` already can be.
Every script that `load`s `game.rb` directly (CRuby-side check scripts —
`rpg2k_scene_check.rb`, `rpg2k_logic_check.rb`, `rpg2k_render_check.rb`,
`rpg2k_save_load_check.rb`, `rpg2k3_battle_row_check.rb`,
`rpg2k3_battle_gauge_check.rb`) needed a matching `load` for the new file
added right after — a plain `load` has no notion of `require`'s automatic
file discovery the way mruby's own `Dir.glob("mrblib/**/*.rb")` gem-file
list already does.

**Two real, load-bearing dependencies on `Game::Battle` from outside
battle's own files**, found by grepping for every non-comment reference
before assuming the split was safe:

- `Scene::Base.battle_scene_class` reads `RPG2k3::Scene::Battle` — already
  safe by its own existing design (its own comment: "Referenced at call
  time (not load time)"), since it only runs immediately before a fight
  actually starts.
- `Game::Party#toggle_actor_row` (the field-menu Row command,
  `scene/menu.rb`) and `Scene::StatusMenu#draw_battle_row` (the status
  panel's row indicator) both read `Battle::ROW_FRONT`/`ROW_BACK` —
  genuinely reachable from ordinary field-menu use, no battle required at
  all, unlike the call-time-only reference above.

Fixed by giving `ROW_FRONT`/`ROW_BACK` a real, always-loaded home:
`Game::Actor` (which already needed them for its own `#battle_row=`, an
existing forward reference that only worked because Ruby resolves
constants at call time, not method-definition time). `Game::Battle` keeps
its own `ROW_FRONT`/`ROW_BACK` too, now aliases (`Actor::ROW_FRONT`) rather
than the definition, so its own ~15 existing bare-name call sites needed no
changes at all. `Game::Party#toggle_actor_row` and
`Scene::StatusMenu#draw_battle_row` now read `Actor::ROW_FRONT`/`ROW_BACK`
directly instead.

**Excluded from the wio build's compiled bytecode** (`mruby-rpg2k/mrbgem.rake`),
*wio-only*, deliberately not grouped with the existing `%w[psp wio]`
debug-tools trim: PSP has real storage headroom this board does not, and —
unlike the debug tools, genuinely dead code on every target — dropping
these files here comes with no way to get them back yet. No runtime loader
reads bytecode from the SD card the way ADR 0007's still-unbuilt P3
asset-streaming work would need to, so **a wio build with this exclusion
cannot actually start a fight today**. This trim proves the split is real
and measures its actual cost; it is not a claim that battle is done as a
wio feature.

### What was measured

Real per-file `mrbc` compiles (unoptimized, so nothing is silently
dead-stripped before measuring):

| file | bytes |
| --- | --- |
| `Game::Battle` (extracted, standalone compile) | 81,230 |
| `scene/battle.rb` | 92,976 |
| `scene/battle_rpg2k3.rb` | 6,162 |
| **Total** | **180,368** |

Real relink, `env:wio_rgss_boot`, on top of ADR 106's own state:

| state | FLASH overflow | RAM overflow |
| --- | --- | --- |
| ADR 106 (sections + font trim + NFD skip) | 1,248,724 | 17,576 |
| + battle bytecode excluded | 1,111,092 | **0 — fits** |

**137,632 bytes of flash recovered, and RAM now fits inside its 192 KB
budget entirely** (previously 17,576 bytes over) — a bonus this trim was
not specifically aimed at, from `Game::Battle`'s own static data going
with it.

Verified behavior-neutral on every target this split does *not* exclude
battle from: full `ctest` suite (10/10), and the real correctness scripts
that exercise battle specifically — `rpg2k3_battle_row_check.rb` (19
checks), `rpg2k3_battle_gauge_check.rb` (15 checks),
`rpg2k3_battle_command_check.rb`, `rpg2k_scene_check.rb` (1,062 checks,
including a real fight), `rpg2k_logic_check.rb` (1,201 checks) and
`rpg2k_render_check.rb` (41 checks) — all pass unchanged after the
`Game::Battle` move and the `ROW_FRONT`/`ROW_BACK` refactor.

### What still does not exist

- **No runtime path to actually load battle back in on wio.** This is the
  real remaining gap, not a footnote: until ADR 0007's P3 SD-backed asset
  streaming exists, a wio build carrying this exclusion is missing a whole
  feature, not merely trimmed. The natural shape of the fix — compile these
  same three files into a standalone `.mrb` (RITE binary), ship it beside a
  game's exported data on the SD card, `mrb_load_irep_buf` it the first
  time `Scene::Base.battle_scene_class` (or wherever a fight is actually
  triggered) needs it — is understood, but unimplemented and untestable
  without that pipeline.
- The firmware still does not fit — 1,111,092 bytes over flash, still
  ~2.2x the budget. `game.rb`'s remaining bulk (its own data model minus
  Battle) and `scene/map.rb` are now the largest single levers left.

## Consequences

- `Game::Battle` living in its own file is a real, permanent structural
  improvement independent of wio: it is now excludable, greppable, and
  sized the same way every other scene file already was.
- `ROW_FRONT`/`ROW_BACK` living on `Game::Actor` rather than `Game::Battle`
  is the more correct home regardless of wio — they are actor state that
  outlives any single fight (persisted across saves, read by the field
  menu), not battle-scoped data, so this was arguably a pre-existing
  layering issue this split surfaced and fixed as a side effect.
- Any future contributor extending `Game::Party`/`Scene::StatusMenu`/
  `Scene::Menu` on a wio-targeted change should remember battle is not
  unconditionally available there anymore — check `defined?(Game::Battle)`
  or equivalent before adding a new bare reference, the same discipline
  `Scene::Base.battle_scene_class`'s own existing call-time-only design
  already models.
