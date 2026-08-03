# 10. Validate the LCF save-data schema against a real Save01.lsd

Date: 2026-08-03

## Status

Accepted

## Context

ADR 0009 transcribed the `LcfSaveData` (`Save<N>.lsd`) layout into
`mruby-lcf/mrblib/schema.rb` (`SAVE_DATA`) from the rpg2kpsp wiki, but noted a
gap: *"No real `.lsd` fixture is bundled, so these sections … were exercised
only against synthetic data."* Synthetic blobs are self-consistent by
construction, so they cannot catch a field whose declared type does not match
what a real engine actually writes — exactly the kind of surprise ADR 0002's
policy of "document only what the source spells out" is meant to surface.

`scripts/lcf_testbed_check.rb` already runs the parser over genuine editor
output for the database and maps; the save schema had no equivalent because a
save is produced by *playing* a game, not by shipping one.

## Decision

Generate a real save and validate the schema against it.

- **Produce the fixture by running a real game under wine.** The RPG Maker 2000
  game *Nepheshel* was driven under wine and saved in-game. The genuine
  `RPG_RT.exe` is impractical to automate headlessly (fullscreen DirectDraw
  fails under Xvfb with `DDERR_UNSUPPORTED`, and it runs unthrottled), so the
  save was written by **EasyRPG Player** (a 64-bit PE) under wine, which renders
  through SDL, is frame-limited, and emits byte-compatible `LcfSaveData`.
  `scripts/run-nepheshel-easyrpg-wine.bash` captures that setup. Nepheshel saves
  only at "Gates": the hero starts with a Gate Crystal, and inserting it at the
  town-entrance Gate (map 12) unlocks `SAVE`, writing `Save01.lsd`.
- **Add `scripts/lcf_save_check.rb`.** Mirroring the test-bed checker, it loads
  the mruby/CRuby-common parser over a `Save<N>.lsd`, verifies the header, lists
  every top-level chunk (flagging documented vs. undocumented ones), recursively
  reads every declared field of the documented sections, and prints a summary.
- **Fix the reader bugs the real data exposed** in `mruby-lcf/mrblib/lcf.rb`:
  - `:bool_array` (chunk 32 switches) and `:double` (chunk 100 timestamp) were
    used by the save schema but had no `to_rb` case — reading them raised
    `Unsupported type`. Added `:bool_array` (one byte per boolean) and `:double`
    (little-endian IEEE-754 via `unpack_double`).
  - The screen-transition fields (`SAVE_SYSTEM` chunks 111–116) were typed
    `:int` (BER) but a real save stores each as a single `0xff` byte, which is
    not valid BER (`read_ber` ran off the end, where `nil & 0x7f` collapses to
    `false` and raised a cryptic `TypeError`). Retyped them to a new scalar
    `:uint8` and made `read_ber` fail with a clear "truncated BER integer".
- A new `mruby-lcf/test/lcf_test.rb` case locks in the `:bool_array`,
  `:int32_array`, `:double` and `:uint8` decoders.

## Consequences

- The `SAVE_DATA` schema is now confirmed against genuine engine output: all ten
  documented top-level sections (100, 101, 103–108, 110, 111) are present and
  parse, and their values cross-check (hero on map 12 at the Gate tile, the
  entered name, `save_count`/`save_slot`, 543 switches / 1099 variables).
- The set of still-**undocumented** top-level chunks is now catalogued from real
  data: 102 (5 B), 109 (31 B, party/item info per ADR 0009), 112 (1 B), 113
  (353 B), 114 (6805 B, common-event state per ADR 0009) and 200 (5 B). They are
  left undocumented pending a source that spells out their layout, matching
  ADR 0002/0009 policy; `lcf_save_check.rb` reports them so the gap stays visible.
- No real `.lsd` is vendored — Nepheshel is downloaded, never redistributed
  (the same policy as the test-bed games). `lcf_save_check.rb`, like
  `lcf_testbed_check.rb`, therefore runs against a save the user generates via
  `run-nepheshel-easyrpg-wine.bash`.
