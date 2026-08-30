# 48. Building the battle-command menu from RPG2003's own customization

Date: 2026-08-15

## Status

Accepted — the open chunk-29 test-bed validation follow-up is now closed
(2026-08-17, see the Consequences below).

## Context

`Scene::Map#battle_commands` always drew the fixed Attack/Skill/Defend/Item
four for every actor's turn. RPG2003 lets a project replace that per actor or
class (Database > Battle Commands, and the Change Battle Commands (1009)
event command at runtime) — `Game::Actor#battle_commands` /
`#change_battle_commands` already modelled the resulting id list (field 80,
seven slots padded with `-1`, `0` standing for Row), but nothing in the menu
ever read it.

A positive id in that list is not itself a command type — it is a **1-based
reference into a separate, database-wide "Battle Commands" table**, one
`{name, type}` entry per row (`type` one of Attack/Skill/Subskill/
Defense/Item/Escape/Special). That table is chunk `0x1D` (29) on the LDB
`Database` struct; nothing in `mruby-lcf/mrblib/schema.rb` decoded it, so
there was no way to turn a customized id list into real labels or actions at
all, only the already-established special cases `0` (Row) and `-1` (empty
slot).

This project's schema is normally sourced from the VIPRPG 200X analysis wiki
(`schema.rb`'s own header) and, for the LSD save format's undocumented
chunks, from empirical byte-diffing against real saves (AGENTS.md's "LCF save
data" section, ADR 0009/0011). Chunk 29 has no page on that wiki and no test
game close at hand to diff against here. Its field/enum ids are instead
transcribed from liblcf's own `generator/csv/{fields,enums}.csv` — the
reference C++ implementation's declared format, not a byte-level guess — and
 checked against a hand-built synthetic blob the same way every other chunk in
 `mruby-lcf/test/lcf_test.rb` is (`db.battlecommands.commands[id].name/.type`).
It
has **now** been validated against the real 2k3 test bed (mtf-meido-action)
the way `lcf_testbed_check.rb` validates the rest of the 2003-specific schema
— the "customized test-bed database" that was outstanding at the ADR's writing
is mtf-meido-action itself, whose database-wide list carries twelve commands
and whose actors/classes reference them (see the Consequences below).

## Decision

- **`mruby-lcf/mrblib/schema.rb`** gains chunk 29 (`battlecommands`): a
  singleton struct whose field 10 (`commands`) is the `Array2D` of entries,
  each with `name` (string) and `type` (int — `enums:` is documentation only
  here, matching every other enum field in this schema; callers compare the
  raw int).
- **`Game::Actor#battle_command_row(id)`** (`game.rb`) resolves a positive
  `battle_commands` id through `@db.battlecommands.commands[id]`, guarded by
  the same `@db.respond_to?(:x) ? @db.x : nil` idiom the rest of `Game::Actor`
  already uses for optional database sections — nil for an RPG2000 database,
  a fixture without chunk 29, or an id the table doesn't define.
- **`Scene::Map#custom_battle_commands(actor)`** (`scene/map.rb`) walks
  `actor.battle_commands`, skipping `0`/`-1`/unresolvable refs, and turns
  each resolved entry into a `{ label:, action: }` row for the five types
  this engine actually drives (Attack, Skill — Subskill folds into the same
  Skill submenu, there being no single-skill quick-cast modelled — Defense,
  Item, Special). Special is the RPG2003 "does nothing this turn" command —
  ported from a reference implementation's do-nothing battle algorithm, not
  independently confirmed against genuine RPG_RT under wine: it is offered as
  a row and
  `#select_battle_command` forfeits the actor's turn, spending it (and, in a
  gauge battle, the charge) with no action. Escape (already offered as Cancel
  on the first actor) is skipped, the same "reported gap,
  not silently invented" precedent the rest of this file already follows for
  unmodelled RPG2003 features. A list with nothing usable in it — no data at
  all, which reads back as `[0]`, Row alone, same as
  `Game::Actor#class_battle_commands`'s own default — or every entry
  unsupported, returns nil so the caller falls back to the fixed four.
- **`Scene::Map#battle_command_rows`** is the single source both
  `#battle_commands` (labels) and `#select_battle_command` (dispatch) read,
  so a reordered or shortened list still routes the highlighted row to the
  right handler by its own `action` rather than a fixed row index.

## Consequences

An actor with a real RPG2003 customization now sees it in battle instead of
always the fixed four, and a reordered/shortened list dispatches correctly at
whatever row it lands on. A database that never decoded/wrote chunk 29 (every
RPG2000 file, and any fixture built before this change) is unaffected —
`battle_command_row` returns nil for every id, so `custom_battle_commands`
always returns nil and the fixed four still draws exactly as before.

Chunk 29's structural correctness rested on liblcf's own declared format plus
a synthetic round-trip test, not a real save/database byte-diff — the weaker
of the two forms of evidence this project otherwise insists on for LCF
chunks. **That gap is now closed (2026-08-17).** The customized test bed the
ADR was waiting for turned out to be the engine's existing RPG2003 test bed,
mtf-meido-action: its database-wide Battle Commands list carries twelve
commands whose types span the whole 0–6 range (Attack/Defend/Item/Escape and
the skill/subskill rows — Holy Magic, Magic, Special, Ninpou, Nature,
Atmosphere), `placement` 1 (automatic) and `battle_type` 2 (gauge); and its
actors and classes reference them through their own `battle_commands` — all
eighteen classes name a command, while the actor table is mostly the empty
all-`-1` state with only actor 1 carrying a real list (a genuine edge case: no
assertion may require an actor to have one). `lcf_testbed_check.rb` now proves
the real 2003 bytes the way it already does for the Classes (chunk 30) table:
the list is present with a non-empty `commands` field, every positive reference
in any actor's or class's `battle_commands` names a command in that list (0
Row and -1 empty slot are caller-handled sentinels and correctly name no entry),
and an RPG2000 database (Nepheshel) never carries the list at all.

Covered by `mruby-lcf/test/lcf_test.rb` (chunk 29 decode), new
`scripts/rpg2k_logic_check.rb` checks (`battle_command_row` resolving a real
entry, an undefined id, and a database with no chunk 29 at all), new
`scripts/rpg2k_scene_check.rb` checks (a skill-only customized list; a
shortened, reordered Item/Defense list drawing and dispatching in its own
order; Row alone falling back to the fixed four), `scripts/rpg2k3_battle_
command_check.rb` (the chunk's top-level decode against mtf), and — since the
cross-reference was what the synthetic test could not express — the new
`check_battlecommands` pass in `scripts/lcf_testbed_check.rb` described above.
