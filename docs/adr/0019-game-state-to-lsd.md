# 19. Game::State#to_lsd: export the running game as a real Save<N>.lsd

Date: 2026-08-04

## Status

Accepted

## Context

ADR 0018 gave `mruby-lcf` a **write** path proven byte-exact against real saves,
and closed by noting the remaining step: a `Game::State#to_lsd` that builds a
`SAVE_DATA` structure from live game state and calls `SaveData#save_to`. This ADR
is that step.

The read path already exists: `Game::State.from_lsd(db, save)` loads a parsed
`.lsd` into the runtime, so **Continue** can resume a genuine editor save. It
restores exactly four chunks -- system (101: switches, variables, save_count),
hero position/facing (104), the per-actor level/exp/equipment/skills/HP/MP table
(108) and the party roster / gold / item bag (109). `to_lsd` must be its inverse:
write precisely those chunks, so a save we write is one our own reader restores
identically.

Two obstacles stood between the ADR 0018 serializer and `to_lsd`:

- **The writer could only *edit* a save parsed from bytes.** `Array1D#[]=` and the
  `to_lcf` family assume an object already built from a file. Building a save
  *from scratch* -- an empty root, empty chunks, an empty actor table -- had no
  constructor. `Array2D` had no `#[]=` at all.
- **Two field types a save needs were not encodable.** The actor table's
  `equipment` and `skills` (and the inventory's `item_ids`) are `:int16_array`,
  which `LCF.encode` did not handle; ADR 0018 only added the scalar and
  32-bit/8-bit/bool array encoders.

A third question was *policy*, not mechanism: should the in-game Save switch from
the portable `Marshal` dump to `.lsd`? It cannot, cleanly. The `Marshal` save
carries state the `SAVE_DATA` chunks we model here do not -- the timer, message
config, current/memorized BGM, actor name/title/sprite overrides, and the
menu/save/teleport/escape access flags. Making Continue load the `.lsd` would
silently drop all of that.

## Decision

- **`Game::State#to_lsd(save_count = 1)`** (`mruby-rpg2k/mrblib/game.rb`) builds an
  `LCF::SaveData` and populates chunks 101/104/108/109 as the exact inverse of
  `from_lsd`: switch/variable ids shift from 1-indexed in-game to 0-indexed in the
  save (unset entries default to `false`/`0`); each roster `Actor`'s level, exp,
  skills (+ skill count), equipment, HP and MP become a `SAVE_PARTY_ACTOR` entry
  keyed by actor id; the inventory chunk stores the roster, the sorted item ids
  with their counts, and gold. It returns the `SaveData`; the caller writes it
  with `#save_to`.
- **Make the `mruby-lcf` writer build from scratch.** `Array1D.new('', schema)`
  already yields an empty, writable object (the read loop breaks on EOF);
  `Array2D.new('', schema)` now does too (an empty string skips the entry-count
  read) and gains `Array2D#[]=` to store entries; `File.new` (hence
  `SaveData.new`) now accepts **no stream**, building an empty root of the
  schema's type. So a save is assembled purely through `#[]=` and serialized with
  the ADR 0018 `#to_lcf` / `#save_to`.
- **Add the `:int16_array` encoder.** `LCF.pack_int16` is the inverse of the
  reader's `unpack('s<*')`, built byte-wise (like `pack_int32`) so it does not
  depend on mruby-pack's endian-suffix *pack* support; `LCF.encode` gains an
  `:int16_array` branch.
- **Export alongside, do not replace.** `save_game` writes the authoritative
  `Marshal` save and then best-effort-exports `Save<slot>.lsd` via `to_lsd`
  (`export_lsd`); a failed export is logged, never fatal. `continue_game` now
  prefers our `Marshal` save and falls back to a `.lsd` only when there is none,
  so the full-fidelity save always wins for our own slots while a foreign editor
  save dropped into the game dir still resumes.

## Consequences

- **The save loop is closed at the runtime layer.** `Game::State` reads *and*
  writes genuine `.lsd`. `scripts/rpg2k_save_load_check.rb` now also asserts
  `state -> to_lsd -> from_lsd` preserves every modelled field (position, gold,
  items, roster, per-actor level/exp/HP/MP/equipment/skills, switches, variables)
  against the real Nepheshel (2000) and mtf-meido-action (2003) saves.
- **CI guard is the mruby unit tests.** Like ADR 0018, the real `.lsd` fixtures
  are not vendored, so the game-level round-trip runs on demand. The CI gate is
  `mruby-lcf/test/lcf_test.rb`, extended with the from-scratch path: `pack_int16`
  / `:int16_array` encoding, an `Array2D` built and populated via `#[]=`, and an
  empty `SaveData` built chunk by chunk and read straight back.
- **A deliberately lower-fidelity export.** The exported `.lsd` drops the fields
  listed in Context, so it is an interoperability artifact, not the primary save.
  Promoting `.lsd` to the primary save (and letting Continue prefer it) requires
  modelling those fields plus the title chunk (100, which needs `:double`
  timestamp encoding for the save-slot menu) -- tracked in `docs/TODO.md`.
- **mruby-core discipline carries forward.** The new code uses only methods the
  embedded mruby build provides (`+`/`== 0` for byte assembly and index tests,
  no `String#<<` or `Integer#zero?`), the constraint that ADR 0018's follow-up
  fix established; the unit tests run under the native `test` target that surfaces
  such gaps.
