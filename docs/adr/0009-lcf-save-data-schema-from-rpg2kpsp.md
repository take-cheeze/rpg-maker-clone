# 9. Fill LCF save-data schema gaps from the rpg2kpsp wiki

Date: 2026-08-03

## Status

Accepted

## Context

`mruby-lcf/mrblib/schema.rb` describes the on-disk `Save<N>.lsd` (`LcfSaveData`)
layout used to persist a running game. Until now the top-level `Save` section
only decoded five chunks — the file-select title (100), the system snapshot
(101) and the hero / boat / ship / airship positions (104–107). The database
and map schemas were transcribed from the "200X共通 解析まとめ" notes (ADR
0002 / 0008), but the save file was left comparatively bare.

The PSP RPG Maker 2000 emulator wiki maintained by this project's author
(<https://w.atwiki.jp/rpg2kpsp/>, entry point <https://w.atwiki.jp/rpg2kpsp/pages/1.html>)
is primarily a reverse-engineering of the save format. Its
[セーブデータ](https://w.atwiki.jp/rpg2kpsp/pages/13.html) page lays out the full
`LcfSaveData` chunk map, with dedicated pages for the individual sections. Four
of those sections were confidently documented but missing from our schema:

- **103** [ピクチャ情報](https://w.atwiki.jp/rpg2kpsp/pages/21.html) — show-picture state.
- **108** [主人公たちのステータス](https://w.atwiki.jp/rpg2kpsp/pages/40.html) — saved party-member status.
- **110** [テレポート情報](https://w.atwiki.jp/rpg2kpsp/pages/37.html) — remembered teleport/escape targets.
- **111** [イベント情報](https://w.atwiki.jp/rpg2kpsp/pages/27.html) — saved map-event state.

## Decision

Transcribe those four sections into `schema.rb` as new element hashes
(`SAVE_PICTURE`, `SAVE_PARTY_ACTOR`, `SAVE_TARGET`, `SAVE_MAP_EVENT`) and wire
them into `SAVE_DATA` at chunks 103, 108, 110 and 111, deriving field names from
the wiki's Japanese labels. Specifically:

- `SAVE_TARGET` (110) is an `Array2D` indexed by map id (index 0 = escape) with
  the map id, x, y, and the optional "switch on after teleport" flag/id.
- `SAVE_MAP_EVENT` (111) reuses the existing `SAVE_MOVABLE` layout for its
  per-event position list (chunk 11) — the wiki notes an event entry simply
  omits the map-id chunk the hero/vehicle entries carry — plus the two packed
  tile-replacement blobs (chunks 21/22, `uint8[144]`).
- `SAVE_PICTURE` (103) and `SAVE_PARTY_ACTOR` (108) only transcribe the fields
  the wiki actually labels; their undocumented `double` coordinate slots and the
  party member's stat/equipment block (catalogued in sue445's analysis, not this
  wiki) are intentionally left out.

Sections the wiki still marks unanalysed — chunk 109 (party/item info, described
inconsistently across pages) and chunk 114 (common-event state) — are omitted
until their layout is known, matching ADR 0002's policy of documenting only what
the source spells out.

The overlapping sections the wiki also covers (system, terminology, and the
event/hero/vehicle position layout) were **not** changed: our copies, sourced
from the 200X notes, are already as complete or more so, and the wiki's own
author flags the position fields (chunks 21/22, 31–38) as uncertain, so they are
not a safe source to overwrite the existing labels.

## Consequences

- Reading save pictures, remembered teleport targets and saved map-event state
  now works through the existing `Array1D`/`Array2D` accessors. Verified by a new
  `LCF::SaveData` unit test in `mruby-lcf/test/lcf_test.rb` and by loading the
  schema under CRuby with synthetic blobs.
- The packed tile-replacement and party-state arrays use the established
  `:int8_array` / `:int16_array` placeholder types, so the layout is documented
  even though the reader does not materialise those vectors yet.
- No real `.lsd` fixture is bundled, so these sections — like the class and
  battle-animation-2 sections in ADR 0002 — return `nil` when absent and were
  exercised only against synthetic data.
