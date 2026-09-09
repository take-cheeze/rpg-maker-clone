# 128. Drop the RPG_RT-interop (.lsd) save/load path for wio

Date: 2026-09-09

## Status

Accepted

## Context

Asked how much of the "save/load" feature is really just `Game::State#
to_lsd`/`.from_lsd`: it turns out to be a majority (55%) but not all of it.
A real per-method byte audit (`mrbc`'s own RITE serialization, this
session's `irepsize` tool) of `mruby-rpg2k/mrblib/game.rb` found four
distinct pieces:

1. `to_lsd`/`from_lsd` plus their exclusive helpers (`tile_replacement_*`,
   `build/read_event_exec_*`, `bgm/se_chunk`, `restore_pictures`,
   `ole_now`, `bgm/se_from_chunk`) -- 23,099 bytes.
2. `Game::State#to_h`/`.load` -- 4,815 bytes.
3. Per-class `to_h`/`load_h` pairs already living inside classes the game
   needs regardless of saving at all (`Party`, `Screen`, `Picture`,
   `Weather`, `Vehicle`, `Timer`, `MessageConfig`, `Switches`,
   `Variables`) -- 4,602 bytes.
4. `main.rb`'s save orchestration (`save_game`/`load_save_state`/
   `export_lsd`/`save_exists?`/`any_save_exists?`/`save_path`/`lsd_path`)
   -- 1,778 bytes.
5. `scene/save_load.rb`, the whole Save/Load/Continue UI scene -- 7,557
   bytes.

Reading `main.rb`'s own `#save_game` comment settled which piece is
actually load-bearing: "Our own portable Marshal dump is the authoritative
save... Alongside it we also export a near-parity editor Save<slot>.lsd...
The export is best-effort." `Game::State#to_h`/`.load` (piece 2) is the
real save/continue mechanism; `to_lsd`/`from_lsd` (piece 1) only exists so
a save this game writes can round-trip through real RPG_RT or other
RPG2000/2003 editor tooling on a PC -- `from_lsd` is a *fallback* path for
loading a save that never went through this game's own Marshal format in
the first place (a genuine editor `.lsd` dropped straight into the save
directory). Neither is required for Save/Continue to work at all.

Wio has no PC to hand a save file to and no editor tooling of its own to
receive one from, so that interop -- piece 1, the largest single piece --
has no realistic audience there. Pieces 2-5 stay: they *are* Save/Continue
itself (or, for piece 3, bolted onto classes the live game already needs).

## Decision

Split `to_lsd`/`from_lsd` and their nine exclusive helper methods out of
`mrblib/game.rb` into a new file, `mrblib/game/lsd_io.rb` (reopening
`Game::State`, the same split-and-exclude shape ADR 0124 already used for
`game/battle_support.rb`), and excluded that one file for `build.name ==
'wio'` in `mrbgem.rake` -- psp keeps it (real flash/storage headroom, and
a real editor-facing interop use there is at least plausible, the same
distinction ADR 0125/0127 already draw between the two boards).

`main.rb`'s two call sites now guard against the methods not existing:

- `export_lsd` returns immediately unless `state.respond_to?(:to_lsd)`,
  rather than relying on its own existing `rescue StandardError` to
  swallow a `NoMethodError` every single save (that would have worked,
  but wastes the call attempt and logs a spurious "export failed" line
  every save on a target where this is permanent, not exceptional, state).
- `load_save_state`'s `.lsd`-fallback branch is gated on
  `Game::State.respond_to?(:from_lsd)` the same way, so a genuine editor
  `.lsd` dropped into a wio save directory with no Marshal save alongside
  it degrades to "no save there" instead of a rescued exception.

Every other real call site was checked (grep, repo-wide, non-comment
matches only): none exist outside `game.rb`/`game/lsd_io.rb`/`main.rb`.
`interpreter.rb`/`scene/map.rb` only *mention* `to_lsd`/`from_lsd` in
comments explaining where a given field's semantics come from -- no code
coupling to update.

### What was verified

- Both new/edited files pass `mrbc -c` syntax check.
- The moved code is byte-for-byte identical content (diffed directly
  against the pre-move file): the only differences are the new file's
  `module Game; class State; ... end; end` wrapper and one blank-line
  collapse where the cut closed a double blank.
- **Real, whole-gem-level measurement**, not just an isolated-method
  estimate: compiled `mruby-rpg2k`'s exact wio-shaped `rbfiles` list (all
  14 files `mrbgem.rake`'s existing exclusions leave, reproduced here by
  running its own filter logic) with `mrbc --remove-lv` (matching this
  board's real compile flags, ADR 0115/0117) twice -- once with
  `game/lsd_io.rb` included, once without:

  | | bytes |
  | --- | --- |
  | with `lsd_io.rb` (today, pre-ADR) | 501,580 |
  | without (this ADR) | 477,860 |
  | **difference** | **23,720** |

  Consistent with the 23,099-byte per-method estimate above; the small
  gap is the extra per-file top-level scope `lsd_io.rb` costs as its own
  compiled unit, the same small, already-accepted overhead ADR 0124's
  `battle_support.rb` split carries.
- Confirmed (repo-wide grep) no other real call site of `to_lsd`/
  `from_lsd` exists.
- No mrbtest coverage exercises `to_lsd`/`from_lsd` at all (checked;
  `mruby-rpg2k/test` has zero references), so this move changes no test
  surface either way.

### What was not verified

- **No real `MRUBY_TARGET=wio rake` build.** Attempted; blocked by an
  unrelated sandbox gap (`mruby-lcf`'s own `cp932_to_unicode.rb`
  build-time codegen needs a `cp932_table` env var pointing at a CP932
  mapping file this sandbox does not have -- unrelated to this change,
  the same class of external-tool gap prior ADRs in this series have hit
  for a full firmware link). The whole-gem `mrbc` compile above is the
  strongest verification available without it, and is real (the actual
  wio `rbfiles` list, the actual compile flags), just not a full linked
  firmware.
- No full desktop/psp/wasm/android rebuild; trusted on the byte-for-byte
  moved content and the fact that non-wio builds still compile every file
  (game.rb + lsd_io.rb together, unchanged rbfiles list) unchanged.

## Consequences

- A real ~23.7KB flash win for wio, at the cost of a real feature: a Wio
  Terminal save can no longer be opened by real RPG_RT/editor tooling on
  a PC, and a genuine PC-written `.lsd` dropped into the save directory
  with no Marshal save alongside it can no longer be loaded there either.
  Save/Continue itself is unaffected -- `Game::State#to_h`/`.load` never
  depended on either method.
- psp/desktop/wasm/android keep full interop unchanged.
- Still small next to ADR 0108's own finding: even with *all* of
  mruby-rpg2k's Ruby removed, wio overflows its flash budget by 510,340
  bytes. This lever, and the ~18KB terminal-encoder lever (ADR 0127)
  before it, chip at that floor; neither is close to closing it alone.
