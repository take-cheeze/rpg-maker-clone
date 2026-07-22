# 2. Populate LCF database schema fields from the 200X analysis notes

Date: 2026-07-22

## Status

Accepted

## Context

`mruby-lcf/mrblib/schema.rb` describes the on-disk layout of the RPG Maker
2000/2003 `RPG_RT.ldb` (`LcfDataBase`) and `RPG_RT.lmt` (`LcfMapTree`) files as a
declarative chunk-ID → field map consumed by the reader in
`mruby-lcf/mrblib/lcf.rb`.

Most database sections were stubbed with empty `elements: {}` — only the actor,
chipset, terminology and system sections had any fields, and even those were
partial. Several top-level `DataBase` chunk IDs were also placeholder guesses:
common events were mapped to chunks 26–29 (with four duplicate entries), classes
to a `BattleCommand`/dual-`Job` block at 30–32, and battle-animation-2 to 33.

The community "200X共通 解析まとめ" analysis notes
(<https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81>)
document the full chunk layout for every section. We want the schema to match
that spec so future features (battle system, items, skills, common events, …)
can read the data without re-deriving each layout.

## Decision

Transcribe the chunk IDs, types and defaults for every database section from the
analysis notes into `schema.rb`, deriving field names from the pages' Japanese
labels rather than importing any third-party engine's source. Specifically:

- Filled in `skill`, `item`, `enemy`, `enemy_group`, `terrain`, `property`
  (attributes), `situation` (states), `battle_anime`, `job` (classes), the full
  `term` and `system` sections, plus `switch`/`variable`.
- Corrected the top-level `DataBase` chunk IDs to the spec: common events at
  **25** (single section), classes at **30**, battle-animation-2 at **32**.
  Removed the duplicate 26–29 common-event entries and the 30/31/32
  `BattleCommand`/`Job` guesses.
- Corrected actor fields to the spec: chunk 22 is `equipment_fixed`, 23 is
  `force_ai`, added 24 `strong_defence`, and moved initial equipment to chunk 51
  (previously mislabelled at 44); added the 2003-only actor fields.
- Kept the two field names the running code already depends on
  (`system.title` / `system.system_graphic`) and the title-menu terms
  (`term.new_game` / `continue` / `shutdown`).
- Packed homogeneous arrays the reader does not decode yet (byte/short/int
  vectors, event command blobs) are annotated with descriptive placeholder types
  (`:int8_array` / `:int16_array` / `:int32_array` / `:event`), matching the
  pre-existing `:int16_array` convention, so the layout is documented without
  claiming the reader can materialise them.

## Consequences

- Reading actor/skill/item/enemy/terrain/state/attribute/animation/common-event
  data now works through the existing `Array1D`/`Array2D` accessors; verified by
  parsing the bundled Nepheshel `RPG_RT.ldb` and reading representative fields of
  every section.
- The reader still lacks support for the packed-array and event-command types;
  accessing those fields raises `Unsupported type`. Implementing them in
  `lcf.rb` is follow-up work.
- Class (`job`, chunk 30) and battle-animation-2 (chunk 32) support could not be
  exercised against real data because the bundled games are RPG2000 projects
  that omit those sections; the layouts follow the spec and return `nil` when the
  section is absent.
