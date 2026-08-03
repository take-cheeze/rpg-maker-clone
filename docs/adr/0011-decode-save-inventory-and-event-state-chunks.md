# 11. Decode the save inventory and event-state chunks from a real .lsd

Date: 2026-08-03

## Status

Accepted

## Context

ADR 0010 validated the `LcfSaveData` schema against a real `Save01.lsd` and
catalogued the top-level chunks that were present but undocumented: 102, 109,
112, 113, 114 and 200. ADR 0009 had already flagged 109 ("party/item info") and
114 ("common-event state") as sections the rpg2kpsp wiki marks unanalysed, so
they were left out of `schema.rb`. With a real save in hand these can now be
identified empirically rather than left blank.

## Decision

Decode the chunks that a real save lets us confirm, proving each field against
data the game itself defines rather than guessing.

- **109 — inventory.** The chunk is an `Array1D`: gold at field `0x15` read back
  as `100`, matching the on-screen 100G. Its parallel arrays -- item ids
  (`int16`, field 12) and counts (one byte each, field 13) -- decoded to ids
  `[1, 451]` × `[3, 1]`; looking those ids up in the game's own `RPG_RT.ldb`
  gave 薬草 (item 1) and 導きの書 (item 451), exactly the two items still held
  after the gate crystal had been spent inserting it. Added `SAVE_INVENTORY`
  with `item_count`, `item_ids`, `item_counts`, `item_usage` and `gold`; the
  unconfirmed party-roster/counter fields are deliberately omitted.
- **114 — common-event state.** An `Array2D` indexed by common-event id (505
  entries in the save), each holding its interpreter execution state. Added
  `SAVE_COMMON_EVENT` with that state kept as an opaque `int8_array` blob, the
  same way `SAVE_MAP_EVENT` documents its tile-replacement blobs.
- **113 — foreground event state.** The map/parallel event that was mid-command
  when the game was saved. A save taken from an on-screen choice keeps that
  choice's option strings verbatim inside this blob (the SAVE / enter-gate /
  remove-crystal / do-nothing menu), which is how it was identified. Added
  `SAVE_FOREGROUND_EVENT`, likewise an opaque blob.
- `scripts/lcf_save_check.rb` now reports these as documented and prints the
  inventory (gold + item id×count); `mruby-lcf/test/lcf_test.rb` locks in the
  three decoders.

Chunks 102 (screen effects), 112 (a one-byte flag) and 200 (a non-standard
high-id extension chunk written by the runtime, not part of the canonical
RPG2000 layout) are still left undocumented until their fields can be confirmed
the same way.

## Consequences

- Three more top-level save sections are now readable through the normal
  accessors (`save.inventory.gold`, `save.common_events[id]`,
  `save.foreground_event`), and only 102/112/200 remain undocumented.
- The event-state blobs (113, 114) are documented at the section level but kept
  opaque: their inner interpreter grammar (execution frames, command stacks) is
  not yet expanded, so follow-up work can materialise it without changing the
  chunk map. Field meanings were proven by round-tripping real bytes against the
  game's database, matching ADR 0002's "document only what the source spells
  out" policy.
